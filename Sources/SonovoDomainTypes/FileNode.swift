import Foundation

package struct FileNode: Identifiable, Hashable, Sendable {
    package init(id: String, name: String, icon: String, assetID: String?, children: [FileNode]?) {
        self.id = id; self.name = name; self.icon = icon; self.assetID = assetID; self.children = children
    }
    package let id: String
    package let name: String
    package let icon: String
    package let assetID: String?
    package var children: [FileNode]?

    /// Filters a tree while keeping the ancestors of matching descendants.
    /// A matching folder keeps its whole subtree.
    package static func filtered(_ nodes: [FileNode], query: String) -> [FileNode] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nodes }
        return nodes.compactMap { node in
            if node.name.localizedCaseInsensitiveContains(trimmed) {
                return node
            }
            guard let children = node.children else { return nil }
            let matches = filtered(children, query: trimmed)
            guard !matches.isEmpty else { return nil }
            var copy = node
            copy.children = matches
            return copy
        }
    }
}
