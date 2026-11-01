import Foundation

/// The autosave policy: one short idle delay with a hard ceiling.
public enum Autosave {
    public static let idleDelay: TimeInterval = 1.0
    public static let maxDelay: TimeInterval = 5.0

    /// The delay before the next autosave, or `nil` when nothing is pending.
    public static func delay(
        lastEdit: Date,
        firstPendingEdit: Date,
        now: Date
    ) -> TimeInterval? {
        guard now >= lastEdit else { return idleDelay }
        let byIdle = lastEdit.addingTimeInterval(idleDelay)
        let byCeiling = firstPendingEdit.addingTimeInterval(maxDelay)
        let due = min(byIdle, byCeiling)
        return max(0, due.timeIntervalSince(now))
    }
}

/// Why a close could not finish.
public enum CloseBlocker: Sendable, Equatable {
    case untitled
    case saveFailed(String)
}

/// The result of a close/quit flush.
public enum CloseOutcome: Sendable, Equatable {
    case closed
    case needsDecision(CloseBlocker)
}
