import XCTest
@testable import Sonovo

@MainActor
final class TerminalSessionsTests: XCTestCase {
    private var fixture: ProjectUXTestSupport!

    override func setUp() {
        super.setUp()
        fixture = ProjectUXTestSupport()
    }

    override func tearDown() {
        fixture.tearDown()
        fixture = nil
        super.tearDown()
    }

    func testProcessProbeDrivesTheCount() {
        let store = TerminalSessionsStore()
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.runningProcessCount, 0)

        store.processProbe = { _ in true }
        store.refreshProcessStates()
        XCTAssertEqual(store.runningProcessCount, 1)

        // A repeated poll with the same answer must not invalidate chips.
        store.refreshProcessStates()
        XCTAssertEqual(store.runningProcessCount, 1)

        store.processProbe = { _ in false }
        store.refreshProcessStates()
        XCTAssertEqual(store.runningProcessCount, 0)
    }

    func testAddAndShutdownRefreshImmediately() {
        let store = TerminalSessionsStore()
        store.processProbe = { _ in true }
        store.refreshProcessStates()
        XCTAssertEqual(store.runningProcessCount, 1)

        store.addSession()
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.runningProcessCount, 2)

        store.shutdownAll(force: true)
        XCTAssertEqual(store.sessions.count, 0)
        XCTAssertEqual(store.runningProcessCount, 0)
    }

    func testWorkspaceRefreshesEveryProject() throws {
        let workspace = fixture.makeWorkspace()
        let project = try XCTUnwrap(
            workspace.openProject(
                at: try fixture.makeRoot(name: "one")
            )
        )
        workspace.demoProject.terminalSessions.processProbe = { _ in true }
        project.terminalSessions.processProbe = { _ in true }

        workspace.refreshTerminalProcessStates()

        XCTAssertEqual(
            workspace.demoProject.terminalSessions.runningProcessCount,
            1
        )
        XCTAssertEqual(
            project.terminalSessions.runningProcessCount,
            1
        )
    }
}
