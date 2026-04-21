import Foundation

/// Streams fill-field text from Anthropic's Messages API using Server-Sent
/// Events. Prompts the model to emit `<fieldName>...</fieldName>` tags, which
/// `FieldParser` turns into per-field deltas.
///
/// Minimal implementation — no tool use, no vision, no caching. Add as needed.
public struct AnthropicLLMProvider: LLMProvider {
    public let apiKey: String
    public let model: String
    public let maxTokens: Int
    public let endpoint: URL

    public init(
        apiKey: String,
        model: String = "claude-sonnet-4-5",
        maxTokens: Int = 1024,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.endpoint = endpoint
    }

    public func streamFieldFill(
        systemPrompt: String,
        userMessage: String,
        history: [ChatMessage],
        fields: [(name: String, description: String)]
    ) -> AsyncThrowingStream<FieldFillDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runStream(
                        systemPrompt: systemPrompt,
                        userMessage: userMessage,
                        history: history,
                        fields: fields,
                        yield: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        systemPrompt: String,
        userMessage: String,
        history: [ChatMessage],
        fields: [(name: String, description: String)],
        yield: @Sendable (FieldFillDelta) -> Void
    ) async throws {
        // Build the full system prompt with the tagged output template the
        // FieldParser expects. This matches the format the Python reference
        // uses in server/host/claude_brain.py.
        let tagTemplate = fields.map { "<\($0.name)>\($0.description.trimmingCharacters(in: .whitespacesAndNewlines))</\($0.name)>" }.joined(separator: "\n")
        let formatBlock = """


        ## RESPONSE FORMAT

        Output ONLY the XML-tagged response below, filled in. No preamble, no
        commentary, no markdown code fences. Tags in the exact order shown.

        \(tagTemplate)

        The descriptions above are INSTRUCTIONS for what to write inside each tag —
        replace them with your actual content.
        """
        let fullSystem = systemPrompt + formatBlock

        // Build messages: history + current user turn.
        var messages: [[String: Any]] = history.map { ["role": $0.role.rawValue, "content": $0.text] }
        messages.append(["role": "user", "content": userMessage])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": fullSystem,
            "messages": messages,
            "stream": true,
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.noHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.httpStatus(http.statusCode)
        }

        var parser = FieldParser(fieldNames: fields.map(\.name))

        // Anthropic SSE: lines are either `event: <type>`, `data: <json>`, or empty separators.
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let json = String(line.dropFirst(6))
            if json == "[DONE]" { break }
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            if type == "content_block_delta",
               let delta = obj["delta"] as? [String: Any],
               (delta["type"] as? String) == "text_delta",
               let text = delta["text"] as? String {
                for d in parser.feed(text) { yield(d) }
            } else if type == "message_stop" {
                break
            }
        }
        for d in parser.finish() { yield(d) }
    }
}

public enum LLMError: Error, CustomStringConvertible, Sendable {
    case noHTTPResponse
    case httpStatus(Int)

    public var description: String {
        switch self {
        case .noHTTPResponse: return "No HTTP response from LLM endpoint."
        case .httpStatus(let s): return "LLM endpoint returned HTTP \(s)."
        }
    }
}
