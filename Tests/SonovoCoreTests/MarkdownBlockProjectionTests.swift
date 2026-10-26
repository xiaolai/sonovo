import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown block projection")
struct MarkdownBlockProjectionTests {
    private func range(
        _ lower: Int,
        _ upper: Int
    ) -> SourceRange {
        SourceRange(
            start: SourcePosition(line: 1, column: lower, offset: lower),
            end: SourcePosition(line: 1, column: upper, offset: upper)
        )
    }

    @Test("A slice is exactly the block's source")
    func slice() throws {
        let source = "One two.\n\nThree.\n"
        let blockRange = range(0, 8)
        #expect(
            MarkdownBlockProjector.slice(blockRange, in: source)
                == "One two."
        )
        #expect(
            MarkdownBlockProjector.slice(range(8, 100), in: source) == nil
        )
    }

    @Test("A commit replaces only the block")
    func commit() throws {
        let source = "One two.\n\nThree.\n"
        let projection = MarkdownBlockProjection(
            range: 0..<8,
            expectedSlice: "One two."
        )
        let commit = try MarkdownBlockProjector.commit(
            projection,
            replacement: "One TWO.",
            in: source
        )
        #expect(commit.source == "One TWO.\n\nThree.\n")
        #expect(commit.selection == 0..<8)
        #expect(commit.actionName == "Edit Block")
        #expect(commit.source.hasSuffix("\n\nThree.\n"))
    }

    @Test("Bytes outside the block stay byte-identical")
    func bytePreservation() throws {
        let source = "  Leading.\n\n\t*列表* 与 😀\n\nTrailing.  \n"
        let ns = source as NSString
        let targetRange = ns.range(of: "*列表* 与 😀")
        let targetStart = targetRange.location
        let projection = MarkdownBlockProjection(
            range: targetStart..<(targetStart + targetRange.length),
            expectedSlice: "*列表* 与 😀"
        )
        let commit = try MarkdownBlockProjector.commit(
            projection,
            replacement: "*新的列表* 与 🚀",
            in: source
        )
        #expect(
            commit.source
                == "  Leading.\n\n\t*新的列表* 与 🚀\n\nTrailing.  \n"
        )
    }

    @Test("A moved or edited block refuses")
    func stale() {
        let source = "One two.\n\nThree.\n"
        let projection = MarkdownBlockProjection(
            range: 0..<8,
            expectedSlice: "One two."
        )
        #expect(throws: MarkdownBlockProjectionError.staleBlock) {
            try MarkdownBlockProjector.commit(
                projection,
                replacement: "Nope.",
                in: "Zero.\n\n" + source
            )
        }
        #expect(throws: MarkdownBlockProjectionError.staleBlock) {
            try MarkdownBlockProjector.commit(
                projection,
                replacement: "Nope.",
                in: "One TWO.\n\nThree.\n"
            )
        }
    }

    @Test("An out-of-range projection refuses")
    func invalidRange() {
        let projection = MarkdownBlockProjection(
            range: 0..<100,
            expectedSlice: "x"
        )
        #expect(throws: MarkdownBlockProjectionError.invalidRange) {
            try MarkdownBlockProjector.commit(
                projection,
                replacement: "y",
                in: "short"
            )
        }
    }

    @Test("An empty replacement deletes only the block")
    func deleteBlock() throws {
        let source = "One two.\n\nThree.\n"
        let commit = try MarkdownBlockProjector.commit(
            MarkdownBlockProjection(range: 0..<8, expectedSlice: "One two."),
            replacement: "",
            in: source
        )
        #expect(commit.source == "\n\nThree.\n")
        #expect(commit.selection == 0..<0)
    }
}
