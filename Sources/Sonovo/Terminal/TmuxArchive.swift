import CryptoKit
import Darwin
import Foundation
import Security

// MARK: - Metadata

enum TmuxCaptureReason: String, Codable, Sendable, Equatable {
    case manual
    case captureAndEnd
    case automatic
}

/// Authenticated metadata. It is also stored in a cleartext header so a
/// crash between rename and index append can be reconciled without guessing;
/// terminal content is only ever inside the sealed box.
struct TmuxCaptureMetadata: Codable, Equatable, Sendable {
    let captureID: UUID
    let session: TmuxSessionIdentity
    let sessionName: String
    let ownershipPath: String?
    let ownershipFingerprint: String
    let capturedAt: Date
    let reason: TmuxCaptureReason
    let paneLabels: [String]
    let truncated: Bool
    let contentOutcome: TmuxCaptureVerdict
    let byteCount: Int
}

struct TmuxArchiveEnvelope: Codable, Equatable, Sendable {
    let metadata: TmuxCaptureMetadata
    let panes: [TmuxCapturePaneResult]
}

struct TmuxArchiveIndexEntry: Codable, Equatable, Sendable {
    let metadata: TmuxCaptureMetadata
    let fileName: String
    let committedAt: Date
    let reconciled: Bool

    var captureID: UUID { metadata.captureID }
}

struct TmuxArchiveIndexFile: Codable, Equatable, Sendable {
    var version: Int = 1
    var entries: [TmuxArchiveIndexEntry] = []
}

struct TmuxArchiveCommitResult: Sendable, Equatable {
    let isCommitted: Bool
    let reason: String?
}

struct TmuxRevealedCapture: Sendable, Equatable {
    let metadata: TmuxCaptureMetadata
    let panes: [TmuxCapturePaneResult]
}

enum TmuxArchiveError: Error, Equatable {
    case keyUnavailable
    case keyMissing
    case corrupt
    case notFound
    case io
}

enum ArchiveFailurePoint: String, Sendable, Equatable {
    case afterTempWrite
    case afterRenameBeforeIndex
    case indexWriteFailed
}

// MARK: - Key storage

protocol TmuxArchiveKeyStoring: Sendable {
    /// nil means the key does not exist yet. A locked or unavailable
    /// Keychain throws; it never reports absence.
    func existingKey() throws -> SymmetricKey?
    func createKey() throws -> SymmetricKey
}

struct KeychainArchiveKeyStore: TmuxArchiveKeyStoring {
    /// Follow the packaged bundle identity instead of carrying a second copy
    /// of it in source. Existing builds keep the same service; a future
    /// bundle-identity change is then one decision, not two.
    static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "com.sonovo.app").tmux-archive"
    }
    static let account = "local"

    func existingKey() throws -> SymmetricKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        query[kSecUseDataProtectionKeychain as String] = false
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else {
                throw TmuxArchiveError.corrupt
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            // Includes errSecInteractionNotAllowed (locked Keychain) and
            // errSecNotAvailable. No prompt and no replacement key.
            throw TmuxArchiveError.keyUnavailable
        }
    }

    func createKey() throws -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                == errSecSuccess else {
            throw TmuxArchiveError.keyUnavailable
        }
        let data = Data(bytes)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: false
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard let existing = try existingKey() else {
                throw TmuxArchiveError.corrupt
            }
            return existing
        }
        guard status == errSecSuccess else {
            throw TmuxArchiveError.keyUnavailable
        }
        return SymmetricKey(data: data)
    }
}

final class InMemoryArchiveKeyStore: TmuxArchiveKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    private var failure: TmuxArchiveError?

    init(key: SymmetricKey? = nil, failure: TmuxArchiveError? = nil) {
        self.key = key
        self.failure = failure
    }

    func existingKey() throws -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        return key
    }

    func createKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        if let key { return key }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                == errSecSuccess else {
            throw TmuxArchiveError.keyUnavailable
        }
        let created = SymmetricKey(data: Data(bytes))
        key = created
        return created
    }
}

// MARK: - Archive store

/// Encrypted capture archive. Commit order is encrypt in memory, write a
/// 0600 temp file, fsync, rename, then append the index. A crash between
/// steps leaves an orphan that reconciliation pairs.
final class TmuxArchiveStore: @unchecked Sendable {
    static let magic = Data("SONOVOARCH1".utf8)
    static let maxHeaderBytes = 1024 * 1024
    static let maxEncodedFileBytes = 16 * 1024 * 1024

    private let lock = NSLock()
    private let keyStore: any TmuxArchiveKeyStoring
    let directory: URL
    let indexURL: URL
    private var index = TmuxArchiveIndexFile()
    private var enabled: Bool
    private var failures: [String] = []
    private var failurePoint: ArchiveFailurePoint?
    private var maxCountStorage = 500
    private var maxBytesStorage = 512 * 1024 * 1024
    private var retentionDaysStorage = 30
    private var indexPersistenceFailed = false

    static func defaultDirectory() -> URL {
        HygieneFile.supportDirectory()?
            .appendingPathComponent("TmuxArchive", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("SonovoTmuxArchive", isDirectory: true)
    }

    init(
        directory: URL = TmuxArchiveStore.defaultDirectory(),
        keyStore: any TmuxArchiveKeyStoring = KeychainArchiveKeyStore(),
        isEnabled: Bool = false,
        retentionDays: Int = 30,
        maxCount: Int = 500,
        maxBytes: Int = 512 * 1024 * 1024
    ) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
        self.keyStore = keyStore
        self.enabled = isEnabled
        // Apply the saved policy before reconciliation purges anything.
        retentionDaysStorage = Swift.max(1, retentionDays)
        maxCountStorage = Swift.max(1, maxCount)
        maxBytesStorage = Swift.max(1, maxBytes)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        loadIndex()
        reconcile()
    }

    var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return enabled
        }
        set {
            lock.lock()
            enabled = newValue
            lock.unlock()
        }
    }

    func setRetentionDays(_ days: Int) {
        setLimits(retentionDays: days)
    }

    func setLimits(
        maxCount: Int? = nil,
        maxBytes: Int? = nil,
        retentionDays: Int? = nil
    ) {
        lock.lock()
        if let maxCount { maxCountStorage = Swift.max(1, maxCount) }
        if let maxBytes { maxBytesStorage = Swift.max(1, maxBytes) }
        if let retentionDays {
            retentionDaysStorage = Swift.max(1, retentionDays)
        }
        lock.unlock()
    }

    func setFailurePoint(_ point: ArchiveFailurePoint?) {
        lock.lock()
        failurePoint = point
        lock.unlock()
    }

    func latestPurgeFailures() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }

    private func loadIndex() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return
        }
        guard let value = HygieneFile.read(
            TmuxArchiveIndexFile.self,
            from: indexURL
        ), value.version == 1 else {
            // A corrupt index is rebuilt from the files, not trusted.
            index = TmuxArchiveIndexFile()
            return
        }
        index = value
    }

    private func synchronizeDirectory(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        let result = fsync(fd)
        close(fd)
        return result == 0
    }

    /// Writes the index through a synced temp file and rename, then syncs
    /// the directory. A commit is not reported until both are durable.
    private func persistIndexLocked() -> Bool {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(index) else {
            indexPersistenceFailed = true
            return false
        }
        let temp = directory.appendingPathComponent(
            ".index-\(UUID().uuidString).tmp"
        )
        guard FileManager.default.createFile(
            atPath: temp.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), let handle = try? FileHandle(forWritingTo: temp) else {
            indexPersistenceFailed = true
            return false
        }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
            indexPersistenceFailed = true
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: indexURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    indexURL,
                    withItemAt: temp
                )
            } else {
                try FileManager.default.moveItem(at: temp, to: indexURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            indexPersistenceFailed = true
            return false
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: indexURL.path
        )
        if !synchronizeDirectory(directory) {
            indexPersistenceFailed = true
            return false
        }
        indexPersistenceFailed = false
        return true
    }

    // MARK: Commit

    private struct CommitError: Error {
        let reason: String
    }

    private struct PreparedCapture {
        let fileData: Data
        let fileName: String
        let finalURL: URL
        let tempURL: URL
    }

    func commit(
        metadata: TmuxCaptureMetadata,
        capture: TmuxCaptureResult
    ) -> TmuxArchiveCommitResult {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else {
            return TmuxArchiveCommitResult(
                isCommitted: false,
                reason: "The archive is off."
            )
        }
        do {
            let key = try writingKeyLocked()
            let prepared = try prepareCaptureLocked(
                metadata: metadata,
                capture: capture,
                key: key
            )
            if let failure = writeCaptureLocked(prepared) {
                return failure
            }
            if failurePoint == .afterRenameBeforeIndex {
                return TmuxArchiveCommitResult(
                    isCommitted: false,
                    reason: "Simulated crash before the index append."
                )
            }
            if failurePoint == .indexWriteFailed {
                return TmuxArchiveCommitResult(
                    isCommitted: false,
                    reason: "The capture index write failed."
                )
            }
            return appendIndexLocked(
                fileName: prepared.fileName,
                metadata: metadata
            )
        } catch let error as CommitError {
            return TmuxArchiveCommitResult(
                isCommitted: false,
                reason: error.reason
            )
        } catch {
            return TmuxArchiveCommitResult(
                isCommitted: false,
                reason: "The capture could not be encrypted."
            )
        }
    }

    private func writingKeyLocked() throws -> SymmetricKey {
        do {
            return try keyForWritingLocked()
        } catch TmuxArchiveError.keyMissing {
            throw CommitError(
                reason: "The archive key is missing; no new key was created."
            )
        } catch {
            throw CommitError(
                reason: "The Keychain key is unavailable; capture failed closed."
            )
        }
    }

    /// Encrypts in memory and describes the files the commit will write.
    /// Nothing reaches disk until `writeCaptureLocked`.
    private func prepareCaptureLocked(
        metadata: TmuxCaptureMetadata,
        capture: TmuxCaptureResult,
        key: SymmetricKey
    ) throws -> PreparedCapture {
        let envelope = TmuxArchiveEnvelope(
            metadata: metadata,
            panes: capture.panes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadataJSON = try encoder.encode(metadata)
        guard metadataJSON.count <= Self.maxHeaderBytes else {
            throw CommitError(
                reason: "The capture metadata exceeded the header cap."
            )
        }
        let payload = try encoder.encode(envelope)
        let sealed = try AES.GCM.seal(
            payload,
            using: key,
            authenticating: metadataJSON
        )
        guard let combined = sealed.combined else {
            throw TmuxArchiveError.corrupt
        }
        var fileData = Self.magic
        var length = UInt32(metadataJSON.count).bigEndian
        withUnsafeBytes(of: &length) { fileData.append(contentsOf: $0) }
        fileData.append(metadataJSON)
        fileData.append(combined)

        let fileName = "\(metadata.captureID.uuidString).enc"
        return PreparedCapture(
            fileData: fileData,
            fileName: fileName,
            finalURL: directory.appendingPathComponent(fileName),
            tempURL: directory.appendingPathComponent(
                ".\(metadata.captureID.uuidString).tmp"
            )
        )
    }

    /// Writes the temp file, then renames and syncs the directory. nil means
    /// the capture file is durable; a result is the failure to report.
    private func writeCaptureLocked(
        _ prepared: PreparedCapture
    ) -> TmuxArchiveCommitResult? {
        guard FileManager.default.createFile(
            atPath: prepared.tempURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), let handle = try? FileHandle(forWritingTo: prepared.tempURL) else {
            return TmuxArchiveCommitResult(
                isCommitted: false,
                reason: "The capture temp file could not be created."
            )
        }
        do {
            try handle.write(contentsOf: prepared.fileData)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: prepared.tempURL)
            return TmuxArchiveCommitResult(
                isCommitted: false,
                reason: "The capture temp file could not be written."
            )
        }
        if failurePoint == .afterTempWrite {
            return TmuxArchiveCommitResult(
                isCommitted: false,
                reason: "Simulated crash after the temp write."
            )
        }
        do {
            try FileManager.default.moveItem(
                at: prepared.tempURL,
                to: prepared.finalURL
            )
        } catch {
            try? FileManager.default.removeItem(at: prepared.tempURL)
            return TmuxArchiveCommitResult(
                isCommitted: false,
                reason: "The capture file could not be committed."
            )
        }
        guard synchronizeDirectory(directory) else {
            return TmuxArchiveCommitResult(
                isCommitted: false,
                reason: "The capture directory could not be synchronized."
            )
        }
        return nil
    }

    private func appendIndexLocked(
        fileName: String,
        metadata: TmuxCaptureMetadata
    ) -> TmuxArchiveCommitResult {
        index.entries.removeAll { $0.captureID == metadata.captureID }
        index.entries.append(
            TmuxArchiveIndexEntry(
                metadata: metadata,
                fileName: fileName,
                committedAt: Date(),
                reconciled: false
            )
        )
        // Purge before the index write so a capture removed by retention or a
        // cap never remains listed as committed.
        purgeLocked(now: Date())
        guard persistIndexLocked() else {
            // An index that was not durably written must not make the
            // in-memory state claim a committed capture.
            index.entries.removeAll {
                $0.captureID == metadata.captureID
            }
            indexPersistenceFailed = true
            return TmuxArchiveCommitResult(
                isCommitted: false,
                reason: "The capture index could not be written."
            )
        }
        let survives = index.entries.contains {
            $0.captureID == metadata.captureID
        }
        return TmuxArchiveCommitResult(
            isCommitted: survives,
            reason: survives
                ? nil
                : "The capture exceeded the archive cap or retention."
        )
    }

    private func keyForWritingLocked() throws -> SymmetricKey {
        if let existing = try keyStore.existingKey() {
            return existing
        }
        // Never silently replace a key under existing captures. If the
        // directory cannot be read, absence cannot be proven.
        guard let captures = capturesOnDiskLocked() else {
            throw TmuxArchiveError.keyUnavailable
        }
        if !captures.isEmpty {
            throw TmuxArchiveError.keyMissing
        }
        return try keyStore.createKey()
    }

    // MARK: Reconcile

    /// Pairs files and index entries at launch. Orphan files are adopted
    /// when the key can read them; index entries without a file are dropped.
    func reconcile() {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        guard let files = capturesOnDiskLocked() else {
            failures.append(
                "The archive directory could not be read; reconciliation was skipped."
            )
            return
        }
        var validFiles: Set<String> = []
        for url in files {
            let fileName = url.lastPathComponent
            validFiles.insert(fileName)
            if index.entries.contains(where: { $0.fileName == fileName }) {
                continue
            }
            do {
                let recovered = try readEnvelopeLocked(at: url)
                index.entries.append(
                    TmuxArchiveIndexEntry(
                        metadata: recovered.metadata,
                        fileName: fileName,
                        committedAt: recovered.metadata.capturedAt,
                        reconciled: true
                    )
                )
            } catch let error as ArchiveReadError {
                failures.append(
                    "Could not reconcile \(fileName): "
                        + archiveReadReason(error)
                        + "; it was left in place."
                )
            } catch {
                failures.append(
                    "Could not reconcile \(fileName); it was left in place."
                )
            }
        }
        let before = index.entries.count
        index.entries.removeAll {
            !validFiles.contains($0.fileName)
        }
        if index.entries.count != before {
            failures.append(
                "Removed \(before - index.entries.count) index entries with no file."
            )
        }
        removeTempFilesLocked()
        purgeLocked(now: Date())
        if !persistIndexLocked() {
            failures.append(
                "The archive index could not be persisted after reconciliation."
            )
        }
    }

    private func capturesOnDiskLocked() -> [URL]? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        return contents
            .filter { $0.pathExtension == "enc" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func removeTempFilesLocked() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in contents where url.lastPathComponent.hasSuffix(".tmp") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private enum ArchiveReadError: Error {
        case keyUnavailable
        case io
        case corrupt
    }

    private func readEnvelopeLocked(
        at url: URL
    ) throws -> TmuxArchiveEnvelope {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ), let size = attributes[.size] as? NSNumber,
        size.intValue <= Self.maxEncodedFileBytes else {
            throw ArchiveReadError.io
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ArchiveReadError.io
        }
        defer { try? handle.close() }
        let headerLength = Self.magic.count + 4
        let header: Data
        do {
            header = try handle.read(upToCount: headerLength) ?? Data()
        } catch {
            throw ArchiveReadError.io
        }
        guard header.count == headerLength,
              header.prefix(Self.magic.count) == Self.magic else {
            throw ArchiveReadError.corrupt
        }
        let length = header[Self.magic.count..<headerLength]
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0,
              Int(length) <= Self.maxHeaderBytes else {
            throw ArchiveReadError.corrupt
        }
        let metadataJSON: Data
        do {
            metadataJSON = try handle.read(upToCount: Int(length))
                ?? Data()
        } catch {
            throw ArchiveReadError.io
        }
        guard metadataJSON.count == Int(length) else {
            throw ArchiveReadError.corrupt
        }
        let sealedBytes: Data
        do {
            sealedBytes = try handle.readToEnd() ?? Data()
        } catch {
            throw ArchiveReadError.io
        }
        guard !sealedBytes.isEmpty else {
            throw ArchiveReadError.corrupt
        }
        guard let metadata = try? JSONDecoder().decode(
            TmuxCaptureMetadata.self,
            from: metadataJSON
        ) else {
            throw ArchiveReadError.corrupt
        }
        let symmetricKey: SymmetricKey
        do {
            guard let existing = try keyStore.existingKey() else {
                throw ArchiveReadError.keyUnavailable
            }
            symmetricKey = existing
        } catch {
            throw ArchiveReadError.keyUnavailable
        }
        guard let sealed = try? AES.GCM.SealedBox(combined: sealedBytes),
              let plain = try? AES.GCM.open(
                  sealed,
                  using: symmetricKey,
                  authenticating: metadataJSON
              ),
              let envelope = try? JSONDecoder().decode(
                  TmuxArchiveEnvelope.self,
                  from: plain
              ),
              envelope.metadata == metadata else {
            throw ArchiveReadError.corrupt
        }
        return envelope
    }

    private func archiveReadReason(_ error: ArchiveReadError) -> String {
        switch error {
        case .keyUnavailable: "the archive key is unavailable"
        case .io: "the file could not be read"
        case .corrupt: "the file is corrupt"
        }
    }

    // MARK: Reveal and export

    func reveal(captureID: UUID) throws -> TmuxRevealedCapture {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = index.entries.first(where: {
            $0.captureID == captureID
        }) else {
            throw TmuxArchiveError.notFound
        }
        do {
            let envelope = try readEnvelopeLocked(
                at: directory.appendingPathComponent(entry.fileName)
            )
            return TmuxRevealedCapture(
                metadata: envelope.metadata,
                panes: envelope.panes
            )
        } catch let error as ArchiveReadError {
            switch error {
            case .keyUnavailable: throw TmuxArchiveError.keyUnavailable
            case .io: throw TmuxArchiveError.io
            case .corrupt: throw TmuxArchiveError.corrupt
            }
        } catch {
            throw TmuxArchiveError.corrupt
        }
    }

    /// The only plaintext export path. The caller must have shown the
    /// narrower warning; this writes exactly one user-chosen file.
    func exportPlaintext(captureID: UUID, to url: URL) throws {
        let revealed = try reveal(captureID: captureID)
        var text = ""
        for pane in revealed.panes {
            text += pane.text
            if !text.hasSuffix("\n") { text += "\n" }
        }
        try Data(text.utf8).write(to: url, options: [.atomic])
    }

    // MARK: Queries

    func hasCommittedCompleteCapture(
        identity: TmuxSessionIdentity
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !indexPersistenceFailed else { return false }
        let candidates = index.entries
            .filter {
                $0.metadata.session == identity
                    && $0.metadata.contentOutcome == .complete
            }
            .sorted { $0.metadata.capturedAt > $1.metadata.capturedAt }
        for entry in candidates {
            let url = directory.appendingPathComponent(entry.fileName)
            guard let envelope = try? readEnvelopeLocked(at: url) else {
                continue
            }
            if envelope.metadata.session == identity,
               envelope.metadata.contentOutcome == .complete {
                return true
            }
        }
        return false
    }

    func latestEntry(
        identity: TmuxSessionIdentity
    ) -> TmuxArchiveIndexEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard !indexPersistenceFailed else { return nil }
        return index.entries
            .filter { $0.metadata.session == identity }
            .max { $0.metadata.capturedAt < $1.metadata.capturedAt }
    }

    // MARK: Purge

    private func fileSize(of url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ), let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.intValue
    }

    private func fileDate(of url: URL) -> Date {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ), let date = (attributes[.creationDate]
            ?? attributes[.modificationDate]) as? Date else {
            return .distantPast
        }
        return date
    }

    private func purgeLocked(now: Date) {
        let retention = TimeInterval(retentionDaysStorage) * 24 * 60 * 60
        let cutoff = now.addingTimeInterval(-retention)
        guard let files = capturesOnDiskLocked() else {
            failures.append(
                "The archive directory could not be read; purge was skipped."
            )
            return
        }
        let indexed = Dictionary(
            uniqueKeysWithValues: index.entries.map {
                ($0.fileName, $0)
            }
        )
        struct Item {
            let url: URL
            let date: Date
            let entry: TmuxArchiveIndexEntry?
        }
        var remaining: [Item] = []
        for url in files {
            let entry = indexed[url.lastPathComponent]
            let date = entry?.metadata.capturedAt ?? fileDate(of: url)
            if date < cutoff {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    failures.append(
                        "Could not purge \(url.lastPathComponent): "
                            + error.localizedDescription
                    )
                    remaining.append(
                        Item(url: url, date: date, entry: entry)
                    )
                }
            } else {
                remaining.append(Item(url: url, date: date, entry: entry))
            }
        }
        remaining.sort { $0.date < $1.date }
        var totalCount = remaining.count
        var totalBytes = remaining.reduce(0) { $0 + fileSize(of: $1.url) }
        var keep: [Item] = []
        for item in remaining {
            let over = totalCount > maxCountStorage
                || totalBytes > maxBytesStorage
            if over {
                let size = fileSize(of: item.url)
                do {
                    try FileManager.default.removeItem(at: item.url)
                    totalCount -= 1
                    totalBytes -= size
                    continue
                } catch {
                    failures.append(
                        "Could not purge \(item.url.lastPathComponent): "
                            + error.localizedDescription
                    )
                }
            }
            keep.append(item)
        }
        index.entries = keep.compactMap(\.entry)
    }
}
