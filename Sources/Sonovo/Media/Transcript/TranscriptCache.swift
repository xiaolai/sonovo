import CryptoKit
import Foundation

struct TranscriptCacheKey: Hashable, Sendable {
    let assetID: String
    let revisionToken: String
    let localeIdentifier: String
    let provider: TranscriptProviderKind
    let schemaVersion: Int

    var fileName: String {
        let raw = [
            assetID,
            revisionToken,
            localeIdentifier,
            provider.rawValue,
            String(schemaVersion)
        ].joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
            + ".json"
    }
}

/// Derived transcript storage. It lives outside the project so a transcript
/// can be discarded or rebuilt without creating or deleting project files.
actor TranscriptCache {
    static let shared = TranscriptCache()

    private let directory: URL
    private let fileManager: FileManager
    private let maximumFiles: Int

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        maximumFiles: Int = 64
    ) {
        self.fileManager = fileManager
        self.maximumFiles = maximumFiles
        if let directory {
            self.directory = directory
        } else {
            let support = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.directory = support
                .appendingPathComponent("Sonovo", isDirectory: true)
                .appendingPathComponent("Transcripts", isDirectory: true)
        }
    }

    func load(_ key: TranscriptCacheKey) -> TranscriptDocument? {
        let url = directory.appendingPathComponent(key.fileName)
        guard let data = try? Data(contentsOf: url),
              let document = try? decoder.decode(
                  TranscriptDocument.self,
                  from: data
              ),
              document.schemaVersion == key.schemaVersion,
              document.assetID == key.assetID,
              document.revisionToken == key.revisionToken,
              document.localeIdentifier == key.localeIdentifier,
              document.provider == key.provider else {
            return nil
        }
        return document
    }

    /// Finds the newest cache entry for this asset revision regardless of
    /// provider or locale, so reopening an editor can rediscover a transcript
    /// without knowing how it was produced.
    func latest(
        assetID: String,
        revisionToken: String,
        schemaVersion: Int
    ) -> TranscriptDocument? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter({ $0.pathExtension == "json" }) else {
            return nil
        }
        var newest: TranscriptDocument?
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let document = try? decoder.decode(
                      TranscriptDocument.self,
                      from: data
                  ),
                  document.schemaVersion == schemaVersion,
                  document.assetID == assetID,
                  document.revisionToken == revisionToken else {
                continue
            }
            if let current = newest {
                if document.createdAt > current.createdAt {
                    newest = document
                }
            } else {
                newest = document
            }
        }
        return newest
    }

    func store(
        _ document: TranscriptDocument,
        key: TranscriptCacheKey
    ) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(document)
        try data.write(
            to: directory.appendingPathComponent(key.fileName),
            options: .atomic
        )
        trim()
    }

    func removeAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ).filter({ $0.pathExtension == "json" }) else {
            return
        }
        guard files.count > maximumFiles else { return }
        let ordered = files.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: Set(keys))
                .contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: Set(keys))
                .contentModificationDate) ?? .distantPast
            return left < right
        }
        for url in ordered.prefix(files.count - maximumFiles) {
            try? fileManager.removeItem(at: url)
        }
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
