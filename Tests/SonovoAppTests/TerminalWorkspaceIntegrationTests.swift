import XCTest
import SonovoTerminalFeature
@testable import Sonovo
@MainActor final class TerminalWorkspaceIntegrationTests: XCTestCase {
    func testWorkspaceRefreshesEveryProject() throws {
        let fixture = ProjectUXTestSupport()
        defer { fixture.tearDown() }
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
