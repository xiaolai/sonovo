import CryptoKit
import Foundation

/// One captured snapshot. Identity is the project root plus the relative
/// path; the session document UUID is deliberately absent.
public struct MarkdownSnapshotRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let relativePath: String
    public let capturedAt: Date
    public let byteCount: Int
    public let sha256: String
    public let hadBOM: Bool
    public let lineEnding: String
}

public enum MarkdownSnapshotCapture: Sendable, Equatable {
    case captured(MarkdownSnapshotRecord)
    /// A consecutive autosave inside the merge window; the newest snapshot
    /// already covers this state.
    case merged(MarkdownSnapshotRecord)
    /// The quota is exhausted or the store failed. New evidence stops; the
    /// caller must surface "evidence unavailable", never a silent gap.
    case evidenceUnavailable
}

public enum MarkdownSnapshotLoad: Sendable, Equatable {
    case bytes(Data, MarkdownSnapshotRecord)
    case evidenceUnavailable
}

public struct MarkdownSnapshotRecovery: Sendable, Equatable {
    public let orphanBlobsRemoved: Int
    public let missingBlobs: [UUID]
}

/// A project-scoped store of raw-byte snapshots.
///
/// Layout: `<base>/<projectKey>/index.json` plus `blobs/<sha>.bin`. Writes are
/// blob first, index second; a crash in between leaves an orphan blob that
/// recovery removes, while an index entry whose blob is missing reads as
/// evidence unavailable. Files are 0600 inside a 0700 directory, and the
/// index is written to a temporary file, synchronized, then renamed.
public actor MarkdownSnapshotStore {
    public static let schemaVersion = 1

    private struct Index: Codable {
        var version: Int
        var entries: [MarkdownSnapshotRecord]
        var transitions: [MarkdownReviewTransition]?
        /// The acknowledged baseline record for each path.
        var baselines: [String: UUID]?
    }

    private let directory: URL
    private let blobDirectory: URL
    private let indexURL: URL
    private let projectByteQuota: Int
    private let perFileQuota: Int

    public init(
        baseDirectory: URL,
        projectRoot: URL,
        projectByteQuota: Int = 256 * 1024 * 1024,
        perFileQuota: Int = 200
    ) {
        self.projectByteQuota = max(1, projectByteQuota)
        self.perFileQuota = max(1, perFileQuota)
        let key = Self.projectKey(projectRoot)
        self.directory = baseDirectory.appendingPathComponent(
            key,
            isDirectory: true
        )
        self.blobDirectory = directory.appendingPathComponent(
            "blobs",
            isDirectory: true
        )
        self.indexURL = directory.appendingPathComponent("index.json")
    }

    // MARK: - Capture

    public func capture(
        rawBytes: Data,
        relativePath: String,
        date: Date = Date()
    ) -> MarkdownSnapshotCapture {
        var index = readIndex()
        guard index.version == Self.schemaVersion else {
            return .evidenceUnavailable
        }
        let capture = captureLocked(
            rawBytes: rawBytes,
            relativePath: relativePath,
            date: date,
            index: &index
        )
        guard case .captured = capture else { return capture }
        do {
            try writeIndex(index)
        } catch {
            return .evidenceUnavailable
        }
        return capture
    }

    // MARK: - Reading

    public func records(
        for relativePath: String
    ) -> [MarkdownSnapshotRecord] {
        readIndex().entries
            .filter { $0.relativePath == relativePath }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    public func load(id: UUID) -> MarkdownSnapshotLoad {
        let index = readIndex()
        guard let record = index.entries.first(where: { $0.id == id }) else {
            return .evidenceUnavailable
        }
        let blobURL = blobDirectory.appendingPathComponent(
            "\(record.sha256).bin"
        )
        guard let data = try? Data(contentsOf: blobURL) else {
            return .evidenceUnavailable
        }
        guard Self.sha256(data) == record.sha256 else {
            return .evidenceUnavailable
        }
        return .bytes(data, record)
    }

    public func allRecords() -> [MarkdownSnapshotRecord] {
        readIndex().entries.sorted { $0.capturedAt > $1.capturedAt }
    }

    // MARK: - Recovery

    public func recover() -> MarkdownSnapshotRecovery {
        let index = readIndex()
        guard index.version == Self.schemaVersion else {
            return MarkdownSnapshotRecovery(
                orphanBlobsRemoved: 0,
                missingBlobs: []
            )
        }
        let known = Set(index.entries.map { "\($0.sha256).bin" })
        var removed = 0
        let files = (try? FileManager.default.contentsOfDirectory(
            atPath: blobDirectory.path
        )) ?? []
        for file in files where !known.contains(file) {
            try? FileManager.default.removeItem(
                at: blobDirectory.appendingPathComponent(file)
            )
            removed += 1
        }
        var missing: [UUID] = []
        var valid: [MarkdownSnapshotRecord] = []
        for record in index.entries {
            let url = blobDirectory.appendingPathComponent(
                "\(record.sha256).bin"
            )
            if FileManager.default.fileExists(atPath: url.path) {
                valid.append(record)
            } else {
                missing.append(record.id)
            }
        }
        // Keep the gapped entries in the index: a pending decision that
        // references them must read "evidence unavailable", not vanish.
        _ = valid
        return MarkdownSnapshotRecovery(
            orphanBlobsRemoved: removed,
            missingBlobs: missing
        )
    }

    // MARK: - Files

    private func readIndex() -> Index {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data),
              index.version == Self.schemaVersion else {
            return Index(version: Self.schemaVersion, entries: [])
        }
        return index
    }

    // MARK: - History

    /// Captures a save snapshot subject to the history policy: consecutive
    /// autosaves inside the merge window collapse into the newest snapshot.
    public func recordHistory(
        rawBytes: Data,
        relativePath: String,
        kind: MarkdownHistoryPolicy.SaveKind,
        date: Date = Date(),
        policy: MarkdownHistoryPolicy = MarkdownHistoryPolicy()
    ) -> MarkdownSnapshotCapture {
        var index = readIndex()
        let newest = index.entries
            .filter { $0.relativePath == relativePath }
            .max { $0.capturedAt < $1.capturedAt }
        if kind == .autosave,
           let newest,
           date.timeIntervalSince(newest.capturedAt) <= policy.mergeWindow {
            return .merged(newest)
        }
        let capture = captureLocked(
            rawBytes: rawBytes,
            relativePath: relativePath,
            date: date,
            index: &index
        )
        if case .captured = capture {
            writeIndexQuietly(index)
            _ = prune(
                relativePath: relativePath,
                policy: policy,
                now: date
            )
        }
        return capture
    }

    /// Removes snapshots by count and age. Evidence referenced by a pending
    /// review decision is never evicted.
    @discardableResult
    public func prune(
        relativePath: String,
        policy: MarkdownHistoryPolicy,
        now: Date = Date()
    ) -> Int {
        var index = readIndex()
        let pendingIDs = Set(
            (index.transitions ?? [])
                .filter { $0.relativePath == relativePath && $0.decision == nil }
                .flatMap { [$0.beforeID, $0.afterID] }
        )
        let records = index.entries
            .filter { $0.relativePath == relativePath }
            .sorted { $0.capturedAt > $1.capturedAt }
        var removed = 0
        var kept: [MarkdownSnapshotRecord] = []
        for (position, record) in records.enumerated() {
            let tooOld = now.timeIntervalSince(record.capturedAt)
                > policy.maximumAge
            let overCount = position >= policy.maximumCount
            if (tooOld || overCount), !pendingIDs.contains(record.id) {
                removed += 1
                continue
            }
            kept.append(record)
        }
        guard removed > 0 else { return 0 }
        let keptIDs = Set(kept.map(\.id))
        index.entries.removeAll {
            $0.relativePath == relativePath && !keptIDs.contains($0.id)
        }
        writeIndexQuietly(index)
        return removed
    }

    public func delete(id: UUID) {
        var index = readIndex()
        index.entries.removeAll { $0.id == id }
        writeIndexQuietly(index)
    }

    // MARK: - Observed review queue

    /// Records an observed transition. The first call establishes the
    /// baseline; later calls collapse any pending pair to baseline → latest,
    /// so A→B→C is one observation of C.
    @discardableResult
    public func observe(
        relativePath: String,
        diskBytes: Data,
        date: Date = Date()
    ) -> MarkdownReviewTransition? {
        var index = readIndex()
        let sha = Self.sha256(diskBytes)
        var baselines = index.baselines ?? [:]
        var transitions = index.transitions ?? []

        guard let baselineID = baselines[relativePath] else {
            let capture = captureLocked(
                rawBytes: diskBytes,
                relativePath: relativePath,
                date: date,
                index: &index
            )
            guard case let .captured(record) = capture else {
                return nil
            }
            baselines[relativePath] = record.id
            index.baselines = baselines
            writeIndexQuietly(index)
            return nil
        }
        guard let baseline = index.entries.first(where: { $0.id == baselineID })
        else {
            return nil
        }
        if baseline.sha256 == sha { return nil }

        let afterID: UUID
        let afterSha: String
        if let pendingIndex = transitions.firstIndex(where: {
            $0.relativePath == relativePath && $0.decision == nil
        }) {
            let capture = captureLocked(
                rawBytes: diskBytes,
                relativePath: relativePath,
                date: date,
                index: &index
            )
            guard case let .captured(record) = capture else {
                return nil
            }
            afterID = record.id
            afterSha = record.sha256
            transitions[pendingIndex].afterID = afterID
            transitions[pendingIndex].afterSha = afterSha
            transitions[pendingIndex].observedAt = date
        } else {
            let capture = captureLocked(
                rawBytes: diskBytes,
                relativePath: relativePath,
                date: date,
                index: &index
            )
            guard case let .captured(record) = capture else {
                return nil
            }
            afterID = record.id
            afterSha = record.sha256
            transitions.append(
                MarkdownReviewTransition(
                    id: UUID(),
                    relativePath: relativePath,
                    beforeID: baseline.id,
                    afterID: afterID,
                    beforeSha: baseline.sha256,
                    afterSha: afterSha,
                    observedAt: date,
                    decision: nil
                )
            )
        }
        index.transitions = transitions
        index.baselines = baselines
        writeIndexQuietly(index)
        return transitions.last
    }

    public func transitions(
        for relativePath: String,
        includeDecided: Bool = false
    ) -> [MarkdownReviewTransition] {
        (readIndex().transitions ?? [])
            .filter {
                $0.relativePath == relativePath
                    && (includeDecided || $0.decision == nil)
            }
            .sorted { $0.observedAt > $1.observedAt }
    }

    /// Points the baseline at an already captured record (the save path's
    /// history snapshot), without capturing the bytes twice.
    public func setBaseline(relativePath: String, recordID: UUID) {
        guard readIndex().entries.contains(where: { $0.id == recordID })
        else {
            return
        }
        var index = readIndex()
        var baselines = index.baselines ?? [:]
        baselines[relativePath] = recordID
        index.baselines = baselines
        writeIndexQuietly(index)
    }

    /// Advances the acknowledged baseline without creating a transition. The
    /// save path uses it for the project's own writes, so a later watcher
    /// event does not look like an external edit.
    public func acknowledgeBaseline(
        relativePath: String,
        diskBytes: Data,
        date: Date = Date()
    ) -> Bool {
        var index = readIndex()
        let capture = captureLocked(
            rawBytes: diskBytes,
            relativePath: relativePath,
            date: date,
            index: &index
        )
        guard case let .captured(record) = capture else {
            return false
        }
        var baselines = index.baselines ?? [:]
        baselines[relativePath] = record.id
        index.baselines = baselines
        do {
            try writeIndex(index)
        } catch {
            return false
        }
        return true
    }

    /// Keep advances the baseline; Revert returns A's bytes when the current
    /// disk bytes are still B.
    public func decide(
        transitionID: UUID,
        keep: Bool,
        currentDiskBytes: Data? = nil
    ) -> MarkdownReviewDecision {
        var index = readIndex()
        guard var transitions = index.transitions,
              let position = transitions.firstIndex(where: {
                  $0.id == transitionID
              }) else {
            return .evidenceUnavailable
        }
        let transition = transitions[position]
        guard transition.decision == nil else {
            return .alreadyDecided
        }
        var baselines = index.baselines ?? [:]
        if keep {
            baselines[transition.relativePath] = transition.afterID
            transitions[position].decision = "kept"
            index.transitions = transitions
            index.baselines = baselines
            writeIndexQuietly(index)
            return .kept
        }
        guard let currentDiskBytes else {
            return .staleDisk
        }
        guard Self.sha256(currentDiskBytes) == transition.afterSha else {
            return .staleDisk
        }
        guard case let .bytes(before, _) = load(id: transition.beforeID) else {
            return .evidenceUnavailable
        }
        baselines[transition.relativePath] = transition.beforeID
        transitions[position].decision = "reverted"
        index.transitions = transitions
        index.baselines = baselines
        writeIndexQuietly(index)
        return .revert(before)
    }

    /// Capture without re-reading the index; the caller already holds it.
    private func captureLocked(
        rawBytes: Data,
        relativePath: String,
        date: Date,
        index: inout Index
    ) -> MarkdownSnapshotCapture {
        guard rawBytes.count <= projectByteQuota else {
            return .evidenceUnavailable
        }
        let existing = index.entries.filter {
            $0.relativePath == relativePath
        }
        guard existing.count < perFileQuota else {
            return .evidenceUnavailable
        }
        let totalBytes = index.entries.reduce(0) { $0 + $1.byteCount }
        guard totalBytes + rawBytes.count <= projectByteQuota else {
            return .evidenceUnavailable
        }
        let sha = Self.sha256(rawBytes)
        let blobURL = blobDirectory.appendingPathComponent("\(sha).bin")
        if !FileManager.default.fileExists(atPath: blobURL.path) {
            do {
                try writePrivate(rawBytes, to: blobURL)
            } catch {
                return .evidenceUnavailable
            }
        }
        let contents = try? MarkdownEncoding.decode(rawBytes)
        let record = MarkdownSnapshotRecord(
            id: UUID(),
            relativePath: relativePath,
            capturedAt: date,
            byteCount: rawBytes.count,
            sha256: sha,
            hadBOM: contents?.hasBOM ?? false,
            lineEnding: (contents?.lineEnding ?? .lf).rawValue
        )
        index.entries.append(record)
        return .captured(record)
    }

    private func writeIndexQuietly(_ index: Index) {
        try? writeIndex(index)
    }

    private func writeIndex(_ index: Index) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writePrivate(try encoder.encode(index), to: indexURL)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: temporary)
        try manager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporary.path
        )
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: url)
        }
    }

    private static func projectKey(_ root: URL) -> String {
        let canonical = MarkdownSecurity.canonical(root).path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
