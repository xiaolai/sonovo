import SwiftUI
import SonovoDomainTypes
import SonovoFeatureAPI

@MainActor package final class MarkdownFeatureSession: ProjectFeatureSession {
    package let featureID: FeatureID = "builtin.markdown"
    package let workspace: MarkdownWorkspace
    package let documentWorkspace: DocumentWorkspaceAdapter?
    package let editors: [FeatureEditorContribution]
    package var lifecycle = FeatureLifecycle()
    package init(workspace: MarkdownWorkspace) {
        self.workspace = workspace
        self.documentWorkspace = MarkdownFeature.documentWorkspace(workspace)
        self.editors = MarkdownFeature.editors(workspace: workspace)
    }
    package func attachDocumentHost(_ services: DocumentHostServices) {
        workspace.onDocumentClosed = { services.documentClosed($0.id, $0.fileURL) }
        workspace.onDocumentActivated = services.documentActivated
        workspace.onDocumentMoved = services.documentMoved
        workspace.isDestinationReserved = services.isDestinationReserved
        workspace.isPathOwnedElsewhere = { services.isPathOwned($0, nil) }
        workspace.reserveSharedDestination = services.reserveDestination
        workspace.releaseSharedDestination = services.releaseDestination
        if let root = services.root {
            workspace.setWorkspaceRoot(root)
            workspace.onOpenAsset = services.openIndexedAsset
        }
    }

    package var statusSummary: FeatureStatusSummary? {
        guard let document = workspace.selectedDocument else { return nil }
        return FeatureStatusSummary(detail: "\(MarkdownWordCount.count(document.source).formatted()) words",
            trailing: document.hasBOM ? "Markdown · UTF-8 BOM" : "Markdown · UTF-8")
    }

    package var settings: [FeatureSettingsContribution] {
        [FeatureSettingsContribution(id: "builtin.markdown.settings", sectionID: "editor", title: "Editor", icon: "textformat", slot: "editor.leading") { AnyView(MarkdownSettingsRows()) },
            FeatureSettingsContribution(id: "builtin.markdown.reading-settings", sectionID: "reading", title: "Reading", icon: "text.book.closed", slot: "page") { AnyView(ReadingSettingsPane()) }]
    }

}
