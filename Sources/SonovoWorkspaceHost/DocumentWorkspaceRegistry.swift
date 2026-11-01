import Foundation
import SonovoDomainTypes
import SonovoFeatureAPI

package enum DocumentWorkspaceRegistrationError: Error, Equatable {
    case invalidFeatureID(FeatureID)
    case duplicateFeatureID(FeatureID)
    case invalidLegacyDefault(AssetKind, FeatureID)
}

@MainActor
package final class DocumentWorkspaceRegistry {
    package let adapters: [DocumentWorkspaceAdapter]
    private let byFeature: [FeatureID: DocumentWorkspaceAdapter]
    private let byLegacyKind: [AssetKind: DocumentWorkspaceAdapter]

    package init(_ adapters: [DocumentWorkspaceAdapter], legacyDefaults: [AssetKind: FeatureID] = [:]) throws {
        var byFeature: [FeatureID: DocumentWorkspaceAdapter] = [:]
        for adapter in adapters {
            guard adapter.featureID.isValid else { throw DocumentWorkspaceRegistrationError.invalidFeatureID(adapter.featureID) }
            guard byFeature.updateValue(adapter, forKey: adapter.featureID) == nil else {
                throw DocumentWorkspaceRegistrationError.duplicateFeatureID(adapter.featureID)
            }
        }
        var legacy: [AssetKind: DocumentWorkspaceAdapter] = [:]
        for (kind, candidates) in Dictionary(grouping: adapters, by: \.kind) where candidates.count == 1 {
            legacy[kind] = candidates[0]
        }
        for (kind, id) in legacyDefaults {
            guard let adapter = byFeature[id], adapter.kind == kind else {
                throw DocumentWorkspaceRegistrationError.invalidLegacyDefault(kind, id)
            }
            legacy[kind] = adapter
        }
        self.adapters = adapters
        self.byFeature = byFeature
        self.byLegacyKind = legacy
    }

    package func adapter(for featureID: FeatureID) -> DocumentWorkspaceAdapter? { byFeature[featureID] }
    /// Compatibility lookup has no registration-order winner for shared categories.
    package func adapter(for kind: AssetKind) -> DocumentWorkspaceAdapter? { byLegacyKind[kind] }

    package func owner(of path: String, excluding id: UUID? = nil) -> DocumentWorkspaceAdapter? {
        adapters.first { $0.document(at: path, excluding: id) != nil }
    }

    package var hasDirtyDocuments: Bool { adapters.contains { $0.hasDirtyDocuments } }
    package var dirtyAttentionCount: Int {
        adapters.filter(\.includesDirtyAttention).reduce(0) {
            $0 + $1.documents.filter(\.isDirty).count
        }
    }
    package var hasPendingDecision: Bool { adapters.contains { $0.pendingDecision != nil } }
}
