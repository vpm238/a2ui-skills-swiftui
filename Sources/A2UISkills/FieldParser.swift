import Foundation

/// Incremental XML-tag parser for `<fieldName>content</fieldName>` output
/// from an LLM. Call `feed(_:)` with each chunk of streamed text; it returns
/// zero or more `FieldFillDelta` updates.
///
/// Each delta carries both the accumulated-to-date value and just the new
/// chunk, so callers can use v0.9 `set` semantics or Proposal-3 `append`
/// semantics as appropriate.
///
/// Ported from the Python reference at
/// server/host/claude_brain.py#_FieldParser in the hairgrowthproducts stack.
struct FieldParser {
    private let fieldNames: Set<String>
    private var buffer: String = ""
    private var currentField: String?
    private var currentValue: String = ""
    private var lastEmittedValue: String = ""

    init(fieldNames: [String]) {
        self.fieldNames = Set(fieldNames)
    }

    mutating func feed(_ delta: String) -> [FieldFillDelta] {
        buffer.append(delta)
        var out: [FieldFillDelta] = []

        while true {
            if currentField == nil {
                guard let lt = buffer.firstIndex(of: "<") else {
                    buffer = ""
                    return out
                }
                guard let gt = buffer[lt...].firstIndex(of: ">") else {
                    buffer = String(buffer[lt...])
                    return out
                }
                let afterLt = buffer.index(after: lt)
                let tag = String(buffer[afterLt..<gt])
                let afterGt = buffer.index(after: gt)
                if fieldNames.contains(tag) {
                    currentField = tag
                    currentValue = ""
                    lastEmittedValue = ""
                    buffer = String(buffer[afterGt...])
                } else {
                    buffer = String(buffer[afterGt...])
                }
            } else {
                let closing = "</\(currentField!)>"
                if let closeRange = buffer.range(of: closing) {
                    currentValue.append(String(buffer[buffer.startIndex..<closeRange.lowerBound]))
                    if currentValue != lastEmittedValue {
                        let chunk = String(currentValue.dropFirst(lastEmittedValue.count))
                        out.append(FieldFillDelta(
                            fieldName: currentField!,
                            accumulatedValue: currentValue,
                            chunkValue: chunk,
                            isFinal: true
                        ))
                    } else {
                        // Emit a final-marker delta even if value hadn't changed.
                        out.append(FieldFillDelta(
                            fieldName: currentField!,
                            accumulatedValue: currentValue,
                            chunkValue: "",
                            isFinal: true
                        ))
                    }
                    buffer = String(buffer[closeRange.upperBound...])
                    currentField = nil
                    currentValue = ""
                    lastEmittedValue = ""
                    continue
                }
                // Minimal hold-back: only reserve trailing chars that could
                // be the *start* of the closing tag. Previously we held back
                // `closing.count - 1` chars unconditionally, which swallowed
                // real content when the tail wasn't actually tag-like.
                let maxHoldCheck = Swift.min(closing.count - 1, buffer.count)
                var hold = 0
                if maxHoldCheck > 0 {
                    for h in stride(from: maxHoldCheck, through: 1, by: -1) {
                        let suffix = String(buffer.suffix(h))
                        if closing.hasPrefix(suffix) { hold = h; break }
                    }
                }
                if buffer.count > hold {
                    let commitEnd = buffer.index(buffer.endIndex, offsetBy: -hold)
                    let commit = String(buffer[buffer.startIndex..<commitEnd])
                    currentValue.append(commit)
                    buffer = String(buffer[commitEnd...])
                    if currentValue != lastEmittedValue {
                        let chunk = String(currentValue.dropFirst(lastEmittedValue.count))
                        out.append(FieldFillDelta(
                            fieldName: currentField!,
                            accumulatedValue: currentValue,
                            chunkValue: chunk,
                            isFinal: false
                        ))
                        lastEmittedValue = currentValue
                    }
                }
                return out
            }
        }
    }

    mutating func finish() -> [FieldFillDelta] {
        var out: [FieldFillDelta] = []
        if let field = currentField {
            currentValue.append(buffer)
            if currentValue != lastEmittedValue {
                let chunk = String(currentValue.dropFirst(lastEmittedValue.count))
                out.append(FieldFillDelta(
                    fieldName: field,
                    accumulatedValue: currentValue,
                    chunkValue: chunk,
                    isFinal: true
                ))
            }
            currentField = nil
            buffer = ""
        }
        return out
    }
}
