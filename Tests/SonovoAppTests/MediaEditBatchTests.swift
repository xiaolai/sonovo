import XCTest
@testable import Sonovo

@MainActor
final class MediaEditBatchTests: XCTestCase {
    func testRemoveRangesSubtractsFromCurrentEditsAndClearsSelection() {
        var state = MediaEditState(
            sourceDuration: 10,
            keepRanges: [
                MediaTimeRange(start: 0, duration: 2),
                MediaTimeRange(start: 4, duration: 2)
            ],
            selection: MediaTimeRange(start: 1, duration: 1)
        )
        XCTAssertEqual(
            state.removeRanges([
                MediaTimeRange(start: 1, duration: 0.5),
                MediaTimeRange(start: 5, duration: 0.5)
            ]),
            .changed
        )
        XCTAssertEqual(state.keepRanges, [
            MediaTimeRange(start: 0, duration: 1),
            MediaTimeRange(start: 1.5, duration: 0.5),
            MediaTimeRange(start: 4, duration: 1),
            MediaTimeRange(start: 5.5, duration: 0.5)
        ])
        XCTAssertNil(state.selection)
    }

    func testRemoveRangesIsIdempotentAndOrderIndependant() {
        let cuts = [
            MediaTimeRange(start: 2, duration: 1),
            MediaTimeRange(start: 5, duration: 1)
        ]
        var first = MediaEditState(sourceDuration: 10)
        var second = MediaEditState(sourceDuration: 10)
        XCTAssertEqual(first.removeRanges(cuts), .changed)
        XCTAssertEqual(second.removeRanges(Array(cuts.reversed())), .changed)
        XCTAssertEqual(first.keepRanges, second.keepRanges)
        XCTAssertEqual(first.removeRanges(cuts), .unchanged)
    }

    func testRemoveRangesRefusesAnAlmostEmptyResult() {
        var state = MediaEditState(sourceDuration: 1)
        let before = state.snapshot
        XCTAssertEqual(
            state.removeRanges([MediaTimeRange(start: 0.1, duration: 0.8)]),
            .tooShort
        )
        XCTAssertEqual(state.snapshot, before)
    }

    func testDocumentSavesOneUndoEntryForABatch() {
        let document = MediaEditDocument(asset: makeAsset())
        document.prepare(sourceDuration: 10)
        _ = document.setSelection(start: 1, end: 1.5)
        _ = document.deleteSelection()
        let before = document.editState

        XCTAssertEqual(
            document.removeRanges([
                MediaTimeRange(start: 2, duration: 1),
                MediaTimeRange(start: 5, duration: 1)
            ]),
            .changed
        )
        XCTAssertTrue(document.canUndo)
        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.editState, before)
    }

    func testNudgeClampsTheEdgeWithoutSwappingOrClearingTheSelection() {
        let document = MediaEditDocument(asset: makeAsset())
        document.prepare(sourceDuration: 10)
        _ = document.setSelection(start: 3, end: 5)
        XCTAssertFalse(document.canUndo)

        XCTAssertTrue(document.nudgeSelectionStart(bySourceDelta: 5))
        XCTAssertEqual(document.selection?.start ?? 0, 4.98, accuracy: 0.0001)
        XCTAssertEqual(document.selection?.end ?? 0, 5, accuracy: 0.0001)
        XCTAssertFalse(document.canUndo)

        XCTAssertTrue(document.nudgeSelectionStart(bySourceDelta: -10))
        XCTAssertEqual(document.selection?.start ?? 0, 0, accuracy: 0.0001)
        XCTAssertEqual(document.selection?.end ?? 0, 5, accuracy: 0.0001)

        XCTAssertTrue(document.nudgeSelectionEnd(bySourceDelta: -10))
        XCTAssertEqual(document.selection?.start ?? 0, 0, accuracy: 0.0001)
        XCTAssertEqual(
            document.selection?.duration ?? 0,
            MediaEditLimits.minimumSelectionDuration,
            accuracy: 0.0001
        )
        XCTAssertFalse(document.canUndo)
    }

    func testNudgeWithoutSelectionIsANoOp() {
        let document = MediaEditDocument(asset: makeAsset())
        document.prepare(sourceDuration: 10)
        XCTAssertFalse(document.nudgeSelectionStart(bySourceDelta: 0.1))
        XCTAssertFalse(document.nudgeSelectionEnd(bySourceDelta: 0.1))
    }

    func testExportLockAndStaleStateRejectEveryMutation() {
        let document = MediaEditDocument(asset: makeAsset())
        document.prepare(sourceDuration: 10)
        _ = document.setSelection(start: 1, end: 2)
        document.beginExportLock()

        XCTAssertFalse(document.setSelection(start: 2, end: 3))
        XCTAssertFalse(document.nudgeSelectionStart(bySourceDelta: 0.1))
        XCTAssertEqual(
            document.removeRanges([MediaTimeRange(start: 1, duration: 1)]),
            .unchanged
        )
        XCTAssertFalse(document.trimToSelection())

        document.endExportLock()
        XCTAssertTrue(document.setSelection(start: 2, end: 3))

        let changed = ProjectAsset(
            id: "batch-test",
            url: makeAsset().url,
            name: "batch-test.wav",
            relativePath: "batch-test.wav",
            kind: .audio,
            size: 2,
            modified: Date(timeIntervalSince1970: 2),
            revision: AssetRevision(
                fileIdentifier: "other",
                size: 2,
                modified: Date(timeIntervalSince1970: 2)
            )
        )
        document.observe(asset: changed)
        XCTAssertTrue(document.isStale)
        XCTAssertFalse(document.setSelection(start: 1, end: 2))
        XCTAssertFalse(document.nudgeSelectionEnd(bySourceDelta: 0.1))
    }

    func testUndoAndRedoAreFrozenWhileExportingOrStale() {
        let document = MediaEditDocument(asset: makeAsset())
        document.prepare(sourceDuration: 10)
        _ = document.setSelection(start: 1, end: 2)
        XCTAssertTrue(document.deleteSelection())
        XCTAssertTrue(document.canUndo)

        document.beginExportLock()
        XCTAssertFalse(document.canUndo)
        XCTAssertFalse(document.undo())
        document.endExportLock()

        XCTAssertTrue(document.canUndo)
        XCTAssertTrue(document.undo())
        XCTAssertTrue(document.canRedo)

        let changed = ProjectAsset(
            id: "batch-test",
            url: makeAsset().url,
            name: "batch-test.wav",
            relativePath: "batch-test.wav",
            kind: .audio,
            size: 2,
            modified: Date(timeIntervalSince1970: 2),
            revision: AssetRevision(
                fileIdentifier: "other",
                size: 2,
                modified: Date(timeIntervalSince1970: 2)
            )
        )
        document.observe(asset: changed)
        XCTAssertTrue(document.isStale)
        XCTAssertFalse(document.canRedo)
        XCTAssertFalse(document.redo())
    }

    func testRetainedDurationMatchesTheRemoval() {
        let state = MediaEditState(
            sourceDuration: 10,
            keepRanges: [
                MediaTimeRange(start: 0, duration: 2),
                MediaTimeRange(start: 4, duration: 2)
            ]
        )
        XCTAssertEqual(
            state.retainedDuration(afterRemoving: [
                MediaTimeRange(start: 1, duration: 4)
            ]),
            2,
            accuracy: 0.0001
        )
    }

    private func makeAsset() -> ProjectAsset {
        ProjectAsset(
            id: "batch-test",
            url: URL(fileURLWithPath: "/tmp/batch-test.wav"),
            name: "batch-test.wav",
            relativePath: "batch-test.wav",
            kind: .audio,
            size: 1,
            modified: Date(timeIntervalSince1970: 1),
            revision: AssetRevision(
                fileIdentifier: "first",
                size: 1,
                modified: Date(timeIntervalSince1970: 1)
            )
        )
    }
}
