import Foundation

/// The security policy for links, media paths, raw HTML, and wiki targets.
///
/// The viewer never renders raw HTML as markup, never fetches the network, and
/// never follows a path outside the workspace. Every decision here is explicit
/// so tests can assert the exact outcome instead of trusting a "sanitized"
/// impression.
public enum MarkdownSecurity {
    /// The kind of link that passed the policy.
    public enum LinkKind: String, Sendable, Equatable {
        case external
        case mailto
        case local
        case fragment
        /// A validated `sonovo:` media reference.
        case media
    }

    /// The exact policy outcome for a link destination.
    public enum LinkDecision: Sendable, Equatable {
        case allowed(LinkKind)
        case denied(String)

        public var isAllowed: Bool {
            if case .allowed = self { return true }
            return false
        }
    }

    /// How the viewer treats a raw HTML fragment.
    public enum HTMLDisposition: Sendable, Equatable {
        /// Shown as plain text, never executed.
        case shownAsText
        /// Hidden entirely.
        case hidden
    }

    /// Schemes that are always denied, even before the allowlist check.
    public static let deniedSchemes: Set<String> = [
        "javascript", "data", "file", "blob", "vbscript", "about"
    ]

    /// Schemes that are allowed for external navigation.
    public static let allowedSchemes: Set<String> = ["http", "https"]

    /// Classifies a link destination.
    public static func linkDecision(for destination: String) -> LinkDecision {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .denied("empty destination")
        }

        if trimmed.hasPrefix("#") {
            return .allowed(.fragment)
        }

        if trimmed.hasPrefix("//") {
            // Protocol-relative navigation could silently reach the network
            // with whatever scheme the host chooses.
            return .denied("protocol-relative URL")
        }

        if let scheme = scheme(of: trimmed) {
            if deniedSchemes.contains(scheme) {
                return .denied("denied scheme \(scheme)")
            }
            if allowedSchemes.contains(scheme) {
                return .allowed(.external)
            }
            if scheme == "mailto" {
                return .allowed(.mailto)
            }
            if scheme == MediaReference.scheme {
                return MediaReference.parse(trimmed) == nil
                    ? .denied("invalid media link")
                    : .allowed(.media)
            }
            return .denied("unsupported scheme \(scheme)")
        }

        return .allowed(.local)
    }

    /// Resolves a document-relative or workspace-relative path inside `root`.
    ///
    /// Returns `nil` for absolute paths, traversal, URI schemes, and symlinks
    /// that escape the root.
    public static func resolveLocalPath(
        _ path: String,
        relativeTo documentURL: URL,
        root: URL
    ) -> URL? {
        guard case .allowed(.local) = linkDecision(for: path) else {
            return nil
        }

        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.hasPrefix("/"), !decoded.hasPrefix("~") else {
            return nil
        }
        guard !decoded.contains("\\") else { return nil }

        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == ".." }) else { return nil }

        let rootStandardized = canonical(root.standardizedFileURL)
        let documentDirectory = canonical(
            documentURL.deletingLastPathComponent().standardizedFileURL
        )

        let candidate = documentDirectory
            .appendingPathComponent(decoded)
            .standardizedFileURL

        guard contains(candidate, in: rootStandardized) else { return nil }
        return candidate
    }

    /// Whether a path is relative, traversal-free, and free of a scheme.
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

    /// Whether a wiki target is structurally safe. Surrounding whitespace
    /// has never counted as part of the target.
    public static func isValidWikiTarget(_ target: String) -> Bool {
        isValidRelativePath(
            target.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// The viewer's raw-HTML policy: hide everything that is not a structural
    /// details block, which the augmenter has already claimed.
    public static func htmlDisposition(for rawHTML: String) -> HTMLDisposition {
        _ = rawHTML
        return .hidden
    }

    /// Whether `url` is inside `root`.
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

    private static func scheme(of destination: String) -> String? {
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

/// Resolves `[[target]]` and `[[target#fragment]]` to documents in a workspace.
public struct WikiLinkResolver: Sendable {
    public enum Resolution: Sendable, Equatable {
        case resolved(URL)
        case missing
        case ambiguous([URL])
    }

    public let workspaceRoot: URL
    public let documentURL: URL
    public let markdownFiles: [URL]

    public init(
        workspaceRoot: URL,
        documentURL: URL,
        markdownFiles: [URL]
    ) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.documentURL = documentURL.standardizedFileURL
        self.markdownFiles = markdownFiles.map { $0.standardizedFileURL }
    }

    public func resolve(_ link: WikiLink) -> Resolution {
        // `[[#Heading]]` targets the current document.
        if link.target.isEmpty {
            guard let fragment = link.fragment, !fragment.isEmpty else {
                return .missing
            }
            let canonical = MarkdownSecurity.canonical(documentURL)
            guard MarkdownSecurity.contains(canonical, in: workspaceRoot),
                  FileManager.default.fileExists(atPath: canonical.path) else {
                return .missing
            }
            return .resolved(documentURL.standardizedFileURL)
        }

        guard MarkdownSecurity.isValidWikiTarget(link.target) else {
            return .missing
        }

        var path = link.target
        if (path as NSString).pathExtension.isEmpty {
            path += ".md"
        }

        // Document-relative first.
        if let documentRelative = MarkdownSecurity.resolveLocalPath(
            path,
            relativeTo: documentURL,
            root: workspaceRoot
        ), FileManager.default.fileExists(atPath: documentRelative.path) {
            return .resolved(documentRelative)
        }

        // Workspace-root-relative second.
        let rootCandidate = workspaceRoot
            .appendingPathComponent(path)
            .standardizedFileURL
        if MarkdownSecurity.contains(rootCandidate, in: workspaceRoot),
           FileManager.default.fileExists(atPath: rootCandidate.path) {
            return .resolved(rootCandidate)
        }

        // A bare basename resolves only when exactly one document matches.
        if !path.contains("/") {
            let base = (path as NSString).deletingPathExtension
            let requestedExtension = (link.target as NSString)
                .pathExtension
                .lowercased()

            func matchesBase(_ file: URL, caseInsensitive: Bool) -> Bool {
                let name = file.lastPathComponent
                let fileBase = (name as NSString).deletingPathExtension
                let baseMatches = caseInsensitive
                    ? fileBase.caseInsensitiveCompare(base) == .orderedSame
                    : fileBase == base
                guard baseMatches else { return false }
                guard !requestedExtension.isEmpty else { return true }
                return (name as NSString).pathExtension.lowercased()
                    == requestedExtension
            }

            // The candidate list is caller-supplied. Never return an entry
            // that is outside the workspace or that a symlink would move
            // outside it, and bound the work a huge list can cause.
            func candidates(matching predicate: (URL) -> Bool) -> [URL] {
                var seen = Set<String>()
                var result: [URL] = []
                for file in markdownFiles where predicate(file) {
                    let canonical = MarkdownSecurity.canonical(file)
                    guard MarkdownSecurity.contains(canonical, in: workspaceRoot),
                          FileManager.default.fileExists(atPath: canonical.path) else {
                        continue
                    }
                    let identity = file.standardizedFileURL
                    if seen.insert(identity.path).inserted {
                        result.append(identity)
                        if result.count > MarkdownLimits.maxWikiLinkCandidates {
                            break
                        }
                    }
                }
                return result.sorted { $0.path < $1.path }
            }

            let unique = candidates {
                matchesBase($0, caseInsensitive: false)
            }
            if unique.count > MarkdownLimits.maxWikiLinkCandidates {
                return .ambiguous(
                    Array(unique.prefix(MarkdownLimits.maxWikiLinkCandidates))
                )
            }
            switch unique.count {
            case 0:
                let matches = candidates {
                    matchesBase($0, caseInsensitive: true)
                }
                if matches.count > MarkdownLimits.maxWikiLinkCandidates {
                    return .ambiguous(
                        Array(matches.prefix(MarkdownLimits.maxWikiLinkCandidates))
                    )
                }
                if matches.count == 1 { return .resolved(matches[0]) }
                if matches.count > 1 { return .ambiguous(matches) }
                return .missing
            case 1:
                return .resolved(unique[0])
            default:
                return .ambiguous(unique)
            }
        }

        return .missing
    }
}
