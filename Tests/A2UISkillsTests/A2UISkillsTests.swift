import XCTest
@testable import A2UISkills

final class SkillParserTests: XCTestCase {
    func testParsesMinimalFrontmatter() throws {
        let md = """
        ---
        name: greeting
        description: A minimal skill for testing.
        ---

        Body text here.
        """
        let skill = try Skill.parse(markdown: md)
        XCTAssertEqual(skill.name, "greeting")
        XCTAssertEqual(skill.description, "A minimal skill for testing.")
        XCTAssertTrue(skill.body.contains("Body text here"))
        XCTAssertTrue(skill.triggers.isEmpty)
        XCTAssertNil(skill.firstTurnSkeleton)
        XCTAssertNil(skill.firstTurnFillFields)
    }

    func testParsesTriggersAndSkeleton() throws {
        let md = """
        ---
        name: triage
        description: Routes a triage turn.
        triggers:
          - user_said_a
          - user_said_b
        first_turn_skeleton:
          components:
            - id: rec
              component: RichMessageCard
              headline: {path: "/reply/headline"}
        first_turn_fill_fields:
          headline:
            description: One sentence.
        ---

        # Triage body
        """
        let skill = try Skill.parse(markdown: md)
        XCTAssertEqual(skill.triggers, ["user_said_a", "user_said_b"])
        XCTAssertNotNil(skill.firstTurnSkeleton)
        XCTAssertEqual(skill.firstTurnSkeleton?.count, 1)
        XCTAssertEqual(skill.firstTurnFillFields?.first?.name, "headline")
    }

    func testMissingFrontmatterThrows() throws {
        XCTAssertThrowsError(try Skill.parse(markdown: "no frontmatter here"))
    }
}

final class FieldParserTests: XCTestCase {
    func testExtractsSingleField() {
        var parser = FieldParser(fieldNames: ["headline"])
        let deltas = parser.feed("<headline>Hello world</headline>")
        XCTAssertEqual(deltas.last?.accumulatedValue, "Hello world")
        XCTAssertEqual(deltas.last?.isFinal, true)
    }

    func testAccumulatesPartialStream() {
        var parser = FieldParser(fieldNames: ["body"])
        _ = parser.feed("<body>The quick brown ")
        let middle = parser.feed("fox jumps")
        XCTAssertEqual(middle.last?.fieldName, "body")
        XCTAssertEqual(middle.last?.accumulatedValue, "The quick brown fox jumps")
        XCTAssertEqual(middle.last?.isFinal, false)
        let end = parser.feed(" over the lazy dog</body>")
        XCTAssertEqual(end.last?.accumulatedValue, "The quick brown fox jumps over the lazy dog")
        XCTAssertEqual(end.last?.isFinal, true)
    }

    func testHandlesTwoFields() {
        var parser = FieldParser(fieldNames: ["a", "b"])
        var all: [FieldFillDelta] = []
        all += parser.feed("<a>one</a><b>two</b>")
        all += parser.finish()
        XCTAssertTrue(all.contains(where: { $0.fieldName == "a" && $0.accumulatedValue == "one" }))
        XCTAssertTrue(all.contains(where: { $0.fieldName == "b" && $0.accumulatedValue == "two" }))
    }

    func testIgnoresUnknownTags() {
        var parser = FieldParser(fieldNames: ["keep"])
        let deltas = parser.feed("<skip>junk</skip><keep>yes</keep>")
        XCTAssertEqual(deltas.last?.fieldName, "keep")
        XCTAssertEqual(deltas.last?.accumulatedValue, "yes")
    }

    func testChunkValueIsDelta() {
        // Split a value across two feeds. chunkValue should be just the new
        // chars since the last emitted delta for that field.
        var parser = FieldParser(fieldNames: ["t"])
        _ = parser.feed("<t>Hello ")
        let second = parser.feed("world")
        if let d = second.last {
            // `chunkValue` is what was added this call: "world" (plus possibly
            // chars committed from the held-back suffix of the prior call).
            XCTAssertFalse(d.chunkValue.isEmpty)
            XCTAssertTrue(d.accumulatedValue.contains("Hello"))
            XCTAssertTrue(d.accumulatedValue.hasSuffix("world"))
        }
    }
}
