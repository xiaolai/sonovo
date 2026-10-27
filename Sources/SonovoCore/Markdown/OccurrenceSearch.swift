import Foundation

/// Exact, grapheme-aligned occurrence search for the placement commands.
///
/// Nothing here edits text: every function returns a caret set whose ranges
/// name occurrences of one query in the same source. A match whose bound
/// would split a composed character sequence is skipped, because a caret
/// cannot name such a position.
public enum OccurrenceSearch {
    public enum Failure: Error, Equatable, Sendable {
        case noQuery
        case noMoreOccurrences
        case exceedsCaretLimit(Int)
    }

    /// The text the primary names: its selection, or the word under a bare
    /// caret. A caret in whitespace or punctuation names nothing.
    public static func queryRange(
        for caret: MultiCursorSelection.Caret,
        in source: String
    ) -> Range<Int>? {
        if caret.isSelection {
            return caret.range
        }
        return wordRange(at: caret.active, in: source)
    }

    /// The run of non-boundary characters around `offset`, using the same
    /// word rule as Option+arrow. A caret at a word's end names the word
    /// before it.
    public static func wordRange(
        at offset: Int,
        in source: String
    ) -> Range<Int>? {
        let ns = source as NSString
        guard offset >= 0, offset <= ns.length else { return nil }
        // One composed character sequence per step, classified by its first
        // code unit — the same rule as Option+arrow. Testing single UTF-16
        // units let a combining mark answer for its base, so "-" + U+0301
        // produced a range that split the cluster.
        func isWord(_ cluster: NSRange) -> Bool {
            !MarkdownLineEditor.isWordBoundary(ns.character(at: cluster.location))
        }
        let lower: Int
        if offset < ns.length,
           isWord(ns.rangeOfComposedCharacterSequence(at: offset)) {
            var start = ns.rangeOfComposedCharacterSequence(at: offset).location
            while start > 0,
                  isWord(ns.rangeOfComposedCharacterSequence(at: start - 1)) {
                start = ns.rangeOfComposedCharacterSequence(at: start - 1)
                    .location
            }
            lower = start
        } else if offset > 0,
                  isWord(ns.rangeOfComposedCharacterSequence(at: offset - 1)) {
            var start = ns.rangeOfComposedCharacterSequence(at: offset - 1)
                .location
            while start > 0,
                  isWord(ns.rangeOfComposedCharacterSequence(at: start - 1)) {
                start = ns.rangeOfComposedCharacterSequence(at: start - 1)
                    .location
            }
            lower = start
        } else {
            return nil
        }
        var upper = offset
        while upper < ns.length {
            let cluster = ns.rangeOfComposedCharacterSequence(at: upper)
            guard isWord(cluster) else { break }
            upper = cluster.upperBound
        }
        guard upper > lower,
              let range = try? validated(lower..<upper, in: source) else {
            return nil
        }
        return range
    }

    /// Every exact, case-sensitive occurrence of `text`, left to right and
    /// non-overlapping, up to `limit` matches. Overlapping candidates are
    /// intentionally not produced: two carets cannot cover overlapping text.
    public static func occurrences(
        of text: String,
        in source: String,
        limit: Int = MarkdownLimits.maxCarets
    ) -> [Range<Int>] {
        guard !text.isEmpty, limit > 0 else { return [] }
        let ns = source as NSString
        let queryLength = (text as NSString).length
        guard queryLength > 0, queryLength <= ns.length else { return [] }
        var result: [Range<Int>] = []
        var searchStart = 0
        while searchStart <= ns.length - queryLength, result.count < limit {
            let found = ns.range(
                of: text,
                options: [.literal],
                range: NSRange(
                    location: searchStart,
                    length: ns.length - searchStart
                )
            )
            guard found.location != NSNotFound else { break }
            let range = found.location..<(found.location + found.length)
            if (try? validated(range, in: source)) != nil {
                result.append(range)
                searchStart = range.upperBound
            } else {
                // A later occurrence can still start one code unit along.
                searchStart = found.location + 1
            }
        }
        return result
    }

    /// The first occurrence at or after `offset` that no existing caret
    /// already names. The caller wraps by calling again from zero. A
    /// candidate that overlaps or touches a caret's position is skipped:
    /// adding it would displace that caret instead of adding to the set.
    public static func nextOccurrence(
        of text: String,
        in source: String,
        after offset: Int,
        excluding existing: [Range<Int>]
    ) -> Range<Int>? {
        let ns = source as NSString
        let queryLength = (text as NSString).length
        guard queryLength > 0, queryLength <= ns.length else { return nil }
        var searchStart = min(max(0, offset), ns.length)
        while searchStart <= ns.length - queryLength {
            let found = ns.range(
                of: text,
                options: [.literal],
                range: NSRange(
                    location: searchStart,
                    length: ns.length - searchStart
                )
            )
            guard found.location != NSNotFound else { return nil }
            let range = found.location..<(found.location + found.length)
            if (try? validated(range, in: source)) != nil,
               !existing.contains(where: {
                   MultiCursorSelection.conflicts($0, range)
               }) {
                return range
            }
            searchStart = found.location + 1
        }
        return nil
    }

    /// Adds the next occurrence after the last caret, wrapping once. A bare
    /// primary caret first becomes its word, so one command selects the word
    /// and its next occurrence together.
    public static func addingNext(
        to selection: MultiCursorSelection,
        in source: String
    ) throws -> MultiCursorSelection {
        let primary = selection.primary
        guard let query = queryText(for: primary, in: source) else {
            throw Failure.noQuery
        }
        let queryRange = query.range
        let text = query.text
        var base = selection
        if !primary.isSelection {
            var carets = selection.carets
            carets[selection.primaryIndex] = MultiCursorSelection.Caret(
                anchor: queryRange.lowerBound,
                active: queryRange.upperBound
            )
            base = try MultiCursorSelection(
                carets,
                primary: selection.primaryIndex,
                source: source
            )
        }
        let existing = base.ranges
        let last = existing.map(\.upperBound).max() ?? 0
        guard let candidate = nextOccurrence(
            of: text,
            in: source,
            after: last,
            excluding: existing
        ) ?? nextOccurrence(
            of: text,
            in: source,
            after: 0,
            excluding: existing
        ) else {
            throw Failure.noMoreOccurrences
        }
        return try base.adding(
            anchor: candidate.lowerBound,
            active: candidate.upperBound,
            source: source
        )
    }

    /// Every non-overlapping occurrence of the primary's text as one caret
    /// set. Refuses the whole command, changing nothing, when there are more
    /// occurrences than carets allowed. A selection that is itself an
    /// occurrence keeps the primary; otherwise the occurrence containing its
    /// start takes it, so the native selection stays near where the user was
    /// working. An overlapping selection (1..<3 of "aaaa", naming "aa")
    /// cannot be a caret: the enumeration is the plan's non-overlapping one,
    /// which does not contain it.
    public static func selectingAll(
        in selection: MultiCursorSelection,
        source: String,
        maximumCarets: Int = MarkdownLimits.maxCarets
    ) throws -> MultiCursorSelection {
        let primary = selection.primary
        guard let query = queryText(for: primary, in: source) else {
            throw Failure.noQuery
        }
        let queryRange = query.range
        let text = query.text
        // One past the cap is enough to detect "too many" without enumerating
        // the rest; clamped so a caller passing Int.max cannot trap.
        let probeLimit = maximumCarets == .max ? Int.max : maximumCarets + 1
        let all = occurrences(of: text, in: source, limit: probeLimit)
        guard all.count <= maximumCarets else {
            throw Failure.exceedsCaretLimit(maximumCarets)
        }
        guard !all.isEmpty else { throw Failure.noMoreOccurrences }
        let carets = all.map {
            MultiCursorSelection.Caret(
                anchor: $0.lowerBound,
                active: $0.upperBound
            )
        }
        let primaryIndex = all.firstIndex { $0 == queryRange }
            ?? all.firstIndex { $0.contains(queryRange.lowerBound) }
            ?? 0
        return try MultiCursorSelection(
            carets,
            primary: primaryIndex,
            source: source
        )
    }

    // MARK: - Helpers

    /// The primary's query as text, or nil when the selection names a
    /// position that does not exist in `source` — a caret set built on
    /// another text. Rejecting it here keeps a stale range away from
    /// `NSString.substring`, which raises an Objective-C exception.
    private static func queryText(
        for caret: MultiCursorSelection.Caret,
        in source: String
    ) -> (range: Range<Int>, text: String)? {
        // Validate the caret itself first. A bare caret inside a cluster of
        // this source would otherwise be widened to the whole word, and the
        // derived range would validate even though the named position does
        // not exist — the stale selection accepted instead of refused.
        guard (try? MultiCursorSelection.validate(caret.anchor, in: source))
                != nil,
              (try? MultiCursorSelection.validate(caret.active, in: source))
                != nil,
              let range = queryRange(for: caret, in: source),
              (try? validated(range, in: source)) != nil else {
            return nil
        }
        return (range, substring(range, of: source))
    }

    private static func substring(_ range: Range<Int>, of source: String) -> String {
        (source as NSString).substring(
            with: NSRange(location: range.lowerBound, length: range.count)
        )
    }

    private static func validated(
        _ range: Range<Int>,
        in source: String
    ) throws -> Range<Int> {
        try MultiCursorSelection.validate(range.lowerBound, in: source)
        try MultiCursorSelection.validate(range.upperBound, in: source)
        return range
    }
}
