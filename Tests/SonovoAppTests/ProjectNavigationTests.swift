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

    func testEditorModeClampsForEveryNavigationPath() {
        let state = AppState()
        state.activateProject(state.workspace.demoProject)
        state.openAsset("vo-take-03")
        XCTAssertFalse(state.canUseMediaModes)

        state.openAsset("take-03")
        state.editorMode = .compare
        XCTAssertEqual(state.editorMode, .compare)

        state.openAsset("script-md")
        XCTAssertEqual(state.editorMode, .player)

        // A direct Project call bypasses AppState.openAsset; the getter must
        // still clamp against the active tab.
        state.liveProject.openAsset(id: "take-03")
        XCTAssertEqual(state.editorMode, .compare)
        state.liveProject.openAsset(id: "script-md")
        XCTAssertEqual(state.editorMode, .player)
    }

    func testRevealingASubtitleSelectsThatDocumentTab() async throws {
        let root = try makeRoot(files: [
            "a.srt": "1\n00:00:00,000 --> 00:00:01,000\nA\n",
            "b.srt": "1\n00:00:00,000 --> 00:00:01,000\nB\n"
        ])
        let state = AppState()
        let project = try XCTUnwrap(state.openProject(at: root))
        let loaded = await waitUntil { project.assets.count == 2 }
        XCTAssertTrue(loaded)
        let a = try XCTUnwrap(project.assets.first { $0.name == "a.srt" })
        let b = try XCTUnwrap(project.assets.first { $0.name == "b.srt" })
        project.openAsset(a)
        project.openAsset(b)
        let documentB = try XCTUnwrap(
            project.subtitles.documents.first {
                $0.fileURL.lastPathComponent == "b.srt"
            }
        )
        project.openAsset(a)
        XCTAssertEqual(
            project.subtitles.selectedDocument?.fileURL.lastPathComponent,
            "a.srt"
        )

        state.revealSubtitleDocument(documentB)

        XCTAssertEqual(
            project.subtitles.selectedDocument?.fileURL.lastPathComponent,
            "b.srt"
        )
        XCTAssertEqual(project.selectedAssetID, b.id)
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

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

    private func makeRoot(
        files: [String: String] = ["a.md": "one"]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoProjectNavigation-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        for (name, contents) in files {
            try Data(contents.utf8).write(
                to: root.appendingPathComponent(name)
            )
        }
        roots.append(root)
        return root
    }
}

private final class NavigationTestWatcher: ProjectWatching {
    var isRunning = true
    func start() {}
    func stop() { isRunning = false }
}
