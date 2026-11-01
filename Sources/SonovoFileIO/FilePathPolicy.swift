import Foundation

public enum FilePathPolicy {
    package static func canonicalAbsolutePath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return canonical(URL(fileURLWithPath: path)).path
    }

    public static func contains(_ url: URL, in root: URL) -> Bool {
        let rootPath = canonical(root).path
        let path = canonical(url).path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        return path == rootPath || path.hasPrefix(prefix)
    }

    /// Resolves symlinks in the deepest existing ancestor of `url`.
    ///
    /// `URL.resolvingSymlinksInPath()` leaves a symlinked directory unresolved
    /// when the leaf does not exist yet, which would let a media path escape
    /// the workspace. Walking to the deepest existing component closes that
    /// hole without requiring the target file to exist.
    public static func canonical(_ url: URL) -> URL {
        var missing: [String] = []
        var current = url.standardizedFileURL

        while !FileManager.default.fileExists(atPath: current.path) {
            missing.append(current.lastPathComponent)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }

        var resolved = current.resolvingSymlinksInPath()
        for component in missing.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    public static func isValidRelativePath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == path else { return false }
        guard scheme(of: trimmed) == nil else { return false }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            return false
        }
        guard !trimmed.contains("\\") else { return false }
        let components = trimmed.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        return !components.contains(where: { $0 == ".." })
    }

    package static func scheme(of destination: String) -> String? {
        guard let colon = destination.firstIndex(of: ":") else { return nil }
        let candidate = String(destination[destination.startIndex..<colon])
        guard !candidate.isEmpty else { return nil }

        let scalars = candidate.unicodeScalars
        guard let first = scalars.first,
              CharacterSet.letters.contains(first) else {
            return nil
        }
        for scalar in scalars.dropFirst() {
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == "+" || scalar == "-" || scalar == "." {
                continue
            }
            return nil
        }
        return candidate.lowercased()
    }
}
