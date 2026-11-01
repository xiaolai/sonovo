import XCTest
@testable import SonovoDocumentSupport

@MainActor
final class CloseCoordinatorTests: XCTestCase {
    func testRedirtyingRequiresAnotherDeterministicallyOrderedPass() async {
        var firstDirty = true
        var secondDirty = true
        var calls: [String] = []
        let participants = [
            CloseFlushParticipant(
                isDirty: { firstDirty },
                flush: { calls.append("first"); firstDirty = false; return true },
                revealFailure: { XCTFail("unexpected failure") }
            ),
            CloseFlushParticipant(
                isDirty: { secondDirty },
                flush: { calls.append("second"); firstDirty = true; secondDirty = false; return true },
                revealFailure: { XCTFail("unexpected failure") }
            )
        ]
        let result = await DocumentCloseCoordinator().flush(
            participants: { participants }, allClean: { !firstDirty && !secondDirty }
        )
        XCTAssertTrue(result)
        XCTAssertEqual(calls, ["first", "second", "first"])
    }

    func testFailureRevealsItsOwnerAndStopsLaterParticipants() async {
        var calls: [String] = []
        let participants = [
            CloseFlushParticipant(isDirty: { true }, flush: { calls.append("failed"); return false },
                                  revealFailure: { calls.append("reveal owner") }),
            CloseFlushParticipant(isDirty: { true }, flush: { calls.append("wrong"); return true },
                                  revealFailure: {})
        ]
        let result = await DocumentCloseCoordinator().flush(participants: { participants }, allClean: { false })
        XCTAssertFalse(result)
        XCTAssertEqual(calls, ["failed", "reveal owner"])
    }

    func testContinuouslyRedirtiedDocumentsStopAfterThreePasses() async {
        var passes = 0
        let participant = CloseFlushParticipant(
            isDirty: { true }, flush: { passes += 1; return true }, revealFailure: {}
        )
        let result = await DocumentCloseCoordinator().flush(participants: { [participant] }, allClean: { false })
        XCTAssertFalse(result)
        XCTAssertEqual(passes, 3)
    }
}
