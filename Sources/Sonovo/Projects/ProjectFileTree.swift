import Foundation

/// Builds the Files navigator tree from a project's flat scan result.
///
/// Folder-first ordering matches Finder. Node identities are derived from the
/// relative path, so two folders with the same name in different branches
/// never collapse into one row.
enum ProjectFileTree {
    static func nodes(from assets: [ProjectAsset]) -> [FileNode] {
        var root = Builder()
        for asset in assets {
            let components = asset.relativePath
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !components.isEmpty else { continue }
            root.insert(components[...], asset: asset)
        }
        return root.nodes(parentPath: "")
    }

    private struct Builder {
        var folders: [String: Builder] = [:]
        var files: [ProjectAsset] = []

        mutating func insert(
            _ components: ArraySlice<String>,
            asset: ProjectAsset
        ) {
            guard let name = components.first else { return }
            let rest = components.dropFirst()
            if rest.isEmpty {
                files.append(asset)
                return
            }
            var child = folders[name] ?? Builder()
            child.insert(rest, asset: asset)
            folders[name] = child
        }

        func nodes(parentPath: String) -> [FileNode] {
            let folderNodes = folders.keys
                .sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }
                .compactMap { name -> FileNode? in
                    guard let child = folders[name] else { return nil }
                    let path = parentPath + name + "/"
                    return FileNode(
                        id: "folder:\(path)",
                        name: name,
                        icon: "folder",
                        assetID: nil,
                        children: child.nodes(parentPath: path)
                    )
                }
            let fileNodes = files
                .sorted {
                    $0.name.localizedStandardCompare($1.name)
                        == .orderedAscending
                }
                .map { asset in
                    FileNode(
                        id: "file:\(asset.id)",
                        name: asset.name,
                        icon: asset.kind.icon,
                        assetID: asset.id,
                        children: nil
                    )
                }
            return folderNodes + fileNodes
        }
    }
}
