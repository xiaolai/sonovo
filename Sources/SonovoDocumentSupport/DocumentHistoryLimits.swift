import Foundation

/// Shared bounds for in-memory editing history.
public enum DocumentHistoryLimits {
    /// Each undo step retains a complete previous source. Bound the count so a
    /// long editing session cannot retain an unbounded number of full copies.
    public static let undoLevels = 20

    /// Reject a single replacement larger than the Markdown read cap. A paste
    /// larger than this is not an edit of the open document.
    public static let maxReplacementBytes = 16 * 1024 * 1024
}
