import Foundation

/// The complete set of sources one preview needs: the entry document plus
/// every local module it imports, keyed by project-relative POSIX path.
public struct MDXSourceGraph: Hashable, Sendable {
    public let entryID: String
    public let files: [String: String]

    public init(entryID: String, files: [String: String]) {
        self.entryID = entryID
        self.files = files
    }

    public var request: MDXCompileRequest {
        MDXCompileRequest(entry: entryID, files: files)
    }
}

/// The resolved sources and the compile that produced them. The response's
/// modules are for exactly `graph.files`; a caller never compiles twice.
public struct MDXResolvedGraph: Sendable {
    public let graph: MDXSourceGraph
    public let response: MDXCompileResponse

    public init(graph: MDXSourceGraph, response: MDXCompileResponse) {
        self.graph = graph
        self.response = response
    }
}

public struct MDXImportLimits: Hashable, Sendable {
    public var maxFiles: Int
    public var maxFileBytes: Int
    public var maxTotalBytes: Int
    public var maxRounds: Int

    public init(
        maxFiles: Int = 128,
        maxFileBytes: Int = 4 * 1024 * 1024,
        maxTotalBytes: Int = 16 * 1024 * 1024,
        maxRounds: Int = 64
    ) {
        self.maxFiles = maxFiles
        self.maxFileBytes = maxFileBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxRounds = maxRounds
    }

    public static let standard = MDXImportLimits()
}

/// One resolved relative import. The cache re-resolves the same specifier
/// before trusting a hit, so a newly created higher-priority candidate
/// (`.mdx` before `.jsx`) cannot be shadowed by stale output.
public struct MDXResolvedImport: Hashable, Sendable {
    public let moduleID: String
    public let specifier: String
    public let id: String
    public let url: URL

    public init(
        moduleID: String,
        specifier: String,
        id: String,
        url: URL
    ) {
        self.moduleID = moduleID
        self.specifier = specifier
        self.id = id
        self.url = url
    }
}

public enum MDXImportGraphError: Error, LocalizedError, Equatable {
    case entryNotInProject(String)
    case unsupportedEntryExtension(String)
    case unreadableFile(module: String, message: String)
    case notUTF8(module: String)
    case fileTooLarge(module: String, bytes: Int, limit: Int)
    case tooManyFiles(limit: Int)
    case graphTooLarge(limit: Int)
    case compileFailed(MDXCompileDiagnostic)
    case remoteImport(module: String, specifier: String)
    case bareImport(module: String, specifier: String)
    case escapingImport(module: String, specifier: String)
    case unsupportedImport(module: String, specifier: String)
    case missingImport(module: String, specifier: String)
    case roundLimit(Int)

    public var errorDescription: String? {
        switch self {
        case .entryNotInProject(let path):
            "The document is not inside the project folder: \(path)"
        case .unsupportedEntryExtension(let name):
            "Only .mdx and .jsx documents open in the MDX workspace: \(name)"
        case .unreadableFile(let module, let message):
            "Could not read \(module): \(message)"
        case .notUTF8(let module):
            "\(module) is not UTF-8 text."
        case .fileTooLarge(let module, let bytes, let limit):
            "\(module) is \(bytes) bytes; the limit is \(limit)."
        case .tooManyFiles(let limit):
            "The import graph has more than \(limit) files."
        case .graphTooLarge(let limit):
            "The imported sources exceed \(limit) bytes."
        case .compileFailed(let diagnostic):
            diagnostic.displayText
        case .remoteImport(let module, let specifier):
            "Remote imports are refused: “\(specifier)” in \(module)."
        case .bareImport(let module, let specifier):
            "Only local imports (./ or ../) are supported: “\(specifier)” in \(module)."
        case .escapingImport(let module, let specifier):
            "This import leaves the project folder: “\(specifier)” in \(module)."
        case .unsupportedImport(let module, let specifier):
            "Only .mdx, .jsx, and .js modules can be imported: “\(specifier)” in \(module)."
        case .missingImport(let module, let specifier):
            "The import could not be found: “\(specifier)” in \(module)."
        case .roundLimit(let limit):
            "The import graph is deeper than \(limit) levels."
        }
    }
}

/// Resolves the entry document and its local imports into one source graph.
///
/// Every step is a boundary check. A specifier must be relative, resolve
/// inside the project root after symbolic links, and name a supported file.
/// The compiler is asked for dependencies from the parsed source, so an
/// `import` in a code fence or a comment is never treated as real. Remote and
/// package imports are refused before any module reaches a web view.
public enum MDXImportGraphResolver {
    public static let runtimeModules: Set<String> = [
        "react",
        "react/jsx-runtime",
        "react-dom/client"
    ]

    /// The extensions tried for an extensionless import, in order. This is an
    /// array, not a set: `.mdx` must win over `.jsx`, and the order here is
    /// the order the preview loader tries as well.
    public static let localExtensions: [String] = ["mdx", "jsx", "js"]

    /// Resolves `entry` against `projectRoot`, calling `compile` once per
    /// dependency layer. `read` is injectable for tests; production uses the
    /// file system.
    public static func resolve(
        entry: URL,
        projectRoot: URL,
        limits: MDXImportLimits = .standard,
        compile: (MDXCompileRequest) async throws -> MDXCompileResponse,
        read: ((URL, Int) throws -> Data)? = nil
    ) async throws -> MDXResolvedGraph {
        let root = canonical(projectRoot)
        let entryURL = canonical(entry)
        let entryName = entryURL.lastPathComponent
        let entryExtension = entryURL.pathExtension.lowercased()
        guard entryExtension == "mdx" || entryExtension == "jsx" else {
            throw MDXImportGraphError.unsupportedEntryExtension(entryName)
        }
        guard let entryID = relativeID(for: entryURL, root: root) else {
            throw MDXImportGraphError.entryNotInProject(entryURL.path)
        }

        var files: [String: String] = [:]
        var totalBytes = 0
        try load(
            id: entryID,
            url: entryURL,
            limits: limits,
            root: root,
            files: &files,
            totalBytes: &totalBytes,
            read: read
        )

        for _ in 0..<limits.maxRounds {
            let response = try await compile(
                MDXCompileRequest(entry: entryID, files: files)
            )
            guard response.ok else {
                throw MDXImportGraphError.compileFailed(
                    response.diagnostic
                        ?? MDXCompileDiagnostic(
                            message: "MDX compilation failed."
                        )
                )
            }

            var added = false
            for module in response.modules {
                for specifier in module.imports {
                    if runtimeModules.contains(specifier) { continue }
                    if isRemote(specifier) {
                        throw MDXImportGraphError.remoteImport(
                            module: module.id,
                            specifier: specifier
                        )
                    }
                    guard specifier.hasPrefix("./")
                        || specifier.hasPrefix("../") else {
                        throw MDXImportGraphError.bareImport(
                            module: module.id,
                            specifier: specifier
                        )
                    }
                    guard let found = try resolveImport(
                        specifier: specifier,
                        from: module.id,
                        projectRoot: root
                    ) else {
                        throw MDXImportGraphError.missingImport(
                            module: module.id,
                            specifier: specifier
                        )
                    }
                    if files[found.id] != nil { continue }
                    // Checked only before a new file: an already-loaded
                    // import must not fail a graph that is exactly at the
                    // cap on its final compilation pass.
                    guard files.count < limits.maxFiles else {
                        throw MDXImportGraphError.tooManyFiles(
                            limit: limits.maxFiles
                        )
                    }
                    try load(
                        id: found.id,
                        url: found.url,
                        limits: limits,
                        root: root,
                        files: &files,
                        totalBytes: &totalBytes,
                        read: read
                    )
                    added = true
                }
            }
            if !added {
                return MDXResolvedGraph(
                    graph: MDXSourceGraph(entryID: entryID, files: files),
                    response: response
                )
            }
        }
        throw MDXImportGraphError.roundLimit(limits.maxRounds)
    }

    /// Resolves one relative import exactly the way `resolve` does. The
    /// compile cache calls this before trusting a hit: if a new candidate
    /// now wins (or a file vanished), the cached graph is stale.
    public static func resolveImport(
        specifier: String,
        from moduleID: String,
        projectRoot: URL
    ) throws -> MDXResolvedImport? {
        let root = canonical(projectRoot)
        let candidates = try candidateIDs(for: specifier, from: moduleID)
        guard let found = try resolveCandidate(
            candidates,
            root: root,
            module: moduleID,
            specifier: specifier
        ) else {
            return nil
        }
        return MDXResolvedImport(
            moduleID: moduleID,
            specifier: specifier,
            id: found.id,
            url: found.url
        )
    }

    // MARK: - Loading

    /// Production read for one module: opens the file through an anchored
    /// walk that refuses a symlink at every component, validates the opened
    /// descriptor, and never loads more than `limit` bytes.
    ///
    /// Path-level `resourceValues` before an open are advisory: the path can
    /// be swapped for a symlink or a FIFO between the check and the open.
    /// `O_NOFOLLOW` on each `openat` refuses a symlinked component, and
    /// `O_NONBLOCK` keeps a FIFO from blocking. Walking from a descriptor on
    /// the project root pins the chain: replacing a parent directory after
    /// containment validation cannot redirect the read outside the project.
    public static func readBounded(
        _ url: URL,
        limit: Int,
        within root: URL? = nil
    ) throws -> Data {
        let descriptor: Int32
        if let root {
            descriptor = try openAnchored(url, root: root)
        } else {
            descriptor = url.withUnsafeFileSystemRepresentation {
                path -> Int32 in
                guard let path else { return -1 }
                return open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                throw MDXImportGraphError.unreadableFile(
                    module: url.lastPathComponent,
                    message: String(cString: strerror(errno))
                )
            }
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw MDXImportGraphError.unreadableFile(
                module: url.lastPathComponent,
                message: String(cString: strerror(errno))
            )
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw MDXImportGraphError.unreadableFile(
                module: url.lastPathComponent,
                message: "not a regular file"
            )
        }
        if info.st_size > Int64(limit) {
            throw MDXImportGraphError.fileTooLarge(
                module: url.lastPathComponent,
                bytes: Int(info.st_size),
                limit: limit
            )
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        )
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw MDXImportGraphError.fileTooLarge(
                module: url.lastPathComponent,
                bytes: data.count,
                limit: limit
            )
        }
        return data
    }

    /// Opens `url` relative to `root`, one `openat` per path component, so no
    /// component can be a symlink. Every descriptor but the returned leaf is
    /// closed on the way.
    private static func openAnchored(_ url: URL, root: URL) throws -> Int32 {
        let rootURL = canonical(root)
        let target = url.standardizedFileURL
        guard let relative = relativeID(for: target, root: rootURL) else {
            throw MDXImportGraphError.unreadableFile(
                module: url.lastPathComponent,
                message: "outside the project root"
            )
        }
        var components = relative.split(separator: "/").map(String.init)
        guard let leaf = components.popLast(), !leaf.isEmpty else {
            throw MDXImportGraphError.unreadableFile(
                module: url.lastPathComponent,
                message: "no file in path"
            )
        }
        let anchor = rootURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard anchor >= 0 else {
            throw MDXImportGraphError.unreadableFile(
                module: url.lastPathComponent,
                message: String(cString: strerror(errno))
            )
        }
        var directory = anchor
        for component in components {
            let next = component.withCString {
                openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            close(directory)
            guard next >= 0 else {
                throw MDXImportGraphError.unreadableFile(
                    module: url.lastPathComponent,
                    message: String(cString: strerror(errno))
                )
            }
            directory = next
        }
        let descriptor = leaf.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        close(directory)
        guard descriptor >= 0 else {
            throw MDXImportGraphError.unreadableFile(
                module: url.lastPathComponent,
                message: String(cString: strerror(errno))
            )
        }
        return descriptor
    }

    private static func load(
        id: String,
        url: URL,
        limits: MDXImportLimits,
        root: URL,
        files: inout [String: String],
        totalBytes: inout Int,
        read: ((URL, Int) throws -> Data)?
    ) throws {
        guard files.count < limits.maxFiles else {
            throw MDXImportGraphError.tooManyFiles(limit: limits.maxFiles)
        }
        let remaining = max(0, limits.maxTotalBytes - totalBytes)
        let limit = min(limits.maxFileBytes, remaining)
        guard limit > 0 else {
            throw MDXImportGraphError.graphTooLarge(
                limit: limits.maxTotalBytes
            )
        }
        let data: Data
        do {
            if let read {
                data = try read(url, limit)
            } else {
                data = try readBounded(url, limit: limit, within: root)
            }
        } catch let error as MDXImportGraphError {
            throw error
        } catch {
            throw MDXImportGraphError.unreadableFile(
                module: id,
                message: error.localizedDescription
            )
        }
        guard data.count <= limits.maxFileBytes else {
            throw MDXImportGraphError.fileTooLarge(
                module: id,
                bytes: data.count,
                limit: limits.maxFileBytes
            )
        }
        guard totalBytes + data.count <= limits.maxTotalBytes else {
            throw MDXImportGraphError.graphTooLarge(limit: limits.maxTotalBytes)
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw MDXImportGraphError.notUTF8(module: id)
        }
        files[id] = source
        totalBytes += data.count
    }

    // MARK: - Resolution

    private struct Candidate {
        let id: String
        let url: URL
    }

    private static func resolveCandidate(
        _ candidates: [String],
        root: URL,
        module: String,
        specifier: String
    ) throws -> Candidate? {
        let fileManager = FileManager.default
        for id in candidates {
            let url = root.appendingPathComponent(id)
            let resolved = canonical(url)
            // The candidate's canonical location, not its typed path, must
            // stay inside the root. A link that points outside is refused
            // even when a file exists at the link.
            guard relativeID(for: resolved, root: root) != nil else {
                throw MDXImportGraphError.escapingImport(
                    module: module,
                    specifier: specifier
                )
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: resolved.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue else {
                continue
            }
            return Candidate(id: id, url: resolved)
        }
        return nil
    }

    /// Candidate module ids for one specifier, in tried order.
    private static func candidateIDs(
        for specifier: String,
        from moduleID: String
    ) throws -> [String] {
        var components = moduleID.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty else {
            throw MDXImportGraphError.escapingImport(
                module: moduleID,
                specifier: specifier
            )
        }
        components.removeLast()

        for part in specifier.split(
            separator: "/",
            omittingEmptySubsequences: false
        ) {
            let piece = String(part)
            if piece.isEmpty || piece == "." { continue }
            if piece == ".." {
                guard !components.isEmpty else {
                    throw MDXImportGraphError.escapingImport(
                        module: moduleID,
                        specifier: specifier
                    )
                }
                components.removeLast()
                continue
            }
            components.append(piece)
        }
        // An empty resolved base is the project root: `./` from a root-level
        // module, or `../` from a nested module that climbs back to the root.
        // That is not an escaping import; a `..` that passed the guard above
        // already threw.
        let base = components.joined(separator: "/")
        let extensionName = (base as NSString).pathExtension.lowercased()
        if !extensionName.isEmpty {
            guard localExtensions.contains(extensionName) else {
                throw MDXImportGraphError.unsupportedImport(
                    module: moduleID,
                    specifier: specifier
                )
            }
            return [base]
        }
        let direct = base.isEmpty ? [] : localExtensions.map { "\(base).\($0)" }
        let indexPrefix = base.isEmpty ? "" : "\(base)/"
        return direct
            + localExtensions.map { "\(indexPrefix)index.\($0)" }
    }

    private static func isRemote(_ specifier: String) -> Bool {
        if specifier.hasPrefix("//") { return true }
        guard let colon = specifier.firstIndex(of: ":") else { return false }
        let scheme = specifier[specifier.startIndex..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "."
        }
    }

    // MARK: - Paths

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The project-relative POSIX id for a canonical URL, or nil when the URL
    /// is not inside the root.
    private static func relativeID(for url: URL, root: URL) -> String? {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return nil }
        let id = String(url.path.dropFirst(rootPath.count))
        return id.isEmpty ? nil : id
    }
}
