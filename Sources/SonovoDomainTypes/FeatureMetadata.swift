/// Descriptors remain available when a feature's executable factory is omitted.
/// They carry no views, workspaces, I/O, or persisted preference migration.
package struct FeatureWorkspaceDescriptor: Hashable, Sendable {
    package let role: String
    package let editorProviderID: EditorProviderID
    package let title: String
    package let icon: String
    package let legacyKind: AssetKind?
    package let legacyTabID: String?
    package let legacySampleAssetID: String?

    package init(role: String = "primary", editorProviderID: EditorProviderID,
                 title: String, icon: String, legacyKind: AssetKind? = nil, legacyTabID: String? = nil, legacySampleAssetID: String? = nil) {
        self.role = role
        self.editorProviderID = editorProviderID
        self.title = title
        self.icon = icon
        self.legacyKind = legacyKind
        self.legacyTabID = legacyTabID
        self.legacySampleAssetID = legacySampleAssetID
    }

    package func tabID(projectID: String, featureID: FeatureID) -> String {
        legacyTabID ?? "workspace:\(projectID):\(featureID.rawValue):\(role)"
    }
}

package struct FeatureMetadata: Equatable, Sendable {
    package let id: FeatureID
    package let displayName: String
    package let documentProviders: [DocumentProviderDescriptor]
    package let workspaces: [FeatureWorkspaceDescriptor]

    package init(id: FeatureID, displayName: String, documentProviders: [DocumentProviderDescriptor] = [],
                 workspaces: [FeatureWorkspaceDescriptor] = []) {
        self.id = id
        self.displayName = displayName
        self.documentProviders = documentProviders
        self.workspaces = workspaces
    }
}
