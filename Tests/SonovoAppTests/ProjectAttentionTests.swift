import XCTest
@testable import Sonovo

final class ProjectAttentionTests: XCTestCase {
    func testQuietInputHasNoStatuses() {
        let snapshot = ProjectAttentionInput().snapshot
        XCTAssertTrue(snapshot.isQuiet)
        XCTAssertTrue(snapshot.statuses.isEmpty)
        XCTAssertTrue(snapshot.flags.isEmpty)
        XCTAssertEqual(snapshot.summary, "")
    }

    func testEachInputMapsToItsStatus() {
        var input = ProjectAttentionInput()
        input.dirtyDocumentCount = 2
        XCTAssertEqual(input.snapshot.statuses, [.dirtyDocuments])
        XCTAssertTrue(
            input.snapshot.flags.contains(.dirtyDocuments)
        )

        input = ProjectAttentionInput()
        input.isOffline = true
        XCTAssertEqual(input.snapshot.statuses, [.offline])

        input = ProjectAttentionInput()
        input.runningTerminalCount = 1
        XCTAssertEqual(input.snapshot.statuses, [.runningTerminal])

        input = ProjectAttentionInput()
        input.hasRunningConversion = true
        XCTAssertEqual(input.snapshot.statuses, [.converting3D])

        input = ProjectAttentionInput()
        input.hasBackgroundChanges = true
        XCTAssertEqual(input.snapshot.statuses, [.backgroundChanges])
    }

    func testPendingDecisionSuppressesTheDirtyBadge() {
        var input = ProjectAttentionInput()
        input.dirtyDocumentCount = 3
        input.hasPendingSaveDecision = true
        input.isOffline = true

        let snapshot = input.snapshot

        XCTAssertEqual(
            snapshot.statuses,
            [.pendingSaveDecision, .offline]
        )
        XCTAssertFalse(snapshot.flags.contains(.dirtyDocuments))
        XCTAssertEqual(snapshot.dirtyDocumentCount, 3)
        XCTAssertTrue(
            snapshot.summary.contains("save decision")
        )
    }

    func testStatusesKeepPriorityOrderAndChipsShowThree() {
        var input = ProjectAttentionInput()
        input.isOffline = true
        input.dirtyDocumentCount = 1
        input.runningTerminalCount = 2
        input.hasRunningConversion = true
        input.hasBackgroundChanges = true

        let snapshot = input.snapshot

        XCTAssertEqual(
            snapshot.statuses,
            [
                .offline,
                .dirtyDocuments,
                .runningTerminal,
                .converting3D,
                .backgroundChanges
            ]
        )
        XCTAssertEqual(
            snapshot.badges(),
            [.offline, .dirtyDocuments, .runningTerminal]
        )
        XCTAssertEqual(snapshot.overflowCount, 2)
        XCTAssertTrue(
            snapshot.summary.contains("2 terminal processes running")
        )
    }

    func testSummaryUsesSingularAndPluralLabels() {
        var input = ProjectAttentionInput()
        input.dirtyDocumentCount = 1
        XCTAssertTrue(
            input.snapshot.summary.contains("1 unsaved document")
        )

        input.dirtyDocumentCount = 2
        XCTAssertTrue(
            input.snapshot.summary.contains("2 unsaved documents")
        )

        input = ProjectAttentionInput()
        input.runningTerminalCount = 1
        XCTAssertTrue(
            input.snapshot.summary.contains("1 terminal process running")
        )
        input.runningTerminalCount = 2
        XCTAssertTrue(
            input.snapshot.summary.contains("2 terminal processes running")
        )
    }
}
