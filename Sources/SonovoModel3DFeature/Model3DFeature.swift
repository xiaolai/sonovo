import SwiftUI
import SonovoDomainTypes
import SonovoFeatureAPI

@MainActor package enum Model3DFeature {
    nonisolated package static var metadata: FeatureMetadata {
        FeatureMetadata(id: "builtin.model", displayName: "3D Models", documentProviders: descriptors,
            workspaces: [FeatureWorkspaceDescriptor(editorProviderID: "builtin.model.editor", title: AssetKind.model3d.workspaceTitle,
                icon: AssetKind.model3d.tabIcon, legacyKind: .model3d, legacyTabID: "workspace-model3d", legacySampleAssetID: "model-3d")])
    }

    nonisolated package static let descriptors = [DocumentProviderDescriptor(
        id: "builtin.model.editor", featureID: "builtin.model", kind: .model3d,
        selectors: Model3DFormat.allCases.map { DocumentSelector.fileExtension($0.rawValue) })]
    package static func editors(workspace: Model3DWorkspace) -> [FeatureEditorContribution] {
        [FeatureEditorContribution(id: "builtin.model.editor") { request in
            AnyView(Model3DWorkspaceView(workspace: workspace, project: request.project))
        }]
    }
    package static func documentWorkspace(_ workspace: Model3DWorkspace) -> DocumentWorkspaceAdapter {
        func reference(_ document: Model3DDocument) -> WorkspaceDocumentReference {
            WorkspaceDocumentReference(
                id: document.id, url: document.sourceURL, name: document.displayName,
                detail: "3D model", isDirty: false,
                select: { [weak workspace] in workspace?.select(document) },
                close: { [weak workspace] in await workspace?.close(document) ?? true }
            )
        }
        return DocumentWorkspaceAdapter(
            featureID: "builtin.model", editorProviderID: "builtin.model.editor",
            kind: .model3d,
            documents: { [weak workspace] in workspace?.documents.map(reference) ?? [] },
            selected: { [weak workspace] in workspace?.selectedDocument.map(reference) },
            open: { [weak workspace] in _ = workspace?.open(url: $0) },
            includesDirtyAttention: false,
            shutdown: { [weak workspace] in workspace?.prepareForTermination() }
        )
    }

}
