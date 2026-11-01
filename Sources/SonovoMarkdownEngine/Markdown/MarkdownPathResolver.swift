import Foundation

/// Why a local path could not be resolved.
public enum MarkdownPathRefusal: String, Sendable, Equatable, Error {
    case empty
    case notLocal
    case protocolRelative
    case traversal
    case outsideRoot
    case untitledRelative
    case noProjectRoot
    case nonLocalMount
    case unknownMount
}

/// The result of resolving a Markdown path.
public enum MarkdownPathResolution: Sendable, Equatable {
    case resolved(URL)
    /// The candidate is inside the effective root but does not exist.
    case missing(URL)
    case refused(MarkdownPathRefusal)
    case ambiguous([URL])
}

/// One resolver for images, ordinary links, lint probes, and asset routing.
///
/// Resolution has two phases. The **lexical** phase rejects schemes,
/// protocol-relative paths, and traversal, and computes candidates without
/// touching the filesystem. The **filesystem** phase canonicalizes, checks
/// containment, classifies the mount, and only then probes existence.
///
/// The effective root is the project root when the document is inside it;
/// otherwise it is the document's own directory. An untitled document has no
/// directory: with a project root it resolves root-relative paths; without one
/// every relative path refuses.
public struct MarkdownPathResolver: Sendable {
    public typealias Exists = @Sendable (URL) -> Bool
    public typealias Canonicalize = @Sendable (URL) -> URL
    public typealias IsLocalMount = @Sendable (URL) -> Bool

    public let documentURL: URL?
    public let root: URL?
    private let exists: Exists
    private let canonicalize: Canonicalize
    private let isLocalMount: IsLocalMount

    public init(
        documentURL: URL?,
        root: URL?,
        exists: @escaping Exists = MarkdownPathResolver.liveExists,
        canonicalize: @escaping Canonicalize = MarkdownPathResolver.liveCanonical,
        isLocalMount: @escaping IsLocalMount = MarkdownPathResolver.liveIsLocalMount
    ) {
        self.documentURL = documentURL
        self.root = root
        self.exists = exists
        self.canonicalize = canonicalize
        self.isLocalMount = isLocalMount
    }

    /// Resolve an ordinary link or image path. The fragment is the caller's
    /// concern; a fragment-only destination is not a local file.
    public func resolve(_ raw: String) -> MarkdownPathResolution {
        let lexical: Lexical
        do {
            lexical = try candidates(for: raw)
        } catch let refusal as MarkdownPathRefusal {
            return .refused(refusal)
        } catch {
            return .refused(.notLocal)
        }

        var firstMissing: URL?
        for candidate in lexical.candidates {
            // Classify the volume before any filesystem-backed resolution:
            // canonicalizing a path on a network mount can block far past
            // the probe's deadline.
            guard isLocalMount(candidate) else {
                return .refused(.nonLocalMount)
            }
            let canonical = canonicalize(candidate)
            guard MarkdownSecurity.contains(canonical, in: lexical.effectiveRoot) else {
                return .refused(.outsideRoot)
            }
            if exists(canonical) {
                return .resolved(canonical)
            }
            if firstMissing == nil {
                firstMissing = canonical
            }
        }
        if let firstMissing {
            return .missing(firstMissing)
        }
        return .refused(.noProjectRoot)
    }

    /// Resolve a wiki target through the existing wiki resolver, using the
    /// same effective root. Ambiguity is never guessed.
    public func resolveWiki(
        _ link: WikiLink,
        markdownFiles: [URL]
    ) -> WikiLinkResolver.Resolution {
        guard let root else { return .missing }
        let resolver = WikiLinkResolver(
            workspaceRoot: root,
            documentURL: documentURL ?? root,
            markdownFiles: markdownFiles
        )
        return resolver.resolve(link)
    }

    // MARK: - Lexical phase

    private struct Lexical {
        let candidates: [URL]
        let effectiveRoot: URL
    }

    private func candidates(for raw: String) throws -> Lexical {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MarkdownPathRefusal.empty }
        guard trimmed != "//", !trimmed.hasPrefix("//") else {
            throw MarkdownPathRefusal.protocolRelative
        }
        switch MarkdownSecurity.linkDecision(for: trimmed) {
        case .denied:
            throw MarkdownPathRefusal.notLocal
        case .allowed(.external), .allowed(.mailto), .allowed(.fragment),
             .allowed(.media):
            throw MarkdownPathRefusal.notLocal
        case .allowed(.local):
            break
        }

        // Strip literal delimiters before decoding: `%23` and `%3F` are
        // filename characters, not a fragment or query.
        var rawPath = trimmed
        if let hash = rawPath.firstIndex(of: "#") {
            rawPath = String(rawPath[rawPath.startIndex..<hash])
        }
        if let query = rawPath.firstIndex(of: "?") {
            rawPath = String(rawPath[rawPath.startIndex..<query])
        }
        let path = rawPath.removingPercentEncoding ?? rawPath
        guard !path.isEmpty else { throw MarkdownPathRefusal.notLocal }
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else {
            throw MarkdownPathRefusal.outsideRoot
        }
        guard !path.contains("\\") else { throw MarkdownPathRefusal.notLocal }

        let documentDirectory = documentURL?.deletingLastPathComponent()
        let projectRoot = root?.standardizedFileURL
        let documentIsInRoot: Bool
        if let documentDirectory, let projectRoot {
            // Lexical only: this phase must not touch the filesystem. A
            // document that reaches the root through a symlink resolves
            // against its own directory instead; the filesystem phase still
            // rejects a candidate that canonicalizes outside the root.
            documentIsInRoot = lexicallyContains(
                documentDirectory,
                in: projectRoot
            )
        } else {
            documentIsInRoot = false
        }

        let effectiveRoot: URL
        if documentIsInRoot, let projectRoot {
            effectiveRoot = projectRoot
        } else if let documentDirectory {
            effectiveRoot = documentDirectory.standardizedFileURL
        } else if let projectRoot {
            effectiveRoot = projectRoot
        } else {
            throw documentURL == nil
                ? MarkdownPathRefusal.untitledRelative
                : MarkdownPathRefusal.noProjectRoot
        }

        var results: [URL] = []
        if let documentDirectory {
            let candidate = documentDirectory
                .appendingPathComponent(path)
                .standardizedFileURL
            guard lexicallyContains(candidate, in: effectiveRoot) else {
                throw MarkdownPathRefusal.outsideRoot
            }
            results.append(candidate)
        }
        if let projectRoot, documentURL == nil {
            let candidate = projectRoot
                .appendingPathComponent(path)
                .standardizedFileURL
            guard lexicallyContains(candidate, in: projectRoot) else {
                throw MarkdownPathRefusal.outsideRoot
            }
            results.append(candidate)
        } else if let projectRoot, documentIsInRoot {
            let candidate = projectRoot
                .appendingPathComponent(path)
                .standardizedFileURL
            // A relative path that climbs out of the project is not a
            // root-relative candidate. Symlink containment is checked in the
            // filesystem phase, after the mount is known to be local.
            if lexicallyContains(candidate, in: projectRoot) {
                if !results.contains(candidate) {
                    results.append(candidate)
                }
            }
        }

        guard !results.isEmpty else { throw MarkdownPathRefusal.noProjectRoot }
        return Lexical(candidates: results, effectiveRoot: effectiveRoot)
    }

    /// Containment without resolving symlinks. Used to distinguish a path
    /// that climbs out (`..`) from one that is lexically inside but resolves
    /// outside through a symlink.
    private func lexicallyContains(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        return path == rootPath || path.hasPrefix(prefix)
    }

    // MARK: - Live environment

    public static func liveExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public static func liveCanonical(_ url: URL) -> URL {
        MarkdownSecurity.canonical(url)
    }

    public static func liveIsLocalMount(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        // Classify from the mounted-volume table, not by probing the
        // destination: `fileExists` on a path inside an unresponsive network
        // mount blocks until the transport times out, which a synchronous
        // resolver cannot interrupt. The mount table is local kernel state.
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsLocalKey],
            options: []
        ) ?? []
        var match: (path: String, url: URL)?
        for volume in volumes {
            let volumePath = volume.standardizedFileURL.path
            let prefix = volumePath == "/" ? "/" : volumePath + "/"
            guard path == volumePath || path.hasPrefix(prefix) else {
                continue
            }
            if match == nil || volumePath.count > match!.path.count {
                match = (volumePath, volume)
            }
        }
        // The root volume is always mounted; a path with no matching mount
        // is denied rather than probed.
        guard let match else { return false }
        guard let values = try? match.url.resourceValues(
            forKeys: [.volumeIsLocalKey]
        ) else {
            return false
        }
        // `volumeIsLocal` is false for SMB/AFP/NFS/WebDAV. An unknown volume
        // is denied rather than probed.
        return values.volumeIsLocal == true
    }
}
