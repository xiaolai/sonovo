import Foundation
import Testing
@testable import SonovoCore

@Suite("Heading index")
struct HeadingIndexTests {
    private func index(_ source: String, maxRows: Int = MarkdownLimits.maxTOCEntries) -> HeadingIndex {
        let parsed = MarkdownParser.parseCanonical(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        return HeadingIndex(ast: ast, maxRows: maxRows)
    }

    @Test("Slugs follow the contract")
    func slugRules() {
        #expect(HeadingIndex.slug(for: "Hello World") == "hello-world")
        #expect(HeadingIndex.slug(for: "  Trim  Me  ") == "trim-me")
        #expect(HeadingIndex.slug(for: "A--B") == "a-b")
        #expect(HeadingIndex.slug(for: "C++ & Rust!") == "c-rust")
        #expect(HeadingIndex.slug(for: "snake_case") == "snake_case")
        #expect(HeadingIndex.slug(for: "中文 标题") == "中文-标题")
        #expect(HeadingIndex.slug(for: "e\u{0301}") == "e\u{0301}")
        #expect(HeadingIndex.slug(for: "🎬") == nil)
        #expect(HeadingIndex.slug(for: "!!!") == nil)
    }

    @Test("Deduplicates globally, including natural suffixes")
    func duplicateSlugs() {
        let result = index("# A\n\n## A\n\n### A-1\n\n#### A\n")
        #expect(result.headings.map(\.slug) == ["a", "a-1", "a-1-1", "a-2"])
    }

    @Test("Rendered text uses labels, code, wiki display, and ignores images")
    func renderedHeadingText() {
        let source = "# [Link](https://example.com) `code` [[Page|Wiki]] ![alt](x.png)\n"
        let result = index(source)
        #expect(result.headings.first?.text == "Link code Wiki ")
    }

    @Test("Includes headings inside details and marks them")
    func headingsInsideDetails() throws {
        let source = """
        # Top

        <details>
        <summary>S</summary>

        ## Inside
        </details>
        """
        let result = index(source)
        #expect(result.headings.count == 2)
        #expect(result.headings[1].text == "Inside")
        #expect(result.headings[1].isInsideDetails)
    }

    @Test("Indentation is relative to the shallowest heading")
    func relativeIndentation() {
        let result = index("## Two\n\n#### Four\n")
        #expect(result.rows.map(\.indent) == [0, 2])
    }

    @Test("Row cap does not truncate fragment lookup")
    func rowCap() {
        let source = (1...5).map { "# H\($0)" }.joined(separator: "\n\n")
        let result = index(source, maxRows: 2)
        #expect(result.rows.count == 2)
        #expect(result.totalRowCount == 5)
        #expect(result.headings.count == 5)
        #expect(result.heading(forFragment: "h5")?.text == "H5")
    }

    @Test("Fragment lookup accepts exact and slugified fragments")
    func fragmentLookup() {
        let result = index("# Hello World\n")
        #expect(result.heading(forFragment: "hello-world")?.text == "Hello World")
        #expect(result.heading(forFragment: "Hello World")?.text == "Hello World")
        #expect(result.heading(forFragment: "missing") == nil)
    }

    @Test("Scroll IDs are unique and regenerated")
    func scrollIDs() {
        let result = index("# A\n\n# A\n")
        let ids = result.headings.compactMap(\.scrollID)
        #expect(ids == ["a#0", "a-1#1"])
        #expect(Set(ids).count == ids.count)
    }
}
