import Foundation

/// Per-save snapshot policy for version history.
public struct MarkdownHistoryPolicy: Sendable, Equatable {
    public enum SaveKind: String, Sendable, Equatable {
        case autosave
        case explicit
        case restore
    }

    /// Consecutive autosaves inside this window keep one snapshot.
    public var mergeWindow: TimeInterval
    public var maximumCount: Int
    public var maximumAge: TimeInterval

    public init(
        mergeWindow: TimeInterval = 60,
        maximumCount: Int = 100,
        maximumAge: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.mergeWindow = max(0, mergeWindow)
        self.maximumCount = max(1, maximumCount)
        self.maximumAge = max(0, maximumAge)
    }
}

/// One observed A→B transition. The queue is observational: A→B→C collapses
/// to a single baseline→C pair, and the UI must say so.
public struct MarkdownReviewTransition: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let relativePath: String
    public let beforeID: UUID
    public var afterID: UUID
    public let beforeSha: String
    public var afterSha: String
    public var observedAt: Date
    /// `nil` while pending; "kept" or "reverted" after a decision.
    public var decision: String?

    public init(
        id: UUID,
        relativePath: String,
        beforeID: UUID,
        afterID: UUID,
        beforeSha: String,
        afterSha: String,
        observedAt: Date,
        decision: String?
    ) {
        self.id = id
        self.relativePath = relativePath
        self.beforeID = beforeID
        self.afterID = afterID
        self.beforeSha = beforeSha
        self.afterSha = afterSha
        self.observedAt = observedAt
        self.decision = decision
    }
}

public enum MarkdownReviewDecision: Sendable, Equatable {
    case kept
    /// A's exact bytes; the caller restores them through the CAS path.
    case revert(Data)
    case staleDisk
    case alreadyDecided
    case evidenceUnavailable
}
