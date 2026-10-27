import Foundation
import Testing
@testable import SonovoCore

@Suite("Multi cursor edit")
struct MultiCursorEditTests {
    private func model(
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
        try model(offsets.map { ($0, $0) }, primary: primary, source: source)
    }

    private func output(
        _ operation: MultiCursorEdit.Operation,
        _ source: String,
        _ selection: MultiCursorSelection
    ) throws -> MultiCursorEdit.Output {
        switch MultiCursorEdit.apply(
            operation,
            to: source,
            selection: selection
        ) {
        case .success(let output):
            return output
        case .failure(let failure):
            throw failure
        }
    }

    @Test("Insert at three carets")
    func insertAtThreeCarets() throws {
        let source = "alpha beta gamma"
        let selection = try carets([0, 6, 11], primary: 1, source: source)
        let result = try output(.insert("X"), source, selection)
        #expect(result.source == "Xalpha Xbeta Xgamma")
        #expect(result.selection.ranges == [1..<1, 8..<8, 14..<14])
        #expect(result.selection.primaryRange == 8..<8)
        #expect(result.actionName == "Typing")
        #expect(result.previousSource == source)
        #expect(result.replacements.map(\.range) == [11..<11, 6..<6, 0..<0])
    }

    @Test("Replace unequal selections")
    func replaceUnequalSelections() throws {
        let source = "alpha beta gamma"
        let selection = try model([(0, 5), (6, 10)], primary: 0, source: source)
        let result = try output(.replace("Q"), source, selection)
        #expect(result.source == "Q Q gamma")
        #expect(result.selection.ranges == [1..<1, 3..<3])
    }

    @Test("Backspace at a line start removes the newline")
    func deleteBackwardAtLineStart() throws {
        let source = "abc\ndef"
        let selection = try carets([4], source: source)
        let result = try output(.deleteBackward, source, selection)
        #expect(result.source == "abcdef")
        #expect(result.selection.ranges == [3..<3])
    }

    @Test("Backspace removes a whole emoji cluster")
    func deleteBackwardEmoji() throws {
        let source = "👩‍💻x"
        let selection = try carets([5], source: source)
        let result = try output(.deleteBackward, source, selection)
        #expect(result.source == "x")
        #expect(result.selection.ranges == [0..<0])
    }

    @Test("Backspace removes one CJK character")
    func deleteBackwardCJK() throws {
        let source = "你好"
        let selection = try carets([1], source: source)
        let result = try output(.deleteBackward, source, selection)
        #expect(result.source == "好")
        #expect(result.selection.ranges == [0..<0])
    }

    @Test("Forward delete at a line end removes the newline")
    func deleteForwardAtLineEnd() throws {
        let source = "ab\ncd"
        let selection = try carets([2], source: source)
        let result = try output(.deleteForward, source, selection)
        #expect(result.source == "abcd")
        #expect(result.selection.ranges == [2..<2])
    }

    @Test("Forward delete at EOF changes nothing")
    func deleteForwardAtEOF() throws {
        let source = "abc"
        let selection = try carets([3], source: source)
        let result = try output(.deleteForward, source, selection)
        #expect(result.changed == false)
        #expect(result.replacements.isEmpty)
        #expect(result.selection == selection)
    }

    @Test("Adjacent carets delete adjacent graphemes and merge")
    func adjacentCaretsDeleteBackward() throws {
        let source = "abcdef"
        let selection = try model([(3, 3), (4, 4)], primary: 0, source: source)
        let result = try output(.deleteBackward, source, selection)
        #expect(result.source == "abef")
        #expect(result.selection.ranges == [2..<2])
    }

    @Test("Backspace at offset zero is a no-op")
    func deleteBackwardAtStart() throws {
        let source = "abc"
        let selection = try carets([0], source: source)
        let result = try output(.deleteBackward, source, selection)
        #expect(result.changed == false)
        #expect(result.selection == selection)
    }

    @Test("A mixed batch applies the edit and keeps the no-op caret in place")
    func mixedNoOpAndEdit() throws {
        let source = "abc"
        let selection = try carets([0, 3], primary: 0, source: source)
        let result = try output(.deleteForward, source, selection)
        #expect(result.source == "bc")
        #expect(result.selection.ranges == [0..<0, 2..<2])
    }

    @Test("Multi-line paste at several carets")
    func multiLinePaste() throws {
        let source = "alpha beta"
        let selection = try carets([0, 6], source: source)
        let result = try output(.paste("1\n2"), source, selection)
        #expect(result.source == "1\n2alpha 1\n2beta")
        #expect(result.selection.ranges == [3..<3, 12..<12])
    }

    @Test("A selection plus a caret inside its deleted span is refused")
    func overlapRefusal() throws {
        let source = "abcdef"
        let selection = try model([(0, 5), (5, 5)], primary: 0, source: source)
        let result = MultiCursorEdit.apply(
            .deleteBackward,
            to: source,
            selection: selection
        )
        if case .failure(let failure) = result {
            #expect(failure == .overlapping)
        } else {
            Issue.record("expected an overlapping refusal")
        }
    }

    @Test("A deleted selection collapses its caret to the replacement end")
    func replaceSelectionAcrossLines() throws {
        let source = "one\ntwo\nthree"
        let selection = try model([(0, 7)], primary: 0, source: source)
        let result = try output(.replace("X"), source, selection)
        #expect(result.source == "X\nthree")
        #expect(result.selection.ranges == [1..<1])
    }

    @Test("A caret set built on another source is refused at its endpoints")
    func staleSelectionEndpoints() throws {
        // 1..<2 is a boundary in "ab" but falls inside the cluster
        // "e" + U+0301. The engine must reject it rather than split the
        // grapheme, because the set was validated against a different source.
        let source = "e\u{0301}"
        let selection = try model([(1, 2)], primary: 0, source: "ab")
        let result = MultiCursorEdit.apply(
            .replace("X"),
            to: source,
            selection: selection
        )
        if case .failure(let failure) = result {
            #expect(failure == .graphemeSplit(1))
        } else {
            Issue.record("expected a grapheme-split refusal")
        }
    }

    @Test("A merge that leaves the caret inside a cluster snaps to its end")
    func caretSnapsOutOfAMergedCluster() throws {
        // Inserting the base "e" before a leading combining mark merges the
        // two into one cluster; the caret would otherwise land between them
        // and the whole batch would be refused.
        let source = "\u{0301}b"
        let selection = try carets([0], source: source)
        let result = try output(.insert("e"), source, selection)
        #expect(result.source == "e\u{0301}b")
        #expect(result.selection.ranges == [2..<2])
    }

    @Test("A canonically equal replacement that changes code units counts")
    func canonicalEqualityIsNotEnough() throws {
        // Swift's `String ==` says these are equal, so a code-unit-only
        // replacement was reported as unchanged and never written.
        let first = "a\u{0301}\u{0323}"
        let second = "a\u{0323}\u{0301}"
        #expect(first.utf16.count == second.utf16.count)
        let selection = try model([(0, 3)], primary: 0, source: first)
        let result = try output(.replace(second), first, selection)
        #expect(result.changed)
        #expect(result.source.utf16.elementsEqual(second.utf16))
    }

    @Test("A paste larger than the replacement limit is refused before building")
    func projectedSizeIsChecked() throws {
        // The payload would exceed the document's replacement limit once
        // multiplied across carets. The guard must fire before the mutable
        // string is built, so the assertion is on the typed failure. Both
        // insertions add to the size, so the peak is the starting length
        // plus both payloads.
        let source = "ab ab"
        let selection = try carets([0, 3], source: source)
        let payload = String(
            repeating: "x",
            count: DocumentHistoryLimits.maxReplacementBytes
        )
        let result = MultiCursorEdit.apply(
            .paste(payload),
            to: source,
            selection: selection
        )
        if case .failure(let failure) = result {
            #expect(failure == .resultTooLarge(
                source.utf16.count + payload.utf16.count * 2
            ))
        } else {
            Issue.record("expected a size refusal")
        }
    }

    @Test("A batch is judged by its peak, not by an intermediate total")
    func shrinkingBatchIsNotRefused() throws {
        // The first replacement in caret order grows the document past the
        // limit, but replacements are applied descending: the shrinking tail
        // runs first and the peak is the starting length itself. Refusing the
        // running total rejected this valid batch.
        let length = DocumentHistoryLimits.maxReplacementBytes
        let source = String(repeating: "x", count: length)
        let selection = try model(
            [(0, 0), (1, length)],
            primary: 0,
            source: source
        )
        let result = try output(.replace("x"), source, selection)
        #expect(result.source == "xxx")
    }

    @Test("A peak above the limit is refused even when the final size fits")
    func peakAllocationIsRefused() throws {
        // The high insertion runs first and lifts the string to 12 MB + 8 MB;
        // the low replacement then shrinks it to 16 MB, exactly the limit.
        // A final-size check alone would let the 20 MB intermediate through.
        let limit = DocumentHistoryLimits.maxReplacementBytes
        let sourceLength = limit * 3 / 4
        let payloadLength = limit / 2
        let source = String(repeating: "x", count: sourceLength)
        let payload = String(repeating: "y", count: payloadLength)
        let selection = try model(
            [(0, sourceLength), (sourceLength, sourceLength)],
            primary: 0,
            source: source
        )
        let result = MultiCursorEdit.apply(
            .replace(payload),
            to: source,
            selection: selection
        )
        if case .failure(let failure) = result {
            #expect(failure == .resultTooLarge(sourceLength + payloadLength))
        } else {
            Issue.record("expected a peak-size refusal")
        }
    }

    @Test("Deletion refuses a stale caret inside a cluster instead of widening it")
    func deletionRefusesStaleClusterCaret() throws {
        // The caret is a boundary in "ab" but falls inside the composed
        // "e" + U+0301 here. Widening it to that cluster deleted text the
        // caret never named; the stale endpoint must be refused instead.
        let stale = try carets([1], source: "ab")
        let target = "e\u{301}"
        for operation in [
            MultiCursorEdit.Operation.deleteBackward,
            .deleteForward
        ] {
            switch MultiCursorEdit.apply(
                operation,
                to: target,
                selection: stale
            ) {
            case .failure(let failure):
                #expect(failure == .graphemeSplit(1))
            case .success:
                Issue.record("expected a grapheme-split refusal")
            }
        }
    }

    @Test("Every operation reports its action name")
    func actionNames() throws {
        let source = "abc"
        let selection = try carets([1], source: source)
        #expect(
            try output(.insert("x"), source, selection).actionName
                == "Typing"
        )
        #expect(
            try output(.deleteBackward, source, selection).actionName
                == "Delete Backward"
        )
        #expect(
            try output(.deleteForward, source, selection).actionName
                == "Delete Forward"
        )
        #expect(
            try output(.replace("x"), source, selection).actionName
                == "Replace"
        )
        #expect(
            try output(.paste("x"), source, selection).actionName == "Paste"
        )
    }

    @Test("The offset mapping matches a brute-force oracle on random batches")
    func oracle() throws {
        var random = LCG(state: 0x5EED_1234_ABCD_0001)
        let source = "abcdefghijklmnopqrstuvwxyz"
        let ns = source as NSString
        for _ in 0..<80 {
            let count = 1 + random.next(5)
            var offsets: Set<Int> = []
            while offsets.count < count {
                offsets.insert(random.next(ns.length + 1))
            }
            let sorted = offsets.sorted()
            let selection = try carets(sorted, source: source)
            let text = String(repeating: "X", count: 1 + random.next(3))
            let result = try output(.insert(text), source, selection)

            let edits = sorted.map { ($0..<$0, text) }
            let expected = oracleApply(edits, source: source)
            #expect(result.source == expected.source)
            // The oracle emits positions in sorted caret order.
            let positions = result.selection.carets.map(\.active)
            #expect(positions == expected.positions)
        }
    }

    @Test("Backward deletion matches a brute-force oracle on random batches")
    func oracleDeleteBackward() throws {
        var random = LCG(state: 0xDEAD_BEEF_0000_0001)
        let source = "abcdefghijklmnopqrstuvwxyz"
        let ns = source as NSString
        for _ in 0..<80 {
            let count = 1 + random.next(4)
            var offsets: Set<Int> = []
            while offsets.count < count {
                offsets.insert(1 + random.next(ns.length))
            }
            let sorted = offsets.sorted()
            let selection = try carets(sorted, source: source)
            let result = try output(.deleteBackward, source, selection)
            let edits = sorted.map { offset -> (Range<Int>, String) in
                let cluster = ns.rangeOfComposedCharacterSequence(
                    at: offset - 1
                )
                return (
                    cluster.location..<(cluster.location + cluster.length),
                    ""
                )
            }
            let expected = oracleApply(edits, source: source)
            #expect(result.source == expected.source)
            // Adjacent deletions converge on one offset; the model merges
            // those carets (invariant 8).
            let expectedPositions = Array(Set(expected.positions)).sorted()
            #expect(
                result.selection.carets.map(\.active) == expectedPositions
            )
        }
    }

    private func oracleApply(
        _ edits: [(Range<Int>, String)],
        source: String
    ) -> (source: String, positions: [Int]) {
        let ns = source as NSString
        var result = ""
        var cursor = 0
        var positions: [Int] = []
        for (range, text) in edits.sorted(
            by: { $0.0.lowerBound < $1.0.lowerBound }
        ) {
            result += ns.substring(
                with: NSRange(
                    location: cursor,
                    length: range.lowerBound - cursor
                )
            )
            result += text
            positions.append((result as NSString).length)
            cursor = range.upperBound
        }
        result += ns.substring(from: cursor)
        return (result, positions)
    }
}

private struct LCG {
    var state: UInt64

    mutating func next(_ upper: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005
            &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(upper))
    }
}
