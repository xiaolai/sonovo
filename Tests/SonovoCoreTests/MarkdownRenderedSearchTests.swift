import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown rendered search")
struct MarkdownRenderedSearchTests {
    private func blocks(_ source: String) -> [String] {
        let parsed = MarkdownParser.parseCanonical(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        return MarkdownRenderedSearch.blocks(ast)
    }

    @Test("Each top-level block exposes its rendered text")
    func blockText() {
        let source = "# Title\n\nBody text.\n\n- one\n- two\n\n```swift\nlet x = 1\n```\n"
        let texts = blocks(source)
        #expect(texts.count == 4)
        #expect(texts[0] == "Title")
        #expect(texts[1] == "Body text.")
        #expect(texts[2].contains("one"))
        #expect(texts[3] == "let x = 1\n")
    }

    @Test("Matches carry the block and location")
    func matches() {
        let texts = ["alpha beta", "beta gamma"]
        let found = MarkdownRenderedSearch.matches(
            query: "beta",
            blocks: texts
        )
        #expect(found.count == 2)
        #expect(found[0].blockIndex == 0)
        #expect(found[0].location == 6)
        #expect(found[1].blockIndex == 1)
    }

    @Test("Matching is case-insensitive by default")
    func caseInsensitive() {
        let found = MarkdownRenderedSearch.matches(
            query: "HELLO",
            blocks: ["hello world"]
        )
        #expect(found.count == 1)
        #expect(found[0].length == 5)
    }

    @Test("An empty query has no matches")
    func emptyQuery() {
        #expect(
            MarkdownRenderedSearch.matches(query: "", blocks: ["x"]).isEmpty
        )
    }

    @Test("The match limit is enforced")
    func limit() {
        let found = MarkdownRenderedSearch.matches(
            query: "a",
            blocks: [String(repeating: "a", count: 100)],
            limit: 10
        )
        #expect(found.count == 10)
    }

    @Test("Table and details text is searchable")
    func tableAndDetails() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 |\n\n<details><summary>More</summary>\n\ninside\n\n</details>\n"
        let texts = blocks(source)
        #expect(texts.contains { $0.contains("a b") || $0.contains("1") })
        #expect(texts.contains { $0.contains("inside") })
    }

    @Test("Formula source is not visible searchable text")
    func mathIsNotSearchable() {
        let texts = blocks("Before $\\frac{a}{b}$ after.\n")
        #expect(texts.count == 1)
        #expect(texts[0].contains("Before"))
        #expect(texts[0].contains("after"))
        #expect(!texts[0].contains("frac"))
        #expect(
            MarkdownRenderedSearch.matches(
                query: "frac",
                blocks: texts
            ).isEmpty
        )
    }
}
