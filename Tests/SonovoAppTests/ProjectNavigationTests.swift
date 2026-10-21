import XCTest
@testable import Sonovo

@MainActor
final class ProjectNavigationTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots = []
        super.tearDown()
    }

    func testShortcutOrderIsProjectsThenDemo() throws {
        let workspace = makeWorkspace()
        let first = try XCTUnwrap(
            workspace.openProject(at: try makeRoot())
        )
        let second = try XCTUnwrap(
            workspace.openProject(at: try makeRoot())
        )

        XCTAssertTrue(workspace.project(atShortcutIndex: 0) === first)
        XCTAssertTrue(workspace.project(atShortcutIndex: 1) === second)
        XCTAssertTrue(
            workspace.project(atShortcutIndex: 2)
                === workspace.demoProject
        )
        XCTAssertNil(workspace.project(atShortcutIndex: 3))
        XCTAssertNil(workspace.project(atShortcutIndex: -1))
    }

    func testNextAndPreviousWrapThroughAllProjects() throws {
        let workspace = makeWorkspace()
        let first = try XCTUnwrap(
            workspace.openProject(at: try makeRoot())
        )
        let second = try XCTUnwrap(
            workspace.openProject(at: try makeRoot())
        )
        workspace.activate(workspace.demoProject)

        XCTAssertTrue(workspace.activateNext() === first)
        XCTAssertTrue(workspace.activateNext() === second)
        XCTAssertTrue(workspace.activateNext() === workspace.demoProject)
        XCTAssertTrue(workspace.activatePrevious() === second)
        XCTAssertTrue(workspace.activatePrevious() === first)
        XCTAssertTrue(workspace.activatePrevious() === workspace.demoProject)
    }

    func testActivateProjectPausesDemoTransport() throws {
        let state = AppState()
        state.isPlaying = true
        let project = try XCTUnwrap(
            state.openProject(at: try makeRoot())
        )

        state.activateProject(project)

        XCTAssertFalse(state.isPlaying)
        XCTAssertTrue(state.liveProject === project)
    }

    func testAppStateNextAndPreviousProjects() throws {
        let state = AppState()
        let first = try XCTUnwrap(
            state.openProject(at: try makeRoot())
        )
        let second = try XCTUnwrap(
            state.openProject(at: try makeRoot())
        )
        state.activateProject(state.workspace.demoProject)
        state.isPlaying = true

        state.activateNextProject()
        XCTAssertTrue(state.liveProject === first)
        XCTAssertFalse(state.isPlaying)

        state.isPlaying = true
        state.activateNextProject()
        XCTAssertTrue(state.liveProject === second)
        XCTAssertTrue(state.isPlaying)

        state.activatePreviousProject()
        XCTAssertTrue(state.liveProject === first)
    }

    func testRejectedOpenDoesNotPauseDemoTransport() {
        let state = AppState()
        state.isPlaying = true
        let missing = URL(
            fileURLWithPath: "/tmp/sonovo-missing-\(UUID().uuidString)"
        )

        XCTAssertNil(state.openProject(at: missing))
        XCTAssertTrue(state.isPlaying)
        XCTAssertTrue(state.liveProject.isDemo)
    }

    func testActivatingDemoLeavesTransportAlone() {
        let state = AppState()
        state.isPlaying = true

        state.activateProject(state.workspace.demoProject)

        XCTAssertTrue(state.isPlaying)
        XCTAssertTrue(state.liveProject.isDemo)
    }

    // MARK: - Helpers

    private func makeWorkspace() -> Workspace {
        let demo = Project.demo(
            production: .sample,
            markdown: MarkdownWorkspace(readsDemoEnvironment: false),
            subtitles: SubtitleWorkspace(readsDemoEnvironment: false),
            models: Model3DWorkspace(opensDemoModel: false),
            terminalSessions: TerminalSessionsStore(),
            sampleDocuments: nil
        )
        return Workspace(
            demoProject: demo,
            store: InMemoryWorkspaceStore(),
            watchFactory: { _, _ in NavigationTestWatcher() }
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoProjectNavigation-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("one".utf8).write(
            to: root.appendingPathComponent("a.md")
        )
        roots.append(root)
        return root
    }
}

private final class NavigationTestWatcher: ProjectWatching {
    var isRunning = true
    func start() {}
    func stop() { isRunning = false }
}
