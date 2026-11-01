import Foundation
import SwiftUI
import SonovoDomainTypes

/// Read-only project facts and explicit navigation; no concrete workspace,
/// AppState, undo model, process service or universal service locator.
@MainActor
package protocol EditorProjectContext: AnyObject {
    var id: String { get }
    var root: URL? { get }
    var isDemo: Bool { get }
    var assets: [ProjectAsset] { get }
    var selectedAsset: ProjectAsset? { get }
    var scanRevision: UInt64 { get }
    var isOffline: Bool { get }
    func openAsset(_ asset: ProjectAsset)
    func refreshNow() async
    /// Used after a feature creates a file and needs the completed index to
    /// navigate to it, including when an earlier scan is already in flight.
    func refreshAssetsForNavigation() async
    func fileCloseAction(at url: URL, kind: AssetKind, canonicalPaths: Bool) -> (@MainActor () async -> Void)?
    func mediaReferenceState(for reference: MediaReference, documentURL: URL?) -> MediaReferenceState
    func openMediaReference(_ reference: MediaReference, documentURL: URL?)
}

@MainActor
package struct EditorRequest {
    package let project: any EditorProjectContext
    package let asset: ProjectAsset?
    package let isVisible: Bool
    package let mediaReplaceRequests: (any MediaReplaceRequestSource)?
    package let terminalReferences: TerminalReferenceService?
    package let terminalReferenceSink: ((String) -> Bool)?

    package init(
        project: any EditorProjectContext, asset: ProjectAsset?, isVisible: Bool,
        terminalReferenceSink: ((String) -> Bool)? = nil,
        terminalReferences: TerminalReferenceService? = nil,
        mediaReplaceRequests: (any MediaReplaceRequestSource)? = nil
    ) {
        self.mediaReplaceRequests = mediaReplaceRequests
        self.terminalReferences = terminalReferences
        self.project = project
        self.asset = asset
        self.isVisible = isVisible
        self.terminalReferenceSink = terminalReferenceSink
    }
}

@MainActor
package struct FeatureEditorContribution {
    package let id: EditorProviderID
    package let makeView: (EditorRequest) -> AnyView

    package init(id: EditorProviderID, makeView: @escaping (EditorRequest) -> AnyView) {
        self.id = id
        self.makeView = makeView
    }
}

@MainActor package protocol MediaNavigationContext: EditorProjectContext {
    var pendingMediaSeek: MediaSeekRequest? { get }
    func takeMediaSeek(for asset: ProjectAsset) -> MediaSeekRequest?
}
