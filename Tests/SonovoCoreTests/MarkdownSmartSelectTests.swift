import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown smart select")
struct MarkdownSmartSelectTests {
    private func next(
        _ source: String,
        _ selection: Range<Int>
    ) -> Range<Int>? {
        let parsed = MarkdownParser.parseCanonical(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        return MarkdownSmartSelect.next(
            source: source,
            selection: selection,
            ast: ast
        )
    }

    @Test("A table expands cell, then row, then table, then document")
    func tableChain() throws {
        let source = "before\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nafter"
        let ns = source as NSString
        let caret = ns.range(of: "1").location
        let table = try #require(
            MarkdownTableScanner.table(at: caret, in: source)
        )
        let cell = try #require(table.body[0].cells.first)
        let cellLower = cell.segmentRange.lowerBound
        let cellUpper = cell.segmentRange.upperBound
        let cellRange = cellLower..<cellUpper

        let first = try #require(next(source, caret..<caret))
        #expect(first == cellRange)

        let second = try #require(next(source, first))
        let rowLower = table.body[0].range.lowerBound
        let rowUpper = table.body[0].range.upperBound
        #expect(second == rowLower..<rowUpper)

        let third = try #require(next(source, second))
        #expect(
            third == table.range.lowerBound..<table.range.upperBound
        )

        let fourth = try #require(next(source, third))
        #expect(fourth == 0..<ns.length)

        #expect(next(source, fourth) == nil)
    }

    @Test("A quote expands through its container")
    func quoteChain() {
        let source = "> quoted text\n\nbody"
        let caret = (source as NSString).range(of: "quoted").location + 1
        let first = next(source, caret..<caret)
        #expect(first != nil)
        let second = first.flatMap { next(source, $0) }
        #expect(second != nil)
        let document = 0..<(source as NSString).length
        #expect(second == document || next(source, second!) == document)
    }

    @Test("A fenced block expands to its fence")
    func fenceChain() {
        let source = "```\ncode\n```\n"
        let caret = (source as NSString).range(of: "code").location + 1
        let first = next(source, caret..<caret)
        #expect(first != nil)
        let second = first.flatMap { next(source, $0) }
        #expect(second == 0..<(source as NSString).length)
    }

    @Test("An arbitrary selection expands to the document")
    func arbitrarySelection() {
        let source = "hello"
        #expect(next(source, 1..<3) == 0..<5)
    }
}
