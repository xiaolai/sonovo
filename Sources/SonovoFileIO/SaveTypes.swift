import Foundation

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
