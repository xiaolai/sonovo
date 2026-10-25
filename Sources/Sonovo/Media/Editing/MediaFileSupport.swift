import AVFoundation
import CryptoKit
import Darwin
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
    case destinationMissing(String)
    case sourceChanged(String)
    case emptyExport
    case replaceVerificationFailed
    case replacementConflict(keptAt: String)
    case atomicSwapFailed(String)
    case backupFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Application Support is unavailable."
        case let .destinationExists(name):
            "A file named “\(name)” already exists."
        case let .destinationMissing(name):
            "The file “\(name)” is missing."
        case let .sourceChanged(name):
            "“\(name)” changed on disk while it was being edited."
        case .emptyExport:
            "The export produced an empty file."
        case .replaceVerificationFailed:
            "The replacement could not be verified; no file was deleted."
        case let .replacementConflict(path):
            "The source changed while it was being replaced. The conflicting file was kept at “\(path)”."
        case let .atomicSwapFailed(message):
            "This volume cannot replace the file atomically: \(message)"
        case let .backupFailed(message):
            "The backup could not be saved: \(message)"
        }
    }
}

/// Identity and timestamps of one file revision, read with `stat` so it cannot
/// be served from the URL resource cache. A rename changes `ctime` while
/// preserving `mtime`; an in-place write changes both.
struct MediaFileSnapshot: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    /// The same file with the same bytes, ignoring the `ctime` update that a
    /// rename itself performs.
    func sameRevision(as other: MediaFileSnapshot) -> Bool {
        device == other.device
            && inode == other.inode
            && size == other.size
            && modifiedSeconds == other.modifiedSeconds
            && modifiedNanoseconds == other.modifiedNanoseconds
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

    /// Copy through a hidden sibling off the main actor, then publish with a
    /// synchronous rename. The destination never names a partial file.
    static func installAtomicallyAsync(
        from source: URL,
        to destination: URL,
        replacing: Bool
    ) async throws {
        let staged = try await stageAtomicallyAsync(
            from: source,
            to: destination
        )
        do {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                guard replacing else {
                    throw MediaStorageError.destinationExists(
                        destination.lastPathComponent
                    )
                }
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: staged,
                    backupItemName: nil,
                    options: []
                )
            } else {
                guard !replacing else {
                    throw MediaStorageError.destinationMissing(
                        destination.lastPathComponent
                    )
                }
                try FileManager.default.moveItem(
                    at: staged,
                    to: destination
                )
            }
        } catch {
            removeIfPresent(staged)
            throw error
        }
    }

    /// Stage a complete copy next to the destination without publishing it.
    /// Cancellation is observed before and after the copy; a cancelled stage
    /// never leaves a hidden file behind.
    static func stageAtomicallyAsync(
        from source: URL,
        to destination: URL
    ) async throws -> URL {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let hidden = directory.appendingPathComponent(
            ".sonovo-\(UUID().uuidString).tmp"
        )
        do {
            try await runFileTask {
                try FileManager.default.copyItem(at: source, to: hidden)
            }
            return hidden
        } catch {
            removeIfPresent(hidden)
            throw error
        }
    }

    /// Atomically exchange two existing files. This is the compare-and-swap
    /// primitive for replace-original: after the exchange, the old
    /// destination is at `staged`, so a concurrent writer's bytes can be
    /// detected and put back instead of being deleted.
    @discardableResult
    static func swapFiles(_ first: URL, _ second: URL) -> Bool {
        let result = first.withUnsafeFileSystemRepresentation { firstPath in
            second.withUnsafeFileSystemRepresentation { secondPath in
                guard let firstPath, let secondPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return renameatx_np(
                    AT_FDCWD,
                    firstPath,
                    AT_FDCWD,
                    secondPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        return result == 0
    }

    /// Streams a content fingerprint off the main actor. Raw media can be
    /// large, so this is reserved for destructive replacement, where a
    /// same-size/same-mtime in-place write must not be mistaken for the
    /// source the user edited.
    static func fingerprint(for url: URL) async throws -> String {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_048_576),
                  !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
            }
            try Task.checkCancellation()
            return hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func commitStagedReplacement(
        _ staged: URL,
        to destination: URL,
        expectedFingerprint: String,
        expectedSize: Int64,
        backupTo backup: URL,
        fileManager: FileManager = .default,
        swapping: @Sendable (URL, URL) -> Bool = { swapFiles($0, $1) }
    ) async throws {
        guard fileManager.fileExists(atPath: staged.path),
              fileManager.fileExists(atPath: destination.path) else {
            removeIfPresent(staged, fileManager: fileManager)
            throw MediaStorageError.destinationMissing(
                destination.lastPathComponent
            )
        }
        guard let exportBeforeSwap = snapshot(for: staged),
              let sourceBeforeHash = snapshot(for: destination) else {
            removeIfPresent(staged, fileManager: fileManager)
            throw MediaStorageError.replaceVerificationFailed
        }

        // Hash the current source before the exchange. All asynchronous work
        // in this transaction happens here.
        let currentFingerprint: String
        do {
            currentFingerprint = try await fingerprint(for: destination)
        } catch {
            removeIfPresent(staged, fileManager: fileManager)
            throw error
        }
        guard currentFingerprint == expectedFingerprint else {
            removeIfPresent(staged, fileManager: fileManager)
            throw MediaStorageError.sourceChanged(
                destination.lastPathComponent
            )
        }
        // A save that lands while the hash runs can be read only partially, or
        // missed after the reader passed that byte. Require the exact file and
        // timestamps to be unchanged across the whole hash.
        guard let sourceAfterHash = snapshot(for: destination),
              sourceAfterHash == sourceBeforeHash,
              let exportNow = snapshot(for: staged),
              exportNow == exportBeforeSwap else {
            removeIfPresent(staged, fileManager: fileManager)
            throw MediaStorageError.sourceChanged(
                destination.lastPathComponent
            )
        }
        // No suspension remains after this point: the exchange, validation and
        // backup are synchronous. Honour cancellation before touching the
        // source, but never interrupt the commit once it has happened.
        do {
            try Task.checkCancellation()
        } catch {
            removeIfPresent(staged, fileManager: fileManager)
            throw error
        }
        guard swapping(staged, destination) else {
            removeIfPresent(staged, fileManager: fileManager)
            throw MediaStorageError.atomicSwapFailed(
                String(cString: strerror(errno))
            )
        }

        let destinationAfterSwap = snapshot(for: destination)
        let displaced = snapshot(for: staged)
        let destinationIsOurExport = destinationAfterSwap.map {
            $0.sameRevision(as: exportBeforeSwap)
        } ?? false
        let displacedIsHashedSource = displaced.map {
            $0.sameRevision(as: sourceAfterHash)
        } ?? false

        if destinationIsOurExport, displacedIsHashedSource {
            do {
                try fileManager.moveItem(at: staged, to: backup)
            } catch {
                throw MediaStorageError.backupFailed(
                    "\(error.localizedDescription). The previous file was left at “\(staged.path)”."
                )
            }
            // The caller's expected size and the staged export disagree: the
            // exchange is intact, so keep both files and fail the operation.
            guard expectedSize == exportBeforeSwap.size else {
                throw MediaStorageError.replaceVerificationFailed
            }
            guard snapshot(for: destination)?.sameRevision(
                as: exportBeforeSwap
            ) == true else {
                throw MediaStorageError.sourceChanged(
                    destination.lastPathComponent
                )
            }
            return
        }

        // A save landed between the stability check and the exchange, or the
        // destination changed after the exchange. Restore the displaced file
        // only while the destination is provably still our export. Anything
        // this transaction cannot identify is preserved, never deleted.
        if destinationIsOurExport {
            if swapping(staged, destination) {
                if let restored = snapshot(for: staged),
                   restored.sameRevision(as: exportBeforeSwap) {
                    removeIfPresent(staged, fileManager: fileManager)
                    throw MediaStorageError.sourceChanged(
                        destination.lastPathComponent
                    )
                }
                do {
                    try fileManager.moveItem(at: staged, to: backup)
                } catch {
                    throw MediaStorageError.backupFailed(
                        "\(error.localizedDescription). The conflicting file was left at “\(staged.path)”."
                    )
                }
                throw MediaStorageError.replacementConflict(
                    keptAt: backup.path
                )
            }
        }
        // The destination is not ours, or the restore failed. Preserve the
        // displaced bytes; never delete a file this transaction did not make.
        do {
            try fileManager.moveItem(at: staged, to: backup)
        } catch {
            throw MediaStorageError.backupFailed(
                "\(error.localizedDescription). The conflicting file was left at “\(staged.path)”."
            )
        }
        throw MediaStorageError.replacementConflict(keptAt: backup.path)
    }

    /// Detached file work does not inherit cancellation. Bridge it explicitly
    /// and leave the final commit to the caller after the last check.
    private static func runFileTask(
        _ body: @escaping @Sendable () throws -> Void
    ) async throws {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try body()
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
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
    /// Resource identifiers catch same-size/same-mtime replacements; size and
    /// modification time remain the fallback when an identifier is absent.
    static func matches(_ expected: AssetRevision, url: URL) -> Bool {
        guard let current = revision(for: url) else { return false }
        return matches(expected, revision: current)
    }

    static func matches(
        _ expected: AssetRevision,
        revision current: AssetRevision
    ) -> Bool {
        if let expectedID = expected.fileIdentifier,
           let currentID = current.fileIdentifier,
           expectedID != currentID {
            return false
        }
        guard expected.size == current.size else { return false }
        guard let expectedDate = expected.modified,
              let currentDate = current.modified else {
            return true
        }
        return abs(expectedDate.timeIntervalSince(currentDate)) < 0.001
    }

    /// Fresh identity and timestamps from `stat`. URL resource values can lag
    /// behind a rename/swap, so the atomic commit uses this instead.
    static func snapshot(for url: URL) -> MediaFileSnapshot? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation {
            path -> Int32 in
            guard let path else { return Int32(-1) }
            return stat(path, &info)
        }
        guard result == 0 else { return nil }
        return MediaFileSnapshot(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    static func fileSize(for url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ), let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    static func removeIfPresent(
        _ url: URL,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: url)
    }
}
