import Foundation
import SwiftUI
import SonovoDomainTypes
import SonovoFeatureAPI
import SonovoMarkdownEngine

@MainActor package enum MarkdownFeature {
    nonisolated package static var metadata: FeatureMetadata {
        FeatureMetadata(id: "builtin.markdown", displayName: "Markdown", documentProviders: descriptors,
            workspaces: [FeatureWorkspaceDescriptor(editorProviderID: "builtin.markdown.editor", title: AssetKind.script.workspaceTitle,
                icon: AssetKind.script.tabIcon, legacyKind: .script, legacyTabID: "workspace-script", legacySampleAssetID: "script-md")])
    }

    nonisolated package static let descriptors = [DocumentProviderDescriptor(
        id: "builtin.markdown.editor", featureID: "builtin.markdown", kind: .script,
        selectors: ["md", "markdown"].map(DocumentSelector.fileExtension))]

    package static func projectView(workspace: MarkdownWorkspace, project: any EditorProjectContext) -> MarkdownWorkspaceView {
        MarkdownWorkspaceView(workspace: workspace,
            mediaReferenceState: { project.mediaReferenceState(for: $0, documentURL: $1) },
            onOpenMedia: { project.openMediaReference($0, documentURL: $1) })
    }
    package static func editors(workspace: MarkdownWorkspace) -> [FeatureEditorContribution] {
        [FeatureEditorContribution(id: "builtin.markdown.editor") { request in
            AnyView(projectView(workspace: workspace, project: request.project))
        }]
    }
    package static func documentWorkspace(_ workspace: MarkdownWorkspace) -> DocumentWorkspaceAdapter {
        func reference(_ document: MarkdownDocument) -> WorkspaceDocumentReference {
            WorkspaceDocumentReference(
                id: document.id, url: document.fileURL,
                name: document.fileURL?.lastPathComponent ?? "Untitled", detail: "Markdown",
                isDirty: document.isDirty,
                select: { [weak workspace] in workspace?.select(document) },
                close: { [weak workspace] in await workspace?.close(document) ?? true }
            )
        }
        return DocumentWorkspaceAdapter(
            featureID: "builtin.markdown", editorProviderID: "builtin.markdown.editor",
            kind: .script,
            documents: { [weak workspace] in workspace?.documents.map(reference) ?? [] },
            selected: { [weak workspace] in workspace?.selectedDocument.map(reference) },
            hasDirty: { [weak workspace] in workspace?.hasDirtyDocuments == true },
            open: { [weak workspace] in _ = workspace?.open(url: $0) },
            saveCommands: DocumentSaveCommands(
                isSaveAvailable: { true }, isSaveAsAvailable: { true },
                save: { [weak workspace] in await workspace?.saveSelected() },
                saveAs: { [weak workspace] in await workspace?.saveSelectedAs() }
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
            termination: DocumentTerminationParticipant(priority: 1, flush: { [weak workspace] in
                await workspace?.flushAllForTermination() ?? true
            }),
            fileCloseDefersDecision: true,
            decisionPriority: 0,
            mediaLinkContext: { [weak workspace] in
                guard let workspace else { return nil }
                return DocumentMediaLinkContext(documentURL: workspace.selectedDocument?.fileURL, root: workspace.workspaceRoot,
                    resolveLocalPath: { MarkdownSecurity.resolveLocalPath($0, relativeTo: $1, root: $2) })
            },
            tabPolicy: DocumentTabPolicy(movedExternalDocumentUsesWorkspace: true, movedUntabbedDocumentUsesActivation: true, usesUntitledDocumentNameForTab: false),
            shutdown: { [weak workspace] in workspace?.shutdown() }
        )
    }

}
