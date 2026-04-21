import Foundation

/// Streams text-field values back from an LLM for a skill's first-turn fill
/// fields. The concrete implementation is responsible for prompting the LLM
/// in a format that yields discrete fields (the built-in Anthropic provider
/// uses `<fieldName>value</fieldName>` tagged text).
///
/// Runtime consumers push each delta into the surface's data model at
/// `/reply/<fieldName>`.
public protocol LLMProvider: Sendable {
    func streamFieldFill(
        systemPrompt: String,
        userMessage: String,
        history: [ChatMessage],
        fields: [(name: String, description: String)]
    ) -> AsyncThrowingStream<FieldFillDelta, Error>
}

/// One field update as text streams in.
///
/// `accumulatedValue` is the full value to-date; `chunkValue` is just the
/// incremental characters since the last delta for this field. `isFinal` is
/// true on the final delta for that field (when its closing tag was seen).
///
/// Consumers that use RFC Proposal 3's `append` patch op should forward
/// `chunkValue` with `patch: .append`. Consumers using v0.9 `set` semantics
/// can use `accumulatedValue`.
public struct FieldFillDelta: Sendable, Equatable {
    public let fieldName: String
    public let accumulatedValue: String
    public let chunkValue: String
    public let isFinal: Bool
    public init(fieldName: String, accumulatedValue: String, chunkValue: String, isFinal: Bool) {
        self.fieldName = fieldName
        self.accumulatedValue = accumulatedValue
        self.chunkValue = chunkValue
        self.isFinal = isFinal
    }
}

/// Minimal chat-history turn passed to the LLM. The runtime maintains this
/// in parallel with the UI transcript so the LLM sees prior context.
public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public let role: Role
    public let text: String
    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}
