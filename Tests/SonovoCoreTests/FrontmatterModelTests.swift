import Foundation
import Testing
@testable import SonovoCore

@Suite("Production frontmatter")
struct FrontmatterModelTests {
    @Test("Reads the documented keys and ignores unknown ones")
    func knownKeys() {
        let model = ProductionFrontmatter(body: """
        title: Everything Is a Remix
        episode: 3
        scene: Cold open
        status: draft
        assets:
          - assets/one.png
          - assets/two.png
        author: example-author
        """)
        #expect(model.fields.map(\.key) == [
            .title, .episode, .scene, .status, .assets
        ])
        #expect(model.field(for: .title)?.displayValue == "Everything Is a Remix")
        #expect(model.field(for: .episode)?.displayValue == "3")
        #expect(model.field(for: .scene)?.displayValue == "Cold open")
        #expect(model.field(for: .status)?.displayValue == "draft")
        #expect(model.field(for: .assets)?.values == [
            "assets/one.png", "assets/two.png"
        ])
        #expect(model.unknownKeys == ["author"])
        #expect(model.diagnostics.isEmpty)
    }

    @Test("Decodes quotes and strips inline comments")
    func quoting() {
        let model = ProductionFrontmatter(body: """
        title: "A \\"quoted\\" title" # a comment
        scene: 'It''s a scene'
        status: https://example.com/#draft
        """)
        #expect(model.field(for: .title)?.displayValue == "A \"quoted\" title")
        #expect(model.field(for: .scene)?.displayValue == "It's a scene")
        #expect(
            model.field(for: .status)?.displayValue
                == "https://example.com/#draft"
        )
    }

    @Test("Reads literal and folded block scalars")
    func blockScalars() {
        let model = ProductionFrontmatter(body: """
        title: |
          First line
          Second line
        scene: >
          A folded
          sentence
        """)
        #expect(
            model.field(for: .title)?.displayValue
                == "First line\nSecond line"
        )
        #expect(
            model.field(for: .scene)?.displayValue == "A folded sentence"
        )
    }

    @Test("Reads a flow list")
    func flowList() {
        let model = ProductionFrontmatter(body: "assets: [a.png, 'b.png']\n")
        #expect(model.field(for: .assets)?.displayValue == "a.png, b.png")
    }

    @Test("Flags duplicate keys without discarding either value")
    func duplicateKeys() {
        let model = ProductionFrontmatter(body: """
        title: First
        status: draft
        title: Second
        """)
        let title = model.field(for: .title)
        #expect(title?.isDuplicate == true)
        #expect(title?.values == ["First", "Second"])
        #expect(model.diagnostics.count == 1)
        #expect(
            model.diagnostics.first?.kind == .duplicateKey("title")
        )
        #expect(model.diagnostics.first?.line == 3)
    }

    @Test("Reports an unterminated quoted value and keeps it raw")
    func unterminatedQuote() {
        let model = ProductionFrontmatter(body: "title: \"never closed\n")
        #expect(
            model.diagnostics.first?.kind == .unterminatedQuote("title")
        )
        #expect(model.field(for: .title)?.displayValue == "\"never closed")
    }

    @Test("Anchors are stripped for display; aliases stay opaque")
    func anchorsAndAliases() {
        let model = ProductionFrontmatter(body: """
        title: &t Hello
        status: *t
        """)
        #expect(model.field(for: .title)?.displayValue == "Hello")
        #expect(model.field(for: .status)?.displayValue == "*t")
        #expect(model.diagnostics.isEmpty)
    }

    @Test("A nested map never becomes a top-level field")
    func nestedMap() {
        let model = ProductionFrontmatter(body: """
        meta:
          title: inner
        title: outer
        """)
        #expect(model.field(for: .title)?.displayValue == "outer")
        #expect(model.unknownKeys == ["meta"])
    }

    @Test("Reads the body the document parser produces")
    func parsedBody() throws {
        let source = "---\ntitle: Parsed\nepisode: 2\n---\n\nBody\n"
        let parsed = MarkdownParser.parseCanonical(source)
        let frontmatter = try #require(parsed.ast.frontmatter)
        let model = ProductionFrontmatter(body: frontmatter.body)
        #expect(model.field(for: .title)?.displayValue == "Parsed")
        #expect(model.field(for: .episode)?.displayValue == "2")
    }

    @Test("An empty frontmatter body has no fields")
    func emptyBody() {
        let model = ProductionFrontmatter(body: "")
        #expect(model.fields.isEmpty)
        #expect(model.unknownKeys.isEmpty)
        #expect(model.diagnostics.isEmpty)
    }
}
