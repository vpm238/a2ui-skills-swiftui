import Foundation
import Observation
import A2UI

/// Client-side A2UI skill runtime.
///
/// Holds a set of skills, routes user events to the active skill, emits
/// skeleton components into a local `SurfaceState` immediately, then streams
/// text fill values from an `LLMProvider` into the surface's data model via
/// `updateDataModel`-style path patches.
///
/// No server required. Works identically whether the LLM is called directly
/// from the client (Anthropic / Gemini SDKs) or via a thin server proxy.
///
/// Usage:
///
///     let runtime = SkillRuntime(
///         skills: [try .parse(markdown: greetingMd), try .parse(markdown: triageMd)],
///         llm: AnthropicLLMProvider(apiKey: "sk-ant-…")
///     )
///     // In SwiftUI: observe runtime.turns and render each via A2UISurfaceView.
///     runtime.handleUserText("hello")
@Observable
@MainActor
public final class SkillRuntime {
    public private(set) var turns: [ChatTurn] = []
    public private(set) var surfaces: [String: SurfaceState] = [:]
    public private(set) var activeSkillId: String
    public private(set) var lastError: String?

    private let skillsById: [String: Skill]
    private let skillsByTrigger: [String: Skill]
    private let defaultSkillId: String
    private let llm: LLMProvider
    private let catalogReference: String

    private var surfaceCounter: Int = 0
    private var history: [ChatMessage] = []

    /// Create the runtime. `defaultSkillId` is the skill active on first user
    /// input; it's typically the greeting skill. `catalogReference` is
    /// appended to the LLM system prompt so the model knows what components
    /// exist — pass the library's default via `defaultA2UICatalogReference`.
    public init(
        skills: [Skill],
        defaultSkillId: String,
        llm: LLMProvider,
        catalogReference: String = defaultA2UICatalogReference
    ) {
        var byId: [String: Skill] = [:]
        var byTrigger: [String: Skill] = [:]
        for s in skills {
            byId[s.id] = s
            for t in s.triggers where byTrigger[t] == nil { byTrigger[t] = s }
        }
        precondition(byId[defaultSkillId] != nil, "default skill '\(defaultSkillId)' not in provided skills")
        self.skillsById = byId
        self.skillsByTrigger = byTrigger
        self.defaultSkillId = defaultSkillId
        self.activeSkillId = defaultSkillId
        self.llm = llm
        self.catalogReference = catalogReference
    }

    // MARK: - Greeting / initial surface

    /// Emit a skill's static greeting surface (if any) as the first agent
    /// turn. Typically called once on app start.
    public func primeGreeting() {
        let greeting = skillsById[defaultSkillId]
        guard let skeleton = greeting?.firstTurnSkeleton else { return }
        let sid = "greeting"
        let state = SurfaceState(id: sid)
        state.applyComponents(skeleton)
        surfaces[sid] = state
        turns.append(.agent(surfaceId: sid))
    }

    // MARK: - User input

    public func handleUserEvent(name: String, context: [String: JSONValue] = [:], echoLabel: String? = nil) {
        if let label = echoLabel {
            turns.append(.userPill(label: label))
        }
        let prompt = describeUserTap(name: name, context: context)
        Task { await processTurn(userMessage: prompt, eventName: name) }
    }

    public func handleUserText(_ text: String) {
        turns.append(.user(text: text))
        Task { await processTurn(userMessage: text, eventName: nil) }
    }

    // MARK: - Core turn processing

    private func processTurn(userMessage: String, eventName: String?) async {
        // Route: if this event matches a trigger, switch active skill.
        if let en = eventName, let target = skillsByTrigger[en] {
            activeSkillId = target.id
        } else if eventName == "restart" {
            activeSkillId = defaultSkillId
        }

        guard let skill = skillsById[activeSkillId] else { return }

        surfaceCounter += 1
        let sid = "msg_\(surfaceCounter)"

        // Append a thinking turn that will be replaced when the skeleton lands.
        turns.append(.thinking(id: "t_\(surfaceCounter)"))

        // Fast path: skill declares first-turn skeleton. Emit it instantly,
        // then stream text fills.
        if let skeleton = skill.firstTurnSkeleton,
           let fillFields = skill.firstTurnFillFields,
           eventName == nil || skill.triggers.contains(eventName ?? "")
        {
            let state = SurfaceState(id: sid)
            state.applyComponents(skeleton)
            surfaces[sid] = state
            replaceThinkingWithAgent(surfaceId: sid)
            await streamFill(
                skill: skill,
                surface: state,
                userMessage: userMessage,
                fields: fillFields
            )
            history.append(.init(role: .user, text: userMessage))
            return
        }

        // Fallback: free-form LLM response written into a single Text body.
        let state = SurfaceState(id: sid)
        let text: [String: JSONValue] = [
            "id": .string("hdr"),
            "component": .string("Text"),
            "text": .object(["path": .string("/reply/body")]),
            "variant": .string("body"),
        ]
        let column: [String: JSONValue] = [
            "id": .string("root"),
            "component": .string("Column"),
            "children": .array([.string("hdr")]),
        ]
        state.applyComponents([.object(text), .object(column)])
        surfaces[sid] = state
        replaceThinkingWithAgent(surfaceId: sid)
        await streamFill(
            skill: skill,
            surface: state,
            userMessage: userMessage,
            fields: [(name: "body", description: "A direct, helpful reply. Plain prose, no markdown.")]
        )
        history.append(.init(role: .user, text: userMessage))
    }

    private func streamFill(
        skill: Skill,
        surface: SurfaceState,
        userMessage: String,
        fields: [(name: String, description: String)]
    ) async {
        let system = assembleSystemPrompt(skill: skill)
        var finalValues: [String: String] = [:]
        do {
            for try await delta in llm.streamFieldFill(
                systemPrompt: system,
                userMessage: userMessage,
                history: history,
                fields: fields
            ) {
                // RFC Proposals 2 + 3: append-patch the chunk with streaming=true
                // while streaming, then flip streaming=false on the final delta.
                // Append saves ~50× wire bytes vs set-with-accumulated; the
                // streaming flag lets renderers show a typewriter caret.
                surface.applyDataModel(
                    path: "/reply/\(delta.fieldName)",
                    op: .append,
                    value: .string(delta.chunkValue),
                    streaming: !delta.isFinal
                )
                finalValues[delta.fieldName] = delta.accumulatedValue
            }
        } catch {
            lastError = error.localizedDescription
        }
        // Reconstruct a text summary for LLM history. Keeps subsequent turns
        // coherent without re-sending UI shapes.
        let historyText = finalValues.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        if !historyText.isEmpty {
            history.append(.init(role: .assistant, text: historyText))
        }
    }

    // MARK: - Turn helpers

    private func replaceThinkingWithAgent(surfaceId: String) {
        if let idx = turns.lastIndex(where: {
            if case .thinking = $0 { return true } else { return false }
        }) {
            turns[idx] = .agent(surfaceId: surfaceId)
        } else {
            turns.append(.agent(surfaceId: surfaceId))
        }
    }

    private func assembleSystemPrompt(skill: Skill) -> String {
        var parts: [String] = [catalogReference]
        if !skill.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("## ACTIVE SKILL INSTRUCTIONS (\(skill.name))\n\n\(skill.body.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return parts.joined(separator: "\n\n")
    }

    private func describeUserTap(name: String, context: [String: JSONValue]) -> String {
        if context.isEmpty {
            return "User tapped option: \(name)."
        }
        let ctx = (try? String(data: JSONEncoder().encode(context), encoding: .utf8)) ?? "{}"
        return "User tapped option: \(name) with context \(ctx)."
    }
}

/// Default catalog reference injected into the LLM system prompt. Describes
/// the components that ship with `A2UI` (the renderer library). Replace if
/// your app uses a custom catalog.
public let defaultA2UICatalogReference: String = """
You speak via the A2UI v0.9 protocol. When a skill's first-turn skeleton is
pre-rendered on the client, you ONLY write the text fill values for the
fields the skill declared — no JSON, no components, no extra commentary.

Available components (built-in A2UI catalog):
- Text  { text, variant: h1|h2|body|caption }
- Button { label, variant: primary|ghost|danger, action: { event: { name } } }
- Column { children[], gap? }
- Card   { title, child }
- OptionsGrid { prompt, options[] with label + rationale + emoji? + action }
- RichMessageCard { headline, rationale, recommendationType, confidence,
                    confirmAction, dismissAction }

Be specific. Be honest. Conversational. First person. No preamble.
"""
