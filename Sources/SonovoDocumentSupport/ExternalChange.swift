import SonovoFileIO

/// The disk changed underneath a dirty document.
public struct ExternalConflict: Sendable, Equatable {
    public init(diskSnapshot: DiskSnapshot, diskText: String) {
        self.diskSnapshot = diskSnapshot
        self.diskText = diskText
    }

    public let diskSnapshot: DiskSnapshot
    public let diskText: String
}

/// What an external-change check found.
public enum ExternalChange: Sendable, Equatable {
    case none
    case adopted
    case deleted
    case conflict(ExternalConflict)
}

/// A resolved external-change decision.
public enum ExternalResolution: Sendable, Equatable {
    case reload
    case keepLocal
}
