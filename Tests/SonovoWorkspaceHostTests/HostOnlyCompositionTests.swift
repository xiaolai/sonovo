import Foundation
import Observation
import SwiftUI
import XCTest
import SonovoDomainTypes
import SonovoFeatureAPI
@testable import SonovoWorkspaceHost

/// This target imports no executable, concrete feature, parser or media engine.
@MainActor final class HostOnlyCompositionTests: XCTestCase {
    func testRealProjectAndWorkspaceComposeNewFeaturesSharingADisplayCategory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first".utf8).write(to: root.appendingPathComponent("one.firstfeature"))
        try Data("second".utf8).write(to: root.appendingPathComponent("two.secondfeature"))
        let first = HostFixtureSession(id: "test.first", suffix: "firstfeature")
        let second = HostFixtureSession(id: "test.second", suffix: "secondfeature")
        let metadata = [first.metadata, second.metadata]
        let registry = try FeatureSessionRegistry(metadata: metadata, sessions: [first, second])
        let project = Project(id: root.path, name: "Fixture", root: root, featureSessions: registry,
            scanner: ProjectScanner(catalogue: registry.editors.catalogue), watchFactory: { _, _ in HostFixtureWatcher() })
        let empty = try FeatureSessionRegistry(metadata: [], sessions: [])
        let demo = Project(id: "external", name: "External", root: nil, isDemo: true, featureSessions: empty,
            availability: .available, scanner: ProjectScanner(catalogue: empty.editors.catalogue))
        let store = InMemoryWorkspaceStore()
        let workspace = Workspace(demoProject: demo, store: store, projectFactory: { _ in project })
        defer { workspace.prepareForTermination() }
        XCTAssertTrue(workspace.openProject(at: root) === project)
        await project.load()
        XCTAssertEqual(project.assets.count, 2)
        XCTAssertNil(project.documentWorkspaces.adapter(for: AssetKind.other))
        project.showWorkspace(featureID: first.featureID, preferExistingFile: false)
        XCTAssertEqual(project.selectedTabID, "workspace:\(root.path):test.first:primary")
        first.services?.documentActivated(nil)
        XCTAssertEqual(project.selectedTab?.workspaceFeatureID, first.featureID)
        project.showWorkspace(featureID: second.featureID, preferExistingFile: false)
        XCTAssertEqual(project.selectedTab?.workspaceFeatureID, second.featureID)
        XCTAssertEqual(project.restorableTabIDs, [])
        let firstAsset = try XCTUnwrap(project.assets.first { $0.name == "one.firstfeature" })
        let secondAsset = try XCTUnwrap(project.assets.first { $0.name == "two.secondfeature" })
        project.openAsset(firstAsset)
        project.openAsset(secondAsset)
        XCTAssertEqual(first.openedURLs, [firstAsset.url])
        XCTAssertEqual(second.openedURLs, [secondAsset.url])
        XCTAssertEqual(project.documentAdapter(for: try XCTUnwrap(project.selectedTab))?.featureID, second.featureID)
        second.busy = true
        XCTAssertEqual(project.attention.statuses.map(\.label), ["Busy"])
        XCTAssertTrue(project.attention.summary.contains("Custom feature work"))
        XCTAssertEqual(registry.settings.count, 2)
        XCTAssertNotNil(second.inspector?.makeView(EditorRequest(project: project, asset: secondAsset, isVisible: true)))
        XCTAssertNotNil(second.transport?.makeView(EditorRequest(project: project, asset: secondAsset, isVisible: true)))
        let state = AppState(hostWorkspace: workspace)
        XCTAssertTrue(state.canPerformFeatureCommand("test.second.action"))
        XCTAssertFalse(state.canPerformFeatureCommand("test.first.action"))
        state.performFeatureCommand("test.second.action")
        XCTAssertEqual(second.commandCount, 1)
        state.terminalPresentation = .full
        XCTAssertFalse(state.canPerformFeatureCommand("test.second.action"))
        state.performFeatureCommand("test.second.action")
        XCTAssertEqual(second.commandCount, 1)
        state.terminalPresentation = .hidden
        state.activateProject(demo)
        state.performFeatureCommand("test.second.action")
        XCTAssertEqual(second.commandCount, 1)
        state.activateProject(project)
        await project.closeTab(firstAsset.id)
        XCTAssertEqual(first.closeCount, 1)
        XCTAssertEqual(second.closeCount, 0)
        XCTAssertEqual(project.selectedTab?.ownerFeatureID, second.featureID)
        XCTAssertNotNil(registry.editors.contribution(for: second.providerID)?.makeView(
            EditorRequest(project: project, asset: secondAsset, isVisible: true)))
        XCTAssertEqual(second.renderCount, 1)
    }

    func testDescriptorAndNamespacedTabSurviveOmittedFactoryWithoutPreferenceWrites() throws {
        let feature = HostFixtureSession(id: "test.omitted", suffix: "omittedfeature")
        let registry = try FeatureSessionRegistry(metadata: [feature.metadata], sessions: [])
        let project = Project(id: "fixture", name: "Fixture", root: nil, featureSessions: registry,
            scanner: ProjectScanner(catalogue: registry.editors.catalogue))
        defer { project.prepareForTermination() }
        project.showWorkspace(featureID: feature.featureID)
        XCTAssertEqual(project.selectedTabID, "workspace:fixture:test.omitted:primary")
        XCTAssertEqual(project.selectedTab?.workspaceProviderID, feature.providerID)
        XCTAssertEqual(project.featureEditors.catalogue.resolve("a.omittedfeature")?.featureID, feature.featureID)
        XCTAssertNil(project.featureEditors.contribution(for: feature.providerID))
        XCTAssertTrue(project.restorableTabIDs.isEmpty)
        XCTAssertFalse(project.hasDirtyDocuments)
    }
}

@MainActor @Observable private final class HostFixtureSession: ProjectFeatureSession {
    let featureID: FeatureID
    let providerID: EditorProviderID
    let suffix: String
    var services: DocumentHostServices?
    var openedURLs: [URL] = []
    var closeCount = 0
    var renderCount = 0
    var commandCount = 0
    var enabled = true
    var busy = false
    var attention: [FeatureAttentionItem] {
        busy ? [FeatureAttentionItem(id: featureID.rawValue + ".busy", label: "Busy", detail: "Custom feature work", symbol: "clock", priority: 4)] : []
    }
    var settings: [FeatureSettingsContribution] {
        [FeatureSettingsContribution(id: featureID.rawValue + ".settings", sectionID: featureID.rawValue,
            title: "Feature settings", icon: "gear") { AnyView(Text("Feature settings")) }]
    }
    var inspector: FeatureViewContribution? { FeatureViewContribution { _ in AnyView(Text("Feature inspector")) } }
    var transport: FeatureViewContribution? { FeatureViewContribution { _ in AnyView(Text("Feature transport")) } }
    var commands: [FeatureCommandContribution] {
        [FeatureCommandContribution(id: featureID.rawValue + ".action", title: { "Run feature" },
            isEnabled: { [weak self] in self?.enabled == true }, requiresSelectedEditor: true,
            perform: { [weak self] in self?.commandCount += 1 })]
    }
    private var references: [WorkspaceDocumentReference] = []
    init(id: FeatureID, suffix: String) {
        featureID = id; providerID = EditorProviderID(rawValue: id.rawValue + ".editor"); self.suffix = suffix
    }
    var metadata: FeatureMetadata {
        FeatureMetadata(id: featureID, displayName: suffix, documentProviders: [
            DocumentProviderDescriptor(id: providerID, featureID: featureID, kind: .other, selectors: [.fileExtension(suffix)])
        ], workspaces: [FeatureWorkspaceDescriptor(editorProviderID: providerID, title: suffix, icon: "doc")])
    }
    func attachDocumentHost(_ services: DocumentHostServices) { self.services = services }
    var documentWorkspace: DocumentWorkspaceAdapter? {
        DocumentWorkspaceAdapter(featureID: featureID, editorProviderID: providerID, kind: .other,
            documents: { [weak self] in self?.references ?? [] }, selected: { [weak self] in self?.references.last },
            open: { [weak self] url in
                guard let self else { return }
                openedURLs.append(url)
                references.append(WorkspaceDocumentReference(id: UUID(), url: url, name: url.lastPathComponent,
                    detail: "Fixture", isDirty: false, select: {}, close: { [weak self] in self?.closeCount += 1; return true }))
            })
    }
    var editors: [FeatureEditorContribution] {
        [FeatureEditorContribution(id: providerID) { [weak self] _ in
            self?.renderCount += 1; return AnyView(Text("Fixture feature"))
        }]
    }
}
private final class HostFixtureWatcher: ProjectWatching {
    var isRunning = true
    func start() {}
    func stop() { isRunning = false }
}
