import SonovoFileIO
import Foundation
import SonovoDomainTypes
import SonovoFeatureAPI

// Feature views receive only this capability, not the concrete project model
// or its sibling workspaces. Its getters preserve project Observation reads.
extension Project {
    package func mediaReferenceState(for reference: MediaReference, documentURL: URL?) -> MediaReferenceState {
        mediaAsset(for: reference, documentURL: documentURL) == nil ? .missing : .available
    }

    package func fileCloseAction(at url: URL, kind: AssetKind, canonicalPaths: Bool) -> (@MainActor () async -> Void)? {
        let requested = canonicalPaths ? FilePathPolicy.canonical(url) : url.standardizedFileURL
        guard let tab = openTabs.first(where: {
            guard $0.kind == kind, let candidate = $0.url else { return false }
            return (canonicalPaths ? FilePathPolicy.canonical(candidate) : candidate.standardizedFileURL) == requested
        }) else { return nil }
        let identity = tab.id
        return { [weak self] in await self?.closeTab(identity) }
    }
}
