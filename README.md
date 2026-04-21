# a2ui-skills-swiftui

**Client-side A2UI skill runtime for Swift.** Load [SKILL.md](https://docs.anthropic.com/en/docs/agents-and-tools/agent-skills) bundles in your app, route user events, stream LLM-generated text into A2UI surfaces — no server required.

Companion library to [`a2ui-swiftui`](https://github.com/vpm238/a2ui-swiftui) (the renderer). Together they let you ship a Claude-Code-style client-side agent that renders native SwiftUI with Google's A2UI protocol.

## What this solves

A2UI specifies how an agent describes UI. It doesn't specify *where* the agent runs, or how skills compose with A2UI surfaces. Today most A2UI implementations run a server-side agent: server parses skills, calls LLM, emits A2UI messages over WebSocket. That's one valid architecture — but it requires standing up a server, managing state, hiding API keys, etc.

This library ships the **client-side alternative**:

- Skills live as bundled `SKILL.md` strings (or files) in your app
- Event routing is local — no round-trip to pick the next turn
- LLM calls go directly from the client (via `AnthropicLLMProvider`) or through a thin proxy server (bring your own)
- A2UI messages are synthesized locally into a `SurfaceState`; `A2UISurfaceView` from `a2ui-swiftui` renders them natively
- **Skeleton-first rendering**: skills declare a first-turn structure that renders instantly; the LLM only fills text. Much faster perceived latency.

Matches the pattern Claude Code pioneered, extended with A2UI's portable UI layer.

## Install

Add to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/vpm238/a2ui-swiftui",        from: "0.1.0"),
    .package(url: "https://github.com/vpm238/a2ui-skills-swiftui", from: "0.1.0"),
]
```

Targets:
```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "A2UI",        package: "a2ui-swiftui"),
        .product(name: "A2UISkills",  package: "a2ui-skills-swiftui"),
    ]
)
```

## Quickstart

```swift
import A2UI
import A2UISkills

// Parse skills. Can be bundled strings, files, or downloaded.
let greeting = try Skill.parse(markdown: greetingSkillMd, id: "greeting")
let advisor  = try Skill.parse(markdown: advisorSkillMd,  id: "advisor")

// Pick an LLM backend.
let llm = AnthropicLLMProvider(apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!)

// Runtime orchestrates skills + LLM + surface state.
let runtime = SkillRuntime(
    skills: [greeting, advisor],
    defaultSkillId: "greeting",
    llm: llm
)

// Emit the greeting on app start.
runtime.primeGreeting()

// Render with a2ui-swiftui's A2UISurfaceView, reading from `runtime.surfaces`.
// When the user taps an option in a rendered surface, forward it:
runtime.handleUserEvent(name: "want_plan", context: [:], echoLabel: "Make a plan")

// Free-text composer:
runtime.handleUserText("help me think through a career move")
```

## Anatomy of a SKILL.md

```markdown
---
name: advisor
description: General-purpose advisor. Routes on three greeting options.
triggers:
  - want_plan
  - want_decision
  - want_feedback
first_turn_skeleton:
  components:
    - id: rec
      component: RichMessageCard
      headline: { path: "/reply/headline" }
      rationale: { path: "/reply/rationale" }
      confirmAction:
        label: { path: "/reply/confirm_label" }
        event: { name: { path: "/reply/confirm_event" }, context: {} }
      dismissAction:
        label: { path: "/reply/dismiss_label" }
        event: { name: { path: "/reply/dismiss_event" }, context: {} }
    - id: root
      component: Column
      children: [rec]
first_turn_fill_fields:
  headline:
    description: ONE direct sentence — the headline of your take.
  rationale:
    description: 2-3 sentences explaining why.
  confirm_label:
    description: Short action-button text (≤5 words).
  confirm_event:
    description: Event name. One of show_plan, first_step, tradeoffs.
  dismiss_label:
    description: Alternative button text.
  dismiss_event:
    description: Usually `restart`.
---

# Advisor skill (markdown body becomes the system prompt addendum)

You are a direct, honest thinking partner. ...
```

The **skeleton** is the structural UI you want on screen in <100ms. Text fields bind to `/reply/<fieldName>` paths. The **fill_fields** are what the LLM writes — descriptions go into the LLM's instructions, accumulated values stream in via `updateDataModel` patches. See the [progressive-rendering RFC](https://github.com/vpm238/a2ui-progressive-rendering-rfc-rfc) for why this matters.

## LLM providers

Shipped:

- `AnthropicLLMProvider` — hits `https://api.anthropic.com/v1/messages` directly. Uses Server-Sent Events for streaming. Your app needs the API key.

Planned / easy to add:

- `ProxyLLMProvider` — POSTs to a server endpoint you own (for API-key safety). Add by implementing `LLMProvider`.
- `GeminiLLMProvider` — same protocol, different backend.

Conform to `LLMProvider` and you can plug any LLM:

```swift
struct MyLLMProvider: LLMProvider {
    func streamFieldFill(
        systemPrompt: String,
        userMessage: String,
        history: [ChatMessage],
        fields: [(name: String, description: String)]
    ) -> AsyncThrowingStream<FieldFillDelta, Error> {
        // ... your streaming logic, yield FieldFillDelta per field update ...
    }
}
```

## What's inside

| File | Purpose |
|---|---|
| `Skill.swift` | Parses `SKILL.md` (YAML frontmatter + markdown body) |
| `LLMProvider.swift` | Protocol + types for streaming field fills |
| `AnthropicLLMProvider.swift` | Anthropic Messages API via SSE |
| `FieldParser.swift` | Incrementally parses `<field>value</field>` tagged text into per-field deltas |
| `SkillRuntime.swift` | `@Observable` orchestrator: turns list, surface state, event routing, LLM calls |

## Compared to other A2UI integrations

| | Server-side (Google's ADK samples) | Client-side (this library) |
|---|---|---|
| Where skills run | Server | Client |
| Where LLM is called | Server | Client (direct) or server proxy |
| State of UI | Server keeps surface state | Client keeps surface state |
| Needs a server | Yes | No (optional proxy only) |
| API key security | Server-side | Needs key on device OR proxy |
| Latency pattern | WS round-trip per turn | Local decision, direct to LLM |
| Offline | Doesn't work | Stub fallbacks work; LLM calls degrade gracefully |

Both are valid. Use server-side for multi-user apps with shared state; use this for single-user agents, dev tools, or consumer apps where the device is the right place to run the logic.

## Dependencies

- [`a2ui-swiftui`](https://github.com/vpm238/a2ui-swiftui) — the renderer
- [`Yams`](https://github.com/jpsim/Yams) — YAML frontmatter parser

Requires Swift 6.0+, macOS 14+, iOS 17+, visionOS 1+.

## License

MIT. See [LICENSE](LICENSE).
