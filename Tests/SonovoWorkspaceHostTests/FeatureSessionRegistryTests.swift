import Foundation
import Observation
import SwiftUI
import XCTest
import SonovoDomainTypes
import SonovoFeatureAPI
@testable import SonovoWorkspaceHost

@MainActor final class FeatureSessionRegistryTests: XCTestCase {
    private var metadata: FeatureMetadata {
        FeatureMetadata(id: "test.new", displayName: "A new feature", documentProviders: [
            DocumentProviderDescriptor(id: "test.new.editor", featureID: "test.new", kind: .other,
                selectors: [.fileExtension("newfeature")])
        ], workspaces: [FeatureWorkspaceDescriptor(editorProviderID: "test.new.editor", title: "New feature", icon: "doc")])
    }

    func testNewFeatureSuppliesEditorCommandInspectorAttentionAndVisibilityWithoutHostCases() throws {
        let feature = SyntheticFeatureSession()
        let registry = try FeatureSessionRegistry(metadata: [metadata], sessions: [feature])
        let provider = try XCTUnwrap(registry.editors.catalogue.resolve("file.newfeature"))
        XCTAssertEqual(provider.featureID, feature.featureID)
        XCTAssertEqual(feature.renderCount, 0)
        XCTAssertNotNil(registry.editors.contribution(for: provider.id)?.makeView(EditorRequest(project: SyntheticProjectContext(), asset: nil, isVisible: true)))
        XCTAssertEqual(feature.renderCount, 1)
        XCTAssertNotNil(registry.session(for: feature.featureID)?.inspector)
        let command = try XCTUnwrap(registry.command("test.new.action"))
        XCTAssertEqual(command.owner, feature.featureID)
        XCTAssertTrue(command.command.isEnabled())
        command.command.perform()
        XCTAssertEqual(feature.performCount, 1)
        registry.editorVisibilityChanged(false)
        XCTAssertEqual(feature.lastVisibility, false)
        feature.busy = true
        XCTAssertEqual(registry.attention.map(\.id), ["test.new.busy"])
    }

    func testErasedAvailabilityAndAttentionRemainObservable() throws {
        let feature = SyntheticFeatureSession()
        let registry = try FeatureSessionRegistry(metadata: [metadata], sessions: [feature])
        let commandWitness = SessionObservationWitness(), attentionWitness = SessionObservationWitness()
        withObservationTracking {
            XCTAssertTrue(registry.command("test.new.action")?.command.isEnabled() == true)
        } onChange: { commandWitness.mark() }
        withObservationTracking {
            XCTAssertTrue(registry.attention.isEmpty)
        } onChange: { attentionWitness.mark() }
        feature.enabled = false
        feature.busy = true
        XCTAssertTrue(commandWitness.marked)
        XCTAssertTrue(attentionWitness.marked)
    }

    func testCommandGateUsesCurrentSelectionVisibilityAndAvailability() throws {
        let feature = SyntheticFeatureSession()
        let registry = try FeatureSessionRegistry(metadata: [metadata], sessions: [feature])
        XCTAssertTrue(registry.canPerformCommand("test.new.action", selectedFeature: nil, editorIsVisible: true))
        XCTAssertFalse(registry.canPerformCommand("test.new.action", selectedFeature: feature.featureID, editorIsVisible: false))
        XCTAssertFalse(registry.canPerformCommand("missing.action", selectedFeature: feature.featureID, editorIsVisible: true))
        feature.enabled = false
        XCTAssertFalse(registry.canPerformCommand("test.new.action", selectedFeature: feature.featureID, editorIsVisible: true))
    }

    func testOmittedFactoryRetainsRecognitionAndWorkspaceIdentity() throws {
        let registry = try FeatureSessionRegistry(metadata: [metadata], sessions: [])
        XCTAssertEqual(registry.editors.catalogue.resolve("file.newfeature")?.featureID, "test.new")
        XCTAssertNil(registry.editors.contribution(for: "test.new.editor"))
        XCTAssertEqual(registry.descriptor(for: FeatureID(rawValue: "test.new"))?.workspaces.first?.tabID(projectID: "project", featureID: "test.new"),
                       "workspace:project:test.new:primary")
    }

    func testVisibilityIsDeliveredExactlyOncePerTransitionInDeclaredOrder() throws {
        var events: [String] = []
        let first = LifecycleTestSession(id: "test.first"), second = LifecycleTestSession(id: "test.second")
        first.lifecycle = FeatureLifecycle(editorVisibilityChanged: { events.append("first:\($0)") })
        second.lifecycle = FeatureLifecycle(editorVisibilityChanged: { events.append("second:\($0)") })
        second.lifecycle.visibilityPriority = -1
        let registry = try FeatureSessionRegistry(metadata: [FeatureMetadata(id: "test.first", displayName: "First"),
            FeatureMetadata(id: "test.second", displayName: "Second")], sessions: [first, second])
        for visible in [false, false, true, true, false, false] { registry.editorVisibilityChanged(visible) }
        XCTAssertEqual(events, ["second:false", "first:false", "second:true", "first:true", "second:false", "first:false"])
    }

    func testLifecyclePhasesAndFallbackDocumentShutdownAreDeterministic() throws {
        var events: [String] = []
        let first = LifecycleTestSession(id: "test.first"), second = LifecycleTestSession(id: "test.second")
        first.lifecycle = FeatureLifecycle(assetsChanged: { _ in events.append("first.assets") },
            deactivate: { events.append("first.hide") }, invalidate: { events.append("first.invalidate") },
            shutdown: { events.append("first.shutdown") })
        second.lifecycle = FeatureLifecycle(assetsChanged: { _ in events.append("second.assets") },
            deactivate: { events.append("second.hide") }, invalidate: { events.append("second.invalidate") })
        second.lifecycle.assetChangePriority = -1
        second.lifecycle.shutdownPriority = -1
        second.documentWorkspace = DocumentWorkspaceAdapter(featureID: "test.second", kind: .other,
            documents: { [] }, selected: { nil }, open: { _ in }, shutdown: { events.append("second.shutdown") })
        let registry = try FeatureSessionRegistry(metadata: [
            FeatureMetadata(id: "test.first", displayName: "First"), FeatureMetadata(id: "test.second", displayName: "Second")
        ], sessions: [first, second])
        registry.assetsChanged([])
        registry.deactivate()
        registry.invalidate()
        registry.shutdown()
        XCTAssertEqual(events, ["second.assets", "first.assets", "first.hide", "second.hide",
            "first.invalidate", "second.invalidate", "second.shutdown", "first.shutdown"])
    }

    func testAssemblyRejectsUnknownDuplicateAndMismatchedSessions() throws {
        let feature = SyntheticFeatureSession()
        XCTAssertThrowsError(try FeatureSessionRegistry(metadata: [metadata, metadata], sessions: []))
        XCTAssertThrowsError(try FeatureSessionRegistry(metadata: [metadata], sessions: [feature, feature]))
        XCTAssertThrowsError(try FeatureSessionRegistry(metadata: [], sessions: [feature]))
        feature.documentWorkspace = DocumentWorkspaceAdapter(featureID: "test.other", kind: .other,
            documents: { [] }, selected: { nil }, open: { _ in })
        XCTAssertThrowsError(try FeatureSessionRegistry(metadata: [metadata], sessions: [feature]))
    }
}

@MainActor @Observable private final class SyntheticFeatureSession: ProjectFeatureSession {
    let featureID: FeatureID = "test.new"
    var documentWorkspace: DocumentWorkspaceAdapter?
    var enabled = true
    var busy = false
    var renderCount = 0
    var performCount = 0
    var lastVisibility: Bool?
    var editors: [FeatureEditorContribution] {
        [FeatureEditorContribution(id: "test.new.editor") { [weak self] _ in
            self?.renderCount += 1
            return AnyView(Text("A new feature"))
        }]
    }
    var commands: [FeatureCommandContribution] {
        [FeatureCommandContribution(id: "test.new.action", title: { "Run feature" },
            isEnabled: { [weak self] in self?.enabled == true }, perform: { [weak self] in self?.performCount += 1 })]
    }
    var inspector: FeatureViewContribution? { FeatureViewContribution { _ in AnyView(Text("Feature inspector")) } }
    var attention: [FeatureAttentionItem] {
        busy ? [FeatureAttentionItem(id: "test.new.busy", label: "Busy", detail: "Synthetic work", symbol: "clock", priority: 1)] : []
    }
    var lifecycle: FeatureLifecycle {
        FeatureLifecycle(editorVisibilityChanged: { [weak self] in self?.lastVisibility = $0 })
    }
}

@MainActor private final class SyntheticProjectContext: EditorProjectContext {
    let id = "synthetic-project"
    let root: URL? = nil
    let isDemo = false
    let assets: [ProjectAsset] = []
    let selectedAsset: ProjectAsset? = nil
    let scanRevision: UInt64 = 0
    let isOffline = false
    func openAsset(_ asset: ProjectAsset) {}
    func refreshNow() async {}
    func refreshAssetsForNavigation() async {}
    func fileCloseAction(at url: URL, kind: AssetKind, canonicalPaths: Bool) -> (@MainActor () async -> Void)? { nil }
    func mediaReferenceState(for reference: MediaReference, documentURL: URL?) -> MediaReferenceState { .missing }
    func openMediaReference(_ reference: MediaReference, documentURL: URL?) {}
}
private final class SessionObservationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.lock(); value = true; lock.unlock() }
    var marked: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor private final class LifecycleTestSession: ProjectFeatureSession {
    let featureID: FeatureID
    var lifecycle = FeatureLifecycle()
    var documentWorkspace: DocumentWorkspaceAdapter?
    init(id: FeatureID) { self.featureID = id }
}
