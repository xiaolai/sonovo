import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown outline")
struct MarkdownOutlineTests {
    private func index(_ source: String) -> HeadingIndex {
        let parsed = MarkdownParser.parseCanonical(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        return HeadingIndex(ast: ast)
    }

    @Test("Duplicate headings keep distinct scroll IDs")
    func duplicateSlugs() {
        let rows = MarkdownOutline.rows(index("# Title\n\n# Title\n"))
        #expect(rows.count == 2)
        #expect(rows[0].scrollID != rows[1].scrollID)
        #expect(rows[0].occurrence == 0)
        #expect(rows[1].occurrence == 1)
    }

    @Test("A filter keeps each match's ancestors")
    func filterKeepsAncestors() {
        let rows = MarkdownOutline.rows(
            index("# A\n\n## B\n\n### C\n\n# D\n")
        )
        let filtered = MarkdownOutline.filtered(rows, query: "C")
        #expect(filtered.map(\.text) == ["A", "B", "C"])
    }

    @Test("Headings inside details are marked")
    func detailsMarked() {
        let source = "<details><summary>S</summary>\n\n# Inside\n\n</details>\n"
        let rows = MarkdownOutline.rows(index(source))
        #expect(rows.contains { $0.text == "Inside" && $0.isInsideDetails })
    }

    @Test("No headings means no outline")
    func emptyOutline() {
        #expect(MarkdownOutline.rows(index("plain text\n")).isEmpty)
    }

    @Test("The active row follows the caret")
    func activeRow() {
        let source = "# A\n\nbody\n\n## B\n\nmore\n"
        let rows = MarkdownOutline.rows(index(source))
        let bOffset = (source as NSString).range(of: "B").location
        let active = MarkdownOutline.activeIndex(rows, caret: bOffset)
        #expect(active != nil)
        #expect(rows[active!].text == "B")
    }
}
