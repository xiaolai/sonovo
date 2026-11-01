import SonovoWorkspaceHost
import SonovoDomainTypes
import Foundation
import SonovoMarkdownEngine
import SonovoSubtitleEngine
import XCTest
@testable import Sonovo

/// Frozen compatibility cases for the module migration. These use isolated
/// preferences and inert watchers; no app launch, user project or live tmux.
@MainActor
final class FeatureMigrationBaselineTests: XCTestCase {
    func testCancelResolvesOnlyFirstPendingOwnerOfEachExistingFamily() async throws {
        let support = ProjectUXTestSupport()
        defer { support.tearDown() }
        let workspace = support.makeWorkspace()
        let state = AppState(workspace: workspace)
        let first = try XCTUnwrap(workspace.openProject(at: support.makeRoot(name: "first", files: [:])))
        let second = try XCTUnwrap(workspace.openProject(at: support.makeRoot(name: "second", files: [:])))
        defer { workspace.allProjects.forEach { $0.prepareForTermination() } }
        let firstDocument = first.markdown.newDocument()
        try firstDocument.replaceSource("first unsaved document")
        let secondDocument = second.markdown.newDocument()
        try secondDocument.replaceSource("second unsaved document")
        let firstClosed = await first.markdown.close(firstDocument)
        let secondClosed = await second.markdown.close(secondDocument)
        XCTAssertFalse(firstClosed)
        XCTAssertFalse(secondClosed)
        XCTAssertTrue(state.pendingCloseOwner === first)
        state.cancelPendingClose()
        XCTAssertNil(first.markdown.pendingClose)
        XCTAssertTrue(second.markdown.pendingClose === secondDocument)
        XCTAssertTrue(state.pendingCloseOwner === second)
        XCTAssertTrue(firstDocument.isDirty)
        XCTAssertTrue(secondDocument.isDirty)
    }

    func testTerminalFullPreservesCurrentSaveCommandGates() {
        let support = ProjectUXTestSupport()
        defer { support.tearDown() }
        let workspace = support.makeWorkspace()
        defer { workspace.allProjects.forEach { $0.prepareForTermination() } }
        let state = AppState(workspace: workspace)
        workspace.demoProject.showWorkspace(.script)
        XCTAssertTrue(state.canSaveSelectedDocument)
        XCTAssertTrue(state.canSaveSelectedDocumentAs)
        state.terminalPresentation = .full
        XCTAssertFalse(state.canSaveSelectedDocument)
        XCTAssertFalse(state.canSaveSelectedDocumentAs)
    }

    func testRegisteredMenuActionsResolveTheActiveProjectAtInvocation() throws {
        let support = ProjectUXTestSupport()
        defer { support.tearDown() }
        let workspace = support.makeWorkspace()
        defer { workspace.allProjects.forEach { $0.prepareForTermination() } }
        let state = AppState(workspace: workspace)
        let first = try XCTUnwrap(workspace.openProject(at: support.makeRoot(name: "first", files: [:])))
        let second = try XCTUnwrap(workspace.openProject(at: support.makeRoot(name: "second", files: [:])))
        workspace.activate(first)
        let firstCount = first.markdown.documents.count
        let secondCount = second.markdown.documents.count
        XCTAssertTrue(state.canPerformFeatureCommand("builtin.markdown.new-document"))
        workspace.activate(second)
        state.terminalPresentation = .full
        state.performFeatureCommand("builtin.markdown.new-document")
        XCTAssertEqual(first.markdown.documents.count, firstCount)
        XCTAssertEqual(second.markdown.documents.count, secondCount + 1)
        XCTAssertEqual(state.selectedTab?.kind, .script)
        XCTAssertEqual(state.terminalPresentation, .hidden)
        let document = try XCTUnwrap(second.markdown.selectedDocument)
        let mode = document.mode
        second.showWorkspace(.code)
        XCTAssertFalse(state.canPerformFeatureCommand("builtin.markdown.toggle-source-rendered"))
        state.performFeatureCommand("builtin.markdown.toggle-source-rendered")
        XCTAssertEqual(document.mode, mode)
        state.performFeatureCommand("builtin.markdown.new-document", expectedOwner: "builtin.model")
        XCTAssertEqual(second.markdown.documents.count, secondCount + 1)
    }

    func testOldWorkspacePreferenceSchemaRoundTripsWithoutNewKeys() throws {
        let suite = "sonovo.tests.architecture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture: [String: Any] = [
            "sonovo.workspace.projects": ["/fixture/first", "/fixture/second"],
            "sonovo.workspace.active": "/fixture/second",
            "sonovo.workspace.recent": ["/fixture/second", "/fixture/first"],
            "sonovo.workspace.selection": ["/fixture/first": "/fixture/first/a.md"],
            "sonovo.workspace.openTabs": [
                "/fixture/first": ["/fixture/first/a.md", "/fixture/first/b.swift"]
            ],
            "sonovo.workspace.volumes": ["/fixture/first": "fixture-volume"]
        ]
        defaults.setPersistentDomain(fixture, forName: suite)
        let store = UserDefaultsWorkspaceStore(defaults: defaults)
        XCTAssertEqual(store.projectPaths, ["/fixture/first", "/fixture/second"])
        XCTAssertEqual(store.activePath, "/fixture/second")
        XCTAssertEqual(store.openTabs["/fixture/first"], [
            "/fixture/first/a.md", "/fixture/first/b.swift"
        ])
        store.projectPaths = store.projectPaths
        store.activePath = store.activePath
        store.recentPaths = store.recentPaths
        store.selections = store.selections
        store.openTabs = store.openTabs
        store.volumeIdentifiers = store.volumeIdentifiers
        XCTAssertEqual(
            defaults.persistentDomain(forName: suite) as NSDictionary?,
            fixture as NSDictionary
        )
    }

    func testSyntheticWorkspaceTabIDsAreStableAndNeverPersistedAsFiles() throws {
        let support = ProjectUXTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(files: [:])
        let workspace = support.makeWorkspace()
        let project = try XCTUnwrap(workspace.openProject(at: root))
        defer { project.prepareForTermination() }
        for kind: AssetKind in [.script, .subtitle, .model3d, .timeline] {
            let tab = EditorTab(workspaceKind: kind)
            XCTAssertEqual(tab.id, "workspace-\(kind.rawValue)")
            XCTAssertNil(tab.url)
            project.showWorkspace(kind)
        }
        XCTAssertTrue(project.restorableTabIDs.isEmpty)
    }

    func testProjectEagerlyRetainsWorkspaceIdentityAcrossActivation() throws {
        let support = ProjectUXTestSupport()
        defer { support.tearDown() }
        let project = Project(
            folderURL: try support.makeRoot(files: [:]),
            watchFactory: { _, _ in UXTestWatcher() },
            terminalEnvironment: .disabled
        )
        defer { project.prepareForTermination() }
        let initialSessions = project.featureSessions.sessions.map { ObjectIdentifier($0) }
        XCTAssertEqual(initialSessions.count, BuiltInFeatureComposition.metadata.count)
        XCTAssertEqual(Set(initialSessions).count, initialSessions.count)
        let markdown = project.markdown
        let code = project.code
        let subtitles = project.subtitles
        let models = project.models
        let mdx = project.mdx
        project.activate()
        project.deactivate()
        project.activate()
        XCTAssertEqual(project.featureSessions.sessions.map { ObjectIdentifier($0) }, initialSessions)
        XCTAssertTrue(project.markdown === markdown)
        XCTAssertTrue(project.code === code)
        XCTAssertTrue(project.subtitles === subtitles)
        XCTAssertTrue(project.models === models)
        XCTAssertTrue(project.mdx === mdx)
    }
}
