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

    public init(
        documentID: UUID,
        identityGeneration: UInt64,
        sourceRevision: UInt64,
        destination: URL,
        expectedDisk: DiskSnapshot?,
        data: Data,
        mode: SaveMode,
        hooks: SaveHooks? = nil
    ) {
        self.documentID = documentID
        self.identityGeneration = identityGeneration
        self.sourceRevision = sourceRevision
        self.destination = destination
        self.expectedDisk = expectedDisk
        self.data = data
        self.mode = mode
        self.hooks = hooks
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
        let data = try Data(contentsOf: url)
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
        return DiskSnapshot(bytes: try Data(contentsOf: url))
    }

    public func compareDisk(at url: URL, to snapshot: DiskSnapshot) throws -> DiskComparison {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        let current = try Data(contentsOf: url)
        return current == snapshot.bytes ? .unchanged : .changed
    }

    // MARK: - Save

    private static let atFDCWD: Int32 = -2
    private static let renameSwap: UInt32 = 0x0000_0002
    private static let renameExclusive: UInt32 = 0x0000_0004

    public func save(_ request: SaveRequest) throws -> SaveOutcome {
        let destination = request.destination
        let directory = destination.deletingLastPathComponent()
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: destination.path)

        let currentData: Data? = exists ? try Data(contentsOf: destination) : nil

        if let expected = request.expectedDisk {
            guard let currentData, currentData == expected.bytes else {
                throw SaveError.diskChanged(.none)
            }
        } else if exists, request.mode == .automatic {
            throw SaveError.diskChanged(.none)
        }

        let token = UUID().uuidString
        let tempURL = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).sonovo-tmp-\(token)"
        )
        let newArtifact = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).sonovo-new-\(token)"
        )
        let displacedArtifact = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).sonovo-displaced-\(token)"
        )

        do {
            guard try PrivateFileWriter.createExclusively(
                request.data,
                at: tempURL
            ), try PrivateFileWriter.createExclusively(
                request.data,
                at: newArtifact
            ) else {
                throw SaveError.writeFailed(
                    "temporary save file already exists"
                )
            }
            if exists {
                // Replacement bytes must not broaden permissions or drop
                // ACLs/extended attributes from the original file.
                try preserveAttributes(from: destination, to: tempURL)
                try preserveAttributes(from: destination, to: newArtifact)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            try? fileManager.removeItem(at: newArtifact)
            throw SaveError.writeFailed(String(describing: error))
        }

        var keepTemporaryFile = false
        defer {
            if !keepTemporaryFile {
                try? fileManager.removeItem(at: tempURL)
            }
        }

        if !exists {
            request.hooks?.beforeRename?(destination)
            guard renameatx_np(
                Self.atFDCWD,
                tempURL.path,
                Self.atFDCWD,
                destination.path,
                Self.renameExclusive
            ) == 0 else {
                let code = errno
                try? fileManager.removeItem(at: newArtifact)
                if code == EEXIST {
                    throw SaveError.destinationExists
                }
                throw SaveError.writeFailed("renameatx_np EXCL errno \(code)")
            }
            request.hooks?.afterSwap?(destination)

            try verify(
                destination,
                holds: request.data,
                artifacts: SaveArtifacts(displaced: nil, newContent: newArtifact)
            )

            return SaveOutcome(
                snapshot: DiskSnapshot(bytes: request.data),
                artifacts: SaveArtifacts(displaced: nil, newContent: newArtifact)
            )
        }

        // Preserve an independent copy of the displaced target before any
        // replacement. A hard link would share the inode and could be mutated
        // by an external in-place writer.
        if let currentData {
            do {
                guard try PrivateFileWriter.createExclusively(
                    currentData,
                    at: displacedArtifact
                ) else {
                    throw SaveError.writeFailed(
                        "displaced artifact already exists"
                    )
                }
                try preserveAttributes(from: destination, to: displacedArtifact)
            } catch {
                try? fileManager.removeItem(at: newArtifact)
                throw SaveError.writeFailed(String(describing: error))
            }
        }

        request.hooks?.beforeRename?(destination)

        let swapResult: Int32
        if options.supportsAtomicSwap {
            swapResult = renameatx_np(
                Self.atFDCWD,
                tempURL.path,
                Self.atFDCWD,
                destination.path,
                Self.renameSwap
            )
        } else {
            swapResult = -1
            errno = ENOTSUP
        }

        if swapResult == 0 {
            request.hooks?.afterSwap?(destination)

            let displaced: Data
            do {
                displaced = try Data(contentsOf: tempURL)
            } catch {
                // The temporary file may be the only copy of an external
                // edit. Keep it and report its recovery path.
                keepTemporaryFile = true
                throw SaveError.recoveryRequired(tempURL.path)
            }

            // Preserve the actual swapped-out bytes before any verification
            // check can throw. The defer deletes `tempURL`; a verification
            // failure must not take the only copy of the external edit with
            // it.
            do {
                // The pre-swap artifact already exists with owner-only
                // permissions; overwrite it with the bytes that were
                // actually swapped out.
                try displaced.write(to: displacedArtifact)
                // The swapped-out inode's attributes now live on `tempURL`;
                // the artifact must not be broader than the original file.
                try preserveAttributes(from: tempURL, to: displacedArtifact)
            } catch {
                // The artifact write failed, so `tempURL` is now the only
                // surviving copy. Do not let the defer delete it.
                keepTemporaryFile = true
                throw SaveError.writeFailed(
                    "cannot preserve displaced bytes at "
                        + "\(tempURL.path): \(error)"
                )
            }

            try verify(
                destination,
                holds: request.data,
                artifacts: SaveArtifacts(
                    displaced: displacedArtifact,
                    newContent: newArtifact
                )
            )
            if let expected = request.expectedDisk, displaced != expected.bytes {
                // An external writer changed the target between the initial
                // read and the swap. Restore its bytes so reload/keep-local
                // decisions operate on the disk state they describe.
                // The restore is a swap, not an overwrite: whatever the
                // destination holds at that instant is preserved as a
                // recovery artifact, never silently discarded.
                let newerVersion = try restoreDisplaced(
                    displaced,
                    to: destination,
                    directory: directory,
                    token: token,
                    requestData: request.data,
                    artifact: displacedArtifact
                )
                throw SaveError.diskChanged(
                    SaveArtifacts(
                        displaced: newerVersion ?? displacedArtifact,
                        newContent: newArtifact
                    )
                )
            }

            return SaveOutcome(
                snapshot: DiskSnapshot(bytes: request.data),
                artifacts: SaveArtifacts(
                    displaced: displacedArtifact,
                    newContent: newArtifact
                )
            )
        }

        let code = errno
        if code == EINVAL || code == ENOTSUP || code == ENOSYS {
            if request.mode == .automatic {
                try? fileManager.removeItem(at: displacedArtifact)
                try? fileManager.removeItem(at: newArtifact)
                throw SaveError.swapUnavailable
            }

            // Explicit resolution: a plain atomic replace, with the displaced
            // bytes already preserved. Re-read immediately before replacing:
            // this path cannot compare-and-swap, so an edit that arrived
            // after the initial read must be detected and preserved now.
            let latest: Data?
            do {
                latest = try Data(contentsOf: destination)
            } catch {
                latest = nil
            }
            if let expected = request.expectedDisk, latest != expected.bytes {
                if let latest {
                    // The artifact already exists with owner-only
                    // permissions; truncate it in place.
                    try? latest.write(to: displacedArtifact)
                }
                throw SaveError.diskChanged(
                    SaveArtifacts(displaced: displacedArtifact, newContent: newArtifact)
                )
            }

            guard renameatx_np(
                Self.atFDCWD,
                tempURL.path,
                Self.atFDCWD,
                destination.path,
                0
            ) == 0 else {
                throw SaveError.writeFailed("renameatx_np errno \(errno)")
            }
            try verify(
                destination,
                holds: request.data,
                artifacts: SaveArtifacts(
                    displaced: displacedArtifact,
                    newContent: newArtifact
                )
            )
            return SaveOutcome(
                snapshot: DiskSnapshot(bytes: request.data),
                artifacts: SaveArtifacts(
                    displaced: displacedArtifact,
                    newContent: newArtifact
                )
            )
        }

        throw SaveError.writeFailed("renameatx_np SWAP errno \(code)")
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
        to destination: URL,
        directory: URL,
        token: String,
        requestData: Data,
        artifact: URL
    ) throws -> URL? {
        let restoreURL = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).sonovo-restore-\(token)"
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
            // The restored file replaces the destination; it must carry the
            // same permissions, ACLs, and attributes as the file it
            // replaces, not freshly created defaults.
            try preserveAttributes(from: destination, to: restoreURL)
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
        guard let swappedOut = try? Data(contentsOf: restoreURL) else {
            // It cannot be inspected, so it must not be deleted: it may be
            // the only copy of a newer external version.
            return restoreURL
        }
        if swappedOut == requestData {
            try? FileManager.default.removeItem(at: restoreURL)
            return nil
        }

        do {
            try swappedOut.write(to: artifact)
            try? FileManager.default.removeItem(at: restoreURL)
            return nil
        } catch {
            return restoreURL
        }
    }

    /// Confirms the destination holds the bytes this save wrote.
    private func verify(
        _ destination: URL,
        holds expected: Data,
        artifacts: SaveArtifacts
    ) throws {
        guard let written = try? Data(contentsOf: destination),
              written == expected else {
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
