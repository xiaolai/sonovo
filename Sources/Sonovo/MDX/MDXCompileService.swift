import Foundation
import SonovoCore
import SonovoMDXKit

/// Compiles one document's graph and caches the result by content hash.
///
/// A cache hit performs no process launch: the entry source is hashed into
/// the key, and every imported file is rehashed from disk. A changed import
/// or a changed toolchain version misses; the next compile resolves the graph
/// again and replaces the entry.
actor MDXCompileService {
    private struct CacheEntry {
        /// Every relative import the compile resolved, with its module and
        /// specifier. A hit re-resolves each one, so a newly created
        /// higher-priority candidate (`Button.mdx` before `Button.jsx`) or a
        /// deleted file invalidates the entry even when the old target's
        /// bytes are unchanged.
        let entryID: String
        let dependencies: [MDXResolvedImport]
        let dependencyHashes: [String: String]
        let response: MDXCompileResponse
        /// The compiled text the entry keeps alive, used for the byte budget.
        let byteCount: Int
    }

    private let compileRequest:
        @Sendable (MDXCompileRequest) async throws -> MDXCompileResponse
    private let toolchainVersion: String
    private var cache: [String: CacheEntry] = [:]
    private var insertionOrder: [String] = []
    private var cachedBytes = 0
    private let cacheLimit = 32
    /// Compiled modules are strings; a count-only limit could hold hundreds
    /// of megabytes after a few large documents. The byte budget evicts
    /// oldest-first until the cache is back under it.
    private let cacheLimitBytes: Int
    static let defaultCacheLimitBytes = 32 * 1024 * 1024

    /// Counts actual compiler invocations, not cache hits. Tests use it to
    /// prove the second compile did not spawn the helper.
    private(set) var compilerInvocations = 0

    init(compiler: MDXHelperCompiler) {
        compileRequest = { try await compiler.compile($0) }
        toolchainVersion = MDXToolchain.version
        cacheLimitBytes = Self.defaultCacheLimitBytes
    }

    init(
        compile: @escaping @Sendable (
            MDXCompileRequest
        ) async throws -> MDXCompileResponse,
        toolchainVersion: String = MDXToolchain.version,
        cacheLimitBytes: Int = MDXCompileService.defaultCacheLimitBytes
    ) {
        compileRequest = compile
        self.toolchainVersion = toolchainVersion
        self.cacheLimitBytes = max(1, cacheLimitBytes)
    }

    /// The production service. A build without the helper still returns a
    /// service whose compile reports why the preview is unavailable.
    static func live() -> MDXCompileService {
        if let compiler = MDXHelperCompiler.appDefault() {
            return MDXCompileService(compiler: compiler)
        }
        return MDXCompileService(compile: { _ in
            throw MDXCompilerError.helperUnavailable
        })
    }

    /// Compiles `source` as `entryID` under `projectRoot`.
    ///
    /// `source` is the in-memory text, so a preview reflects unsaved edits;
    /// imported files are always read from disk, and the graph resolver
    /// refuses anything outside the project.
    func compile(
        entryID: String,
        source: String,
        projectRoot: URL
    ) async throws -> MDXCompileResponse {
        let root = MarkdownSecurity.canonical(projectRoot)
        let entryKey = MDXCompileCacheKey.entryKey(
            entryID: entryID,
            source: source,
            toolchainVersion: toolchainVersion
        )
        if let cached = cache[entryKey],
           cacheEntryIsValid(cached, root: root) {
            return cached.response
        }

        let entryURL = MarkdownSecurity.canonical(
            root.appendingPathComponent(entryID)
        )
        let response: MDXCompileResponse
        let graph: MDXSourceGraph
        do {
            let resolved = try await MDXImportGraphResolver.resolve(
                entry: entryURL,
                projectRoot: root,
                compile: { [weak self] request in
                    guard let self else { throw CancellationError() }
                    return try await self.invokeCompiler(request)
                },
                read: { url, limit in
                    // The entry may be dirty; its in-memory text wins over
                    // what is on disk. Imports are always read from disk.
                    if url.path == entryURL.path {
                        let data = Data(source.utf8)
                        guard data.count <= limit else {
                            throw MDXImportGraphError.fileTooLarge(
                                module: entryID,
                                bytes: data.count,
                                limit: limit
                            )
                        }
                        return data
                    }
                    return try MDXImportGraphResolver.readBounded(
                        url,
                        limit: limit,
                        within: root
                    )
                }
            )
            response = resolved.response
            graph = resolved.graph
        } catch let error as MDXImportGraphError {
            if case .compileFailed(let diagnostic) = error {
                return .failure(diagnostic)
            }
            throw error
        }

        // Only a successful compile is cached. Caching a failure would keep
        // reporting a missing import after the file was created, because a
        // failure has no dependency set to revalidate.
        guard response.ok else { return response }

        var dependencies: Set<MDXResolvedImport> = []
        for module in response.modules {
            for specifier in module.imports {
                if MDXImportGraphResolver.runtimeModules.contains(specifier) {
                    continue
                }
                guard specifier.hasPrefix("./")
                    || specifier.hasPrefix("../") else {
                    continue
                }
                guard let resolved = try? MDXImportGraphResolver
                    .resolveImport(
                        specifier: specifier,
                        from: module.id,
                        projectRoot: root
                    ) else {
                    // A file changed between the compile and this snapshot;
                    // do not cache a graph that no longer matches the disk.
                    return response
                }
                dependencies.insert(resolved)
            }
        }
        var dependencyHashes: [String: String] = [:]
        for dependency in dependencies
        where dependency.id != graph.entryID {
            if let text = graph.files[dependency.id] {
                dependencyHashes[dependency.id] =
                    MDXCompileCacheKey.contentHash(text)
            }
        }
        let byteCount = response.modules.reduce(0) {
            $0 + $1.code.utf8.count
        }
        store(
            CacheEntry(
                entryID: graph.entryID,
                dependencies: Array(dependencies),
                dependencyHashes: dependencyHashes,
                response: response,
                byteCount: byteCount
            ),
            for: entryKey
        )
        return response
    }

    private func invokeCompiler(
        _ request: MDXCompileRequest
    ) async throws -> MDXCompileResponse {
        compilerInvocations += 1
        return try await compileRequest(request)
    }

    private func cacheEntryIsValid(
        _ entry: CacheEntry,
        root: URL
    ) -> Bool {
        for dependency in entry.dependencies {
            guard let current = try? MDXImportGraphResolver.resolveImport(
                specifier: dependency.specifier,
                from: dependency.moduleID,
                projectRoot: root
            ), current.id == dependency.id else {
                return false
            }
            // The entry's own bytes are already the entry key; a dirty
            // entry must still hit when its imports are unchanged.
            if dependency.id == entry.entryID { continue }
            guard let expected = entry.dependencyHashes[dependency.id],
                  // Bounded: a dependency replaced with a huge file must not
                  // be allocated just to invalidate the cache.
                  let data = try? MDXImportGraphResolver.readBounded(
                      current.url,
                      limit: MDXImportLimits.standard.maxFileBytes,
                      within: root
                  ),
                  let text = String(data: data, encoding: .utf8),
                  MDXCompileCacheKey.contentHash(text) == expected else {
                return false
            }
        }
        return true
    }

    private func store(_ entry: CacheEntry, for key: String) {
        guard entry.byteCount <= cacheLimitBytes else { return }
        if let previous = cache[key] {
            cachedBytes -= previous.byteCount
        } else {
            insertionOrder.append(key)
        }
        cache[key] = entry
        cachedBytes += entry.byteCount
        while insertionOrder.count > 1,
              (insertionOrder.count > cacheLimit
                || cachedBytes > cacheLimitBytes) {
            let stale = insertionOrder.removeFirst()
            if let removed = cache.removeValue(forKey: stale) {
                cachedBytes -= removed.byteCount
            }
        }
    }
}
