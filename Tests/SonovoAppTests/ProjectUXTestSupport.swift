import Foundation
@testable import Sonovo

/// Shared fixture for the multi-project UX tests. Projects are real folder
/// models; watchers are inert and stores are in-memory.
@MainActor
final class ProjectUXTestSupport {
    private(set) var roots: [URL] = []

    func makeWorkspace(
        store: WorkspacePersisting = InMemoryWorkspaceStore()
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
            watchFactory: { _, _ in UXTestWatcher() }
        )
    }

    func makeRoot(
        parent: String = "ProjectUX",
        name: String = "project",
        files: [String: String] = ["a.md": "a"]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(parent)-\(UUID().uuidString)",
                isDirectory: true
            )
            .appendingPathComponent(name, isDirectory: true)
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

    func tearDown() {
        for root in roots {
            try? FileManager.default.removeItem(
                at: root.deletingLastPathComponent()
            )
        }
        roots = []
    }
}

final class UXTestWatcher: ProjectWatching {
    var isRunning = true
    func start() {}
    func stop() { isRunning = false }
}
