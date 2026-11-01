import Foundation

/// Guarded lookup for a module that promises an unavailable state when its
/// optional resource bundle is absent. It never evaluates Bundle.module,
/// recursively scans a directory, or searches user data locations.
public enum ResourceBundleLocator {
    public static func find(named name: String, searchRoots: [URL]) -> Bundle? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
              name != ".", name != ".." else { return nil }
        let filename = name.hasSuffix(".bundle") ? name : name + ".bundle"
        for root in searchRoots {
            if let bundle = Bundle(url: root.appendingPathComponent(filename)) { return bundle }
        }
        return nil
    }

    public static func find(named name: String, relativeTo anchor: Bundle) -> Bundle? {
        var roots: [URL] = []
        for bundle in [Bundle.main, anchor] {
            if let resourceURL = bundle.resourceURL { roots.append(resourceURL) }
            var directory = bundle.bundleURL
            // Packaged app Resources and Swift Build's sibling/PackageFrameworks
            // layouts are within these bounded ancestors; no recursive search.
            for _ in 0..<4 {
                roots.append(directory)
                let parent = directory.deletingLastPathComponent()
                if parent == directory { break }
                directory = parent
            }
        }
        return find(named: name, searchRoots: roots)
    }
}
