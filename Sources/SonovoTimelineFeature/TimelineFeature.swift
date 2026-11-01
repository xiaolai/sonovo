import SwiftUI
import SonovoDomainTypes
import SonovoFeatureAPI

@MainActor package enum TimelineFeature {
    nonisolated package static var metadata: FeatureMetadata {
        FeatureMetadata(id: "builtin.timeline", displayName: "Timeline", documentProviders: descriptors,
            workspaces: [FeatureWorkspaceDescriptor(editorProviderID: "builtin.timeline.editor", title: AssetKind.timeline.workspaceTitle,
                icon: AssetKind.timeline.tabIcon, legacyKind: .timeline, legacyTabID: "workspace-timeline")])
    }

    nonisolated package static let descriptors = [DocumentProviderDescriptor(
        id: "builtin.timeline.editor", featureID: "builtin.timeline", kind: .timeline,
        selectors: [.fileSuffix(".timeline.json")], overrides: ["builtin.code.editor", "builtin.code.dockerfile"])]
    package static func editors(workspace: TimelineWorkspace) -> [FeatureEditorContribution] {
        [FeatureEditorContribution(id: "builtin.timeline.editor") { request in
            AnyView(TimelineDocumentView(workspace: workspace, assets: request.project.assets,
                project: request.project, isVisible: request.isVisible, scanRevision: request.project.scanRevision))
        }]
    }
    package static func documentWorkspace(_ workspace: TimelineWorkspace) -> DocumentWorkspaceAdapter {
        func reference(_ document: TimelineDocument) -> WorkspaceDocumentReference {
            WorkspaceDocumentReference(
                id: nil, url: document.url, name: document.url.lastPathComponent,
                detail: "Timeline", isDirty: document.hasUnsavedChanges, select: {},
                close: { [weak workspace] in
                    return await workspace?.close(url: document.url) ?? true
                }
            )
        }
        return DocumentWorkspaceAdapter(
            featureID: "builtin.timeline", editorProviderID: "builtin.timeline.editor",
            kind: .timeline,
            documents: { [weak workspace] in workspace?.document.map { [reference($0)] } ?? [] },
            // Existing synthetic Timeline tabs do not report an identity in
            // workspaceDocumentIdentity; preserve that until a separate UX change.
            selected: { nil },
            hasDirty: { [weak workspace] in workspace?.hasDirtyDocuments == true },
            open: { [weak workspace] in workspace?.open(url: $0) },
            termination: DocumentTerminationParticipant(priority: 4, flush: { [weak workspace] in
                await workspace?.flushAllForTermination() ?? true
            }),
            dirtyQueryCanonicalizesURL: true,
            includesDirtyAttention: false,
            beforeClose: { [weak workspace] in workspace?.cancelJobs() },
            workspaceClosePolicy: .singleDocument,
            shutdown: { [weak workspace] in workspace?.prepareForTermination() }
        )
    }}
