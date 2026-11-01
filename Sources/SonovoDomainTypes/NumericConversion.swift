import CoreGraphics
import Foundation

/// Numeric conversions at trust boundaries. Media and preference values can be
/// finite yet outside `Int`, and a raw `Int(_:)` conversion traps in Swift.
///
/// Every conversion from a floating-point value in this code base goes through
/// here. `Int(_:)` on `Double`/`CGFloat` traps on NaN, infinity, and anything
/// outside `Int`'s range — including `Double(Int.max)`, which rounds up to
/// 2^63 and cannot be converted back.
public enum NumericConversion {
    /// Rounds a finite value and converts it, or returns nil when the rounded
    /// value is not representable as `Int`.
    public static func int(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded())
    }

    public static func int(_ value: CGFloat) -> Int? {
        int(Double(value))
    }

    /// Truncates toward negative infinity, or returns nil when the result is
    /// not representable as `Int`.
    public static func floor(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded(.down))
    }

    /// Rounds up, or returns nil when the result is not representable as
    /// `Int`.
    public static func ceil(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded(.up))
    }

    /// Rounds and clamps to `range`. Non-finite input maps to the nearer
    /// bound: positive infinity to the upper bound, NaN and negative
    /// infinity to the lower bound.
    public static func clamped(
        _ value: Double,
        to range: ClosedRange<Int>
    ) -> Int {
        if value.isNaN { return range.lowerBound }
        if value <= Double(range.lowerBound) { return range.lowerBound }
        if value >= Double(range.upperBound) { return range.upperBound }
        return int(value) ?? range.lowerBound
    }

    /// A non-negative millisecond count for display. Invalid and negative
    /// input maps to zero; a value beyond `Int` saturates rather than trapping.
    public static func milliseconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let value = (seconds * 1000).rounded()
        guard value.isFinite else { return 0 }
        return Int(exactly: value) ?? Int.max
    }
}
