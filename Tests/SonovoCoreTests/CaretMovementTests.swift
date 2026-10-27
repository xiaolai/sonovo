import Foundation
import Testing
@testable import SonovoCore

@Suite("Caret movement")
struct CaretMovementTests {
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

    private func carets(
        _ offsets: [Int],
        primary: Int = 0,
        source: String
    ) throws -> MultiCursorSelection {
        try selection(
            offsets.map { ($0, $0) },
            primary: primary,
            source: source
        )
    }

    private struct TestLines: CaretLineProvider {
        let lines: [CaretDisplayLine]

        func line(containing offset: Int) -> CaretDisplayLine? {
            lines.last { $0.range.contains(offset) }
                ?? lines.last { $0.range.upperBound == offset }
                ?? (lines.isEmpty ? nil : lines[lines.count - 1])
        }

        func line(above line: CaretDisplayLine) -> CaretDisplayLine? {
            guard let index = lines.firstIndex(of: line), index > 0 else {
                return nil
            }
            return lines[index - 1]
        }

        func line(below line: CaretDisplayLine) -> CaretDisplayLine? {
            guard let index = lines.firstIndex(of: line),
                  index + 1 < lines.count else { return nil }
            return lines[index + 1]
        }
    }

    @Test("Motion refuses a caret that does not exist in this source")
    func staleCaretIsRefused() throws {
        // The caret set was built against "alpha"; the destination text is
        // shorter, so indexing it raised an Objective-C exception before the
        // set could be refused. The check must come before any offset use.
        let stale = try carets([5], source: "alpha")
        for unit in [CaretMovement.Unit.grapheme, .word, .document] {
            do {
                _ = try CaretMovement.horizontal(
                    stale,
                    in: "x",
                    direction: .backward,
                    unit: unit,
                    extending: false
                )
                Issue.record("expected an out-of-bounds refusal")
            } catch let failure as MultiCursorSelection.Failure {
                #expect(failure == .outOfBounds(5))
            }
        }
        let lines = TestLines(lines: [CaretDisplayLine(range: 0..<1)])
        do {
            _ = try CaretMovement.vertical(
                stale,
                in: "x",
                direction: .down,
                extending: false,
                lines: lines
            )
            Issue.record("expected an out-of-bounds refusal")
        } catch let failure as MultiCursorSelection.Failure {
            #expect(failure == .outOfBounds(5))
        }
    }

    @Test("Grapheme motion steps over a combining accent as one unit")
    func graphemeCombiningAccent() throws {
        let source = "a\u{301}bc"
        let model = try carets([0], source: source)
        let forward = try CaretMovement.horizontal(
            model,
            in: source,
            direction: .forward,
            unit: .grapheme,
            extending: false
        )
        #expect(forward.primaryRange == 2..<2)
        let back = try CaretMovement.horizontal(
            forward,
            in: source,
            direction: .backward,
            unit: .grapheme,
            extending: false
        )
        #expect(back.primaryRange == 0..<0)
    }

    @Test("Grapheme motion steps over a ZWJ emoji as one unit")
    func graphemeZWJ() throws {
        let source = "👨‍👩‍👧x"
        let model = try carets([0], source: source)
        let forward = try CaretMovement.horizontal(
            model,
            in: source,
            direction: .forward,
            unit: .grapheme,
            extending: false
        )
        #expect(forward.primaryRange == 8..<8)
    }

    @Test("Word motion stops at the next word and the current word start")
    func wordMotion() throws {
        let source = "alpha beta gamma"
        let model = try carets([0, 6], primary: 0, source: source)
        let forward = try CaretMovement.horizontal(
            model,
            in: source,
            direction: .forward,
            unit: .word,
            extending: false
        )
        #expect(forward.ranges == [6..<6, 11..<11])

        let back = try CaretMovement.horizontal(
            try carets([8], source: source),
            in: source,
            direction: .backward,
            unit: .word,
            extending: false
        )
        #expect(back.primaryRange == 6..<6)
    }

    @Test("Word motion treats a boundary cluster and its mark as one unit")
    func wordMotionUsesClusters() throws {
        // "-" followed by a combining mark is a single cluster. Classifying
        // code units separately left backward motion on offset 1, inside the
        // cluster, and the caret set refused the move.
        let source = "a-\u{0301}b"
        let back = try CaretMovement.horizontal(
            try carets([4], source: source),
            in: source,
            direction: .backward,
            unit: .word,
            extending: false
        )
        #expect(back.primaryRange == 3..<3)

        let forward = try CaretMovement.horizontal(
            try carets([0], source: source),
            in: source,
            direction: .forward,
            unit: .word,
            extending: false
        )
        #expect(forward.primaryRange == 3..<3)
    }

    @Test("Line motion reaches the logical line boundaries")
    func lineMotion() throws {
        let source = "one\ntwo\nthree"
        let model = try carets([6], source: source)
        let end = try CaretMovement.horizontal(
            model,
            in: source,
            direction: .forward,
            unit: .line,
            extending: false
        )
        #expect(end.primaryRange == 7..<7)
        let start = try CaretMovement.horizontal(
            model,
            in: source,
            direction: .backward,
            unit: .line,
            extending: false
        )
        #expect(start.primaryRange == 4..<4)
    }

    @Test("Document motion reaches both ends")
    func documentMotion() throws {
        let source = "alpha beta"
        let model = try carets([5], source: source)
        let end = try CaretMovement.horizontal(
            model,
            in: source,
            direction: .forward,
            unit: .document,
            extending: false
        )
        #expect(end.primaryRange == 10..<10)
        let start = try CaretMovement.horizontal(
            model,
            in: source,
            direction: .backward,
            unit: .document,
            extending: false
        )
        #expect(start.primaryRange == 0..<0)
    }

    @Test("Shift+Right extends each caret from its own anchor")
    func extensionKeepsAnchors() throws {
        // The two histories of 2..<5 extend differently by design.
        let fromLeft = try selection([(2, 5)], primary: 0, source: "abcdefghij")
        let right = try CaretMovement.horizontal(
            fromLeft,
            in: "abcdefghij",
            direction: .forward,
            unit: .grapheme,
            extending: true
        )
        #expect(right.primaryRange == 2..<6)

        let fromRight = try selection([(5, 2)], primary: 0, source: "abcdefghij")
        let grown = try CaretMovement.horizontal(
            fromRight,
            in: "abcdefghij",
            direction: .forward,
            unit: .grapheme,
            extending: true
        )
        #expect(grown.primaryRange == 3..<5)
    }

    @Test("Shift+Left contracts a forward selection from its moving end")
    func contraction() throws {
        let model = try selection([(2, 5)], primary: 0, source: "abcdefghij")
        let contracted = try CaretMovement.horizontal(
            model,
            in: "abcdefghij",
            direction: .backward,
            unit: .grapheme,
            extending: true
        )
        #expect(contracted.primaryRange == 2..<4)
        #expect(contracted.primary.anchor == 2)
    }

    @Test("Vertical motion keeps a goal column across a short line")
    func verticalGoalColumn() throws {
        let source = "abcdefghij\nabc\nabcdefghij"
        let lines = TestLines(lines: [
            CaretDisplayLine(range: 0..<10),
            CaretDisplayLine(range: 11..<14),
            CaretDisplayLine(range: 15..<25)
        ])
        let model = try carets([7], source: source)
        let down = try CaretMovement.vertical(
            model,
            in: source,
            direction: .down,
            extending: false,
            lines: lines
        )
        #expect(down.primaryRange == 14..<14)
        #expect(down.primary.goalColumn == 7)

        let downAgain = try CaretMovement.vertical(
            down,
            in: source,
            direction: .down,
            extending: false,
            lines: lines
        )
        #expect(downAgain.primaryRange == 22..<22)

        let up = try CaretMovement.vertical(
            downAgain,
            in: source,
            direction: .up,
            extending: false,
            lines: lines
        )
        #expect(up.primaryRange == 14..<14)
        let upAgain = try CaretMovement.vertical(
            up,
            in: source,
            direction: .up,
            extending: false,
            lines: lines
        )
        #expect(upAgain.primaryRange == 7..<7)
    }

    @Test("Vertical motion stops at the first and last display line")
    func verticalBoundaries() throws {
        let source = "abc\ndef"
        let lines = TestLines(lines: [
            CaretDisplayLine(range: 0..<3),
            CaretDisplayLine(range: 4..<7)
        ])
        let model = try carets([1], source: source)
        let up = try CaretMovement.vertical(
            model,
            in: source,
            direction: .up,
            extending: false,
            lines: lines
        )
        #expect(up.primaryRange == 1..<1)
        #expect(up.primary.goalColumn == 1)

        let bottom = try carets([5], source: source)
        let down = try CaretMovement.vertical(
            bottom,
            in: source,
            direction: .down,
            extending: false,
            lines: lines
        )
        #expect(down.primaryRange == 5..<5)
    }

    @Test("Horizontal motion clears the vertical goal column")
    func horizontalClearsGoal() throws {
        let source = "abc\ndef"
        let lines = TestLines(lines: [
            CaretDisplayLine(range: 0..<3),
            CaretDisplayLine(range: 4..<7)
        ])
        let down = try CaretMovement.vertical(
            try carets([1], source: source),
            in: source,
            direction: .down,
            extending: false,
            lines: lines
        )
        #expect(down.primary.goalColumn == 1)
        let right = try CaretMovement.horizontal(
            down,
            in: source,
            direction: .forward,
            unit: .grapheme,
            extending: false
        )
        #expect(right.primary.goalColumn == nil)
        #expect(right.primaryRange == 6..<6)
    }

    @Test("Vertical motion onto one short line merges the carets")
    func verticalConvergence() throws {
        let source = "abcd\nab\nabcd"
        let lines = TestLines(lines: [
            CaretDisplayLine(range: 0..<4),
            CaretDisplayLine(range: 5..<7),
            CaretDisplayLine(range: 8..<12)
        ])
        let model = try carets([2, 3], primary: 1, source: source)
        let down = try CaretMovement.vertical(
            model,
            in: source,
            direction: .down,
            extending: false,
            lines: lines
        )
        #expect(down.count == 1)
        #expect(down.primaryRange == 7..<7)
    }

    @Test("Word motion treats an RTL run as one word")
    func wordMotionRTL() throws {
        let source = "שלום עולם"
        let forward = try CaretMovement.horizontal(
            try carets([0], source: source),
            in: source,
            direction: .forward,
            unit: .word,
            extending: false
        )
        #expect(forward.primaryRange == 5..<5)
        let back = try CaretMovement.horizontal(
            try carets([5], source: source),
            in: source,
            direction: .backward,
            unit: .word,
            extending: false
        )
        #expect(back.primaryRange == 0..<0)
    }
}
