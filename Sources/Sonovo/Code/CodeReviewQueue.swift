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

/// One changed file, bound to the baseline it is compared against.
struct CodeReviewQueueItem: Identifiable, Equatable, Sendable {
    let path: String
    let url: URL
    let status: CodeReviewQueueStatus
    /// Absent for a deleted file.
    let currentHash: String?
    let baseline: CodeReviewCursor?
    let decision: StoredReviewDecision?

    var id: String { path }

    /// Whether the queue can show the previous bytes for a diff.
    var canReviewContent: Bool {
        status != .deleted && (baseline?.hasContent == true || baseline == nil)
    }
}

/// One file captured while establishing the first baseline.
struct CodeReviewBaseline: Equatable, Sendable {
    let path: String
    let snapshot: DiskSnapshot
    /// Retained only within the baseline content budget.
    let bytes: Data?
}

struct CodeReviewScan: Equatable, Sendable {
    let items: [CodeReviewQueueItem]
    let baselines: [CodeReviewBaseline]
    let coveredFiles: Int
    let unavailableFiles: Int
    let truncated: Bool
    let establishedBaseline: Bool
    let scannedAt: Date

    var snapshot: CodeReviewQueueSnapshot {
        CodeReviewQueueSnapshot(
            items: items,
            coveredFiles: coveredFiles,
            unavailableFiles: unavailableFiles,
            truncated: truncated,
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
/// `CodeLimits.discoveryFiles` entries. The queue says so instead of implying
/// it sees the whole project.
enum CodeReviewInventory {
    /// Reads at most 512 KB of any single file into the baseline budget and
    /// 64 MB in total; larger or unlucky files keep a hash without bytes.
    static let baselineFileBudget = 512 * 1024
    static let baselineContentBudget = 64 * 1024 * 1024

    static func files(in root: URL) -> (files: [URL], truncated: Bool) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ([], false)
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
        return (files.sorted { $0.path < $1.path }, truncated)
    }

    /// Scans the project against the stored cursors. Runs off the main actor;
    /// reads are bounded and cancelled through `Task.isCancelled`.
    static func scan(
        root: URL,
        cursors: [String: CodeReviewCursor],
        decisions: [StoredReviewDecision],
        establishesBaseline: Bool,
        now: Date = Date()
    ) -> CodeReviewScan {
        let canonicalRoot = MarkdownSecurity.canonical(root)
        let rootPath = canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path
            : canonicalRoot.path + "/"
        let (files, truncated) = files(in: canonicalRoot)
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
                var retained: Data?
                if data.count <= baselineFileBudget,
                   retainedBaselineBytes + data.count <= baselineContentBudget {
                    retained = data
                    retainedBaselineBytes += data.count
                }
                baselines.append(
                    CodeReviewBaseline(
                        path: relative,
                        snapshot: snapshot,
                        bytes: retained
                    )
                )
                continue
            }
            let decision = decisions.last { $0.path == relative }
            guard let cursor = cursors[relative] else {
                items.append(
                    CodeReviewQueueItem(
                        path: relative,
                        url: url,
                        status: .unreviewed,
                        currentHash: snapshot.sha256,
                        baseline: nil,
                        decision: decision
                    )
                )
                continue
            }
            guard cursor.hash != snapshot.sha256 else { continue }
            items.append(
                CodeReviewQueueItem(
                    path: relative,
                    url: url,
                    status: status(for: decision, currentHash: snapshot.sha256),
                    currentHash: snapshot.sha256,
                    baseline: cursor,
                    decision: decision
                )
            )
        }

        if !establishesBaseline {
            for cursor in cursors.values where !seen.contains(cursor.path) {
                let url = canonicalRoot.appendingPathComponent(cursor.path)
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    continue
                }
                items.append(
                    CodeReviewQueueItem(
                        path: cursor.path,
                        url: url,
                        status: .deleted,
                        currentHash: nil,
                        baseline: cursor,
                        decision: decisions.last { $0.path == cursor.path }
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
            establishedBaseline: establishesBaseline,
            scannedAt: now
        )
    }

    private static func status(
        for decision: StoredReviewDecision?,
        currentHash: String
    ) -> CodeReviewQueueStatus {
        guard let decision else { return .unreviewed }
        guard decision.rightHash == currentHash else { return .stale }
        switch decision.disposition {
        case .seen: return .seen
        case .changesRequested: return .changesRequested
        }
    }
}
