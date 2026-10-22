import Foundation
import SonovoCore

/// The consumption-boundary path policy.
///
/// Discovery filters what the sidebar shows; read, save, and search must
/// enforce the same boundaries again. A hidden directory or an outside-root
/// symlink that slips into a tab is refused here.
enum ProjectPathPolicy {
    static func isIgnoredDirectory(_ name: String) -> Bool {
        ProjectScanner.ignoredDirectories.contains(name)
    }

    /// Whether any path component after `root` is hidden (starts with a dot).
    static func isHidden(relativeTo root: URL, url: URL) -> Bool {
        let rootPath = MarkdownSecurity.canonical(root).path
        let path = MarkdownSecurity.canonical(url).path
        guard path.hasPrefix(rootPath) else { return true }
        let relative = path.dropFirst(rootPath.count)
        return relative.split(separator: "/").contains {
            $0.hasPrefix(".")
        }
    }

    /// Resolves symlinks and checks containment. A file symlink is allowed
    /// only when its target is inside the project root.
    static func resolvesInsideRoot(_ url: URL, root: URL) -> Bool {
        let canonical = MarkdownSecurity.canonical(url)
        guard MarkdownSecurity.contains(canonical, in: root) else {
            return false
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: canonical.path,
            isDirectory: &isDirectory
        ) else {
            return false
        }
        return isDirectory.boolValue
            || FileManager.default.isReadableFile(atPath: canonical.path)
    }

    /// Whether this URL may be read or saved by the code workspace.
    static func isAllowed(_ url: URL, in root: URL) -> Bool {
        let canonical = MarkdownSecurity.canonical(url)
        guard MarkdownSecurity.contains(canonical, in: root) else {
            return false
        }
        guard !isHidden(relativeTo: root, url: canonical) else { return false }
        let rootPath = MarkdownSecurity.canonical(root).path
        let components = canonical.path
            .dropFirst(rootPath.count)
            .split(separator: "/")
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: canonical.path,
            isDirectory: &isDirectory
        )
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            // Discovery excludes ignored *directories*; a regular file that
            // happens to be named `Caches` or `DerivedData` is still a file.
            if isLast, !(exists && isDirectory.boolValue) {
                continue
            }
            if isIgnoredDirectory(String(component)) {
                return false
            }
        }
        return true
    }
}
