import Foundation

/// One rendered block captured for source editing.
///
/// The projection is a range and the exact bytes the viewer displayed at that
/// range. A commit replaces those bytes and nothing else; if the document no
/// longer holds them, the commit refuses rather than editing whatever moved
/// into the range.
public struct MarkdownBlockProjection: Sendable, Equatable {
    public let range: Range<Int>
    public let expectedSlice: String

    public init(range: Range<Int>, expectedSlice: String) {
        self.range = range
        self.expectedSlice = expectedSlice
    }
}

public enum MarkdownBlockProjectionError: Error, Equatable, Sendable {
    /// The document no longer holds the block's bytes at its range.
    case staleBlock
    case invalidRange
}

public struct MarkdownBlockCommit: Sendable, Equatable {
    public let source: String
    /// The edited block's range in the new source, selected for the user.
    public let selection: Range<Int>
    public let actionName: String

    public init(
        source: String,
        selection: Range<Int>,
        actionName: String
    ) {
        self.source = source
        self.selection = selection
        self.actionName = actionName
    }
}

/// Reads and writes one block's source through its rendered range.
public enum MarkdownBlockProjector {
    /// The block's exact source, or nil when the range is not inside it.
    public static func slice(
        _ range: SourceRange,
        in source: String
    ) -> String? {
        let lower = range.lowerBound
        let upper = range.upperBound
        let ns = source as NSString
        guard lower >= 0, upper >= lower, upper <= ns.length else {
            return nil
        }
        return ns.substring(
            with: NSRange(location: lower, length: upper - lower)
        )
    }

    /// Replaces exactly the projection's range. Bytes outside it, including a
    /// trailing newline the range excludes, stay byte-identical.
    public static func commit(
        _ projection: MarkdownBlockProjection,
        replacement: String,
        in source: String
    ) throws -> MarkdownBlockCommit {
        let ns = source as NSString
        guard projection.range.lowerBound >= 0,
              projection.range.upperBound >= projection.range.lowerBound,
              projection.range.upperBound <= ns.length else {
            throw MarkdownBlockProjectionError.invalidRange
        }
        let current = ns.substring(
            with: NSRange(
                location: projection.range.lowerBound,
                length: projection.range.count
            )
        )
        // Compare UTF-16 code units, not Swift strings: String equality is
        // canonical equivalence, so U+00C5 and U+212B would pass a check
        // that is meant to prove the exact bytes are unchanged.
        guard current.utf16.elementsEqual(projection.expectedSlice.utf16)
        else {
            throw MarkdownBlockProjectionError.staleBlock
        }
        let newSource = ns.replacingCharacters(
            in: NSRange(
                location: projection.range.lowerBound,
                length: projection.range.count
            ),
            with: replacement
        )
        let start = projection.range.lowerBound
        let end = start + (replacement as NSString).length
        return MarkdownBlockCommit(
            source: newSource,
            selection: start..<end,
            actionName: "Edit Block"
        )
    }
}
