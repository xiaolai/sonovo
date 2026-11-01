import SonovoTextEngine
import Foundation
import SwiftUI
import SonovoDomainTypes
import SonovoFeatureAPI

@MainActor package enum CodeFeature {
    nonisolated package static func metadata(overriding dedicated: Set<EditorProviderID>) -> FeatureMetadata {
        FeatureMetadata(id: "builtin.code", displayName: "Code", documentProviders: descriptors(overriding: dedicated),
            workspaces: [FeatureWorkspaceDescriptor(editorProviderID: "builtin.code.editor", title: AssetKind.code.workspaceTitle,
                icon: AssetKind.code.tabIcon, legacyKind: .code, legacyTabID: "workspace-code")])
    }

    nonisolated package static func descriptors(overriding dedicated: Set<EditorProviderID>) -> [DocumentProviderDescriptor] {
        [DocumentProviderDescriptor(id: "builtin.code.editor", featureID: "builtin.code", kind: .code,
            selectors: CodeLanguage.extensions.sorted().map(DocumentSelector.fileExtension)
                + CodeLanguage.specialFilenames.sorted().map(DocumentSelector.fileName)),
         DocumentProviderDescriptor(id: "builtin.code.dockerfile", featureID: "builtin.code", kind: .code,
            selectors: [.filePrefix("Dockerfile.")], overrides: dedicated.union(["builtin.code.editor"]))]
    }

    @MainActor package static func editors(workspace: CodeWorkspace) -> [FeatureEditorContribution] {
        ["builtin.code.editor", "builtin.code.dockerfile"].map { id in
            FeatureEditorContribution(id: EditorProviderID(rawValue: id)) { request in
                AnyView(CodeWorkspaceView(workspace: workspace, project: request.project,
                    terminalReferences: request.terminalReferences))
            }
        }
    }
    package static func documentWorkspace(_ workspace: CodeWorkspace) -> DocumentWorkspaceAdapter {
        func reference(_ document: CodeDocument) -> WorkspaceDocumentReference {
            let language = document.language.displayName
            let detail = document.readOnlyReason.map { "\(language) · \($0)" }
                ?? "\(language) · \(document.lineEnding == .crlf ? "CRLF" : "LF")"
            return WorkspaceDocumentReference(
                id: document.id, url: document.fileURL, name: document.displayName,
                detail: detail, isDirty: document.isDirty,
                select: { [weak workspace] in workspace?.select(document) },
                close: { [weak workspace] in await workspace?.close(document) ?? true }
            )
        }
        return DocumentWorkspaceAdapter(
            featureID: "builtin.code", editorProviderID: "builtin.code.editor",
            kind: .code,
            documents: { [weak workspace] in workspace?.documents.map(reference) ?? [] },
            selected: { [weak workspace] in workspace?.selectedDocument.map(reference) },
            hasDirty: { [weak workspace] in workspace?.hasDirtyDocuments == true },
            open: { [weak workspace] in _ = workspace?.open(url: $0) },
            saveCommands: DocumentSaveCommands(
                isSaveAvailable: { [weak workspace] in workspace?.selectedDocument?.canAttemptSave == true },
                isSaveAsAvailable: { [weak workspace] in workspace?.selectedDocument != nil },
                save: { [weak workspace] in await workspace?.saveSelected() },
                saveAs: { [weak workspace] in await workspace?.saveAsSelected() }
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
            termination: DocumentTerminationParticipant(priority: 2, flush: { [weak workspace] in
                await workspace?.flushAllForTermination() ?? true
            }),
            fileCloseDefersDecision: true,
            decisionPriority: 1,
            tabPolicy: DocumentTabPolicy(forceKindForUnindexedFiles: true),
            shutdown: { [weak workspace] in workspace?.prepareForTermination() }
        )
    }

}
