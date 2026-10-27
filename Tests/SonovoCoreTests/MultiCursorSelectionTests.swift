import Foundation
import Testing
@testable import SonovoCore

@Suite("Multi cursor selection")
struct MultiCursorSelectionTests {
    private func selection(
        _ carets: [(anchor: Int, active: Int)],
        primary: Int,
        source: String
    ) throws -> MultiCursorSelection {
        try MultiCursorSelection(
            carets.map {
                MultiCursorSelection.Caret(anchor: $0.anchor, active: $0.active)
            },
            primary: primary,
            source: source
        )
    }

    @Test("Unsorted input normalises and the primary follows its caret")
    func sortsAndNormalises() throws {
        let model = try selection(
            [(8, 8), (2, 2), (5, 5)],
            primary: 1,
            source: "abcdefghij"
        )
        #expect(model.ranges == [2..<2, 5..<5, 8..<8])
        #expect(model.primaryIndex == 0)
        #expect(model.primaryRange == 2..<2)
    }

    @Test("Duplicate ranges merge and the primary keeps its direction")
    func duplicateMergeKeepsPrimaryDirection() throws {
        let model = try selection(
            [(2, 6), (6, 2)],
            primary: 1,
            source: "abcdefghij"
        )
        #expect(model.count == 1)
        #expect(model.primary.anchor == 6)
        #expect(model.primary.active == 2)
        #expect(model.primary.range == 2..<6)
    }

    @Test("A duplicate placement toggles off; the sole caret cannot")
    func duplicateToggle() throws {
        let two = try selection(
            [(2, 2), (5, 5)],
            primary: 0,
            source: "abcdefghij"
        )
        let toggled = try two.adding(anchor: 2, active: 2, source: "abcdefghij")
        #expect(toggled.ranges == [5..<5])

        let sole = try MultiCursorSelection(caret: 5, source: "abcdefghij")
        let unchanged = try sole.adding(
            anchor: 5,
            active: 5,
            source: "abcdefghij"
        )
        #expect(unchanged == sole)
    }

    @Test("A range spanning two selections removes both")
    func rangeSpanningTwoSelections() throws {
        let model = try selection(
            [(0, 0), (8, 8)],
            primary: 0,
            source: "abcdefghij"
        )
        let replaced = try model.adding(
            anchor: 0,
            active: 10,
            source: "abcdefghij"
        )
        #expect(replaced.count == 1)
        #expect(replaced.ranges == [0..<10])
        #expect(replaced.primaryIndex == 0)
    }

    @Test("Distinct overlapping ranges are refused in the initialiser")
    func overlapRejection() {
        #expect(throws: MultiCursorSelection.Failure.overlapping) {
            _ = try selection(
                [(0, 5), (3, 8)],
                primary: 0,
                source: "abcdefghij"
            )
        }
    }

    @Test("Adjacent carets do not overlap")
    func adjacentCaret() throws {
        let model = try selection(
            [(0, 3), (3, 3)],
            primary: 0,
            source: "abcdefghij"
        )
        #expect(model.count == 2)
        #expect(model.ranges == [0..<3, 3..<3])
    }

    @Test("Removing the primary promotes the nearest caret")
    func primaryRemovalPromotesNearest() throws {
        let model = try selection(
            [(0, 0), (5, 5), (10, 10)],
            primary: 1,
            source: "abcdefghijkl"
        )
        let next = try model.removing(at: 1, source: "abcdefghijkl")
        #expect(next.ranges == [0..<0, 10..<10])
        #expect(next.primaryRange == 10..<10)

        let last = try next.removing(at: 1, source: "abcdefghijkl")
        #expect(last.ranges == [0..<0])
        #expect(last.primaryRange == 0..<0)
    }

    @Test("Carets that converge at the start or EOF merge")
    func convergence() throws {
        let start = try selection(
            [(0, 0), (0, 0), (3, 3), (3, 3)],
            primary: 1,
            source: "abcdefghij"
        )
        #expect(start.ranges == [0..<0, 3..<3])

        let eof = try selection(
            [(3, 3), (3, 3)],
            primary: 0,
            source: "abc"
        )
        #expect(eof.count == 1)
        #expect(eof.primaryRange == 3..<3)
    }

    @Test("An empty source holds one caret at zero")
    func emptySource() throws {
        let model = try MultiCursorSelection(caret: 0, source: "")
        #expect(model.ranges == [0..<0])
        let unchanged = try model.adding(anchor: 0, active: 0, source: "")
        #expect(unchanged == model)
    }

    @Test("The caret cap refuses one more than the limit")
    func maximumCarets() throws {
        let source = String(repeating: "a", count: 101)
        let full = (0...99).map { (anchor: $0, active: $0) }
        let atCap = try selection(full, primary: 0, source: source)
        #expect(atCap.count == 100)
        let over = (0...100).map { (anchor: $0, active: $0) }
        #expect(throws: MultiCursorSelection.Failure.tooManyCarets(101)) {
            _ = try selection(over, primary: 0, source: source)
        }
    }

    @Test("A combining accent cannot be split")
    func combiningAccentSplit() throws {
        let source = "e\u{301}x"
        #expect(throws: MultiCursorSelection.Failure.graphemeSplit(1)) {
            _ = try MultiCursorSelection(caret: 1, source: source)
        }
        let after = try MultiCursorSelection(caret: 2, source: source)
        #expect(after.primaryRange == 2..<2)
    }

    @Test("A ZWJ emoji cannot be split")
    func zwjEmojiSplit() throws {
        let source = "👩‍💻x"
        for offset in 1...4 {
            #expect(
                throws: MultiCursorSelection.Failure.graphemeSplit(offset)
            ) {
                _ = try MultiCursorSelection(caret: offset, source: source)
            }
        }
        let after = try MultiCursorSelection(caret: 5, source: source)
        #expect(after.primaryRange == 5..<5)
    }

    @Test("Anchor and active histories differ on the next movement")
    func anchorHistories() throws {
        let forward = try selection(
            [(2, 5)],
            primary: 0,
            source: "abcdefghijkl"
        )
        let backward = try selection(
            [(5, 2)],
            primary: 0,
            source: "abcdefghijkl"
        )
        #expect(forward.primary.range == backward.primary.range)

        let extended = try forward.moved(
            at: 0,
            to: 6,
            goalColumn: nil,
            source: "abcdefghijkl"
        )
        #expect(extended.primaryRange == 2..<6)

        let contracted = try backward.moved(
            at: 0,
            to: 3,
            goalColumn: nil,
            source: "abcdefghijkl"
        )
        #expect(contracted.primaryRange == 3..<5)
    }

    @Test("A goal column survives a vertical move and clears on a horizontal")
    func goalColumn() throws {
        let model = try MultiCursorSelection(
            caret: 0,
            source: "abcdefghijkl"
        )
        let down = try model.moved(
            at: 0,
            to: 4,
            goalColumn: 12,
            source: "abcdefghijkl"
        )
        #expect(down.primary.goalColumn == 12)
        let right = try down.moved(
            at: 0,
            to: 5,
            goalColumn: nil,
            source: "abcdefghijkl"
        )
        #expect(right.primary.goalColumn == nil)
    }

    @Test("Out-of-bounds offsets are refused")
    func outOfBounds() {
        #expect(throws: MultiCursorSelection.Failure.outOfBounds(4)) {
            _ = try MultiCursorSelection(caret: 4, source: "abc")
        }
        #expect(throws: MultiCursorSelection.Failure.outOfBounds(-1)) {
            _ = try MultiCursorSelection(caret: -1, source: "abc")
        }
    }

    @Test("A move that overlaps another caret replaces it")
    func moveOverlapsAnotherCaret() throws {
        let model = try selection(
            [(0, 0), (8, 8)],
            primary: 0,
            source: "abcdefghijkl"
        )
        let moved = try model.moved(
            at: 0,
            to: 10,
            goalColumn: nil,
            source: "abcdefghijkl"
        )
        #expect(moved.count == 1)
        #expect(moved.primaryRange == 0..<10)
    }

    @Test("A move that replaces the primary promotes the moved caret")
    func moveReplacingPrimary() throws {
        let model = try selection(
            [(0, 0), (8, 8)],
            primary: 1,
            source: "abcdefghijkl"
        )
        let moved = try model.moved(
            at: 0,
            to: 10,
            goalColumn: nil,
            source: "abcdefghijkl"
        )
        #expect(moved.count == 1)
        #expect(moved.primaryRange == 0..<10)
    }

    @Test("Moving the primary keeps clear carets and drops a colliding one")
    func movingThePrimary() throws {
        let source = "alpha beta gamma"
        let model = try selection(
            [(0, 0), (6, 6), (11, 11)],
            primary: 1,
            source: source
        )
        // A move to a range no other caret occupies keeps every caret.
        let moved = try model.movingPrimary(
            to: MultiCursorSelection.Caret(anchor: 12, active: 16),
            source: source
        )
        #expect(moved.ranges == [0..<0, 11..<11, 12..<16])
        #expect(moved.primaryRange == 12..<16)

        // A move that covers a secondary drops that secondary instead of
        // refusing the whole move.
        let collided = try model.movingPrimary(
            to: MultiCursorSelection.Caret(anchor: 9, active: 13),
            source: source
        )
        #expect(collided.ranges == [0..<0, 9..<13])
        #expect(collided.primaryRange == 9..<13)
    }

    // MARK: - Composition translation
    @Test("An insertion shifts carets after it and keeps carets before it")
    func translationInsertion() throws {
        let model = try selection(
            [(0, 0), (5, 5), (9, 9)],
            primary: 1,
            source: "alpha beta"
        )
        // Inserting 日本 at 5 must produce exactly this postimage: the old
        // fixture carried an extra space, so the offsets were right for a
        // string the replacement never produced.
        let postimage = "alpha日本 beta"
        #expect(
            postimage.utf16.count == "alpha beta".utf16.count + 2
        )
        let translated = try model.translated(
            replacing: 5..<5,
            with: 5..<7,
            primary: MultiCursorSelection.Caret(anchor: 7, active: 7),
            source: postimage
        )
        #expect(translated.ranges == [0..<0, 7..<7, 11..<11])
        #expect(translated.primaryRange == 7..<7)
    }

    @Test("A replacement drops a secondary inside it and shifts later ones")
    func translationReplacement() throws {
        let model = try selection(
            [(0, 0), (3, 3), (5, 5), (9, 9)],
            primary: 2,
            source: "alpha beta gamma"
        )
        // Replacing 2..<6 in "alpha beta gamma" replaces "pha " and yields
        // this postimage; the old fixture kept a space the edit removed.
        let postimage = "al日本beta gamma"
        #expect(
            postimage.utf16.count
                == "alpha beta gamma".utf16.count + 2 - 4
        )
        let translated = try model.translated(
            replacing: 2..<6,
            with: 2..<4,
            primary: MultiCursorSelection.Caret(anchor: 4, active: 4),
            source: postimage
        )
        #expect(translated.ranges == [0..<0, 4..<4, 7..<7])
        #expect(translated.primaryRange == 4..<4)
    }

    @Test("A deletion shifts later carets and drops one landing on the primary")
    func translationDeletion() throws {
        let model = try selection(
            [(0, 0), (8, 8), (9, 9)],
            primary: 1,
            source: "abcdefghijkl"
        )
        let translated = try model.translated(
            replacing: 4..<9,
            with: 4..<4,
            primary: MultiCursorSelection.Caret(anchor: 4, active: 4),
            source: "abcdjkl"
        )
        #expect(translated.ranges == [0..<0, 4..<4])
        #expect(translated.primaryRange == 4..<4)
    }

    @Test("A selection after the replaced span shifts both ends")
    func translationSelection() throws {
        let model = try selection(
            [(0, 0), (8, 10), (5, 5)],
            primary: 2,
            source: "abcdefghijkl"
        )
        let translated = try model.translated(
            replacing: 2..<3,
            with: 2..<4,
            primary: MultiCursorSelection.Caret(anchor: 5, active: 5),
            source: "abXYdefghijkl"
        )
        #expect(translated.carets[2].anchor == 9)
        #expect(translated.carets[2].active == 11)
        #expect(translated.carets[2].range == 9..<11)
    }

    @Test("A caret exactly at the insertion point stays put")
    func translationBoundaryInsertion() throws {
        let model = try selection(
            [(2, 2), (6, 6), (8, 8)],
            primary: 1,
            source: "abcdefghij"
        )
        let translated = try model.translated(
            replacing: 2..<2,
            with: 2..<4,
            primary: MultiCursorSelection.Caret(anchor: 6, active: 6),
            source: "abXXcdefghij"
        )
        // Offset 2 was the insertion point itself; it does not move.
        #expect(translated.ranges == [2..<2, 6..<6, 10..<10])
    }

    @Test("A translation that lands mid-grapheme is refused")
    func translationRefusesGraphemeSplit() throws {
        let model = try selection(
            [(2, 2), (3, 3)],
            primary: 1,
            source: "a\u{301}b"
        )
        #expect(throws: MultiCursorSelection.Failure.graphemeSplit(1)) {
            try model.translated(
                replacing: 0..<1,
                with: 0..<1,
                primary: MultiCursorSelection.Caret(anchor: 1, active: 1),
                source: "a\u{301}b"
            )
        }
    }

    @Test("Dropping every secondary leaves one caret")
    func translationCollapsesToPrimary() throws {
        let model = try selection(
            [(3, 3), (5, 5)],
            primary: 1,
            source: "alpha beta gamma"
        )
        let translated = try model.translated(
            replacing: 2..<9,
            with: 2..<2,
            primary: MultiCursorSelection.Caret(anchor: 2, active: 2),
            source: "al gamma"
        )
        #expect(translated.count == 1)
        #expect(translated.primaryRange == 2..<2)
    }
}
