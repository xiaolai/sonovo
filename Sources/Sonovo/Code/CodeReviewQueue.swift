import Darwin
import Foundation
import SonovoCore

/// The state of one file in the project review queue.
enum CodeReviewQueueStatus: String, Equatable, Sendable {
    case unreviewed
    case seen
    case changesRequested
    case stale
    case deleted

    var label: String {
        switch self {
        case .unreviewed: "Unreviewed"
        case .seen: "Seen"
        case .changesRequested: "Changes requested"
        case .stale: "Stale"
        case .deleted: "Deleted"
        }
    }

    var symbol: String {
        switch self {
        case .unreviewed: "circle"
        case .seen: "eye"
        case .changesRequested: "exclamationmark.bubble"
        case .stale: "clock.arrow.circlepath"
        case .deleted: "trash"
        }
    }
}

/// Which exact pair a queue item reviews.
enum CodeReviewPairBasis: Equatable, Sendable {
    /// The active decision matches both sides of the current pair.
    case decision(StoredReviewDecision)
    /// A decision is newer than the baseline but does not cover the current
    /// bytes; the pair is last decided → current.
    case lastDecided(StoredReviewDecision)
    /// The baseline → current pair, with an older or absent decision.
    case baseline(CodeReviewCursor)
    /// A newly added file: empty → current.
    case added
}

/// One changed file, bound to the exact pair it reviews.
struct CodeReviewQueueItem: Identifiable, Equatable, Sendable {
    let path: String
    let url: URL
    let status: CodeReviewQueueStatus
    /// Absent for a deleted file.
    let currentHash: String?
    let baseline: CodeReviewCursor?
    let decision: StoredReviewDecision?
    /// Whether the store retains every blob needed to build the pair.
    let canReviewContent: Bool

    var id: String { path }
}

/// One file captured while establishing the first baseline. Only the bytes
/// retained within the budget are kept; the hash is always available.
struct CodeReviewBaseline: Equatable, Sendable {
    let path: String
    let hash: String
    let bytes: Data?
}

struct CodeReviewScan: Equatable, Sendable {
    let items: [CodeReviewQueueItem]
    let baselines: [CodeReviewBaseline]
    let coveredFiles: Int
    let unavailableFiles: Int
    let truncated: Bool
    let coverageComplete: Bool
    let establishedBaseline: Bool
    let scannedAt: Date

    var snapshot: CodeReviewQueueSnapshot {
        CodeReviewQueueSnapshot(
            items: items,
            coveredFiles: coveredFiles,
            unavailableFiles: unavailableFiles,
            truncated: truncated,
            coverageComplete: coverageComplete,
            establishedBaseline: establishedBaseline,
            scannedAt: scannedAt
        )
    }
}

/// What the queue view presents. Baseline bytes are consumed by the store and
/// are deliberately not retained here.
struct CodeReviewQueueSnapshot: Equatable, Sendable {
    let items: [CodeReviewQueueItem]
    let coveredFiles: Int
    let unavailableFiles: Int
    let truncated: Bool
    let coverageComplete: Bool
    let establishedBaseline: Bool
    let scannedAt: Date

    var changedFileCount: Int {
        items.filter { $0.status != .deleted }.count
    }
}

/// The review inventory and the changed-file scan.
///
/// Coverage is explicit: code and plain-text files only, hidden files and
/// ignored directories excluded, symlinks skipped, at most
/// `CodeLimits.discoveryFiles` entries. Enumeration failures and inaccessible
/// paths are reported as incomplete coverage, never as deletions.
enum CodeReviewInventory {
    /// Reads at most 512 KB of any single file into the baseline budget and
    /// 64 MB in total; larger or unlucky files keep a hash without bytes.
    static let baselineFileBudget = 512 * 1024
    static let baselineContentBudget = 64 * 1024 * 1024

    private static let emptyHash = DiskSnapshot(bytes: Data()).sha256

    static func files(
        in root: URL
    ) -> (files: [URL], truncated: Bool, complete: Bool) {
        var complete = true
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                complete = false
                return true
            }
        ) else {
            return ([], false, false)
        }
        var files: [URL] = []
        var visited = 0
        var truncated = false
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            visited += 1
            if visited > CodeLimits.discoveryVisitedEntries
                || files.count >= CodeLimits.discoveryFiles {
                truncated = true
                break
            }
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            if values?.isDirectory == true {
                if values?.isSymbolicLink == true
                    || ProjectPathPolicy.isIgnoredDirectory(
                        url.lastPathComponent
                    ) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isSymbolicLink != true else { continue }
            guard CodeLanguage.language(forFilename: url.lastPathComponent)
                != nil else {
                continue
            }
            files.append(url.standardizedFileURL)
        }
        return (
            files.sorted { $0.path < $1.path },
            truncated,
            complete
        )
    }

    /// The pair a current decision is about, or the pair the queue should
    /// offer when no single decision covers both sides.
    static func pairBasis(
        decision: StoredReviewDecision?,
        baseline: CodeReviewCursor?,
        currentHash: String
    ) -> CodeReviewPairBasis {
        let activeLeft = baseline?.hash ?? emptyHash
        if let decision,
           decision.rightHash == currentHash,
           decision.leftHash == activeLeft,
           baseline.map({ decision.createdAt > $0.capturedAt }) ?? true {
            return .decision(decision)
        }
        if let baseline {
            if let decision,
               decision.rightHash != baseline.hash,
               decision.createdAt > baseline.capturedAt {
                return .lastDecided(decision)
            }
            return .baseline(baseline)
        }
        if let decision {
            return .lastDecided(decision)
        }
        return .added
    }

    static func status(
        for basis: CodeReviewPairBasis,
        hasDecision: Bool,
        currentHash: String
    ) -> CodeReviewQueueStatus {
        switch basis {
        case .decision(let decision):
            return decision.disposition == .seen ? .seen : .changesRequested
        case .lastDecided(let decision):
            guard decision.rightHash == currentHash else { return .stale }
            return decision.disposition == .seen ? .seen : .changesRequested
        case .baseline:
            return hasDecision ? .stale : .unreviewed
        case .added:
            return .unreviewed
        }
    }

    static func hasEvidence(
        for basis: CodeReviewPairBasis,
        currentHash: String,
        retained: Set<String>
    ) -> Bool {
        switch basis {
        case .decision(let decision):
            return retained.contains(decision.leftHash)
                && retained.contains(decision.rightHash)
        case .lastDecided(let decision):
            if decision.rightHash == currentHash {
                return retained.contains(decision.leftHash)
                    && retained.contains(decision.rightHash)
            }
            return retained.contains(decision.rightHash)
        case .baseline(let cursor):
            return retained.contains(cursor.hash)
        case .added:
            return true
        }
    }

    /// Scans the project against the stored cursors. Runs off the main actor;
    /// reads are bounded and cancelled through `Task.isCancelled`.
    static func scan(
        root: URL,
        cursors: [String: CodeReviewCursor],
        decisions: [StoredReviewDecision],
        retained: Set<String>,
        establishesBaseline: Bool,
        now: Date = Date()
    ) -> CodeReviewScan {
        let canonicalRoot = MarkdownSecurity.canonical(root)
        let rootPath = canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path
            : canonicalRoot.path + "/"
        let (files, truncated, complete) = files(in: canonicalRoot)
        let reader = CodeFileReader()
        var items: [CodeReviewQueueItem] = []
        var baselines: [CodeReviewBaseline] = []
        var covered = 0
        var unavailable = 0
        var retainedBaselineBytes = 0
        var seen: Set<String> = []

        for url in files {
            if Task.isCancelled { break }
            guard url.path.hasPrefix(rootPath) else { continue }
            let relative = String(url.path.dropFirst(rootPath.count))
            seen.insert(relative)
            covered += 1
            let bounded = try? reader.boundedData(
                at: url,
                maximumBytes: CodeLimits.maximumReadBytes
            )
            guard case .data(let data)? = bounded else {
                unavailable += 1
                continue
            }
            let snapshot = DiskSnapshot(bytes: data)
            if establishesBaseline {
                var retainedBytes: Data?
                if data.count <= baselineFileBudget,
                   retainedBaselineBytes + data.count <= baselineContentBudget {
                    retainedBytes = data
                    retainedBaselineBytes += data.count
                }
                baselines.append(
                    CodeReviewBaseline(
                        path: relative,
                        hash: snapshot.sha256,
                        bytes: retainedBytes
                    )
                )
                continue
            }
            let cursor = cursors[relative]
            let decision = decisions.last { $0.path == relative }
            let basis = pairBasis(
                decision: decision,
                baseline: cursor,
                currentHash: snapshot.sha256
            )
            if case .baseline(let active) = basis,
               active.hash == snapshot.sha256 {
                continue
            }
            items.append(
                CodeReviewQueueItem(
                    path: relative,
                    url: url,
                    status: status(
                        for: basis,
                        hasDecision: decision != nil,
                        currentHash: snapshot.sha256
                    ),
                    currentHash: snapshot.sha256,
                    baseline: cursor,
                    decision: decision,
                    canReviewContent: hasEvidence(
                        for: basis,
                        currentHash: snapshot.sha256,
                        retained: retained
                    )
                )
            )
        }

        if !establishesBaseline {
            // A reviewed file can have a decision without a baseline cursor
            // (a newly added file). Deletion must be reported for those too,
            // not only for paths that once had a cursor.
            var trackedPaths = Set(cursors.keys)
            for decision in decisions {
                trackedPaths.insert(decision.path)
            }
            for path in trackedPaths where !seen.contains(path) {
                let url = canonicalRoot.appendingPathComponent(path)
                let decision = decisions.last { $0.path == path }
                guard deletionConfirmed(url) else {
                    unavailable += 1
                    continue
                }
                items.append(
                    CodeReviewQueueItem(
                        path: path,
                        url: url,
                        status: .deleted,
                        currentHash: nil,
                        baseline: cursors[path],
                        decision: decision,
                        canReviewContent: false
                    )
                )
            }
        }

        let order: [CodeReviewQueueStatus: Int] = [
            .unreviewed: 0,
            .stale: 1,
            .changesRequested: 2,
            .seen: 3,
            .deleted: 4
        ]
        items.sort {
            let left = order[$0.status] ?? 0
            let right = order[$1.status] ?? 0
            if left != right { return left < right }
            return $0.path.localizedStandardCompare($1.path)
                == .orderedAscending
        }
        return CodeReviewScan(
            items: items,
            baselines: baselines,
            coveredFiles: covered,
            unavailableFiles: unavailable,
            truncated: truncated,
            coverageComplete: complete,
            establishedBaseline: establishesBaseline,
            scannedAt: now
        )
    }

    /// True only when the path itself is confirmed absent, not merely
    /// inaccessible. A deleted parent directory is confirmed absence too; a
    /// permission failure is not.
    private static func deletionConfirmed(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        if access(parent.path, R_OK | X_OK) != 0 {
            let parentError = errno
            return parentError == ENOENT || parentError == ENOTDIR
        }
        guard access(url.path, F_OK) != 0 else { return false }
        let fileError = errno
        return fileError == ENOENT || fileError == ENOTDIR
    }
}
