import Foundation
import SwiftUI
import SonovoDomainTypes
import SonovoFeatureAPI

@MainActor package enum MDXFeature {
    nonisolated package static var metadata: FeatureMetadata {
        FeatureMetadata(id: "builtin.mdx", displayName: "MDX", documentProviders: descriptors,
            workspaces: [FeatureWorkspaceDescriptor(editorProviderID: "builtin.mdx.editor", title: AssetKind.mdx.workspaceTitle,
                icon: AssetKind.mdx.tabIcon, legacyKind: .mdx, legacyTabID: "workspace-mdx")])
    }

    nonisolated package static let descriptors = [DocumentProviderDescriptor(
        id: "builtin.mdx.editor", featureID: "builtin.mdx", kind: .mdx,
        selectors: ["mdx", "jsx"].map(DocumentSelector.fileExtension), overrides: ["builtin.code.editor", "builtin.code.dockerfile"])]
    package static func editors(workspace: MDXWorkspace) -> [FeatureEditorContribution] {
        [FeatureEditorContribution(id: "builtin.mdx.editor") { _ in
            AnyView(MDXWorkspaceView(workspace: workspace))
        }]
    }
    package static func documentWorkspace(_ workspace: MDXWorkspace) -> DocumentWorkspaceAdapter {
        func reference(_ document: MDXDocument) -> WorkspaceDocumentReference {
            WorkspaceDocumentReference(
                id: document.id, url: document.fileURL, name: document.displayName,
                detail: "MDX · \(document.isDirty ? "Edited" : "Saved")", isDirty: document.isDirty,
                select: { [weak workspace] in workspace?.select(document) },
                close: { [weak workspace] in await workspace?.close(document) ?? true }
            )
        }
        return DocumentWorkspaceAdapter(
            featureID: "builtin.mdx", editorProviderID: "builtin.mdx.editor",
            kind: .mdx,
            documents: { [weak workspace] in workspace?.documents.map(reference) ?? [] },
            selected: { [weak workspace] in workspace?.selectedDocument.map(reference) },
            hasDirty: { [weak workspace] in workspace?.hasDirtyDocuments == true },
            open: { [weak workspace] in _ = workspace?.open(url: $0) },
            saveCommands: DocumentSaveCommands(
                isSaveAvailable: { [weak workspace] in workspace?.selectedDocument?.isDirty == true },
                isSaveAsAvailable: { false },
                save: { [weak workspace] in await workspace?.saveSelected() }, saveAs: {}
            ),
            decision: { [weak workspace] in
                guard let workspace, let document = workspace.pendingClose else { return nil }
                return DocumentPendingDecision(
                    document: reference(document),
                    save: { [weak workspace] in
                        guard workspace?.pendingClose?.id == document.id else { return }
                        await workspace?.saveAndClose(document)
                    },
                    discard: { [weak workspace] in
                        guard workspace?.pendingClose?.id == document.id else { return }
                        workspace?.discardAndClose(document)
                    },
                    cancel: { [weak workspace] in
                        guard workspace?.pendingClose?.id == document.id else { return }
                        workspace?.cancelPendingClose()
                    }
                )
            },
            termination: DocumentTerminationParticipant(priority: 3, flush: { [weak workspace] in
                await workspace?.flushAllForTermination() ?? true
            }),
            decisionPriority: 2,
            usesSelectedDocumentNameForTab: false,
            shutdown: { [weak workspace] in workspace?.prepareForTermination() }
        )
    }

}
