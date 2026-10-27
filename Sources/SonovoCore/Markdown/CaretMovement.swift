import Foundation

/// One visual line of the laid-out source, in UTF-16 offsets. The range
/// excludes the line terminator, so a caret at the end of the line has a
/// column equal to the visible length.
public struct CaretDisplayLine: Sendable, Equatable {
    public let range: Range<Int>

    public init(range: Range<Int>) {
        self.range = range
    }

    /// The caret column of `offset` on this line, clamped into the range.
    public func column(of offset: Int) -> Int {
        min(max(offset, range.lowerBound), range.upperBound)
            - range.lowerBound
    }

    /// The offset at `column`, clamped to the line and snapped down to a
    /// composed-character boundary.
    public func offset(at column: Int, in source: String) -> Int {
        let clamped = range.lowerBound + min(max(0, column), range.count)
        return CaretMovement.snapDown(clamped, in: source)
    }
}

/// The display lines the vertical motion walks. The source editor supplies
/// TextKit 2's layout; tests supply a deterministic table.
public protocol CaretLineProvider {
    func line(containing offset: Int) -> CaretDisplayLine?
    func line(above line: CaretDisplayLine) -> CaretDisplayLine?
    func line(below line: CaretDisplayLine) -> CaretDisplayLine?
}

/// Selection-only motion. Nothing here edits text: every function returns a
/// new caret set whose offsets are grapheme boundaries in the same source.
///
/// Horizontal units follow the same UTF-16 and word-boundary rules as
/// `MarkdownLineEditor`. Vertical motion walks display lines through a
/// provider and keeps a per-caret column across consecutive vertical moves;
/// horizontal motion clears it.
public enum CaretMovement {
    public enum Direction: Sendable {
        case backward
        case forward
    }

    public enum Unit: Sendable {
        case grapheme
        case word
        case line
        case document
    }

    public enum Vertical: Sendable {
        case up
        case down
    }

    /// Moves every caret by one `unit`. Shift-style extension keeps each
    /// caret's own anchor; otherwise the caret collapses at its target.
    public static func horizontal(
        _ selection: MultiCursorSelection,
        in source: String,
        direction: Direction,
        unit: Unit,
        extending: Bool
    ) throws -> MultiCursorSelection {
        try validate(selection, in: source)
        let table = unit == .line ? LineTable(source: source) : nil
        let moved = selection.carets.enumerated().map { index, caret in
            let target = offset(
                from: caret.active,
                in: source,
                direction: direction,
                unit: unit,
                table: table
            )
            let anchor = extending ? caret.anchor : target
            return (
                caret: MultiCursorSelection.Caret(
                    anchor: anchor,
                    active: target
                ),
                wasPrimary: index == selection.primaryIndex
            )
        }
        return try assemble(moved, in: source)
    }

    /// Moves every caret to the same goal column on the adjacent display
    /// line. The goal is captured from the caret's own line the first time
    /// and survives a shorter line, so Up returns to the starting column.
    public static func vertical(
        _ selection: MultiCursorSelection,
        in source: String,
        direction: Vertical,
        extending: Bool,
        lines: any CaretLineProvider
    ) throws -> MultiCursorSelection {
        try validate(selection, in: source)
        let moved = selection.carets.enumerated().map { index, caret in
            guard let current = lines.line(containing: caret.active) else {
                return (caret: caret, wasPrimary: index == selection.primaryIndex)
            }
            let goal = caret.goalColumn ?? current.column(of: caret.active)
            let neighbor = direction == .up
                ? lines.line(above: current)
                : lines.line(below: current)
            guard let neighbor else {
                // No line in that direction: the caret stays put, but a
                // non-extending move still collapses the selection the way
                // the neighbor branch does. Keeping it meant Down on the last
                // line left a selection that the next keystroke replaced.
                return (
                    caret: MultiCursorSelection.Caret(
                        anchor: extending ? caret.anchor : caret.active,
                        active: caret.active,
                        goalColumn: goal
                    ),
                    wasPrimary: index == selection.primaryIndex
                )
            }
            let target = neighbor.offset(at: goal, in: source)
            let anchor = extending ? caret.anchor : target
            return (
                caret: MultiCursorSelection.Caret(
                    anchor: anchor,
                    active: target,
                    goalColumn: goal
                ),
                wasPrimary: index == selection.primaryIndex
            )
        }
        return try assemble(moved, in: source)
    }

    /// Refuses a caret set built against another source before any offset is
    /// used to index this one. `NSString.rangeOfComposedCharacterSequence`
    /// raises an Objective-C exception for an out-of-bounds offset, so the
    /// check must come first; a caret inside a cluster is refused for the
    /// same reason a placement there would be.
    private static func validate(
        _ selection: MultiCursorSelection,
        in source: String
    ) throws {
        for caret in selection.carets {
            try MultiCursorSelection.validate(caret.anchor, in: source)
            try MultiCursorSelection.validate(caret.active, in: source)
        }
    }

    // MARK: - Offset arithmetic

    static func offset(
        from start: Int,
        in source: String,
        direction: Direction,
        unit: Unit,
        table: LineTable?
    ) -> Int {
        let ns = source as NSString
        let length = ns.length
        switch unit {
        case .grapheme:
            if direction == .forward {
                guard start < length else { return length }
                return ns.rangeOfComposedCharacterSequence(at: start)
                    .upperBound
            }
            guard start > 0 else { return 0 }
            return ns.rangeOfComposedCharacterSequence(at: start - 1)
                .lowerBound
        case .word:
            return wordOffset(
                from: start,
                in: ns,
                direction: direction
            )
        case .line:
            guard let table else { return start }
            return direction == .forward
                ? lineEnd(of: start, in: table)
                : lineStart(of: start, in: table)
        case .document:
            return direction == .forward ? length : 0
        }
    }

    private static func wordOffset(
        from start: Int,
        in ns: NSString,
        direction: Direction
    ) -> Int {
        let length = ns.length
        var index = start
        // Classify one composed character sequence per step. Testing single
        // UTF-16 units split a boundary character from a following combining
        // mark ("-" + U+0301): backward motion landed inside the cluster and
        // the caret set then refused the move, while forward motion could
        // stop without advancing.
        if direction == .forward {
            while index < length {
                let cluster = ns.rangeOfComposedCharacterSequence(at: index)
                guard !isBoundaryCluster(cluster, in: ns) else { break }
                index = cluster.upperBound
            }
            while index < length {
                let cluster = ns.rangeOfComposedCharacterSequence(at: index)
                guard isBoundaryCluster(cluster, in: ns) else { break }
                index = cluster.upperBound
            }
            return snapDown(index, in: ns)
        }
        while index > 0 {
            let cluster = ns.rangeOfComposedCharacterSequence(at: index - 1)
            guard isBoundaryCluster(cluster, in: ns) else { break }
            index = cluster.location
        }
        while index > 0 {
            let cluster = ns.rangeOfComposedCharacterSequence(at: index - 1)
            guard !isBoundaryCluster(cluster, in: ns) else { break }
            index = cluster.location
        }
        return index
    }

    /// A cluster is a word boundary when its first code unit is one. The
    /// classification is per cluster, so a combining mark can never decide
    /// the class of the character it belongs to.
    private static func isBoundaryCluster(
        _ cluster: NSRange,
        in ns: NSString
    ) -> Bool {
        MarkdownLineEditor.isWordBoundary(ns.character(at: cluster.location))
    }

    private static func lineStart(of offset: Int, in table: LineTable) -> Int {
        table.lineStart(containing: offset)
    }

    private static func lineEnd(of offset: Int, in table: LineTable) -> Int {
        table.lineEnd(containing: offset)
    }

    /// Snaps an offset down to the start of its composed character sequence.
    static func snapDown(_ offset: Int, in source: String) -> Int {
        snapDown(offset, in: source as NSString)
    }

    private static func snapDown(_ offset: Int, in ns: NSString) -> Int {
        guard offset > 0, offset < ns.length else {
            return min(max(0, offset), ns.length)
        }
        return ns.rangeOfComposedCharacterSequence(at: offset).location
    }

    /// Builds the new set. The primary caret wins any overlap the move
    /// creates; a secondary that collides with an earlier kept range is
    /// dropped, the same rule placement uses.
    private static func assemble(
        _ moved: [(caret: MultiCursorSelection.Caret, wasPrimary: Bool)],
        in source: String
    ) throws -> MultiCursorSelection {
        let ordered = moved.enumerated().sorted { lhs, rhs in
            if lhs.element.wasPrimary != rhs.element.wasPrimary {
                return lhs.element.wasPrimary
            }
            return lhs.element.caret < rhs.element.caret
        }
        var kept: [(caret: MultiCursorSelection.Caret, wasPrimary: Bool)] = []
        for entry in ordered {
            if kept.contains(where: {
                MultiCursorSelection.conflicts(
                    $0.caret.range,
                    entry.element.caret.range
                )
            }) {
                continue
            }
            kept.append((entry.element.caret, entry.element.wasPrimary))
        }
        kept.sort { $0.caret < $1.caret }
        guard let primary = kept.firstIndex(where: \.wasPrimary) else {
            throw MultiCursorSelection.Failure.invalidPrimary(0)
        }
        return try MultiCursorSelection(
            kept.map(\.caret),
            primary: primary,
            source: source
        )
    }
}
