import Foundation

/// One Quick Open candidate: an open tab or a project file.
public struct MarkdownQuickOpenEntry: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case tab
        case file
    }

    public let url: URL
    public let title: String
    public let relativePath: String
    public let kind: Kind

    public var id: String { url.path }

    public init(
        url: URL,
        title: String,
        relativePath: String,
        kind: Kind
    ) {
        self.url = url
        self.title = title
        self.relativePath = relativePath
        self.kind = kind
    }
}

/// Quick Open ranking: tabs before files, then prefix matches, then
/// subsequence matches. Paths outside the root never enter the list.
public enum MarkdownQuickOpen {
    public static func entries(
        tabs: [URL],
        files: [URL],
        root: URL?
    ) -> [MarkdownQuickOpenEntry] {
        var seen = Set<String>()
        var result: [MarkdownQuickOpenEntry] = []

        func relative(_ url: URL) -> String {
            guard let root else { return url.lastPathComponent }
            let canonicalRoot = MarkdownSecurity.canonical(root).path
            let path = MarkdownSecurity.canonical(url).path
            let prefix = canonicalRoot.hasSuffix("/")
                ? canonicalRoot
                : canonicalRoot + "/"
            guard path.hasPrefix(prefix) else {
                return url.lastPathComponent
            }
            return String(path.dropFirst(prefix.count))
        }

        for url in tabs where seen.insert(url.path).inserted {
            result.append(
                MarkdownQuickOpenEntry(
                    url: url,
                    title: url.lastPathComponent,
                    relativePath: relative(url),
                    kind: .tab
                )
            )
        }
        for url in files where seen.insert(url.path).inserted {
            result.append(
                MarkdownQuickOpenEntry(
                    url: url,
                    title: url.lastPathComponent,
                    relativePath: relative(url),
                    kind: .file
                )
            )
        }
        return result
    }

    public static func filter(
        _ entries: [MarkdownQuickOpenEntry],
        query: String
    ) -> [MarkdownQuickOpenEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return entries }
        let needle = trimmed.lowercased()

        func score(_ entry: MarkdownQuickOpenEntry) -> Int? {
            let path = entry.relativePath.lowercased()
            let title = entry.title.lowercased()
            if title.hasPrefix(needle) || path.hasPrefix(needle) {
                return 3
            }
            if title.contains(needle) || path.contains(needle) {
                return 2
            }
            var index = path.startIndex
            for character in needle {
                guard let found = path[index...].firstIndex(of: character)
                else {
                    return nil
                }
                index = path.index(after: found)
            }
            return 1
        }

        return entries
            .compactMap { entry -> (MarkdownQuickOpenEntry, Int)? in
                guard let value = score(entry) else { return nil }
                return (entry, value)
            }
            .sorted { lhs, rhs in
                let leftTab = lhs.0.kind == .tab
                let rightTab = rhs.0.kind == .tab
                if leftTab != rightTab { return leftTab }
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.relativePath.count
                    < rhs.0.relativePath.count
            }
            .map(\.0)
    }
}
