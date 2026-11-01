import SwiftUI
import SonovoDomainTypes
import SonovoFeatureAPI

@MainActor package final class SubtitleFeatureSession: ProjectFeatureSession {
    package let featureID: FeatureID = "builtin.subtitle"
    package let workspace: SubtitleWorkspace
    package let documentWorkspace: DocumentWorkspaceAdapter?
    package let editors: [FeatureEditorContribution]
    package var lifecycle = FeatureLifecycle()
    package init(workspace: SubtitleWorkspace) {
        self.workspace = workspace
        self.documentWorkspace = SubtitleFeature.documentWorkspace(workspace)
        self.editors = SubtitleFeature.editors(workspace: workspace)
        self.lifecycle = FeatureLifecycle(editorVisibilityChanged: { [weak workspace] visible in
            if !visible { workspace?.pauseForDeactivation() }
        }, deactivate: { [weak workspace] in workspace?.pauseForDeactivation() })
    }
    package func attachDocumentHost(_ services: DocumentHostServices) {
        workspace.onDocumentClosed = { services.documentClosed(nil, $0) }
        workspace.onDocumentActivated = { services.documentActivated($0) }
        workspace.isDestinationReserved = services.isDestinationReserved
        workspace.isPathOwnedElsewhere = { services.isPathOwned($0, nil) }
    }

    package var statusSummary: FeatureStatusSummary? {
        guard let document = workspace.selectedDocument else { return nil }
        return FeatureStatusSummary(detail: "\(document.cueCount) cues",
            trailing: "\(document.format.displayName) · \(document.encoding.displayName)")
    }

    package var commands: [FeatureCommandContribution] {
        [
            FeatureCommandContribution(id: "builtin.subtitle.show", title: { "Show Subtitle Editor" }, requiresVisibleEditor: false,
                action: { $0.revealWorkspace() }),
            FeatureCommandContribution(id: "builtin.subtitle.preview", title: { [workspace] in
                workspace.previewMode == .collapsed ? "Show Video" : "Hide Video"
            }, requiresVisibleEditor: false, perform: { [workspace] in workspace.togglePreviewMode() }),
            FeatureCommandContribution(id: "builtin.subtitle.open", title: { "Open Subtitle…" }, requiresVisibleEditor: false,
                shortcut: KeyboardShortcut("o", modifiers: [.command, .option]), action: { [workspace] invocation in
                    invocation.revealWorkspace(); workspace.presentOpenPanel()
                }),
            FeatureCommandContribution(id: "builtin.subtitle.media", title: { "Open Media…" },
                isEnabled: { [workspace] in workspace.selectedDocument != nil }, requiresVisibleEditor: false,
                action: { [weak self, workspace] invocation in
                    guard let document = workspace.selectedDocument, let reference = self?.documentWorkspace?.selectedDocument else { return }
                    invocation.revealDocument(reference)
                    workspace.presentOpenMediaPanel(for: document)
                }),
            FeatureCommandContribution(id: "builtin.subtitle.close", title: { "Close Document" },
                isEnabled: { [workspace] in workspace.selectedDocument != nil }, requiresVisibleEditor: false, menuGroup: 1,
                perform: { [workspace] in Task { await workspace.closeSelected() } })
        ]
    }

}
