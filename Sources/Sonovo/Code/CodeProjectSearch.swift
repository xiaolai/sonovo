import Foundation
import SonovoCore

struct CodeSearchMatch: Identifiable, Equatable, Sendable {
    let url: URL
    let relativePath: String
    /// 1-based.
    let line: Int
    /// 1-based column of the first matching character.
    let column: Int
    let preview: String

    var id: String { "\(url.path):\(line):\(column)" }
}

/// Which files a project search may open.
enum CodeSearchScope: Sendable {
    /// Code files only, for the Code viewer's Find in Files.
    case code
    /// Markdown documents, for the Markdown workspace's Find in Files.
    case markdown

    func includes(_ filename: String) -> Bool {
        switch self {
        case .code:
            return CodeLanguage.language(forFilename: filename) != nil
        case .markdown:
            return ProjectScanner.markdownExtensions.contains(
                (filename as NSString).pathExtension.lowercased()
            )
        }
    }
}

struct CodeSearchResult: Equatable, Sendable {
    let matches: [CodeSearchMatch]
    let filesSearched: Int
    let skippedLargeFiles: Int
    let bytesSearched: Int
    /// A user-facing reason when the result is not exhaustive.
    let truncationReason: String?
    let totalMatches: Int
    let wasCancelled: Bool

    var isTruncated: Bool { truncationReason != nil }

    /// One group per file, in sorted path order. The matches keep their line
    /// order from the search.
    var groupedByFile: [CodeSearchGroup] {
        var order: [String] = []
        var byPath: [String: [CodeSearchMatch]] = [:]
        for match in matches {
            if byPath[match.relativePath] == nil {
                order.append(match.relativePath)
            }
            byPath[match.relativePath, default: []].append(match)
        }
        return order.map {
            CodeSearchGroup(path: $0, matches: byPath[$0] ?? [])
        }
    }
}

struct CodeSearchGroup: Identifiable, Equatable, Sendable {
    let path: String
    let matches: [CodeSearchMatch]

    var id: String { path }
}

/// Literal, case-insensitive project search.
///
/// The search runs off the main actor, is cancellable, and enforces the same
/// boundaries as the scanner at the point of consumption: hidden targets,
/// ignored directories, outside-root symlinks, binary files, and per-file and
/// total byte caps.
struct CodeProjectSearch: Sendable {
    var resultLimit = CodeLimits.searchResultLimit
    var perFileBytes = CodeLimits.searchPerFileBytes
    var totalBytes = CodeLimits.searchTotalBytes

    func search(
        root: URL,
        query: String,
        scope: CodeSearchScope = .code,
        caseSensitive: Bool = false
    ) async -> CodeSearchResult {
        let trimmed = query
        guard !trimmed.isEmpty else {
            return CodeSearchResult(
                matches: [],
                filesSearched: 0,
                skippedLargeFiles: 0,
                bytesSearched: 0,
                truncationReason: nil,
                totalMatches: 0,
                wasCancelled: false
            )
        }
        let options: NSString.CompareOptions = caseSensitive
            ? []
            : [.caseInsensitive]
        let limit = resultLimit
        let perFile = perFileBytes
        let total = totalBytes

        let task = Task.detached(priority: .userInitiated) {
            Self.run(
                root: root,
                query: trimmed,
                scope: scope,
                options: options,
                limit: limit,
                perFileBytes: perFile,
                totalBytes: total
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func run(
        root: URL,
        query: String,
        scope: CodeSearchScope,
        options: NSString.CompareOptions,
        limit: Int,
        perFileBytes: Int,
        totalBytes: Int
    ) -> CodeSearchResult {
        let canonicalRoot = MarkdownSecurity.canonical(root)
        let rootPath = canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path
            : canonicalRoot.path + "/"
        var matches: [CodeSearchMatch] = []
        var filesSearched = 0
        var skippedLarge = 0
        var bytesSearched = 0
        var totalMatches = 0
        var truncation: String?
        var cancelled = false
        var seenFiles: Set<String> = []
        var readFailures = 0
        var enumerationFailed = false
        let reader = CodeFileReader()
        let formattedTotal = ByteCountFormatter.string(
            fromByteCount: Int64(totalBytes),
            countStyle: .file
        )

        guard let enumerator = FileManager.default.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                enumerationFailed = true
                return true
            }
        ) else {
            return CodeSearchResult(
                matches: [],
                filesSearched: 0,
                skippedLargeFiles: 0,
                bytesSearched: 0,
                truncationReason: "The folder could not be read.",
                totalMatches: 0,
                wasCancelled: false
            )
        }

        scanLoop: for case let entry as URL in enumerator {
            if Task.isCancelled {
                cancelled = true
                break
            }
            let values = try? entry.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ]
            )
            guard let values else {
                readFailures += 1
                continue
            }
            let isDirectory = values.isDirectory == true
            let isSymbolicLink = values.isSymbolicLink == true

            if isDirectory {
                if isSymbolicLink
                    || ProjectPathPolicy.isIgnoredDirectory(
                        entry.lastPathComponent
                    ) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true || isSymbolicLink else {
                continue
            }
            guard scope.includes(entry.lastPathComponent) else {
                continue
            }

            let resolved = MarkdownSecurity.canonical(entry)
            // The same consumption-boundary policy as the workspace: a
            // symlink into node_modules is refused even when it is visible.
            guard resolved.path.hasPrefix(rootPath),
                  ProjectPathPolicy.isAllowed(
                      resolved,
                      in: canonicalRoot
                  ) else {
                continue
            }
            guard ProjectPathPolicy.resolvesInsideRoot(
                resolved,
                root: canonicalRoot
            ) else {
                if MarkdownSecurity.contains(resolved, in: canonicalRoot) {
                    // Inside the project but unreadable: the result is
                    // incomplete, not exhaustive.
                    readFailures += 1
                }
                continue
            }
            // A file reachable by two paths (a symlink and its target) is
            // searched once, matching the scanner's identity rule.
            guard seenFiles.insert(resolved.path).inserted else {
                continue
            }

            let size = Int64(values.fileSize ?? 0)
            if size > Int64(perFileBytes) {
                skippedLarge += 1
                continue
            }
            if bytesSearched + Int(size) > totalBytes {
                truncation = "Search stopped at the \(formattedTotal) total limit."
                break
            }

            let bounded: CodeBoundedData
            do {
                bounded = try reader.boundedData(
                    at: resolved,
                    maximumBytes: perFileBytes
                )
            } catch {
                readFailures += 1
                continue
            }
            let data: Data
            switch bounded {
            case .absent, .notRegular:
                // The entry was listed but is gone or no longer readable.
                readFailures += 1
                continue
            case .tooLarge:
                // The file grew past the per-file cap between listing and
                // reading. The bounded read still consumed cap + 1 bytes;
                // charge them or repeatedly growing files escape the total
                // budget.
                bytesSearched += min(perFileBytes + 1, totalBytes)
                skippedLarge += 1
                continue
            case .data(let bytes):
                data = bytes
            }
            // A file that grew between enumeration and reading must not push
            // the total past its bound.
            if bytesSearched + data.count > totalBytes {
                truncation = "Search stopped at the \(formattedTotal) total limit."
                break
            }
            // Charge the read before deciding whether the bytes are
            // searchable: binary and invalid-UTF-8 files still cost this
            // pass its work, and leaving them uncharged would let a folder
            // of them read without bound.
            bytesSearched += data.count
            if data.contains(0) {
                continue
            }
            // Search the same canonical text the editor displays. A lone CR
            // becomes an LF there, so counting only LF on the raw bytes
            // reports the wrong line.
            guard let contents = try? MarkdownEncoding.decode(data) else {
                continue
            }

            filesSearched += 1
            let ns = contents.canonicalText as NSString
            let lineStarts = lineStartOffsets(in: ns)
            var searchStart = 0
            while searchStart < ns.length {
                if Task.isCancelled {
                    cancelled = true
                    break scanLoop
                }
                let found = ns.range(
                    of: query,
                    options: options,
                    range: NSRange(
                        location: searchStart,
                        length: ns.length - searchStart
                    )
                )
                guard found.location != NSNotFound else { break }
                totalMatches += 1
                if matches.count < limit {
                    let position = lineColumn(
                        lineStarts: lineStarts,
                        at: found.location
                    )
                    let lineRange = ns.lineRange(
                        for: NSRange(location: found.location, length: 0)
                    )
                    let preview = ns.substring(with: lineRange)
                        .trimmingCharacters(in: .newlines)
                    matches.append(
                        CodeSearchMatch(
                            url: resolved,
                            relativePath: String(
                                resolved.path.dropFirst(rootPath.count)
                            ),
                            line: position.line,
                            column: position.column,
                            preview: String(preview.prefix(4_000))
                        )
                    )
                } else if truncation == nil {
                    truncation = "Showing the first \(limit) results."
                }
                searchStart = found.location + max(1, found.length)
            }
        }

        if cancelled {
            truncation = "Search cancelled."
        } else if truncation == nil,
                  readFailures > 0 || enumerationFailed {
            truncation = "Some files could not be read; results may be incomplete."
        }

        return CodeSearchResult(
            matches: matches.sorted {
                if $0.relativePath != $1.relativePath {
                    return $0.relativePath.localizedStandardCompare(
                        $1.relativePath
                    ) == .orderedAscending
                }
                return $0.line < $1.line
            },
            filesSearched: filesSearched,
            skippedLargeFiles: skippedLarge,
            bytesSearched: bytesSearched,
            truncationReason: truncation,
            totalMatches: totalMatches,
            wasCancelled: cancelled
        )
    }

    /// One pass per file; each match then costs a binary search, not a scan
    /// from the file's beginning.
    private static func lineStartOffsets(in text: NSString) -> [Int] {
        var starts = [0]
        guard text.length > 0 else { return starts }
        for index in 0..<text.length where text.character(at: index) == 0x0A {
            starts.append(index + 1)
        }
        return starts
    }

    private static func lineColumn(
        lineStarts: [Int],
        at offset: Int
    ) -> (line: Int, column: Int) {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return (low + 1, offset - lineStarts[low] + 1)
    }
}
