import Foundation
import Testing
@testable import SonovoCore

@Suite("Reading anchors")
struct ReadingAnchorTests {
    private func sourceRange(_ offsets: Range<Int>) -> SourceRange {
        SourceRange(
            start: SourcePosition(
                line: 1,
                column: offsets.lowerBound,
                offset: offsets.lowerBound
            ),
            end: SourcePosition(
                line: 1,
                column: offsets.upperBound,
                offset: offsets.upperBound
            )
        )
    }

    private func blocks() -> [Block] {
        [
            .paragraph(
                inlines: [.text("a", range: nil)],
                range: sourceRange(0..<4)
            ),
            .heading(
                level: 2,
                inlines: [.text("h", range: nil)],
                range: sourceRange(5..<10)
            ),
            .paragraph(
                inlines: [.text("b", range: nil)],
                range: sourceRange(11..<20)
            )
        ]
    }

    @Test("A rendered anchor resolves by source offset and kind")
    func exactBlock() {
        let index = ReadingAnchorResolver.renderedBlockIndex(
            for: RenderedReadingAnchor(
                blockOffset: 5,
                blockKind: .heading,
                fraction: 0.5
            ),
            in: blocks()
        )
        #expect(index == 1)
    }

    @Test("A moved block falls back to the nearest preceding block")
    func precedingBlock() {
        let index = ReadingAnchorResolver.renderedBlockIndex(
            for: RenderedReadingAnchor(
                blockOffset: 15,
                blockKind: .paragraph,
                fraction: 0.2
            ),
            in: blocks()
        )
        #expect(index == 2)
    }

    @Test("An offset before every block resolves to the first block")
    func beforeFirstBlock() {
        let index = ReadingAnchorResolver.renderedBlockIndex(
            for: RenderedReadingAnchor(
                blockOffset: 0,
                blockKind: .table,
                fraction: 0
            ),
            in: blocks()
        )
        #expect(index == 0)
    }

    @Test("An empty document has no block to restore")
    func emptyDocument() {
        #expect(
            ReadingAnchorResolver.renderedBlockIndex(
                for: RenderedReadingAnchor(
                    blockOffset: 10,
                    blockKind: .paragraph,
                    fraction: 0
                ),
                in: []
            ) == nil
        )
    }

    @Test("Block kinds survive the round trip through the anchor")
    func blockKinds() {
        let cases: [(Block, ReadingBlockKind)] = [
            (.paragraph(inlines: [], range: nil), .paragraph),
            (.heading(level: 1, inlines: [], range: nil), .heading),
            (.blockQuote(blocks: [], range: nil), .blockQuote),
            (
                .list(
                    ListBlock(kind: .bullet, items: [], tight: true),
                    range: nil
                ),
                .list
            ),
            (
                .codeBlock(
                    CodeBlock(
                        code: "",
                        language: nil,
                        fenced: true,
                        info: nil
                    ),
                    range: nil
                ),
                .codeBlock
            ),
            (.htmlBlock(raw: "", range: nil), .htmlBlock),
            (.thematicBreak(range: nil), .thematicBreak),
            (
                .table(
                    TableBlock(
                        header: [],
                        rows: [],
                        alignments: []
                    ),
                    range: nil
                ),
                .table
            ),
            (
                .details(
                    DetailsBlock(
                        summary: [],
                        blocks: [],
                        isOpen: true,
                        range: nil
                    ),
                    range: nil
                ),
                .details
            ),
            (.tableOfContents(range: nil), .tableOfContents)
        ]
        for (block, kind) in cases {
            #expect(ReadingBlockKind(block) == kind)
        }
    }

    @Test("A source anchor clamps to the nearest preceding line")
    func sourceLine() {
        let source = "one\ntwo\nthree"
        #expect(
            ReadingAnchorResolver.sourceLineStart(
                for: SourceReadingAnchor(
                    lineOffset: 5,
                    viewportOffset: 0
                ),
                in: source
            ) == 4
        )
        // An external reload shrank the file: the offset clamps to the last
        // character and then back to its line start.
        #expect(
            ReadingAnchorResolver.sourceLineStart(
                for: SourceReadingAnchor(
                    lineOffset: 999,
                    viewportOffset: 0
                ),
                in: source
            ) == 8
        )
        #expect(
            ReadingAnchorResolver.sourceLineStart(
                for: SourceReadingAnchor(
                    lineOffset: 0,
                    viewportOffset: 0
                ),
                in: ""
            ) == nil
        )
    }

    @Test("Fractions are clamped and non-finite values become zero")
    func fractions() {
        #expect(ReadingAnchorResolver.clampedFraction(-1) == 0)
        #expect(ReadingAnchorResolver.clampedFraction(2) == 1)
        #expect(ReadingAnchorResolver.clampedFraction(.nan) == 0)
        #expect(
            RenderedReadingAnchor(
                blockOffset: 0,
                blockKind: .paragraph,
                fraction: 3
            ).fraction == 1
        )
        #expect(
            SourceReadingAnchor(
                lineOffset: -5,
                viewportOffset: .infinity
            ).viewportOffset == 0
        )
    }
}
