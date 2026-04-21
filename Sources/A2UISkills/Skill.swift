import Foundation
import A2UI
import Yams

/// A parsed SKILL.md bundle. Skill authors author these as plain markdown
/// with a YAML frontmatter block; this struct holds the parsed form.
///
/// Frontmatter fields honored:
///   - `name` (required)
///   - `description` (required)
///   - `triggers` (optional, list of event names)
///   - `first_turn_skeleton.components` (optional, list of A2UI component dicts)
///   - `first_turn_fill_fields` (optional, ordered map of fieldName → description)
///
/// Markdown body (everything after `---`) becomes the system-prompt addendum
/// the runtime injects when this skill is active.
public struct Skill: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let triggers: [String]
    public let body: String

    /// If non-nil, the runtime emits these components into the surface
    /// immediately when this skill activates on a trigger event. Components
    /// have path bindings like `{path: "/reply/<field>"}` for each entry in
    /// `firstTurnFillFields`.
    public let firstTurnSkeleton: [JSONValue]?

    /// Ordered list of text slots Claude fills per first-turn. Each pair is
    /// (fieldName, descriptionInstructingTheLLM). The runtime wires these into
    /// the LLM prompt and streams values back into `/reply/<fieldName>`.
    public let firstTurnFillFields: [(name: String, description: String)]?

    public init(
        id: String,
        name: String,
        description: String,
        triggers: [String] = [],
        body: String = "",
        firstTurnSkeleton: [JSONValue]? = nil,
        firstTurnFillFields: [(name: String, description: String)]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.triggers = triggers
        self.body = body
        self.firstTurnSkeleton = firstTurnSkeleton
        self.firstTurnFillFields = firstTurnFillFields
    }
}

// MARK: - Parsing SKILL.md

extension Skill {
    /// Parse a SKILL.md document (YAML frontmatter + markdown body) into a Skill.
    /// `id` defaults to the frontmatter `name` if not provided.
    public static func parse(markdown: String, id: String? = nil) throws -> Skill {
        let (frontmatter, body) = splitFrontmatter(markdown)
        guard let frontmatter else {
            throw SkillParseError.missingFrontmatter
        }
        guard let root = try Yams.load(yaml: frontmatter) as? [String: Any] else {
            throw SkillParseError.frontmatterNotMapping
        }
        guard let name = root["name"] as? String else {
            throw SkillParseError.missingField("name")
        }
        guard let description = root["description"] as? String else {
            throw SkillParseError.missingField("description")
        }

        let triggers = (root["triggers"] as? [Any])?.compactMap { $0 as? String } ?? []

        var firstTurnSkeleton: [JSONValue]? = nil
        if let skeletonRoot = root["first_turn_skeleton"] as? [String: Any],
           let components = skeletonRoot["components"] as? [Any] {
            firstTurnSkeleton = components.compactMap(toJSONValue)
        }

        var firstTurnFillFields: [(name: String, description: String)]? = nil
        if let rawFields = root["first_turn_fill_fields"] as? [String: Any] {
            // Preserve order — Yams returns an unordered Dictionary; fall back
            // to alphabetical by key to give authors a predictable order.
            // Callers needing custom order should parse and re-sort themselves.
            firstTurnFillFields = rawFields.keys.sorted().compactMap { key in
                guard let spec = rawFields[key] else { return nil }
                if let dict = spec as? [String: Any], let d = dict["description"] as? String {
                    return (name: key, description: d)
                }
                if let s = spec as? String {
                    return (name: key, description: s)
                }
                return nil
            }
        }

        return Skill(
            id: id ?? name,
            name: name,
            description: description,
            triggers: triggers,
            body: body,
            firstTurnSkeleton: firstTurnSkeleton,
            firstTurnFillFields: firstTurnFillFields
        )
    }

    /// Load a SKILL.md from a bundle resource. `subdirectory` typically
    /// matches the skill-bundle folder name.
    public static func bundled(
        _ filename: String = "SKILL",
        in bundle: Bundle = .main,
        subdirectory: String? = nil
    ) throws -> Skill {
        guard let url = bundle.url(forResource: filename, withExtension: "md", subdirectory: subdirectory) else {
            throw SkillParseError.resourceNotFound(filename)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(markdown: text, id: subdirectory ?? filename)
    }
}

public enum SkillParseError: Error, CustomStringConvertible, Sendable {
    case missingFrontmatter
    case frontmatterNotMapping
    case missingField(String)
    case resourceNotFound(String)

    public var description: String {
        switch self {
        case .missingFrontmatter:
            return "SKILL.md must start with YAML frontmatter fenced by --- lines."
        case .frontmatterNotMapping:
            return "Frontmatter YAML must be a mapping at its top level."
        case .missingField(let f):
            return "Required frontmatter field missing: \(f)"
        case .resourceNotFound(let name):
            return "Could not find SKILL resource named \(name).md in the given bundle."
        }
    }
}

// Split `---\n...yaml...\n---\nbody` into (yaml, body). Returns (nil, original)
// if no fenced frontmatter.
func splitFrontmatter(_ text: String) -> (frontmatter: String?, body: String) {
    guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return (nil, text) }
    let afterOpen = text.dropFirst(text.hasPrefix("---\r\n") ? 5 : 4)
    // Find the closing ---\n or ---\r\n
    guard let closeRange = afterOpen.range(of: "\n---\n") ?? afterOpen.range(of: "\r\n---\r\n") else {
        return (nil, text)
    }
    let frontmatter = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
    let body = String(afterOpen[closeRange.upperBound...])
    return (frontmatter, body)
}

// Convert a YAML-decoded value (from Yams' Any tree) into a JSONValue.
func toJSONValue(_ any: Any) -> JSONValue? {
    if any is NSNull { return .null }
    if let b = any as? Bool { return .bool(b) }
    if let i = any as? Int { return .number(Double(i)) }
    if let d = any as? Double { return .number(d) }
    if let s = any as? String { return .string(s) }
    if let a = any as? [Any] { return .array(a.compactMap(toJSONValue)) }
    if let o = any as? [String: Any] {
        var out: [String: JSONValue] = [:]
        for (k, v) in o { if let jv = toJSONValue(v) { out[k] = jv } }
        return .object(out)
    }
    return nil
}
