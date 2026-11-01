import SonovoDomainTypes
import Foundation
import SonovoFileIO

/// Presentation and commands for an existing document, not a new document
/// model. The owning workspace keeps its bytes, undo and persistence policy.
@MainActor
package struct WorkspaceDocumentReference {

    package init(
        id: UUID?,
        url: URL?,
        name: String,
        detail: String,
        isDirty: Bool,
        select: @escaping () -> Void,
        close: @escaping () async -> Bool
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.detail = detail
        self.isDirty = isDirty
        self.select = select
        self.close = close
    }

    package let id: UUID?
    package let url: URL?
    package let name: String
    package let detail: String
    package let isDirty: Bool
    package let select: () -> Void
    package let close: () async -> Bool
}

@MainActor
package struct DocumentSaveCommands {

    package init(
        isSaveAvailable: @escaping () -> Bool,
        isSaveAsAvailable: @escaping () -> Bool,
        save: @escaping () async -> Void,
        saveAs: @escaping () async -> Void
    ) {
        self.isSaveAvailable = isSaveAvailable
        self.isSaveAsAvailable = isSaveAsAvailable
        self.save = save
        self.saveAs = saveAs
    }

    package let isSaveAvailable: () -> Bool
    package let isSaveAsAvailable: () -> Bool
    package let save: () async -> Void
    package let saveAs: () async -> Void

    package var canSave: Bool { isSaveAvailable() }
    package var canSaveAs: Bool { isSaveAsAvailable() }
}

@MainActor
package struct DocumentPendingDecision {

    package init(
        document: WorkspaceDocumentReference,
        save: @escaping () async -> Void,
        discard: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        self.document = document
        self.save = save
        self.discard = discard
        self.cancel = cancel
    }

    package let document: WorkspaceDocumentReference
    package let save: () async -> Void
    package let discard: () -> Void
    package let cancel: () -> Void
}

@MainActor
package struct DocumentTerminationParticipant {

    package init(
        priority: Int,
        flush: @escaping () async -> Bool
    ) {
        self.priority = priority
        self.flush = flush
    }

    package let priority: Int
    package let flush: () async -> Bool
}

package enum WorkspaceDocumentClosePolicy {
    case trackedDocumentsPreservingFileTabs
    case singleDocument
}

/// Per-document presentation policy, independent of a format or model type.
package struct DocumentTabPolicy {
    package let usesUntitledDocumentNameForTab: Bool
    package let forceKindForUnindexedFiles: Bool
    package let movedExternalDocumentUsesWorkspace: Bool
    package let movedUntabbedDocumentUsesActivation: Bool
    package init(forceKindForUnindexedFiles: Bool = false, movedExternalDocumentUsesWorkspace: Bool = false,
                 movedUntabbedDocumentUsesActivation: Bool = false, usesUntitledDocumentNameForTab: Bool = true) {
        self.usesUntitledDocumentNameForTab = usesUntitledDocumentNameForTab
        self.forceKindForUnindexedFiles = forceKindForUnindexedFiles
        self.movedExternalDocumentUsesWorkspace = movedExternalDocumentUsesWorkspace
        self.movedUntabbedDocumentUsesActivation = movedUntabbedDocumentUsesActivation
    }
}

@MainActor package struct DocumentMediaLinkContext {
    package let documentURL: URL?
    package let root: URL?
    package let resolveLocalPath: (String, URL, URL) -> URL?
    package init(documentURL: URL?, root: URL?, resolveLocalPath: @escaping (String, URL, URL) -> URL?) {
        self.documentURL = documentURL; self.root = root; self.resolveLocalPath = resolveLocalPath
    }
}

/// A small adapter over a real document workspace. UI contributions and shell
/// features do not implement this capability unless they own documents.
@MainActor
package final class DocumentWorkspaceAdapter {
    package let featureID: FeatureID
    package let editorProviderID: EditorProviderID?
    package let kind: AssetKind
    private let readDocuments: () -> [WorkspaceDocumentReference]
    private let readSelected: () -> WorkspaceDocumentReference?
    private let readDirty: () -> Bool
    package let open: (URL) -> Void
    package let saveCommands: DocumentSaveCommands?
    private let readDecision: () -> DocumentPendingDecision?
    package let termination: DocumentTerminationParticipant?
    package let dirtyQueryCanonicalizesURL: Bool
    package let fileCloseDefersDecision: Bool
    package let includesDirtyAttention: Bool
    package let beforeClose: () -> Void
    package let usesSelectedDocumentNameForTab: Bool
    package let workspaceClosePolicy: WorkspaceDocumentClosePolicy
    package let decisionPriority: Int?
    package let shutdown: () -> Void
    package let mediaLinkContext: () -> DocumentMediaLinkContext?
    package let tabPolicy: DocumentTabPolicy

    package init(
        featureID: FeatureID,
        editorProviderID: EditorProviderID? = nil,
        kind: AssetKind,
        documents: @escaping () -> [WorkspaceDocumentReference],
        selected: @escaping () -> WorkspaceDocumentReference?,
        hasDirty: @escaping () -> Bool = { false },
        open: @escaping (URL) -> Void,
        saveCommands: DocumentSaveCommands? = nil,
        decision: @escaping () -> DocumentPendingDecision? = { nil },
        termination: DocumentTerminationParticipant? = nil,
        dirtyQueryCanonicalizesURL: Bool = false,
        fileCloseDefersDecision: Bool = false,
        includesDirtyAttention: Bool = true,
        beforeClose: @escaping () -> Void = {},
        workspaceClosePolicy: WorkspaceDocumentClosePolicy = .trackedDocumentsPreservingFileTabs,
        decisionPriority: Int? = nil,
        usesSelectedDocumentNameForTab: Bool = true,
        mediaLinkContext: @escaping () -> DocumentMediaLinkContext? = { nil },
        tabPolicy: DocumentTabPolicy = DocumentTabPolicy(),
        shutdown: @escaping () -> Void = {}
    ) {
        self.featureID = featureID
        self.editorProviderID = editorProviderID
        self.kind = kind
        readDocuments = documents
        readSelected = selected
        readDirty = hasDirty
        self.open = open
        self.saveCommands = saveCommands
        readDecision = decision
        self.termination = termination
        self.dirtyQueryCanonicalizesURL = dirtyQueryCanonicalizesURL
        self.fileCloseDefersDecision = fileCloseDefersDecision
        self.includesDirtyAttention = includesDirtyAttention
        self.beforeClose = beforeClose
        self.workspaceClosePolicy = workspaceClosePolicy
        self.decisionPriority = decisionPriority
        self.usesSelectedDocumentNameForTab = usesSelectedDocumentNameForTab
        self.shutdown = shutdown
        self.tabPolicy = tabPolicy
        self.mediaLinkContext = mediaLinkContext
    }

    // Read these in the consumer's observation scope. Caching their values
    // outside a SwiftUI body would lose the underlying model dependencies.
    package var documents: [WorkspaceDocumentReference] { readDocuments() }
    package var selectedDocument: WorkspaceDocumentReference? { readSelected() }
    package var hasDirtyDocuments: Bool { readDirty() }
    package var pendingDecision: DocumentPendingDecision? { readDecision() }

    package func document(at path: String, excluding id: UUID? = nil) -> WorkspaceDocumentReference? {
        documents.first { document in
            guard id == nil || document.id == nil || document.id != id,
                  let url = document.url else { return false }
            return FilePathPolicy.canonical(url).path == path
        }
    }

    package func select(path: String) {
        document(at: path)?.select()
    }
}
