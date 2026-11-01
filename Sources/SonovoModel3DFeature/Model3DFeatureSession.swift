import SwiftUI
import Foundation
import SonovoDomainTypes
import SonovoFeatureAPI

@MainActor package final class Model3DFeatureSession: ProjectFeatureSession {
    package let featureID: FeatureID = "builtin.model"
    package let workspace: Model3DWorkspace
    package let documentWorkspace: DocumentWorkspaceAdapter?
    package let editors: [FeatureEditorContribution]
    package var lifecycle = FeatureLifecycle()
    package init(workspace: Model3DWorkspace) {
        self.workspace = workspace
        self.documentWorkspace = Model3DFeature.documentWorkspace(workspace)
        self.editors = Model3DFeature.editors(workspace: workspace)
        self.lifecycle = FeatureLifecycle(assetsChanged: { [weak workspace] _ in
            guard let workspace else { return }
            // Sidecars are not necessarily indexed assets. Always compare
            // revisions recorded when each resource was actually served.
            for document in workspace.documents where !document.resourcePaths.isEmpty {
                if document.resourcePaths.contains(where: { path in
                    document.resourceRevisions[path] != Model3DDocument.revision(of: URL(fileURLWithPath: path))
                }) { workspace.reload(document) }
            }
        })
    }
    package func attachDocumentHost(_ services: DocumentHostServices) {
        workspace.onDocumentClosed = { services.documentClosed(nil, $0) }
        workspace.onDocumentActivated = { services.documentActivated($0) }
        workspace.isDestinationReserved = services.isDestinationReserved
        workspace.isPathOwnedElsewhere = { services.isPathOwned($0, nil) }
    }

    package var statusSummary: FeatureStatusSummary? {
        guard let document = workspace.selectedDocument else { return nil }
        let detail: String
        if let stats = document.stats { detail = "\(stats.triangles.formatted()) triangles" }
        else {
            detail = switch document.state {
            case .needsConversion: "Needs conversion"
            case .converting: "Converting…"
            case .conversionFailed: "Conversion failed"
            case .loading: "Loading…"
            case .ready: "Ready"
            case .failed: "Could not load"
            }
        }
        return FeatureStatusSummary(detail: detail, trailing: "\(document.format.displayName) · three.js")
    }

    package var commands: [FeatureCommandContribution] {
        [
            FeatureCommandContribution(id: "builtin.model.show", title: { "Show 3D Viewer" }, requiresVisibleEditor: false,
                action: { $0.revealWorkspace() }),
            FeatureCommandContribution(id: "builtin.model.open", title: { "Open Model…" }, requiresVisibleEditor: false,
                shortcut: KeyboardShortcut("m", modifiers: [.command, .shift]), action: { [workspace] invocation in
                    invocation.revealWorkspace(); workspace.presentOpenPanel()
                }),
            FeatureCommandContribution(id: "builtin.model.reload", title: { "Reload Model" },
                isEnabled: { [workspace] in workspace.selectedDocument != nil }, requiresVisibleEditor: false, menuGroup: 1,
                perform: { [workspace] in workspace.reloadSelected() }),
            FeatureCommandContribution(id: "builtin.model.convert", title: { "Convert with Blender…" },
                isEnabled: { [workspace] in workspace.selectedDocument?.format.canConvertWithBlender == true && workspace.blenderInstallation != nil },
                requiresVisibleEditor: false, menuGroup: 1, action: { [weak self, workspace] invocation in
                    guard let document = workspace.selectedDocument, let reference = self?.documentWorkspace?.selectedDocument else { return }
                    invocation.revealDocument(reference)
                    workspace.convert(document)
                }),
            FeatureCommandContribution(id: "builtin.model.close", title: { "Close Model" },
                isEnabled: { [workspace] in workspace.selectedDocument != nil }, requiresVisibleEditor: false, menuGroup: 2,
                perform: { [workspace] in Task { await workspace.closeSelected() } })
        ]
    }

    package var attention: [FeatureAttentionItem] {
        workspace.hasRunningConversion ? [FeatureAttentionItem(id: "builtin.model.converting", label: "Converting",
            detail: "A 3D conversion is running", symbol: "cube.transparent", priority: 4, role: .conversion)] : []
    }

}
