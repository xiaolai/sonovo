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

/// The app-owned review ledger for one project root.
///
/// Git is deliberately not the store: unreferenced Git objects are prunable,
/// and filters can transform captured bytes. The ledger keeps exact bytes in
/// a content-addressed object directory and the decisions in a manifest, so a
/// decision always has the evidence it was made against.
@MainActor
final class CodeReviewStore {
    private struct Manifest: Codable {
        var version: Int
        var baselineEstablishedAt: Date?
        var cursors: [CodeReviewCursor]
        var decisions: [StoredReviewDecision]
    }

    static let schemaVersion = 1
    /// Content budget for baselines. Decisions are always retained; the
    /// budget only stops baseline capture from growing without limit.
    static let objectBudget = 512 * 1024 * 1024

    let root: URL
    private let directory: URL
    private let objectsDirectory: URL
    private let manifestURL: URL
    private(set) var cursors: [String: CodeReviewCursor] = [:]
    private(set) var decisions: [StoredReviewDecision] = []
    /// When the first baseline was captured, including an empty project.
    private(set) var baselineEstablishedAt: Date?
    private(set) var lastError: String?
    private var objectBytes: Int = 0

    init(root: URL, directory: URL? = nil) {
        self.root = MarkdownSecurity.canonical(root)
        let resolved = directory ?? Self.defaultDirectory(for: self.root)
        self.directory = resolved
        self.objectsDirectory = resolved.appendingPathComponent(
            "objects",
            isDirectory: true
        )
        self.manifestURL = resolved.appendingPathComponent("manifest.json")
        load()
    }

    /// A stable per-root location. The path hash keeps two projects with the
    /// same folder name apart.
    static func defaultDirectory(for root: URL) -> URL {
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

    func cursor(for path: String) -> CodeReviewCursor? {
        cursors[path]
    }

    /// The most recent decision for a path, if any.
    func latestDecision(for path: String) -> StoredReviewDecision? {
        decisions.last { $0.path == path }
    }

    func content(for hash: String) -> Data? {
        try? Data(contentsOf: objectsDirectory.appendingPathComponent(hash))
    }

    /// Whether the store has a retained copy of this exact content.
    func hasContent(for hash: String) -> Bool {
        FileManager.default.fileExists(
            atPath: objectsDirectory.appendingPathComponent(hash).path
        )
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

    func recordBaseline(
        path: String,
        hash: String,
        at date: Date = Date()
    ) throws {
        cursors[path] = CodeReviewCursor(
            path: path,
            hash: hash,
            capturedAt: date,
            hasContent: false
        )
        try save()
    }

    /// Establishes the first baseline for a project in one manifest write.
    func recordBaselines(
        _ baselines: [CodeReviewBaseline],
        at date: Date = Date()
    ) throws {
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
                hash: baseline.snapshot.sha256,
                capturedAt: date,
                hasContent: keepsContent
            )
        }
        baselineEstablishedAt = date
        try save()
    }

    /// Stores a decision and retains both sides' bytes. The cursor does not
    /// move: it is the baseline the queue compares against, and the file stays
    /// in the queue with its decision until the reviewer sets a new baseline.
    func record(
        _ decision: CodeReviewDecision,
        before: Data?,
        after: Data?
    ) throws {
        if let before, before.count <= CodeLimits.editableBytes {
            try storeBlob(DiskSnapshot(bytes: before))
        }
        if let after, after.count <= CodeLimits.editableBytes {
            try storeBlob(DiskSnapshot(bytes: after))
        }
        decisions.append(StoredReviewDecision(decision))
        try save()
    }

    /// Forgets a path after its file is gone and the reviewer acknowledged it.
    func remove(path: String) throws {
        cursors.removeValue(forKey: path)
        decisions.removeAll { $0.path == path }
        try save()
    }

    // MARK: - Persistence

    func save() throws {
        let manifest = Manifest(
            version: Self.schemaVersion,
            baselineEstablishedAt: baselineEstablishedAt,
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
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(
                to: manifestURL,
                options: .atomic
            )
            pruneObjects()
            lastError = nil
        } catch {
            lastError = "Cannot save the review ledger: \(error)"
            throw error
        }
    }

    private func load() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: manifestURL.path) else {
            try? manager.createDirectory(
                at: objectsDirectory,
                withIntermediateDirectories: true
            )
            return
        }
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(Manifest.self, from: data)
            guard manifest.version == Self.schemaVersion else {
                throw CocoaError(.coderReadCorrupt)
            }
            cursors = Dictionary(
                manifest.cursors.map { ($0.path, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            decisions = manifest.decisions
            baselineEstablishedAt = manifest.baselineEstablishedAt
            objectBytes = directorySize(objectsDirectory)
        } catch {
            lastError = "The review ledger could not be read: \(error)"
            preserveCorruptManifest()
            cursors = [:]
            decisions = []
        }
    }

    private func preserveCorruptManifest() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = directory.appendingPathComponent(
            "manifest.corrupt-\(stamp).json"
        )
        try? FileManager.default.moveItem(
            at: manifestURL,
            to: target
        )
    }

    // MARK: - Objects

    @discardableResult
    private func storeBlob(_ snapshot: DiskSnapshot) throws -> Bool {
        let url = objectsDirectory.appendingPathComponent(snapshot.sha256)
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        try FileManager.default.createDirectory(
            at: objectsDirectory,
            withIntermediateDirectories: true
        )
        try snapshot.bytes.write(to: url, options: .atomic)
        objectBytes += snapshot.byteCount
        return true
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
