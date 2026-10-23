import Darwin
import Foundation

/// A file read from disk.
public struct LoadedMarkdown: Sendable {
    public let url: URL
    public let contents: MarkdownFileContents
    public let snapshot: DiskSnapshot
    /// Whether the document is above the editable-size threshold.
    public let isLarge: Bool

    public init(url: URL, contents: MarkdownFileContents, snapshot: DiskSnapshot) {
        self.url = url
        self.contents = contents
        self.snapshot = snapshot
        self.isLarge = snapshot.byteCount > MarkdownLimits.maxEditableDocumentBytes
    }
}

public enum MarkdownFileStoreError: Error, Equatable, CustomStringConvertible {
    case fileTooLarge(byteCount: Int)

    public var description: String {
        switch self {
        case let .fileTooLarge(byteCount):
            "The Markdown file is \(byteCount) bytes; the reading limit is "
                + "\(MarkdownLimits.maxReadBytes) bytes."
        }
    }
}

extension MarkdownFileStoreError: LocalizedError {
    public var errorDescription: String? { description }
}

/// The result of comparing the disk with a snapshot.
public enum DiskComparison: Sendable, Equatable {
    case unchanged
    case changed
    case missing
}

/// Artifacts preserved around a swap.
public struct SaveArtifacts: Sendable, Equatable {
    public let displaced: URL?
    public let newContent: URL?

    public init(displaced: URL? = nil, newContent: URL? = nil) {
        self.displaced = displaced
        self.newContent = newContent
    }

    public static let none = SaveArtifacts()
}

/// Save modes.
public enum SaveMode: Sendable, Equatable {
    /// Automatic autosave: never replaces an existing target on a filesystem
    /// that cannot swap atomically.
    case automatic
    /// An explicit user save or conflict resolution.
    case explicitOverwrite
    /// Recreate a file known to be missing. Refuses a destination that
    /// reappeared, rather than overwriting it.
    case create
}

/// Test-only hooks for race injection.
public struct SaveHooks: Sendable {
    public var beforeRename: (@Sendable (URL) -> Void)?
    public var afterSwap: (@Sendable (URL) -> Void)?

    public init(
        beforeRename: (@Sendable (URL) -> Void)? = nil,
        afterSwap: (@Sendable (URL) -> Void)? = nil
    ) {
        self.beforeRename = beforeRename
        self.afterSwap = afterSwap
    }
}

/// A save request carrying document identity and the disk state it expects.
public struct SaveRequest: Sendable {
    public let documentID: UUID
    public let identityGeneration: UInt64
    public let sourceRevision: UInt64
    public let destination: URL
    public let expectedDisk: DiskSnapshot?
    public let data: Data
    public let mode: SaveMode
    public let hooks: SaveHooks?
    /// The largest existing destination this save may read and displace.
    /// `nil` keeps the historic unbounded read. An unconditional overwrite
    /// (no expected snapshot) sets this so a destination that grew past the
    /// caller's cap is refused instead of allocated.
    public let maximumReplacedBytes: Int?

    public init(
        documentID: UUID,
        identityGeneration: UInt64,
        sourceRevision: UInt64,
        destination: URL,
        expectedDisk: DiskSnapshot?,
        data: Data,
        mode: SaveMode,
        hooks: SaveHooks? = nil,
        maximumReplacedBytes: Int? = nil
    ) {
        self.documentID = documentID
        self.identityGeneration = identityGeneration
        self.sourceRevision = sourceRevision
        self.destination = destination
        self.expectedDisk = expectedDisk
        self.data = data
        self.mode = mode
        self.hooks = hooks
        self.maximumReplacedBytes = maximumReplacedBytes
    }
}

/// The result of a successful save.
public struct SaveOutcome: Sendable, Equatable {
    public let snapshot: DiskSnapshot
    public let artifacts: SaveArtifacts

    public init(snapshot: DiskSnapshot, artifacts: SaveArtifacts) {
        self.snapshot = snapshot
        self.artifacts = artifacts
    }
}

/// A save failure.
public enum SaveError: Error, Equatable {
    case diskChanged(SaveArtifacts)
    case destinationExists
    case swapUnavailable
    case verificationFailed(SaveArtifacts)
    /// The save could not preserve the displaced bytes at the contained
    /// path. The file is deliberately left on disk for recovery.
    case recoveryRequired(String)
    case writeFailed(String)
}

/// Options for the file store.
public struct FileStoreOptions: Sendable {
    /// Test seam for filesystems that cannot swap. Production leaves it true
    /// and lets the syscall report ENOTSUP/EINVAL.
    public var supportsAtomicSwap: Bool

    public init(supportsAtomicSwap: Bool = true) {
        self.supportsAtomicSwap = supportsAtomicSwap
    }
}

/// Reads, compares, and saves Markdown files.
///
/// The save path is compare-and-swap: the caller passes the exact bytes the
/// edit was based on. A mismatch aborts before any replacement. On success the
/// displaced bytes and the new content are preserved as independent artifacts,
/// and the target is verified after the swap.
public struct MarkdownFileStore: Sendable {
    public var options: FileStoreOptions

    public init(options: FileStoreOptions = FileStoreOptions()) {
        self.options = options
    }

    public func read(_ url: URL) throws -> LoadedMarkdown {
        let data = try Self.readBoundedData(at: url)
        let contents = try MarkdownEncoding.decode(data)
        return LoadedMarkdown(
            url: url,
            contents: contents,
            snapshot: DiskSnapshot(bytes: data)
        )
    }

    /// Returns `nil` when the file does not exist.
    public func diskSnapshot(at url: URL) throws -> DiskSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return DiskSnapshot(bytes: try Self.readBoundedData(at: url))
    }

    public func compareDisk(at url: URL, to snapshot: DiskSnapshot) throws -> DiskComparison {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        // A destination that grew past the read cap is changed by definition;
        // never allocate it just to discover that.
        let current: Data
        do {
            current = try Self.readBoundedData(at: url)
        } catch {
            return .changed
        }
        return current == snapshot.bytes ? .unchanged : .changed
    }

    static func readBoundedData(at url: URL) throws -> Data {
        if let size = try? url.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize, size > MarkdownLimits.maxReadBytes {
            throw MarkdownFileStoreError.fileTooLarge(byteCount: size)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let cap = MarkdownLimits.maxReadBytes + 1
        var data = Data()
        while data.count < cap {
            let chunk = try handle.read(
                upToCount: min(1 << 18, cap - data.count)
            )
            guard let chunk, !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= MarkdownLimits.maxReadBytes else {
            throw MarkdownFileStoreError.fileTooLarge(byteCount: data.count)
        }
        return data
    }

    // MARK: - Save

    private static let atFDCWD: Int32 = -2
    private static let renameSwap: UInt32 = 0x0000_0002
    private static let renameExclusive: UInt32 = 0x0000_0004

    public func save(_ request: SaveRequest) throws -> SaveOutcome {
        let workspace = try prepare(request)
        if !workspace.exists {
            return try writeNewFile(request, workspace)
        }
        return try replaceExistingFile(request, workspace)
    }

    /// The files and identity of one save attempt.
    ///
    /// The temporary file's lifetime spans the whole replacement. It is
    /// removed on every ordinary failure, but a failure that leaves it as the
    /// only copy of displaced external bytes sets `keepTemporary`, so cleanup
    /// deliberately leaves it for recovery.
    private final class SaveWorkspace {
        let destination: URL
        let directory: URL
        let token: String
        let exists: Bool
        let previousBytes: Data?
        let temporary: URL
        let newArtifact: URL
        let displacedArtifact: URL
        var keepTemporary = false

        init(destination: URL, exists: Bool, previousBytes: Data?) {
            self.destination = destination
            self.directory = destination.deletingLastPathComponent()
            self.token = UUID().uuidString
            self.exists = exists
            self.previousBytes = previousBytes

            let name = destination.lastPathComponent
            temporary = self.directory.appendingPathComponent(
                ".\(name).sonovo-tmp-\(self.token)"
            )
            newArtifact = self.directory.appendingPathComponent(
                ".\(name).sonovo-new-\(self.token)"
            )
            displacedArtifact = self.directory.appendingPathComponent(
                ".\(name).sonovo-displaced-\(self.token)"
            )
        }

        deinit {
            if !keepTemporary {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        func removeNewArtifact() {
            try? FileManager.default.removeItem(at: newArtifact)
        }

        func removeDisplacedArtifact() {
            try? FileManager.default.removeItem(at: displacedArtifact)
        }
    }

    /// The read bound for the pre-swap destination. A compare-and-swap
    /// request can be bounded by its expected size because a larger file
    /// cannot match — the mismatched read ends in `diskChanged` either way.
    /// An unconditional overwrite is bounded only by its explicit maximum.
    private func preflightLimit(for request: SaveRequest) -> Int? {
        if let maximum = request.maximumReplacedBytes {
            return max(request.expectedDisk?.byteCount ?? 0, maximum)
        }
        return request.expectedDisk?.byteCount
    }

    /// Reads a file with a hard allocation bound. Returns nil when the file
    /// is larger than `limit`; never allocates past `limit + 1`.
    private func readBoundedFile(at url: URL, limit: Int) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        let cap = limit + 1
        while data.count < cap {
            let chunk = try handle.read(
                upToCount: min(1 << 18, cap - data.count)
            )
            guard let chunk, !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data.count <= limit ? data : nil
    }

    /// Reads the existing destination within the bound this request can
    /// justify. A compare-and-swap request is bounded by its expected
    /// snapshot — a file that grew past it cannot match, so `diskChanged` is
    /// the correct result — and an unconditional overwrite is bounded by
    /// `maximumReplacedBytes`, beyond which the save refuses rather than
    /// allocate an arbitrary file.
    private func readPreviousBytes(for request: SaveRequest) throws -> Data {
        let destination = request.destination
        guard let limit = preflightLimit(for: request) else {
            return try Data(contentsOf: destination)
        }
        guard let data = try readBoundedFile(at: destination, limit: limit)
        else {
            if request.expectedDisk != nil {
                throw SaveError.diskChanged(.none)
            }
            throw SaveError.writeFailed(
                "The destination is larger than the "
                    + "\(limit)-byte replace limit."
            )
        }
        return data
    }

    /// Validates the compare-and-swap precondition and creates the two
    /// replacement files. Every replacement strategy works from this state.
    private func prepare(_ request: SaveRequest) throws -> SaveWorkspace {
        let destination = request.destination
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: destination.path)
        // Reject a recreated destination before reading it: a create request
        // carries no size bound, so reading first would allocate an arbitrary
        // file only to refuse it.
        if exists, request.mode == .create {
            throw SaveError.destinationExists
        }
        let previousBytes: Data? = exists
            ? try readPreviousBytes(for: request)
            : nil

        if let expected = request.expectedDisk {
            guard let previousBytes, previousBytes == expected.bytes else {
                throw SaveError.diskChanged(.none)
            }
        } else if exists, request.mode == .automatic {
            throw SaveError.diskChanged(.none)
        }

        let workspace = SaveWorkspace(
            destination: destination,
            exists: exists,
            previousBytes: previousBytes
        )
        do {
            guard try PrivateFileWriter.createExclusively(
                request.data,
                at: workspace.temporary
            ), try PrivateFileWriter.createExclusively(
                request.data,
                at: workspace.newArtifact
            ) else {
                throw SaveError.writeFailed(
                    "temporary save file already exists"
                )
            }
            if exists {
                // Replacement bytes must not broaden permissions or drop
                // ACLs/extended attributes from the original file.
                try preserveAttributes(
                    from: destination,
                    to: workspace.temporary
                )
                try preserveAttributes(
                    from: destination,
                    to: workspace.newArtifact
                )
            }
        } catch {
            workspace.removeNewArtifact()
            throw SaveError.writeFailed(String(describing: error))
        }
        return workspace
    }

    /// Creates a file that did not exist before. `RENAME_EXCL` refuses to
    /// replace anything that appeared after the preflight check.
    private func writeNewFile(
        _ request: SaveRequest,
        _ workspace: SaveWorkspace
    ) throws -> SaveOutcome {
        request.hooks?.beforeRename?(workspace.destination)
        guard renameatx_np(
            Self.atFDCWD,
            workspace.temporary.path,
            Self.atFDCWD,
            workspace.destination.path,
            Self.renameExclusive
        ) == 0 else {
            let code = errno
            workspace.removeNewArtifact()
            if code == EEXIST {
                throw SaveError.destinationExists
            }
            throw SaveError.writeFailed("renameatx_np EXCL errno \(code)")
        }
        request.hooks?.afterSwap?(workspace.destination)

        let artifacts = SaveArtifacts(
            displaced: nil,
            newContent: workspace.newArtifact
        )
        try verify(
            workspace.destination,
            holds: request.data,
            artifacts: artifacts
        )
        return SaveOutcome(
            snapshot: DiskSnapshot(bytes: request.data),
            artifacts: artifacts
        )
    }

    /// Replaces an existing target, choosing the strongest strategy the
    /// filesystem supports.
    private func replaceExistingFile(
        _ request: SaveRequest,
        _ workspace: SaveWorkspace
    ) throws -> SaveOutcome {
        try preserveDisplacedCopy(workspace)
        request.hooks?.beforeRename?(workspace.destination)

        if attemptSwap(workspace) == 0 {
            return try finishSwap(request, workspace)
        }

        let code = errno
        if code == EINVAL || code == ENOTSUP || code == ENOSYS {
            return try replaceWithoutSwap(request, workspace)
        }
        throw SaveError.writeFailed("renameatx_np SWAP errno \(code)")
    }

    /// Preserves an independent copy of the displaced target before any
    /// replacement. A hard link would share the inode and could be mutated by
    /// an external in-place writer.
    private func preserveDisplacedCopy(_ workspace: SaveWorkspace) throws {
        guard let previousBytes = workspace.previousBytes else { return }
        do {
            guard try PrivateFileWriter.createExclusively(
                previousBytes,
                at: workspace.displacedArtifact
            ) else {
                throw SaveError.writeFailed(
                    "displaced artifact already exists"
                )
            }
            try preserveAttributes(
                from: workspace.destination,
                to: workspace.displacedArtifact
            )
        } catch {
            workspace.removeNewArtifact()
            throw SaveError.writeFailed(String(describing: error))
        }
    }

    private func attemptSwap(_ workspace: SaveWorkspace) -> Int32 {
        guard options.supportsAtomicSwap else {
            errno = ENOTSUP
            return -1
        }
        return renameatx_np(
            Self.atFDCWD,
            workspace.temporary.path,
            Self.atFDCWD,
            workspace.destination.path,
            Self.renameSwap
        )
    }

    /// Completes a successful swap: preserves the actual swapped-out bytes,
    /// verifies the target, and turns a concurrent external write into a
    /// conflict without losing either version.
    private func finishSwap(
        _ request: SaveRequest,
        _ workspace: SaveWorkspace
    ) throws -> SaveOutcome {
        request.hooks?.afterSwap?(workspace.destination)

        let displaced: Data
        do {
            if let limit = request.maximumReplacedBytes {
                guard let data = try readBoundedFile(
                    at: workspace.temporary,
                    limit: limit
                ) else {
                    // The file grew past the save's bound after the swap.
                    // The temporary file is now the only copy of the
                    // external bytes; keep it and report the recovery path.
                    workspace.keepTemporary = true
                    throw SaveError.recoveryRequired(workspace.temporary.path)
                }
                displaced = data
            } else {
                displaced = try Data(contentsOf: workspace.temporary)
            }
        } catch {
            // The temporary file may be the only copy of an external edit.
            // Keep it and report its recovery path.
            workspace.keepTemporary = true
            throw SaveError.recoveryRequired(workspace.temporary.path)
        }

        // Preserve the actual swapped-out bytes before any verification
        // check can throw. Cleanup must not take the only copy of the
        // external edit with it.
        do {
            // The pre-swap artifact already exists with owner-only
            // permissions; overwrite it with the bytes that were actually
            // swapped out.
            try displaced.write(to: workspace.displacedArtifact)
            // The swapped-out inode's attributes now live on the temporary
            // file; the artifact must not be broader than the original.
            try preserveAttributes(
                from: workspace.temporary,
                to: workspace.displacedArtifact
            )
        } catch {
            // The artifact write failed, so the temporary file is now the
            // only surviving copy. Do not let cleanup delete it.
            workspace.keepTemporary = true
            throw SaveError.writeFailed(
                "cannot preserve displaced bytes at "
                    + "\(workspace.temporary.path): \(error)"
            )
        }

        let artifacts = SaveArtifacts(
            displaced: workspace.displacedArtifact,
            newContent: workspace.newArtifact
        )
        try verify(
            workspace.destination,
            holds: request.data,
            artifacts: artifacts
        )

        if let expected = request.expectedDisk, displaced != expected.bytes {
            // An external writer changed the target between the initial read
            // and the swap. Restore its bytes so reload/keep-local decisions
            // operate on the disk state they describe. The restore is a
            // swap, not an overwrite: whatever the destination holds at that
            // instant is preserved as a recovery artifact, never silently
            // discarded.
            let newerVersion = try restoreDisplaced(
                displaced,
                in: workspace,
                requestData: request.data
            )
            throw SaveError.diskChanged(
                SaveArtifacts(
                    displaced: newerVersion ?? workspace.displacedArtifact,
                    newContent: workspace.newArtifact
                )
            )
        }

        return SaveOutcome(
            snapshot: DiskSnapshot(bytes: request.data),
            artifacts: artifacts
        )
    }

    /// The filesystem refused a swap. An automatic save must never replace
    /// an existing file on such a filesystem; an explicit resolution does a
    /// plain atomic replace with the displaced bytes already preserved.
    private func replaceWithoutSwap(
        _ request: SaveRequest,
        _ workspace: SaveWorkspace
    ) throws -> SaveOutcome {
        if request.mode == .automatic || request.mode == .create {
            workspace.removeDisplacedArtifact()
            workspace.removeNewArtifact()
            throw SaveError.swapUnavailable
        }

        // Re-read immediately before replacing: this path cannot
        // compare-and-swap, so an edit that arrived after the initial read
        // must be detected and preserved now. The same bound applies, so a
        // late growth cannot allocate without limit.
        var latest: Data?
        do {
            if let limit = request.maximumReplacedBytes {
                latest = try readBoundedFile(
                    at: workspace.destination,
                    limit: limit
                )
                if latest == nil, request.expectedDisk != nil {
                    throw SaveError.diskChanged(.none)
                }
                if latest == nil {
                    throw SaveError.writeFailed(
                        "The destination is larger than the "
                            + "\(limit)-byte replace limit."
                    )
                }
            } else {
                latest = try Data(contentsOf: workspace.destination)
            }
        } catch let error as SaveError {
            throw error
        } catch {
            latest = nil
        }
        if let expected = request.expectedDisk, latest != expected.bytes {
            if let latest {
                // The artifact already exists with owner-only permissions;
                // truncate it in place.
                try? latest.write(to: workspace.displacedArtifact)
            }
            throw SaveError.diskChanged(
                SaveArtifacts(
                    displaced: workspace.displacedArtifact,
                    newContent: workspace.newArtifact
                )
            )
        }

        // An unconditional overwrite has no expected snapshot, but a writer
        // may still have changed the destination between the initial read and
        // the reread. Preserve those bytes, not the older copy, before
        // replacing them.
        if request.expectedDisk == nil,
           let latest,
           latest != workspace.previousBytes {
            do {
                try latest.write(to: workspace.displacedArtifact)
            } catch {
                // The rename has not run, so the destination still holds the
                // external bytes. Fail without touching it.
                throw SaveError.writeFailed(
                    "cannot preserve the changed destination at "
                        + "\(workspace.displacedArtifact.path): \(error)"
                )
            }
        }

        guard renameatx_np(
            Self.atFDCWD,
            workspace.temporary.path,
            Self.atFDCWD,
            workspace.destination.path,
            0
        ) == 0 else {
            throw SaveError.writeFailed("renameatx_np errno \(errno)")
        }

        let artifacts = SaveArtifacts(
            displaced: workspace.displacedArtifact,
            newContent: workspace.newArtifact
        )
        try verify(
            workspace.destination,
            holds: request.data,
            artifacts: artifacts
        )
        return SaveOutcome(
            snapshot: DiskSnapshot(bytes: request.data),
            artifacts: artifacts
        )
    }

    /// Restores `data` to `destination` with an atomic swap.
    ///
    /// The swap displaces whatever the destination held at that instant. If
    /// that content is not this save's own bytes, it is a newer external
    /// version: it is written over the displaced artifact (so the conflict
    /// shows the newest text) or, when that write fails, its temporary file
    /// is returned so the caller can report it. Never an unconditional
    /// overwrite of unknown content.
    private func restoreDisplaced(
        _ data: Data,
        in workspace: SaveWorkspace,
        requestData: Data
    ) throws -> URL? {
        let destination = workspace.destination
        let restoreURL = workspace.directory.appendingPathComponent(
            ".\(destination.lastPathComponent).sonovo-restore-"
                + workspace.token
        )
        do {
            guard try PrivateFileWriter.createExclusively(
                data,
                at: restoreURL
            ) else {
                throw SaveError.writeFailed(
                    "restore file already exists at \(restoreURL.path)"
                )
            }
            // The restored bytes are the inode that was swapped out to the
            // temporary file. Carry that inode's permissions, ACLs, and
            // attributes, not the installed local replacement's broader
            // defaults.
            try preserveAttributes(from: workspace.temporary, to: restoreURL)
        } catch {
            try? FileManager.default.removeItem(at: restoreURL)
            throw SaveError.writeFailed(
                "cannot prepare displaced bytes at \(restoreURL.path): \(error)"
            )
        }

        guard renameatx_np(
            Self.atFDCWD,
            restoreURL.path,
            Self.atFDCWD,
            destination.path,
            Self.renameSwap
        ) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: restoreURL)
            throw SaveError.writeFailed(
                "cannot restore displaced bytes at \(destination.path): "
                    + "errno \(code)"
            )
        }

        // `restoreURL` now holds what the destination held at the swap.
        // Bounded by this save's own data: a larger file cannot be our own
        // bytes, and it is preserved rather than read without limit.
        guard let swappedOut = try? readBoundedFile(
            at: restoreURL,
            limit: requestData.count
        ) else {
            // It cannot be inspected, so it must not be deleted: it may be
            // the only copy of a newer external version.
            return restoreURL
        }
        if swappedOut == requestData {
            try? FileManager.default.removeItem(at: restoreURL)
            return nil
        }

        do {
            try swappedOut.write(to: workspace.displacedArtifact)
        } catch {
            return restoreURL
        }
        // The destination held a newer external version than the one being
        // restored. Put that newer version back on disk so the disk and the
        // conflict artifact agree; the older restored bytes are superseded.
        // `restoreURL` currently holds the newer version as its own inode.
        guard renameatx_np(
            Self.atFDCWD,
            restoreURL.path,
            Self.atFDCWD,
            destination.path,
            Self.renameSwap
        ) == 0 else {
            // Leave the newer version at the recovery path rather than
            // deleting the only copy.
            return restoreURL
        }
        // The second swap moved the older restored bytes to restoreURL.
        // Only delete it when it really is those bytes; a third external
        // version may have arrived in between and must be preserved.
        if let swappedBack = try? readBoundedFile(
            at: restoreURL,
            limit: data.count
        ), swappedBack == data {
            try? FileManager.default.removeItem(at: restoreURL)
            return nil
        }
        return restoreURL
    }

    /// Confirms the destination holds the bytes this save wrote. Bounded by
    /// the expected size: a larger file cannot match.
    private func verify(
        _ destination: URL,
        holds expected: Data,
        artifacts: SaveArtifacts
    ) throws {
        let written = try? readBoundedFile(
            at: destination,
            limit: expected.count
        )
        guard let written, written == expected else {
            throw SaveError.verificationFailed(artifacts)
        }
    }

    /// Copies POSIX permissions, ACLs, and extended attributes from an
    /// existing destination to a replacement file.
    ///
    /// ACLs are kernel state, not represented by `attributesOfItem`; only
    /// `copyfile` carries them. Failures other than an unsupported filesystem
    /// fail the save: continuing would silently broaden access to a
    /// restricted file.
    private func preserveAttributes(from source: URL, to target: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)
        if copyfile(source.path, target.path, nil, flags) != 0, errno != ENOTSUP {
            throw SaveError.writeFailed(
                "cannot preserve metadata from \(source.path): errno \(errno)"
            )
        }

        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: source.path
        ) else {
            throw SaveError.writeFailed(
                "cannot read attributes from \(source.path)"
            )
        }
        guard let permissions = attributes[.posixPermissions] else {
            throw SaveError.writeFailed(
                "cannot read permissions from \(source.path)"
            )
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: target.path
            )
        } catch {
            throw SaveError.writeFailed(
                "cannot preserve permissions at \(target.path): \(error)"
            )
        }
    }
}
