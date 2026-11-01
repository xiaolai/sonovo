import Foundation

/// The selection model above `NSTextView`: an ordered set of carets, one of
/// which is primary and mirrors the native selection.
///
/// Offsets are UTF-16, matching `NSRange`. Every offset must be a grapheme
/// cluster boundary, not merely a valid scalar boundary: splitting `e` plus a
/// combining accent or a ZWJ emoji is refused. The type is a value; every
/// mutation returns a new selection so source and selection cannot drift.
public struct MultiCursorSelection: Sendable, Equatable {
    /// One caret. `anchor` stays where the caret started; `active` moves.
    /// The visible range is derived, so Shift+arrow can extend and contract
    /// from either direction.
    public struct Caret: Sendable, Equatable, Comparable {
        public let anchor: Int
        public var active: Int
        public var goalColumn: Int?

        public init(anchor: Int, active: Int, goalColumn: Int? = nil) {
            self.anchor = anchor
            self.active = active
            self.goalColumn = goalColumn
        }

        /// The source range the caret covers; zero-length for a caret.
        public var range: Range<Int> {
            min(anchor, active)..<max(anchor, active)
        }

        public var isSelection: Bool { anchor != active }

        public static func < (lhs: Caret, rhs: Caret) -> Bool {
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            if lhs.range.upperBound != rhs.range.upperBound {
                return lhs.range.upperBound < rhs.range.upperBound
            }
            return lhs.anchor < rhs.anchor
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case outOfBounds(Int)
        case graphemeSplit(Int)
        case overlapping
        case tooManyCarets(Int)
        case invalidPrimary(Int)
    }

    public private(set) var carets: [Caret]
    public private(set) var primaryIndex: Int

    public var count: Int { carets.count }
    public var primary: Caret { carets[primaryIndex] }
    public var primaryRange: Range<Int> { primary.range }
    public var ranges: [Range<Int>] { carets.map(\.range) }

    /// Normalises per invariants 1–8: validates every offset, sorts, merges
    /// exact duplicates (the primary's direction wins), and refuses overlap
    /// between distinct ranges. Placement resolves overlap by replacement;
    /// an initial value with two different overlapping ranges is a caller
    /// error.
    public init(
        _ input: [Caret],
        primary: Int,
        source: String,
        maximumCarets: Int = MarkdownLimits.maxCarets
    ) throws {
        guard !input.isEmpty,
              primary >= 0,
              primary < input.count else {
            throw Failure.invalidPrimary(primary)
        }
        for caret in input {
            try Self.validate(caret.anchor, in: source)
            try Self.validate(caret.active, in: source)
        }
        let ordered = input.enumerated()
            .map { (index: $0.offset, caret: $0.element) }
            .sorted { $0.caret < $1.caret }
        var merged: [(caret: Caret, wasPrimary: Bool)] = []
        for entry in ordered {
            let isPrimary = entry.index == primary
            if let last = merged.last, last.caret.range == entry.caret.range {
                if isPrimary {
                    merged[merged.count - 1] = (entry.caret, true)
                }
                continue
            }
            merged.append((entry.caret, isPrimary))
        }
        for pair in zip(merged, merged.dropFirst())
        where Self.conflicts(pair.0.caret.range, pair.1.caret.range) {
            throw Failure.overlapping
        }
        guard merged.count <= maximumCarets else {
            throw Failure.tooManyCarets(merged.count)
        }
        guard let primaryPosition = merged.firstIndex(where: \.wasPrimary)
        else {
            throw Failure.invalidPrimary(primary)
        }
        self.carets = merged.map(\.caret)
        self.primaryIndex = primaryPosition
    }

    public init(
        caret: Int,
        source: String
    ) throws {
        try self.init(
            [Caret(anchor: caret, active: caret)],
            primary: 0,
            source: source
        )
    }

    // MARK: - Placement

    /// Adds a caret and makes it primary. An exact duplicate is toggled off;
    /// the sole caret cannot be toggled off (invariant 8). A new range that
    /// overlaps existing ranges removes all of them and is inserted.
    public func adding(
        anchor: Int,
        active: Int,
        source: String
    ) throws -> MultiCursorSelection {
        try Self.validate(anchor, in: source)
        try Self.validate(active, in: source)
        let added = Caret(anchor: anchor, active: active)
        if let duplicate = carets.firstIndex(where: {
            $0.range == added.range
        }) {
            return try removing(at: duplicate, source: source)
        }
        var kept = carets.filter { !Self.conflicts($0.range, added.range) }
        kept.append(added)
        return try MultiCursorSelection(
            kept,
            primary: kept.count - 1,
            source: source
        )
    }

    /// Removes a caret. The sole caret stays (invariant 8). Removing the
    /// primary promotes the caret that takes its place, or the previous one.
    public func removing(
        at index: Int,
        source: String
    ) throws -> MultiCursorSelection {
        guard carets.count > 1, index >= 0, index < carets.count else {
            return self
        }
        var kept = carets
        kept.remove(at: index)
        let promoted: Int
        if index == primaryIndex {
            promoted = min(index, kept.count - 1)
        } else {
            promoted = primaryIndex > index ? primaryIndex - 1 : primaryIndex
        }
        return try MultiCursorSelection(
            kept,
            primary: promoted,
            source: source
        )
    }

    /// Collapses the set to one zero-length caret at `offset`.
    public func collapsing(
        to offset: Int,
        source: String
    ) throws -> MultiCursorSelection {
        try MultiCursorSelection(
            [Caret(anchor: offset, active: offset)],
            primary: 0,
            source: source
        )
    }

    /// Moves one caret's active end, keeping its anchor so Shift+arrow can
    /// extend and contract. A moved range that overlaps another caret
    /// replaces it; a caret whose primary was replaced by the move promotes
    /// the moved caret.
    public func moved(
        at index: Int,
        to active: Int,
        goalColumn: Int?,
        source: String
    ) throws -> MultiCursorSelection {
        guard index >= 0, index < carets.count else {
            throw Failure.invalidPrimary(index)
        }
        try Self.validate(active, in: source)
        var updated = carets
        updated[index].active = active
        updated[index].goalColumn = goalColumn
        let moved = updated[index]
        let primaryAfter: Range<Int>? = index == primaryIndex
            ? moved.range
            : carets[primaryIndex].range
        let kept = updated.enumerated().compactMap { position, caret in
            position == index || !Self.conflicts(caret.range, moved.range)
                ? caret
                : nil
        }
        let primary = kept.firstIndex { $0.range == primaryAfter }
            ?? kept.firstIndex { $0.range == moved.range }
            ?? 0
        return try MultiCursorSelection(
            kept,
            primary: primary,
            source: source
        )
    }

    // MARK: - Composition translation

    /// Moves the primary to `newPrimary`, keeping every secondary that does
    /// not conflict with it.
    ///
    /// Primary-only navigation (Find, review markers, Edit in Source) moves
    /// the native selection without touching the caret set. The model must
    /// still follow, or the next edit lands at the old primary while the user
    /// looks at a different caret. A secondary the new primary would collide
    /// with is dropped, not a reason to refuse the move.
    public func movingPrimary(
        to newPrimary: Caret,
        source: String
    ) throws -> MultiCursorSelection {
        var kept = carets.enumerated()
            .filter { $0.offset != primaryIndex }
            .map(\.element)
        kept.removeAll { Self.conflicts($0.range, newPrimary.range) }
        kept.append(newPrimary)
        return try MultiCursorSelection(
            kept,
            primary: kept.count - 1,
            source: source
        )
    }

    /// Maps the set through a replacement that turned the preimage span
    /// `replaced` into the postimage range `inserted` — an input-method
    /// commit or cancellation, always at the primary.
    ///
    /// The primary is whatever the native selection now says: AppKit owns
    /// it. A secondary whose range intersects the replaced span is dropped;
    /// one after it shifts by the length delta; one before it stays. A
    /// translated secondary that would conflict with the new primary is
    /// dropped rather than refusing the whole translation. When the result
    /// is a single caret, the caller leaves multi-cursor mode.
    public func translated(
        replacing replaced: Range<Int>,
        with inserted: Range<Int>,
        primary newPrimary: Caret,
        source: String
    ) throws -> MultiCursorSelection {
        let delta = inserted.count - replaced.count
        var kept: [Caret] = []
        for (index, caret) in carets.enumerated() where index != primaryIndex {
            if caret.range.isEmpty {
                let offset = caret.anchor
                guard offset > replaced.lowerBound else {
                    // Before the replacement, including an insertion point
                    // exactly at its start: the caret stays where it is.
                    kept.append(caret)
                    continue
                }
                guard offset >= replaced.upperBound else {
                    // Inside the replaced text: the position is gone.
                    continue
                }
                kept.append(
                    Caret(
                        anchor: caret.anchor + delta,
                        active: caret.active + delta,
                        goalColumn: caret.goalColumn
                    )
                )
                continue
            }
            if caret.range.overlaps(replaced) {
                continue
            }
            if caret.range.lowerBound >= replaced.upperBound,
               caret.range.lowerBound > replaced.lowerBound {
                kept.append(
                    Caret(
                        anchor: caret.anchor + delta,
                        active: caret.active + delta,
                        goalColumn: caret.goalColumn
                    )
                )
            } else {
                kept.append(caret)
            }
        }
        kept.removeAll { Self.conflicts($0.range, newPrimary.range) }
        kept.append(newPrimary)
        return try MultiCursorSelection(
            kept,
            primary: kept.count - 1,
            source: source
        )
    }

    // MARK: - Validation

    /// Offsets must exist and start a composed character sequence. The end of
    /// the source is always a boundary.
    static func validate(_ offset: Int, in source: String) throws {
        let ns = source as NSString
        guard offset >= 0, offset <= ns.length else {
            throw Failure.outOfBounds(offset)
        }
        guard offset < ns.length else { return }
        let cluster = ns.rangeOfComposedCharacterSequence(at: offset)
        guard cluster.location == offset else {
            throw Failure.graphemeSplit(offset)
        }
    }

    /// Whether two carets cannot coexist. Two non-empty ranges overlap in
    /// the half-open sense; a zero-length caret conflicts when it sits
    /// inside a non-empty range, because a replacement of that range would
    /// consume the position the caret names.
    static func conflicts(
        _ lhs: Range<Int>,
        _ rhs: Range<Int>
    ) -> Bool {
        if lhs.isEmpty, rhs.isEmpty {
            return lhs.lowerBound == rhs.lowerBound
        }
        if lhs.isEmpty {
            return rhs.contains(lhs.lowerBound)
        }
        if rhs.isEmpty {
            return lhs.contains(rhs.lowerBound)
        }
        return lhs.lowerBound < rhs.upperBound
            && rhs.lowerBound < lhs.upperBound
    }
}
