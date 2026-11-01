import Foundation

package struct ExternalEditorAsset: Identifiable, Hashable, Sendable {
    package init(id: String, name: String, detail: String, kind: AssetKind) {
        self.id = id; self.name = name; self.detail = detail; self.kind = kind
    }
    package let id: String
    package let name: String
    package let detail: String
    package let kind: AssetKind

    package var shortDetail: String {
        detail.components(separatedBy: " · ").first ?? detail
    }
}

package struct ExternalEditorGroup: Identifiable, Hashable, Sendable {
    package init(id: String, title: String, assets: [ExternalEditorAsset]) {
        self.id = id; self.title = title; self.assets = assets
    }
    package let id: String
    package let title: String
    package let assets: [ExternalEditorAsset]
}
