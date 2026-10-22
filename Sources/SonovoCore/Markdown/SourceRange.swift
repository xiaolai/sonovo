/// A position in the canonical Markdown source.
///
/// Lines are 1-based. Columns and offsets count UTF-16 code units, matching
/// `NSRange`, `NSTextView`, and SwiftUI text APIs. A position always carries
/// the global UTF-16 offset so callers do not need a `SourceMap` to use it.
public struct SourcePosition: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The 1-based line number.
    public let line: Int

    /// The 0-based UTF-16 column within the line.
    public let column: Int

    /// The 0-based UTF-16 offset from the start of the canonical source.
    public let offset: Int

    public init(line: Int, column: Int, offset: Int) {
        precondition(line >= 1, "SourcePosition line is 1-based")
        precondition(column >= 0, "SourcePosition column is 0-based")
        precondition(offset >= 0, "SourcePosition offset is 0-based")
        self.line = line
        self.column = column
        self.offset = offset
    }

    public static func < (lhs: SourcePosition, rhs: SourcePosition) -> Bool {
        lhs.offset < rhs.offset
    }

    /// Positions are identified by their canonical offset. Keeping equality
    /// and hashing on the same field as `<` preserves the `Comparable` and
    /// `Hashable` contracts.
    public static func == (lhs: SourcePosition, rhs: SourcePosition) -> Bool {
        lhs.offset == rhs.offset
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(offset)
    }

    public var description: String {
        "\(line):\(column)"
    }
}

/// A half-open range in the canonical Markdown source.
///
/// The range is `[start, end)`. A node whose upstream position is unavailable
/// has no `SourceRange` at all; the code never synthesizes an "exact" range by
/// guessing.
public struct SourceRange: Hashable, Sendable, CustomStringConvertible {
    public let start: SourcePosition
    public let end: SourcePosition

    public init(start: SourcePosition, end: SourcePosition) {
        precondition(start <= end, "SourceRange start must not follow end")
        self.start = start
        self.end = end
    }

    /// The lower UTF-16 offset.
    public var lowerBound: Int { start.offset }

    /// The upper UTF-16 offset.
    public var upperBound: Int { end.offset }

    /// The number of UTF-16 code units in the range.
    public var length: Int { upperBound - lowerBound }

    /// Whether the range is empty.
    public var isEmpty: Bool { lowerBound == upperBound }

    /// The lines the range touches.
    ///
    /// A nonempty half-open range that ends at column zero has no character
    /// on the ending line.
    public var lineSpan: ClosedRange<Int> {
        let endLine: Int
        if !isEmpty, end.column == 0 {
            endLine = end.line - 1
        } else {
            endLine = end.line
        }
        return start.line...max(start.line, endLine)
    }

    /// Whether the range contains a UTF-16 offset.
    public func contains(offset: Int) -> Bool {
        offset >= lowerBound && offset < upperBound
    }

    /// Whether two ranges share at least one UTF-16 offset.
    ///
    /// An empty range contains no offsets, so it intersects nothing.
    public func intersects(_ other: SourceRange) -> Bool {
        guard !isEmpty, !other.isEmpty else { return false }
        return lowerBound < other.upperBound && other.lowerBound < upperBound
    }

    /// The range covering both ranges.
    public func union(_ other: SourceRange) -> SourceRange {
        SourceRange(
            start: min(start, other.start),
            end: max(end, other.end)
        )
    }

    public var description: String {
        "\(start)..<\(end)[\(lowerBound)..<\(upperBound)]"
    }
}
