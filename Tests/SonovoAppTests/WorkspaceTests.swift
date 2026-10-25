import Foundation
import XCTest
@testable import Sonovo

@MainActor
final class WorkspaceTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots = []
        super.tearDown()
    }

    func testOpenProjectLoadsAssetsAndGroups() async throws {
        let root = try makeRoot(
            files: [
                "script.md": "text",
                "still.png": "png",
                "voice.wav": "wav",
                "models/scene.glb": "glb"
            ]
        )
        let workspace = makeWorkspace()
        let project = try XCTUnwrap(workspace.openProject(at: root))
        let loaded = await waitUntil { project.assets.count == 4 }
        XCTAssertTrue(loaded)
        XCTAssertEqual(
            project.groups.map(\.title),
            ["Documents", "Audio", "Images", "3D"]
        )
        XCTAssertEqual(workspace.activeProject?.id, project.id)
    }

    func testScanBuildsTheFilesTreeUsedByTheFilesNavigator() async throws {
        let root = try makeRoot(
            files: [
                "script.md": "text",
                "shots/one.png": "png",
                "shots/two.png": "png",
            ]
        )
        let workspace = makeWorkspace()
        let project = try XCTUnwrap(workspace.openProject(at: root))
        let loaded = await waitUntil { project.assets.count == 3 }
        XCTAssertTrue(loaded)

        XCTAssertEqual(
            project.fileTree.map(\.name),
            ["shots", "script.md"]
        )
        let shots = try XCTUnwrap(project.fileTree.first)
        XCTAssertEqual(shots.children?.map(\.name), ["one.png", "two.png"])

        project.filterText = "one"
        let filtered = FileNode.filtered(
            project.fileTree,
            query: project.filterText
        )
        XCTAssertEqual(filtered.map(\.name), ["shots"])
        XCTAssertEqual(
            filtered.first?.children?.map(\.name),
            ["one.png"]
        )
    }

    func testDuplicateAndOverlappingRootsAreRejected() async throws {
        let parent = try makeRoot(files: ["a.md": "a"])
        let child = parent.appendingPathComponent("shots", isDirectory: true)
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: true
        )
        try Data("b".utf8).write(
            to: child.appendingPathComponent("b.md")
        )
        let other = try makeRoot(files: ["c.md": "c"])

        let workspace = makeWorkspace()
        let first = try XCTUnwrap(workspace.openProject(at: parent))
        XCTAssertEqual(workspace.openProject(at: parent)?.id, first.id)
        XCTAssertNil(workspace.openProject(at: child))
        XCTAssertNotNil(workspace.lastError)

        XCTAssertNotNil(workspace.openProject(at: other))
        XCTAssertEqual(workspace.projects.count, 2)
    }

    func testSelectionBindsTheMatchingDocument() async throws {
        let root = try makeRoot(
            files: ["a.md": "a", "b.md": "b"]
        )
        let workspace = makeWorkspace()
        let project = try XCTUnwrap(workspace.openProject(at: root))
        let loaded = await waitUntil { project.assets.count == 2 }
        XCTAssertTrue(loaded)

        let a = try XCTUnwrap(project.assets.first { $0.name == "a.md" })
        let b = try XCTUnwrap(project.assets.first { $0.name == "b.md" })
        project.openAsset(a)
        XCTAssertEqual(
            project.markdown.selectedDocument?.fileURL?.path,
            a.url.path
        )
        project.openAsset(b)
        XCTAssertEqual(
            project.markdown.selectedDocument?.fileURL?.path,
            b.url.path
        )

        let aTab = try XCTUnwrap(project.openTabs.first { $0.id == a.id })
        project.selectTab(aTab.id)
        XCTAssertEqual(project.selectedAssetID, a.id)
        XCTAssertEqual(
            project.markdown.selectedDocument?.fileURL?.path,
            a.url.path
        )
    }

    func testClosingTheLastTabClosesTheDocument() async throws {
        let root = try makeRoot(files: ["a.md": "a"])
        let workspace = makeWorkspace()
        let project = try XCTUnwrap(workspace.openProject(at: root))
        let loaded = await waitUntil { project.assets.count == 1 }
        XCTAssertTrue(loaded)
        let asset = try XCTUnwrap(project.assets.first)
        project.openAsset(asset)
        XCTAssertEqual(project.markdown.documents.count, 1)

        await project.closeTab(asset.id)
        XCTAssertTrue(project.markdown.documents.isEmpty)
        XCTAssertTrue(project.openTabs.isEmpty)
    }

    func testClosingTheLastProjectActivatesTheDemo() async throws {
        let root = try makeRoot(files: ["a.md": "a"])
        let workspace = makeWorkspace()
        let project = try XCTUnwrap(workspace.openProject(at: root))
        let loaded = await waitUntil { project.assets.count == 1 }
        XCTAssertTrue(loaded)
        XCTAssertEqual(workspace.activeProjectID, project.id)

        XCTAssertTrue(workspace.closeProject(project))

        // `liveProject` falls back to the demo as soon as the list empties.
        // The stored identity must fall back too, or the demo is on screen
        // while the workspace still believes the closed project is active.
        XCTAssertNil(workspace.activeProjectID)
        XCTAssertTrue(workspace.liveProject.isDemo)
        XCTAssertTrue(workspace.demoProject.isActive)
        XCTAssertTrue(workspace.projects.isEmpty)
    }

    func testClosingAnUnselectedTabBumpsTheTabRevisionOnly() async throws {
        let root = try makeRoot(files: ["a.md": "a", "b.md": "b"])
        let workspace = makeWorkspace()
        let project = try XCTUnwrap(workspace.openProject(at: root))
        let loaded = await waitUntil { project.assets.count == 2 }
        XCTAssertTrue(loaded)
        let a = try XCTUnwrap(project.assets.first { $0.name == "a.md" })
        let b = try XCTUnwrap(project.assets.first { $0.name == "b.md" })
        project.openAsset(a)
        project.openAsset(b)
        XCTAssertEqual(project.selectedAssetID, b.id)
        let tabs = project.tabRevision
        let selection = project.selectionRevision

        await project.closeTab(a.id)

        XCTAssertEqual(project.selectedAssetID, b.id)
        XCTAssertEqual(project.selectionRevision, selection)
        XCTAssertEqual(project.tabRevision, tabs + 1)
        XCTAssertFalse(project.openTabs.contains { $0.assetID == a.id })
    }

    func testLoadWaitsForInFlightScanAndQueuedRescan() async throws {
        let root = try makeRoot(files: ["a.md": "a"])
        let scanner = GatedScanner()
        let project = Project(
            folderURL: root,
            scanner: scanner,
            watchFactory: { _, _ in TestProjectWatcher() }
        )
        let first = Task { await project.load() }
        let startDeadline = Date().addingTimeInterval(2)
        while !scanner.hasStarted, Date() < startDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(scanner.hasStarted)

        let completed = CompletionFlag()
        let second = Task {
            await project.load()
            await completed.mark()
        }
        try await Task.sleep(for: .milliseconds(100))
        let returnedEarly = await completed.isSet()
        XCTAssertFalse(
            returnedEarly,
            "A load queued behind an in-flight scan returned early."
        )

        scanner.release()
        await first.value
        await second.value
        let finishedAfterRelease = await completed.isSet()
        XCTAssertTrue(finishedAfterRelease)
        XCTAssertEqual(project.assets.map(\.name), ["a.md"])
    }

    func testExpectedVolumeMismatchKeepsTheProjectOffline() async throws {
        let root = try makeRoot(files: ["a.md": "a"])
        let project = Project(
            folderURL: root,
            expectedVolumeIdentifier: "not-the-current-volume"
        )
        await project.load()
        guard case .offline(let reason) = project.availability else {
            return XCTFail(
                "Expected an offline project, got \(project.availability)"
            )
        }
        XCTAssertTrue(reason.contains("different volume"))
        XCTAssertTrue(project.assets.isEmpty)
    }

    func testAssetRevisionChangesWhenSelectedFileIsRevised() async throws {
        let root = try makeRoot(files: ["a.md": "one"])
        let workspace = makeWorkspace()
        let project = try XCTUnwrap(workspace.openProject(at: root))
        let loaded = await waitUntil { project.assets.count == 1 }
        XCTAssertTrue(loaded)
        let asset = try XCTUnwrap(project.assets.first)
        project.openAsset(asset)
        // Viewers key their identity on this token; the scan must publish a
        // new token when the file behind the asset changes.
        let baseline = asset.revision.token

        let url = asset.url
        try Data("a much longer body".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: url.path
        )
        await project.refreshNow()

        let refreshed = try XCTUnwrap(
            project.assets.first { $0.id == asset.id }
        )
        XCTAssertNotEqual(refreshed.revision.token, baseline)
    }

    func testOfflineProjectsSurviveRestore() {
        let store = InMemoryWorkspaceStore()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoMissing-\(UUID().uuidString)",
                isDirectory: true
            )
        store.projectPaths = [missing.path]
        let workspace = makeWorkspace(store: store)
        workspace.restore()

        XCTAssertEqual(workspace.projects.count, 1)
        XCTAssertTrue(workspace.projects[0].isOffline)
        XCTAssertEqual(workspace.projects[0].name, missing.lastPathComponent)
        XCTAssertEqual(store.projectPaths, [missing.path])
    }

    func testPersistenceRestoresProjectsAndSelection() async throws {
        let root = try makeRoot(files: ["a.md": "a", "b.md": "b"])
        let store = InMemoryWorkspaceStore()
        let workspace = makeWorkspace(store: store)
        let project = try XCTUnwrap(workspace.openProject(at: root))
        let loaded = await waitUntil { project.assets.count == 2 }
        XCTAssertTrue(loaded)
        let b = try XCTUnwrap(project.assets.first { $0.name == "b.md" })
        project.openAsset(b)
        XCTAssertEqual(store.activePath, project.id)
        XCTAssertEqual(store.selections[project.id], b.id)

        let restored = makeWorkspace(store: store)
        restored.restore()
        let projectRestored = await waitUntil {
            restored.projects.first?.assets.count == 2
        }
        XCTAssertTrue(projectRestored)
        let selected = await waitUntil {
            restored.projects.first?.selectedAssetID == b.id
        }
        XCTAssertTrue(selected)
        XCTAssertEqual(restored.activeProject?.id, project.id)
    }

    func testProjectsKeepIndependentTabs() async throws {
        let firstRoot = try makeRoot(files: ["one.md": "1"])
        let secondRoot = try makeRoot(files: ["two.md": "2"])
        let workspace = makeWorkspace()
        let first = try XCTUnwrap(workspace.openProject(at: firstRoot))
        let second = try XCTUnwrap(workspace.openProject(at: secondRoot))
        let loaded = await waitUntil {
            first.assets.count == 1 && second.assets.count == 1
        }
        XCTAssertTrue(loaded)

        first.openAsset(first.assets[0])
        second.openAsset(second.assets[0])
        XCTAssertEqual(first.openTabs.count, 1)
        XCTAssertEqual(second.openTabs.count, 1)
        XCTAssertNotEqual(
            first.openTabs[0].id,
            second.openTabs[0].id
        )
        XCTAssertNotEqual(
            first.markdown.documents.first?.fileURL?.path,
            second.markdown.documents.first?.fileURL?.path
        )
    }

    func testActivationKeepsTerminalIdentityAndOneActiveProject() throws {
        let workspace = makeWorkspace()
        let first = try XCTUnwrap(
            workspace.openProject(
                at: try makeRoot(files: ["one.md": "1"])
            )
        )
        let second = try XCTUnwrap(
            workspace.openProject(
                at: try makeRoot(files: ["two.md": "2"])
            )
        )
        let firstSession = try XCTUnwrap(
            first.terminalSessions.sessions.first
        )

        workspace.activate(first)
        XCTAssertTrue(first.isActive)
        XCTAssertFalse(second.isActive)
        XCTAssertTrue(workspace.liveProject === first)
        XCTAssertTrue(
            first.terminalSessions.sessions.first === firstSession
        )

        workspace.activate(second)
        XCTAssertFalse(first.isActive)
        XCTAssertTrue(second.isActive)
        XCTAssertTrue(
            first.terminalSessions.sessions.first === firstSession,
            "Switching away must not recreate or drop a terminal session"
        )
        XCTAssertEqual(
            workspace.allProjects.filter(\.isActive).count,
            1
        )
    }

    func testActivationClearsBackgroundActivity() throws {
        let workspace = makeWorkspace()
        let project = try XCTUnwrap(
            workspace.openProject(
                at: try makeRoot(files: ["one.md": "1"])
            )
        )
        workspace.activate(workspace.demoProject)
        project.hasActivity = true

        workspace.activate(project)

        XCTAssertFalse(project.hasActivity)
    }

    func testWatcherEventRefreshesTheIndex() async throws {
        let root = try makeRoot(files: ["one.md": "1"])
        let workspace = makeWorkspace(
            watchFactory: { _, onChange in
                CapturingWatcher(onChange: onChange)
            }
        )
        let project = try XCTUnwrap(workspace.openProject(at: root))
        let loaded = await waitUntil { project.assets.count == 1 }
        XCTAssertTrue(loaded)
        let watcher = try XCTUnwrap(project.watcher as? CapturingWatcher)

        try Data("two".utf8).write(
            to: root.appendingPathComponent("two.md")
        )
        watcher.fire()

        let refreshed = await waitUntil { project.assets.count == 2 }
        XCTAssertTrue(refreshed)
    }

    func testProjectTerminalsStartAtTheProjectRoot() async throws {
        let root = try makeRoot(files: ["one.md": "1"])
        let workspace = makeWorkspace()
        let project = try XCTUnwrap(workspace.openProject(at: root))
        _ = await waitUntil { project.assets.count == 1 }

        XCTAssertEqual(project.terminalSessions.workingDirectory, root.path)
        XCTAssertEqual(
            project.terminalSessions.selectedSession?.workingDirectory,
            root.path
        )
    }

    func testDirtyDocumentsAcrossProjectsFlushIndependently() async throws {
        let firstRoot = try makeRoot(files: ["one.md": "one"])
        let secondRoot = try makeRoot(files: ["two.md": "two"])
        let workspace = makeWorkspace()
        let first = try XCTUnwrap(workspace.openProject(at: firstRoot))
        let second = try XCTUnwrap(workspace.openProject(at: secondRoot))
        let loaded = await waitUntil {
            first.assets.count == 1 && second.assets.count == 1
        }
        XCTAssertTrue(loaded)

        first.openAsset(first.assets[0])
        second.openAsset(second.assets[0])
        try XCTUnwrap(first.markdown.selectedDocument)
            .replaceSource("# first edit\n")
        try XCTUnwrap(second.markdown.selectedDocument)
            .replaceSource("# second edit\n")
        XCTAssertTrue(workspace.hasDirtyDocuments)

        for project in workspace.allProjects where !project.isDemo {
            let saved = await project.markdown.flushAllForTermination()
            XCTAssertTrue(saved, "\(project.name) should save")
        }
        XCTAssertFalse(workspace.hasDirtyDocuments)
        XCTAssertEqual(
            try String(
                contentsOf: firstRoot.appendingPathComponent("one.md"),
                encoding: .utf8
            ),
            "# first edit\n"
        )
        XCTAssertEqual(
            try String(
                contentsOf: secondRoot.appendingPathComponent("two.md"),
                encoding: .utf8
            ),
            "# second edit\n"
        )
    }

    // MARK: - Helpers

    func testMigrationSourceHintRequiresAUniqueIdentityMatch() throws {
        let root = try makeRoot(files: ["a.md": "a"])
        let store = InMemoryWorkspaceStore()
        let workspace = makeWorkspace(store: store)
        let project = try XCTUnwrap(workspace.openProject(at: root))
        XCTAssertNotNil(workspace.folderIdentity(for: project))

        let identity = FolderIdentityRecord(
            volumeUUID: "VOLUME",
            fileResourceIdentifier: "RESOURCE",
            capturedAt: Date(),
            provenance: .observed
        )
        store.folderIdentities[project.id] = identity
        store.folderIdentities["/tmp/old-one"] = identity
        XCTAssertEqual(
            workspace.migrationSourceHint(for: project),
            "/tmp/old-one"
        )
        store.folderIdentities["/tmp/old-two"] = identity
        XCTAssertNil(workspace.migrationSourceHint(for: project))
    }

    private func makeWorkspace(
        store: WorkspacePersisting = InMemoryWorkspaceStore(),
        watchFactory: @escaping ProjectWatchFactory = { _, _ in
            TestProjectWatcher()
        }
    ) -> Workspace {
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
            store: store,
            watchFactory: watchFactory
        )
    }

    private func makeRoot(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoWorkspaceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        roots.append(root)
        return root
    }

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
}

private actor CompletionFlag {
    private var value = false

    func mark() { value = true }
    func isSet() -> Bool { value }
}

/// Blocks the first scan so a second load arrives while one is in flight.
private final class GatedScanner: ProjectScanning, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    private var didStart = false
    private let scanner = ProjectScanner()

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    func scan(root: URL) -> ProjectScanResult {
        lock.lock()
        calls += 1
        let call = calls
        if call == 1 { didStart = true }
        lock.unlock()
        if call == 1 { gate.wait() }
        return scanner.scan(root: root)
    }

    func release() {
        gate.signal()
    }
}

private final class TestProjectWatcher: ProjectWatching {
    var isRunning = true
    func start() {}
    func stop() { isRunning = false }
}

private final class CapturingWatcher: ProjectWatching {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    var isRunning = true
    func start() {}
    func stop() { isRunning = false }
    func fire() { onChange() }
}
