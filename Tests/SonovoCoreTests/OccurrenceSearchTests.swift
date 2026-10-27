import Foundation
import Testing
@testable import SonovoCore

@Suite("Occurrence search")
struct OccurrenceSearchTests {
    private func carets(
        _ offsets: [Int],
        primary: Int = 0,
        source: String
    ) throws -> MultiCursorSelection {
        try MultiCursorSelection(
            offsets.map {
                MultiCursorSelection.Caret(anchor: $0, active: $0)
            },
            primary: primary,
            source: source
        )
    }

    private func selection(
        _ range: Range<Int>,
        source: String
    ) throws -> MultiCursorSelection {
        try MultiCursorSelection(
            [MultiCursorSelection.Caret(
                anchor: range.lowerBound,
                active: range.upperBound
            )],
            primary: 0,
            source: source
        )
    }

    @Test("Search is exact and case-sensitive")
    func exact() {
        let source = "Alpha alpha alpha"
        #expect(
            OccurrenceSearch.occurrences(of: "alpha", in: source)
                == [6..<11, 12..<17]
        )
        #expect(
            OccurrenceSearch.occurrences(of: "Alpha", in: source)
                == [0..<5]
        )
        #expect(OccurrenceSearch.occurrences(of: "missing", in: source) == [])
    }

    @Test("Search does not produce overlapping ranges")
    func nonOverlapping() {
        let source = "ababa"
        #expect(
            OccurrenceSearch.occurrences(of: "aba", in: source)
                == [0..<3]
        )
        #expect(
            OccurrenceSearch.occurrences(of: "aa", in: "aaaa")
                == [0..<2, 2..<4]
        )
    }

    @Test("A match that splits a grapheme is skipped")
    func graphemeSnapped() {
        // The second "e" is the base of a composed cluster; its end would
        // fall inside the cluster, so it cannot become a caret.
        let source = "e e\u{301}"
        #expect(
            OccurrenceSearch.occurrences(of: "e", in: source)
                == [0..<1]
        )
        #expect(
            OccurrenceSearch.occurrences(of: "e\u{301}", in: source)
                == [2..<4]
        )
    }

    @Test("The word under a caret follows the navigation word rule")
    func wordUnderCaret() {
        let source = "alpha beta-gamma"
        #expect(
            OccurrenceSearch.wordRange(at: 2, in: source) == 0..<5
        )
        // A caret at a word's end names the word before it.
        #expect(
            OccurrenceSearch.wordRange(at: 5, in: source) == 0..<5
        )
        #expect(
            OccurrenceSearch.wordRange(at: 6, in: source) == 6..<10
        )
        // Hyphen is a word boundary, matching Option+arrow.
        #expect(
            OccurrenceSearch.wordRange(at: 12, in: source) == 11..<16
        )
        // Between two boundary characters there is no word at all.
        #expect(
            OccurrenceSearch.wordRange(at: 6, in: "alpha  beta") == nil
        )
    }

    @Test("A primary selection names its own text, not the word")
    func selectionQuery() throws {
        let source = "alpha beta"
        let model = try selection(3..<5, source: source)
        #expect(
            OccurrenceSearch.queryRange(for: model.primary, in: source)
                == 3..<5
        )
    }

    @Test("Adding the next occurrence upgrades a bare caret to its word")
    func addingNextUpgradesWord() throws {
        let source = "alpha beta alpha gamma alpha"
        let model = try carets([2], source: source)
        let first = try OccurrenceSearch.addingNext(to: model, in: source)
        #expect(first.ranges == [0..<5, 11..<16])
        #expect(first.primaryRange == 11..<16)

        let second = try OccurrenceSearch.addingNext(to: first, in: source)
        #expect(second.ranges == [0..<5, 11..<16, 23..<28])
        #expect(second.primaryRange == 23..<28)
    }

    @Test("Adding wraps once and refuses when every occurrence is placed")
    func addingWrapsAndRefuses() throws {
        let source = "alpha beta alpha"
        let model = try selection(11..<16, source: source)
        let wrapped = try OccurrenceSearch.addingNext(to: model, in: source)
        #expect(wrapped.ranges == [0..<5, 11..<16])
        #expect(wrapped.primaryRange == 0..<5)

        #expect(throws: OccurrenceSearch.Failure.noMoreOccurrences) {
            _ = try OccurrenceSearch.addingNext(to: wrapped, in: source)
        }
    }

    @Test("An overlapping existing caret is not displaced")
    func addingSkipsConflicts() throws {
        // The second caret sits inside the second occurrence. Placing that
        // occurrence would replace the caret, so the command refuses rather
        // than silently discarding a selection.
        let source = "alpha alpha"
        let model = try MultiCursorSelection(
            [
                MultiCursorSelection.Caret(anchor: 0, active: 5),
                MultiCursorSelection.Caret(anchor: 6, active: 9)
            ],
            primary: 0,
            source: source
        )
        #expect(throws: OccurrenceSearch.Failure.noMoreOccurrences) {
            _ = try OccurrenceSearch.addingNext(to: model, in: source)
        }
    }

    @Test("A caret in whitespace names no query")
    func noQueryInWhitespace() throws {
        let source = "alpha  beta"
        let model = try carets([6], source: source)
        #expect(throws: OccurrenceSearch.Failure.noQuery) {
            _ = try OccurrenceSearch.addingNext(to: model, in: source)
        }
        #expect(throws: OccurrenceSearch.Failure.noQuery) {
            _ = try OccurrenceSearch.selectingAll(in: model, source: source)
        }
    }

    @Test("Selecting all keeps the occurrence under the caret primary")
    func selectingAllPrimary() throws {
        let source = "alpha beta alpha gamma alpha"
        let model = try carets([13], source: source)
        let all = try OccurrenceSearch.selectingAll(in: model, source: source)
        #expect(all.ranges == [0..<5, 11..<16, 23..<28])
        #expect(all.primaryRange == 11..<16)
    }

    @Test("Selecting all refuses beyond the caret cap")
    func selectingAllCap() throws {
        let source = String(repeating: "ab ", count: 101)
        let model = try carets([0], source: source)
        #expect(throws: OccurrenceSearch.Failure.exceedsCaretLimit(100)) {
            _ = try OccurrenceSearch.selectingAll(in: model, source: source)
        }
        // Exactly at the cap is allowed.
        let atCap = String(repeating: "ab ", count: 100)
        let capped = try OccurrenceSearch.selectingAll(
            in: try carets([0], source: atCap),
            source: atCap
        )
        #expect(capped.count == 100)
    }

    @Test("A bare caret inside a cluster of this source names no query")
    func staleCaretInsideClusterIsRefused() throws {
        // Offset 1 is a boundary in "ab" but falls inside the composed
        // "e" + U+0301 in the queried text. Widening it to the word made the
        // stale position look valid; the caret itself must be checked.
        let stale = try carets([1], source: "ab")
        let source = "e\u{301} e\u{301}"
        do {
            _ = try OccurrenceSearch.addingNext(to: stale, in: source)
            Issue.record("expected a no-query refusal")
        } catch let failure as OccurrenceSearch.Failure {
            #expect(failure == .noQuery)
        }
        do {
            _ = try OccurrenceSearch.selectingAll(in: stale, source: source)
            Issue.record("expected a no-query refusal")
        } catch let failure as OccurrenceSearch.Failure {
            #expect(failure == .noQuery)
        }
    }

    @Test("A caret set built on another source is refused, not extracted")
    func staleSelectionIsRefused() throws {
        // The selection names 0..<5 in a five-character source. Using it
        // against "x" used to reach NSString.substring and raise an
        // Objective-C range exception, which terminates the process.
        let stale = try MultiCursorSelection(
            [MultiCursorSelection.Caret(anchor: 0, active: 5)],
            primary: 0,
            source: "alpha"
        )
        #expect(throws: OccurrenceSearch.Failure.noQuery) {
            _ = try OccurrenceSearch.addingNext(to: stale, in: "x")
        }
        #expect(throws: OccurrenceSearch.Failure.noQuery) {
            _ = try OccurrenceSearch.selectingAll(in: stale, source: "x")
        }
    }

    @Test("A selection the enumeration straddles keeps its own position primary")
    func selectingAllStraddledPrimary() throws {
        // "aa" occurs at 0 and 2; the selection 1..<3 is not one of them.
        // Primary index 0 would jump the caret back to the document start;
        // the occurrence that contains offset 1 is the one the user is in.
        let source = "aaaa"
        let model = try MultiCursorSelection(
            [MultiCursorSelection.Caret(anchor: 1, active: 3)],
            primary: 0,
            source: source
        )
        let all = try OccurrenceSearch.selectingAll(in: model, source: source)
        #expect(all.ranges == [0..<2, 2..<4])
        #expect(all.primaryRange == 0..<2)
    }

    @Test("Word ranges follow composed character sequences")
    func wordRangeUsesClusters() {
        // "-" followed by a combining mark is one cluster. Classifying its
        // code units separately let the mark answer for the base and could
        // produce a range that split the cluster.
        let source = "a-\u{0301}b"
        #expect(OccurrenceSearch.wordRange(at: 4, in: source) == 3..<4)
        #expect(OccurrenceSearch.wordRange(at: 3, in: source) == 3..<4)
    }
}
