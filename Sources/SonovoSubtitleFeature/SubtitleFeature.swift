import Foundation
import SwiftUI
import SonovoDomainTypes
import SonovoFeatureAPI
import SonovoSubtitleEngine

@MainActor package enum SubtitleFeature {
    nonisolated package static var metadata: FeatureMetadata {
        FeatureMetadata(id: "builtin.subtitle", displayName: "Subtitles", documentProviders: descriptors,
            workspaces: [FeatureWorkspaceDescriptor(editorProviderID: "builtin.subtitle.editor", title: AssetKind.subtitle.workspaceTitle,
                icon: AssetKind.subtitle.tabIcon, legacyKind: .subtitle, legacyTabID: "workspace-subtitle", legacySampleAssetID: "captions-srt")])
    }

    nonisolated package static let descriptors = [DocumentProviderDescriptor(
        id: "builtin.subtitle.editor", featureID: "builtin.subtitle", kind: .subtitle,
        selectors: Set(SubtitleFormat.allCases.map(\.rawValue)).sorted().map(DocumentSelector.fileExtension))]
    package static func editors(workspace: SubtitleWorkspace) -> [FeatureEditorContribution] {
        [FeatureEditorContribution(id: "builtin.subtitle.editor") { _ in
            AnyView(SubtitleWorkspaceView(workspace: workspace))
        }]
    }
    package static func documentWorkspace(_ workspace: SubtitleWorkspace) -> DocumentWorkspaceAdapter {
        func reference(_ document: SubtitleDocument) -> WorkspaceDocumentReference {
            WorkspaceDocumentReference(
                id: document.id, url: document.fileURL,
                name: document.fileURL.lastPathComponent, detail: "Subtitle", isDirty: document.isDirty,
                select: { [weak workspace] in workspace?.select(document) },
                close: { [weak workspace] in await workspace?.close(document) ?? true }
            )
        }
        return DocumentWorkspaceAdapter(
            featureID: "builtin.subtitle", editorProviderID: "builtin.subtitle.editor",
            kind: .subtitle,
            documents: { [weak workspace] in workspace?.documents.map(reference) ?? [] },
            selected: { [weak workspace] in workspace?.selectedDocument.map(reference) },
            hasDirty: { [weak workspace] in workspace?.hasDirtyDocuments == true },
            open: { [weak workspace] in _ = workspace?.open(url: $0) },
            saveCommands: DocumentSaveCommands(
                isSaveAvailable: { [weak workspace] in workspace?.selectedDocument != nil },
                isSaveAsAvailable: { false },
                save: { [weak workspace] in await workspace?.saveSelected() }, saveAs: {}
            ),
            termination: DocumentTerminationParticipant(priority: 0, flush: { [weak workspace] in
                await workspace?.flushAllForTermination() ?? true
            })
        )
    }

}
