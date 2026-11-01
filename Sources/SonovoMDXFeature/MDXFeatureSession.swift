import SonovoDomainTypes
import SonovoFeatureAPI

@MainActor package final class MDXFeatureSession: ProjectFeatureSession {
    package let featureID: FeatureID = "builtin.mdx"
    package let workspace: MDXWorkspace
    package let documentWorkspace: DocumentWorkspaceAdapter?
    package let editors: [FeatureEditorContribution]
    package var lifecycle = FeatureLifecycle()
    package init(workspace: MDXWorkspace) {
        self.workspace = workspace
        self.documentWorkspace = MDXFeature.documentWorkspace(workspace)
        self.editors = MDXFeature.editors(workspace: workspace)
        self.lifecycle = FeatureLifecycle(invalidate: { [weak workspace] in workspace?.prepareForTermination() })
    }
    package func attachDocumentHost(_ services: DocumentHostServices) {
        workspace.onDocumentClosed = { services.documentClosed($0.id, $0.fileURL) }
        workspace.onDocumentActivated = { services.documentActivated($0) }
        if let root = services.root { workspace.setWorkspaceRoot(root) }
    }

    package var statusSummary: FeatureStatusSummary? {
        guard let document = workspace.selectedDocument else { return nil }
        return FeatureStatusSummary(detail: "\(document.source.components(separatedBy: "\n").count.formatted()) lines",
            trailing: "MDX · \(document.isDirty ? "Edited" : "Saved")", summarizesFileTab: false)
    }

}
