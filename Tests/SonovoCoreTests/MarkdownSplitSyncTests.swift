import Foundation
import Testing
@testable import SonovoCore

@Suite("Split view sync")
struct MarkdownSplitSyncTests {
    private func parsed(_ source: String) -> ParsedMarkdown {
        MarkdownParser.parseCanonical(source)
    }

    private func index(
        of block: Block,
        in blocks: [Block]
    ) -> Int? {
        blocks.firstIndex(of: block)
    }

    @Test("A source offset inside a block maps to that block")
    func sourceOffsetInsideBlock() throws {
        let parsed = parsed("# Title\n\nParagraph one.\n\n- item\n")
        let blocks = parsed.ast.blocks
        let heading = try #require(blocks.first)
        let headingRange = try #require(heading.range)
        let paragraph = try #require(
            blocks.first { block in
                if case .paragraph = block { return true }
                return false
            }
        )
        let paragraphRange = try #require(paragraph.range)

        #expect(
            MarkdownSplitSync.renderedBlockIndex(
                forSourceOffset: headingRange.lowerBound,
                in: blocks
            ) == 0
        )
        #expect(
            MarkdownSplitSync.renderedBlockIndex(
                forSourceOffset: headingRange.upperBound - 1,
                in: blocks
            ) == 0
        )
        #expect(
            MarkdownSplitSync.renderedBlockIndex(
                forSourceOffset: paragraphRange.lowerBound,
                in: blocks
            ) == index(of: paragraph, in: blocks)
        )
    }

    @Test("Whitespace between blocks does not map anywhere")
    func whitespaceRefuses() throws {
        let source = "# Title\n\nParagraph one.\n\n- item\n"
        let parsed = parsed(source)
        let blocks = parsed.ast.blocks
        let gap = (source as NSString).range(of: "\n\n")
        #expect(gap.location != NSNotFound)
        let offset = gap.location + 1
        for block in blocks {
            guard let range = block.range else { continue }
            #expect(!(range.lowerBound <= offset && offset < range.upperBound))
        }
        #expect(
            MarkdownSplitSync.renderedBlockIndex(
                forSourceOffset: offset,
                in: blocks
            ) == nil
        )
    }

    @Test("An offset outside the document refuses")
    func outsideRefuses() {
        let parsed = parsed("# Title\n")
        let blocks = parsed.ast.blocks
        #expect(
            MarkdownSplitSync.renderedBlockIndex(
                forSourceOffset: -1,
                in: blocks
            ) == nil
        )
        #expect(
            MarkdownSplitSync.renderedBlockIndex(
                forSourceOffset: 10_000,
                in: blocks
            ) == nil
        )
    }

    @Test("A rendered anchor maps back to the same block start")
    func renderedAnchorToSource() throws {
        let parsed = parsed("# Title\n\nParagraph one.\n\n- item\n")
        let blocks = parsed.ast.blocks
        for block in blocks {
            let range = try #require(block.range)
            let anchor = RenderedReadingAnchor(
                blockOffset: range.lowerBound,
                blockKind: ReadingBlockKind(block),
                fraction: 0.25
            )
            #expect(
                MarkdownSplitSync.sourceOffset(for: anchor, in: blocks)
                    == range.lowerBound
            )
        }
    }

    @Test("A moved or retyped rendered anchor refuses")
    func renderedAnchorMismatchRefuses() throws {
        let parsed = parsed("# Title\n\nParagraph one.\n")
        let blocks = parsed.ast.blocks
        let paragraph = try #require(
            blocks.first { block in
                if case .paragraph = block { return true }
                return false
            }
        )
        let range = try #require(paragraph.range)
        #expect(
            MarkdownSplitSync.sourceOffset(
                for: RenderedReadingAnchor(
                    blockOffset: range.lowerBound + 1,
                    blockKind: .paragraph,
                    fraction: 0
                ),
                in: blocks
            ) == nil
        )
        #expect(
            MarkdownSplitSync.sourceOffset(
                for: RenderedReadingAnchor(
                    blockOffset: range.lowerBound,
                    blockKind: .heading,
                    fraction: 0
                ),
                in: blocks
            ) == nil
        )
    }

    @Test("Headings sync to their scroll ID, other blocks to their index")
    func scrollAnchors() throws {
        let parsed = parsed("# Title\n\nParagraph one.\n")
        let blocks = parsed.ast.blocks
        let headings = HeadingIndex(ast: parsed.ast).headings
        let heading = try #require(blocks.first)
        let headingRange = try #require(heading.range)
        let scrollID = try #require(
            headings.first {
                $0.range?.lowerBound == headingRange.lowerBound
            }?.scrollID
        )
        #expect(
            MarkdownSplitSync.renderedScrollAnchor(
                forBlockIndex: 0,
                in: blocks,
                headings: headings
            ) == scrollID
        )
        #expect(
            MarkdownSplitSync.renderedScrollAnchor(
                forBlockIndex: 1,
                in: blocks,
                headings: headings
            ) == "block-1"
        )
        #expect(
            MarkdownSplitSync.renderedScrollAnchor(
                forBlockIndex: 9,
                in: blocks,
                headings: headings
            ) == nil
        )
    }

    @Test("A block without a source range cannot be a sync target")
    func rangeLessBlockRefuses() {
        let blocks: [Block] = [
            .thematicBreak(range: nil),
            .paragraph(
                inlines: [.text("x", range: nil)],
                range: SourceRange(
                    start: SourcePosition(line: 1, column: 0, offset: 0),
                    end: SourcePosition(line: 1, column: 1, offset: 1)
                )
            ),
        ]
        #expect(
            MarkdownSplitSync.renderedScrollAnchor(
                forBlockIndex: 0,
                in: blocks,
                headings: []
            ) == nil
        )
        #expect(
            MarkdownSplitSync.renderedBlockIndex(
                forSourceOffset: 0,
                in: blocks
            ) == 1
        )
    }
}
