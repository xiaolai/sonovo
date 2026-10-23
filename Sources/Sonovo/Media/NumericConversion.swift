import Foundation

/// Numeric conversions at trust boundaries. Media and preference values can be
/// finite yet outside `Int`, and a raw `Int(_:)` conversion traps in Swift.
enum NumericConversion {
    /// Rounds a finite value and converts it, or returns nil when the rounded
    /// value is not representable as `Int`.
    static func int(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded())
    }

    /// A non-negative millisecond count for display. Invalid and negative
    /// input maps to zero; a value beyond `Int` saturates rather than trapping.
    static func milliseconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let value = (seconds * 1000).rounded()
        guard value.isFinite else { return 0 }
        return Int(exactly: value) ?? Int.max
    }
}
