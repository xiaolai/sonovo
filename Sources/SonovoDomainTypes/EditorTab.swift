import Foundation

package enum EditorTabContent: Hashable, Sendable {
    case external(ExternalEditorAsset)
    case project(ProjectAsset)
    /// A workspace with no file yet: the empty state is the content.
    case workspace(AssetKind)
    case featureWorkspace(FeatureID, FeatureWorkspaceDescriptor)
}

package struct EditorTab: Identifiable, Hashable, Sendable {
    package let id: String
    package let assetID: String
    package let title: String
    package let kind: AssetKind
    package let icon: String
    /// The file this tab owns in a real project. Nil for a sample tab.
    package let url: URL?
    package let ownerFeatureID: FeatureID?
    package let content: EditorTabContent

    package init(asset: ExternalEditorAsset) {
        id = asset.id
        assetID = asset.id
        title = asset.name
        kind = asset.kind
        icon = asset.kind.tabIcon
        url = nil
        ownerFeatureID = nil
        content = .external(asset)
    }

    package init(asset: ProjectAsset, ownerFeatureID: FeatureID? = nil) {
        id = asset.id
        assetID = asset.id
        title = asset.name
        kind = asset.kind
        icon = asset.kind.tabIcon
        url = asset.url
        self.ownerFeatureID = ownerFeatureID
        content = .project(asset)
    }

    package init(workspaceKind kind: AssetKind) {
        id = "workspace-\(kind.rawValue)"
        assetID = id
        title = kind.workspaceTitle
        self.kind = kind
        icon = kind.tabIcon
        url = nil
        ownerFeatureID = nil
        content = .workspace(kind)
    }

    package init(workspace: FeatureWorkspaceDescriptor, featureID: FeatureID, projectID: String) {
        id = workspace.tabID(projectID: projectID, featureID: featureID)
        assetID = id; title = workspace.title; kind = workspace.legacyKind ?? .other
        icon = workspace.icon; url = nil; ownerFeatureID = featureID
        content = .featureWorkspace(featureID, workspace)
    }
    package var workspaceFeatureID: FeatureID? {
        if case .featureWorkspace(let id, _) = content { return id }
        return nil
    }
    package var workspaceProviderID: EditorProviderID? {
        if case .featureWorkspace(_, let descriptor) = content { return descriptor.editorProviderID }
        return nil
    }
    package var projectAsset: ProjectAsset? {
        if case .project(let asset) = content { return asset }
        return nil
    }

    package var externalAsset: ExternalEditorAsset? {
        if case .external(let asset) = content { return asset }
        return nil
    }

    /// The workspace kind when this is a synthetic workspace tab. Such a tab
    /// has no URL; its identity is the document selected inside it.
    package var workspaceKind: AssetKind? {
        if case .workspace(let kind) = content { return kind }
        if case .featureWorkspace(_, let descriptor) = content { return descriptor.legacyKind ?? .other }
        return nil
    }
}
