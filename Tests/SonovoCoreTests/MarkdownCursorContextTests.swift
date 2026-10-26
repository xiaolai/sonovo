import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown cursor context")
struct MarkdownCursorContextTests {
    private func context(
        _ source: String,
        at needle: String,
        occurrence: Int = 1
    ) -> MarkdownCursorContext {
        let parsed = MarkdownParser.parse(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        let ns = source as NSString
        var search = NSRange(location: 0, length: ns.length)
        var location = NSNotFound
        for _ in 0..<occurrence {
            let found = ns.range(of: needle, options: [], range: search)
            guard found.location != NSNotFound else { break }
            location = found.location
            let next = found.location + max(found.length, 1)
            search = NSRange(
                location: next,
                length: ns.length - next
            )
        }
        #expect(location != NSNotFound)
        return MarkdownCursorContext.at(
            offset: location,
            in: ast,
            source: source
        )
    }

    @Test("A paragraph context names the block")
    func paragraph() {
        let context = context("hello world", at: "world")
        #expect(context.block == .paragraph)
        #expect(context.topLevelBlockIndex == 0)
        #expect(context.headingLevel == nil)
    }

    @Test("A heading context carries its level")
    func heading() {
        let context = context("## Title\n\nbody", at: "Title")
        #expect(context.block == .heading)
        #expect(context.headingLevel == 2)
    }

    @Test("A nested blockquote counts its depth")
    func blockquote() {
        let context = context("> > deep", at: "deep")
        #expect(context.block == .paragraph)
        #expect(context.blockQuoteDepth == 2)
    }

    @Test("A nested list counts its depth and finds a marker")
    func list() {
        let source = "- outer\n  - inner\n"
        let context = context(source, at: "inner")
        #expect(context.list?.depth == 2)
        #expect(context.list?.markerRange != nil)
    }

    @Test("A code fence carries its range and language")
    func codeFence() {
        let source = "```swift\nlet x = 1\n```"
        let context = context(source, at: "let x")
        #expect(context.block == .codeBlock)
        #expect(context.codeLanguage == "swift")
        #expect(context.codeFence != nil)
    }

    @Test("A table context names the cell")
    func table() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let context = context(source, at: "2")
        #expect(context.block == .table)
        #expect(context.table?.rowIndex == 1)
        #expect(context.table?.column == 1)
        #expect(context.table?.isValid == true)
        #expect(context.table?.cellRange.isEmpty == false)
    }

    @Test("A wiki link context is recognized after augmentation")
    func wikiLink() {
        let source = "See [[Page|the page]] now."
        let context = context(source, at: "the page")
        #expect(context.link?.kind == .wikiLink)
    }

    @Test("A link inside emphasis is still a link")
    func linkInsideEmphasis() {
        let source = "*see [docs](https://example.com) here*"
        let context = context(source, at: "docs")
        #expect(context.link?.kind == .link)
    }

    @Test("Frontmatter is exposed by range")
    func frontmatter() {
        let source = "---\ntitle: Test\n---\n\nbody"
        let context = context(source, at: "title")
        #expect(context.frontmatterRange != nil)
    }

    @Test("An empty document has no block context")
    func outsideBlocks() {
        let parsed = MarkdownParser.parse("")
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        let context = MarkdownCursorContext.at(
            offset: 0,
            in: ast,
            source: ""
        )
        #expect(context.block == nil)
        #expect(context.topLevelBlockIndex == nil)
    }
}

@Suite("Markdown cursor context audit regressions")
struct MarkdownCursorContextAuditTests {
    private func context(
        _ source: String,
        at needle: String
    ) -> MarkdownCursorContext {
        let parsed = MarkdownParser.parse(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        let offset = (source as NSString).range(of: needle).location
        return MarkdownCursorContext.at(
            offset: offset,
            in: ast,
            source: source
        )
    }

    @Test("A heading in a quote is not reported as the following paragraph")
    func headingInQuote() {
        let context = context("> # Head\n> body", at: "Head")
        #expect(context.block == .heading)
        #expect(context.blockQuoteDepth == 1)
    }

    @Test("A caret in the first list item does not inherit a nested list depth")
    func listDepthIsNotInflated() {
        let context = context("- a\n- b\n  - c", at: "a")
        #expect(context.list?.depth == 1)
    }

    @Test("The caret at EOF keeps the heading inside a quote")
    func headingInQuoteAtEOF() {
        let source = "> # Head"
        let parsed = MarkdownParser.parse(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        let context = MarkdownCursorContext.at(
            offset: (source as NSString).length,
            in: ast,
            source: source
        )
        #expect(context.block == .heading)
        #expect(context.headingLevel == 1)
        #expect(context.blockQuoteDepth == 1)
    }

    @Test("The caret at EOF keeps the nested list depth")
    func nestedListAtEOF() {
        let source = "- a\n  - b"
        let parsed = MarkdownParser.parse(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        let context = MarkdownCursorContext.at(
            offset: (source as NSString).length,
            in: ast,
            source: source
        )
        #expect(context.list?.depth == 2)
    }

    @Test("The caret at EOF keeps an inline link context")
    func wikiLinkAtEOF() {
        let source = "See [[Page]]"
        let parsed = MarkdownParser.parse(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        let context = MarkdownCursorContext.at(
            offset: (source as NSString).length,
            in: ast,
            source: source
        )
        #expect(context.link?.kind == .wikiLink)
    }
}
