import Foundation
import SonovoCore

/// One file's last acknowledged version in a project.
struct CodeReviewCursor: Codable, Equatable, Sendable {
    var path: String
    var hash: String
    var capturedAt: Date
    /// Whether the baseline bytes were retained for diffing.
    var hasContent: Bool
}

/// A decision persisted by Sonovo. The hashes are the content identity; the
/// bytes live in the store's object directory.
struct StoredReviewDecision: Codable, Equatable, Sendable {
    var path: String
    var leftLabel: String
    var rightLabel: String
    var leftHash: String
    var rightHash: String
    var disposition: CodeReviewDisposition
    var note: String
    var reference: String
    var createdAt: Date

    init(_ decision: CodeReviewDecision) {
        path = decision.path
        leftLabel = decision.leftLabel
        rightLabel = decision.rightLabel
        leftHash = decision.leftHash
        rightHash = decision.rightHash
        disposition = decision.disposition
        note = decision.note
        reference = decision.reference
        createdAt = decision.createdAt
    }

    var reviewDecision: CodeReviewDecision {
        CodeReviewDecision(
            path: path,
            leftLabel: leftLabel,
            rightLabel: rightLabel,
            leftHash: leftHash,
            rightHash: rightHash,
            disposition: disposition,
            note: note,
            reference: reference,
            createdAt: createdAt
        )
    }
}

enum CodeReviewStoreError: Error, Equatable {
    /// The corrupt manifest could not be archived, so writing would destroy
    /// the only copy of the previous ledger.
    case writesDisabled
}

/// The app-owned review ledger for one project root.
///
/// Git is deliberately not the store: unreferenced Git objects are prunable,
/// and filters can transform captured bytes. The ledger keeps exact bytes in
/// a content-addressed object directory and the decisions in a manifest, so a
/// decision always has the evidence it was made against.
///
/// The store is an actor: every read, write, hash verification, and manifest
/// serialization runs off the main actor, serialized with the others.
actor CodeReviewStore {
    struct State: Sendable {
        let cursors: [String: CodeReviewCursor]
        let decisions: [StoredReviewDecision]
        let baselineEstablishedAt: Date?
        let lastError: String?
    }

    private struct Manifest: Codable {
        var version: Int
        var baselineEstablishedAt: Date?
        var objectBytes: Int?
        var cursors: [CodeReviewCursor]
        var decisions: [StoredReviewDecision]
    }

    private struct Loaded {
        var cursors: [String: CodeReviewCursor] = [:]
        var decisions: [StoredReviewDecision] = []
        var baselineEstablishedAt: Date?
        var lastError: String?
        var objectBytes = 0
        var writesDisabled = false
    }

    static let schemaVersion = 1
    /// Content budget for baselines. Decisions are always retained; the
    /// budget only stops baseline capture from growing without limit.
    static let objectBudget = 512 * 1024 * 1024

    nonisolated let root: URL
    private let directory: URL
    private let objectsDirectory: URL
    private let manifestURL: URL
    private(set) var cursors: [String: CodeReviewCursor] = [:]
    private(set) var decisions: [StoredReviewDecision] = []
    /// When the first baseline was captured, including an empty project.
    private(set) var baselineEstablishedAt: Date?
    private(set) var lastError: String?
    private var objectBytes = 0
    private var writesDisabled = false
    private var isLoaded = false
    /// Hashes whose bytes failed verification during this session. They are
    /// not offered as evidence again until a write replaces the object.
    private var invalidHashes: Set<String> = []
    /// Hashes verified against their names on this session's first listing.
    private var verifiedHashes: Set<String> = []

    init(root: URL, directory: URL? = nil) {
        let canonical = MarkdownSecurity.canonical(root)
        self.root = canonical
        let resolved = directory ?? Self.defaultDirectory(for: canonical)
        self.directory = resolved
        self.objectsDirectory = resolved.appendingPathComponent(
            "objects",
            isDirectory: true
        )
        self.manifestURL = resolved.appendingPathComponent("manifest.json")
    }

    /// Reads the manifest once on the actor's executor. Every public entry
    /// point calls it, so a store used directly is never silently empty and
    /// the read never blocks the main thread.
    func load() {
        guard !isLoaded else { return }
        isLoaded = true
        let loaded = Self.loadState(
            manifestURL: manifestURL,
            directory: directory,
            objectsDirectory: objectsDirectory
        )
        cursors = loaded.cursors
        decisions = loaded.decisions
        baselineEstablishedAt = loaded.baselineEstablishedAt
        lastError = loaded.lastError
        objectBytes = loaded.objectBytes
        writesDisabled = loaded.writesDisabled
    }

    /// A stable per-root location. The path hash keeps two projects with the
    /// same folder name apart.
    nonisolated static func defaultDirectory(for root: URL) -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let key = DiskSnapshot(
            bytes: Data(MarkdownSecurity.canonical(root).path.utf8)
        ).sha256
        return support
            .appendingPathComponent("Sonovo", isDirectory: true)
            .appendingPathComponent("Review", isDirectory: true)
            .appendingPathComponent(String(key.prefix(16)), isDirectory: true)
    }

    // MARK: - Queries

    func state() -> State {
        load()
        return State(
            cursors: cursors,
            decisions: decisions,
            baselineEstablishedAt: baselineEstablishedAt,
            lastError: lastError
        )
    }

    func cursor(for path: String) -> CodeReviewCursor? {
        load()
        return cursors[path]
    }

    /// The most recent decision for a path, if any.
    func latestDecision(for path: String) -> StoredReviewDecision? {
        load()
        return decisions.last { $0.path == path }
    }

    /// Reads a blob only when its bytes still hash to its name. A truncated
    /// or replaced object is unavailable evidence, never silent corruption.
    func content(for hash: String) -> Data? {
        load()
        guard !invalidHashes.contains(hash) else { return nil }
        guard let data = try? Data(
            contentsOf: objectsDirectory.appendingPathComponent(hash)
        ) else {
            invalidHashes.insert(hash)
            lastError = "Review evidence \(hash.prefix(12))… is unavailable."
            return nil
        }
        guard DiskSnapshot(bytes: data).sha256 == hash else {
            invalidHashes.insert(hash)
            lastError = "Review evidence \(hash.prefix(12))… is corrupted."
            return nil
        }
        verifiedHashes.insert(hash)
        return data
    }

    func hasContent(for hash: String) -> Bool {
        content(for: hash) != nil
    }

    /// The hashes with a retained, verified object, used to decide whether a
    /// queue item can be reviewed before any file is read. Each object is
    /// checked once per session: contents are read and hashed, non-regular
    /// files are rejected, and failures are not offered again.
    func retainedHashes() -> Set<String> {
        load()
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(
            atPath: objectsDirectory.path
        )) ?? []
        var result: Set<String> = []
        for name in names
        where !name.hasPrefix(".") && !invalidHashes.contains(name) {
            if verifiedHashes.contains(name) {
                result.insert(name)
                continue
            }
            let url = objectsDirectory.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  DiskSnapshot(bytes: data).sha256 == name else {
                invalidHashes.insert(name)
                continue
            }
            verifiedHashes.insert(name)
            result.insert(name)
        }
        return result
    }

    // MARK: - Writes

    /// Records a baseline. Files above the editable cap, or beyond the content
    /// budget, keep a hash without retained bytes; the queue then says the
    /// previous content is unavailable instead of pretending it can diff.
    func recordBaseline(
        path: String,
        snapshot: DiskSnapshot,
        at date: Date = Date()
    ) throws {
        load()
        try mutate {
            var keepsContent = false
            if snapshot.byteCount <= CodeLimits.editableBytes,
               objectBytes + snapshot.byteCount <= Self.objectBudget {
                do {
                    try storeBlob(snapshot)
                    keepsContent = true
                } catch {
                    lastError = "Cannot retain the review baseline: \(error)"
                }
            }
            cursors[path] = CodeReviewCursor(
                path: path,
                hash: snapshot.sha256,
                capturedAt: date,
                hasContent: keepsContent
            )
            try save()
        }
    }

    /// Establishes the first baseline for a project in one manifest write.
    func recordBaselines(
        _ baselines: [CodeReviewBaseline],
        at date: Date = Date()
    ) throws {
        load()
        try mutate {
            for baseline in baselines {
                var keepsContent = false
                if let bytes = baseline.bytes {
                    do {
                        try storeBlob(DiskSnapshot(bytes: bytes))
                        keepsContent = true
                    } catch {
                        lastError = "Cannot retain a review baseline: \(error)"
                    }
                }
                cursors[baseline.path] = CodeReviewCursor(
                    path: baseline.path,
                    hash: baseline.hash,
                    capturedAt: date,
                    hasContent: keepsContent
                )
            }
            baselineEstablishedAt = date
            try save(prune: false)
        }
    }

    /// Stores a decision and retains both sides' bytes. The cursor does not
    /// move: it is the baseline the queue compares against, and the file stays
    /// in the queue with its decision until the reviewer sets a new baseline.
    func record(
        _ decision: CodeReviewDecision,
        before: Data?,
        after: Data?
    ) throws {
        load()
        try mutate {
            if let before, before.count <= CodeLimits.editableBytes {
                try storeBlob(DiskSnapshot(bytes: before))
            }
            if let after, after.count <= CodeLimits.editableBytes {
                try storeBlob(DiskSnapshot(bytes: after))
            }
            decisions.append(StoredReviewDecision(decision))
            try save()
        }
    }

    /// Forgets a path after its file is gone and the reviewer acknowledged it.
    func remove(path: String) throws {
        load()
        try mutate {
            cursors.removeValue(forKey: path)
            decisions.removeAll { $0.path == path }
            try save()
        }
    }

    /// Removes the review history for a path but keeps its baseline.
    func clearDecisions(path: String) throws {
        load()
        try mutate {
            decisions.removeAll { $0.path == path }
            try save()
        }
    }

    // MARK: - Persistence

    func save(prune: Bool = true) throws {
        load()
        guard !writesDisabled else {
            throw CodeReviewStoreError.writesDisabled
        }
        let manifest = Manifest(
            version: Self.schemaVersion,
            baselineEstablishedAt: baselineEstablishedAt,
            objectBytes: objectBytes,
            cursors: cursors.values.sorted { $0.path < $1.path },
            decisions: decisions
        )
        do {
            try FileManager.default.createDirectory(
                at: objectsDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Ordering between a cursor and a decision decides which pair the
            // queue offers, so the date keeps its full precision. Encoding in
            // Date's own reference epoch preserves every distinct Date; Unix
            // seconds add a large offset and can round adjacent values
            // together. Older string manifests still decode.
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(date.timeIntervalSinceReferenceDate)
            }
            try encoder.encode(manifest).write(
                to: manifestURL,
                options: .atomic
            )
        } catch {
            lastError = "Cannot save the review ledger: \(error)"
            throw error
        }
        if prune, !hasArchivedManifest() {
            pruneObjects()
        }
    }

    private static func isoDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// Runs a mutation and restores the in-memory state when its save fails,
    /// so memory never claims a baseline the disk does not have.
    private func mutate<T>(_ body: () throws -> T) throws -> T {
        let oldCursors = cursors
        let oldDecisions = decisions
        let oldEstablished = baselineEstablishedAt
        let oldObjectBytes = objectBytes
        do {
            return try body()
        } catch {
            cursors = oldCursors
            decisions = oldDecisions
            baselineEstablishedAt = oldEstablished
            objectBytes = oldObjectBytes
            throw error
        }
    }

    /// Whether an archived manifest may exist. A listing failure cannot prove
    /// absence, so it is treated as "yes" and pruning is skipped.
    private func hasArchivedManifest() -> Bool {
        do {
            let names = try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            )
            return names.contains { $0.hasPrefix("manifest.corrupt-") }
        } catch {
            return true
        }
    }

    private static func loadState(
        manifestURL: URL,
        directory: URL,
        objectsDirectory: URL
    ) -> Loaded {
        let manager = FileManager.default
        guard manager.fileExists(atPath: manifestURL.path) else {
            try? manager.createDirectory(
                at: objectsDirectory,
                withIntermediateDirectories: true
            )
            return Loaded()
        }
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                if let seconds = try? container.decode(Double.self) {
                    return Date(timeIntervalSinceReferenceDate: seconds)
                }
                let text = try container.decode(String.self)
                guard let date = isoDate(text) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Invalid date: \(text)"
                    )
                }
                return date
            }
            let manifest = try decoder.decode(Manifest.self, from: data)
            guard manifest.version == schemaVersion else {
                throw CocoaError(.coderReadCorrupt)
            }
            var loaded = Loaded()
            loaded.cursors = Dictionary(
                manifest.cursors.map { ($0.path, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            loaded.decisions = manifest.decisions
            loaded.baselineEstablishedAt = manifest.baselineEstablishedAt
            loaded.objectBytes = manifest.objectBytes ?? 0
            return loaded
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let target = directory.appendingPathComponent(
                "manifest.corrupt-\(stamp).json"
            )
            do {
                try manager.moveItem(at: manifestURL, to: target)
                var loaded = Loaded()
                loaded.lastError = "The review ledger could not be read and "
                    + "was archived as \(target.lastPathComponent): \(error)"
                return loaded
            } catch {
                var loaded = Loaded()
                loaded.writesDisabled = true
                loaded.lastError = "The review ledger could not be read or "
                    + "archived; writes are disabled to protect it: \(error)"
                return loaded
            }
        }
    }

    // MARK: - Objects

    private func storeBlob(_ snapshot: DiskSnapshot) throws {
        let url = objectsDirectory.appendingPathComponent(snapshot.sha256)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        )
        if exists, !isDirectory.boolValue,
           let data = try? Data(contentsOf: url),
           DiskSnapshot(bytes: data).sha256 == snapshot.sha256 {
            invalidHashes.remove(snapshot.sha256)
            return
        }
        try manager.createDirectory(
            at: objectsDirectory,
            withIntermediateDirectories: true
        )
        try snapshot.bytes.write(to: url, options: .atomic)
        invalidHashes.remove(snapshot.sha256)
        if !exists {
            objectBytes += snapshot.byteCount
        } else {
            objectBytes = directorySize(objectsDirectory)
        }
    }

    /// Deletes blobs no cursor or decision references. Referenced evidence is
    /// never evicted here; a missing referenced blob is reported by the queue,
    /// not silently replaced.
    private func pruneObjects() {
        var referenced: Set<String> = []
        for cursor in cursors.values where cursor.hasContent {
            referenced.insert(cursor.hash)
        }
        for decision in decisions {
            referenced.insert(decision.leftHash)
            referenced.insert(decision.rightHash)
        }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(
            atPath: objectsDirectory.path
        ) else {
            return
        }
        for name in names where !referenced.contains(name) {
            try? manager.removeItem(
                at: objectsDirectory.appendingPathComponent(name)
            )
        }
        objectBytes = directorySize(objectsDirectory)
    }

    private func directorySize(_ url: URL) -> Int {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: url.path)
        else {
            return 0
        }
        return names.reduce(0) { total, name in
            let path = url.appendingPathComponent(name).path
            let size = (try? manager.attributesOfItem(atPath: path)[.size])
                as? NSNumber
            return total + (size?.intValue ?? 0)
        }
    }
}
