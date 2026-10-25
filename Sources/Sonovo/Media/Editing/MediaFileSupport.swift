import AVFoundation
import Foundation

struct MediaAudioDescription: Equatable, Sendable {
    let duration: Double
    let sampleRate: Double
    let channelCount: Int
    let bitDepth: Int?

    var durationText: String {
        guard duration.isFinite, duration >= 0 else { return "—" }
        let minutes = Int(duration) / 60
        let seconds = duration - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, seconds)
    }

    var sampleRateText: String {
        guard sampleRate.isFinite, sampleRate > 0 else { return "—" }
        let kilohertz = sampleRate / 1000
        if kilohertz.rounded() == kilohertz {
            return "\(Int(kilohertz)) kHz"
        }
        var text = String(format: "%.2f", kilohertz)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        return "\(text) kHz"
    }

    var channelText: String {
        switch channelCount {
        case 1: "Mono"
        case 2: "Stereo"
        default: "\(channelCount) ch"
        }
    }

    var detail: String {
        "\(durationText) · \(sampleRateText) · \(channelText)"
    }
}

enum MediaAudioMetadata {
    /// Reads the real file rather than trusting a production row or a stale
    /// duration captured before an edit.
    static func describe(url: URL) -> MediaAudioDescription? {
        guard let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        let format = file.fileFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        guard rate.isFinite, rate > 0, channels > 0 else { return nil }
        let bits = Int(format.streamDescription.pointee.mBitsPerChannel)
        return MediaAudioDescription(
            duration: Double(file.length) / rate,
            sampleRate: rate,
            channelCount: channels,
            bitDepth: bits > 0 ? bits : nil
        )
    }
}

enum MediaStorageError: LocalizedError, Equatable {
    case applicationSupportUnavailable
    case destinationExists(String)
    case sourceChanged(String)
    case emptyExport
    case replaceVerificationFailed

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Application Support is unavailable."
        case let .destinationExists(name):
            "A file named “\(name)” already exists."
        case let .sourceChanged(name):
            "“\(name)” changed on disk while it was being edited."
        case .emptyExport:
            "The export produced an empty file."
        case .replaceVerificationFailed:
            "The replacement could not be verified; the backup was restored."
        }
    }
}

/// File placement for recording and export. Nothing is installed into a
/// project until it is complete: exports and recordings live in Application
/// Support first, and the final install copies to a hidden sibling and
/// renames. The project scanner ignores dotfiles, so a crash never publishes
/// a partial asset.
enum MediaStorage {
    static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw MediaStorageError.applicationSupportUnavailable
        }
        return base.appendingPathComponent("Sonovo", isDirectory: true)
    }

    static func temporaryDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("Temp", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    static func backupDirectory(
        projectName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(
                safeFileComponent(projectName),
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    static func makeTemporaryURL(
        pathExtension: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try temporaryDirectory(fileManager: fileManager)
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        return directory.appendingPathComponent(
            "sonovo-\(UUID().uuidString)\(suffix)"
        )
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func safeFileComponent(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Project" : cleaned
    }

    /// A free path in `directory`. An existing timestamped name is never
    /// overwritten; a short UUID suffix makes the collision explicit.
    static func uniqueURL(
        in directory: URL,
        preferredName: String,
        fileManager: FileManager = .default
    ) -> URL {
        let candidate = directory.appendingPathComponent(preferredName)
        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }
        let base = candidate.deletingPathExtension()
        let pathExtension = candidate.pathExtension
        let suffix = String(UUID().uuidString.prefix(6))
        let suffixed = base.deletingLastPathComponent()
            .appendingPathComponent("\(base.lastPathComponent)-\(suffix)")
        return pathExtension.isEmpty
            ? suffixed
            : suffixed.appendingPathExtension(pathExtension)
    }

    /// Copy through a hidden sibling and rename, so a visible path only ever
    /// names a complete file. `.tmp` files are skipped by the project scanner.
    static func installAtomically(
        from source: URL,
        to destination: URL,
        replacing: Bool,
        fileManager: FileManager = .default
    ) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let hidden = directory.appendingPathComponent(
            ".sonovo-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: hidden) }

        try fileManager.copyItem(at: source, to: hidden)
        if fileManager.fileExists(atPath: destination.path) {
            guard replacing else {
                throw MediaStorageError.destinationExists(
                    destination.lastPathComponent
                )
            }
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: hidden,
                backupItemName: nil,
                options: []
            )
        } else {
            guard !replacing else {
                throw MediaStorageError.destinationExists(
                    destination.lastPathComponent
                )
            }
            try fileManager.moveItem(at: hidden, to: destination)
        }
    }

    /// Large exports must not copy on the main actor. The install itself is
    /// still atomic; only its file I/O moves to a background task.
    static func installAtomicallyAsync(
        from source: URL,
        to destination: URL,
        replacing: Bool
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try installAtomically(
                from: source,
                to: destination,
                replacing: replacing
            )
        }.value
    }

    static func copyItemAsync(from source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
    }

    static func revision(for url: URL) -> AssetRevision? {
        guard let values = try? url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        ) else {
            return nil
        }
        return AssetRevision(
            fileIdentifier: values.fileResourceIdentifier.map {
                String(describing: $0)
            },
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate
        )
    }

    /// Compares the identity the editor opened against the file on disk.
    /// File identifiers differ between scanner and sample-built assets, so
    /// the contract is size plus modification time.
    static func matches(_ expected: AssetRevision, url: URL) -> Bool {
        guard let current = revision(for: url) else { return false }
        guard expected.size == current.size else { return false }
        guard let expectedDate = expected.modified,
              let currentDate = current.modified else {
            return true
        }
        return abs(expectedDate.timeIntervalSince(currentDate)) < 0.001
    }

    static func fileSize(for url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
    }

    static func removeIfPresent(
        _ url: URL,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: url)
    }
}
