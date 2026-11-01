import Foundation

/// A table captured for the grid editor.
///
/// The snapshot keeps the table's block range and its exact block text. A
/// commit first proves the block is still there, byte for byte; a document
/// that moved the table refuses instead of editing whatever now occupies the
/// old offsets. The table scanner remains the model: every cell carries its
/// own source range.
public struct MarkdownTableSnapshot: Sendable, Equatable {
    public let table: MarkdownTable
    public let blockRange: Range<Int>
    public let blockText: String

    public init(table: MarkdownTable) {
        self.table = table
        self.blockRange = table.range.lowerBound..<table.range.upperBound
        self.blockText = table.sourceText
    }

    /// Header row plus body rows.
    public var rowCount: Int { table.body.count + 1 }
    public var columnCount: Int { table.header.cells.count }

    /// The authored cell at this position. A short body row has no cell here;
    /// the grid shows it empty and refuses to write it.
    public func cell(row: Int, column: Int) -> MarkdownTable.Cell? {
        guard row >= 0, column >= 0 else { return nil }
        let cells: [MarkdownTable.Cell]
        if row == 0 {
            cells = table.header.cells
        } else {
            guard row - 1 < table.body.count else { return nil }
            cells = table.body[row - 1].cells
        }
        guard column < cells.count else { return nil }
        return cells[column]
    }

    public func content(row: Int, column: Int) -> String? {
        cell(row: row, column: column)?.content
    }

    public func alignment(column: Int) -> TableBlock.Alignment? {
        guard column >= 0, column < table.alignments.count else {
            return nil
        }
        return table.alignments[column]
    }

    /// True only when the source still holds this exact block at this exact
    /// range and the scanner still reads a table there.
    public func isCurrent(in source: String) -> Bool {
        let ns = source as NSString
        guard blockRange.lowerBound >= 0,
              blockRange.upperBound <= ns.length else {
            return false
        }
        let slice = ns.substring(
            with: NSRange(
                location: blockRange.lowerBound,
                length: blockRange.count
            )
        )
        guard slice == blockText,
              let current = MarkdownTableScanner.table(
                  at: blockRange.lowerBound,
                  in: source
              ) else {
            return false
        }
        return current.range.lowerBound == blockRange.lowerBound
            && current.range.upperBound == blockRange.upperBound
    }
}

public enum MarkdownTableGridError: Error, Equatable, Sendable {
    case noTable
    case invalidTable
    /// The table moved or changed since the grid captured it.
    case staleTable
    case unknownCell
    case refused(MarkdownTableRefusal)
    case notApplicable
}

/// One grid commit as a complete replacement source, ready for the editor's
/// ordinary command path (one undo group, one document revision).
public struct MarkdownTableGridEdit: Sendable, Equatable {
    public let source: String
    public let selection: Range<Int>
    public let actionName: String
    /// Where the table starts in `source`, so the grid can refresh.
    public let blockRange: Range<Int>

    public init(
        source: String,
        selection: Range<Int>,
        actionName: String,
        blockRange: Range<Int>
    ) {
        self.source = source
        self.selection = selection
        self.actionName = actionName
        self.blockRange = blockRange
    }
}

/// The grid editor's model over canonical source.
///
/// It never owns a second document: every commit replaces exactly one cell's
/// source range (or delegates a structural command to `MarkdownTableEditor`)
/// and returns the complete new source for the editor to apply once.
public enum MarkdownTableGrid {
    public static func snapshot(
        at offset: Int,
        in source: String
    ) -> MarkdownTableSnapshot? {
        guard let table = MarkdownTableScanner.table(at: offset, in: source),
              table.isValid else {
            return nil
        }
        return MarkdownTableSnapshot(table: table)
    }

    /// Finds the same table again after the document changed elsewhere. The
    /// block text must occur exactly once.
    public static func relocate(
        _ snapshot: MarkdownTableSnapshot,
        in source: String
    ) -> MarkdownTableSnapshot? {
        let ns = source as NSString
        var matches: [Int] = []
        var start = 0
        while start <= ns.length {
            let found = ns.range(
                of: snapshot.blockText,
                options: [],
                range: NSRange(location: start, length: ns.length - start)
            )
            if found.location == NSNotFound { break }
            if let table = MarkdownTableScanner.table(
                at: found.location,
                in: source
            ), table.range.lowerBound == found.location,
            // The block must have exactly the old extent: a larger table
            // that merely starts with the old text is a different table.
            table.range.upperBound == found.location
                + (snapshot.blockText as NSString).length {
                matches.append(found.location)
                if matches.count > 1 { return nil }
            }
            start = found.location + 1
        }
        guard let offset = matches.first else { return nil }
        return self.snapshot(at: offset, in: source)
    }

    /// Replaces one authored cell's content. The surrounding cell whitespace
    /// and every other byte stay untouched.
    public static func setContent(
        _ content: String,
        row: Int,
        column: Int,
        in snapshot: MarkdownTableSnapshot,
        source: String
    ) throws -> MarkdownTableGridEdit {
        guard snapshot.isCurrent(in: source) else {
            throw MarkdownTableGridError.staleTable
        }
        guard let cell = snapshot.cell(row: row, column: column) else {
            throw MarkdownTableGridError.unknownCell
        }
        let replacement = normalizedCellText(content)
        let range = cell.range.lowerBound..<cell.range.upperBound
        let newSource = (source as NSString).replacingCharacters(
            in: NSRange(location: range.lowerBound, length: range.count),
            with: replacement
        )
        let edit = try edit(
            newSource: newSource,
            actionName: "Edit Table Cell",
            target: (row: row, column: column),
            fallbackSelection: range.lowerBound
        )
        // A commit replaces content only; the rescan must still see the same
        // shape. A replacement whose bytes restructured the row would
        // otherwise be accepted with a silently wrong cell underneath.
        guard let refreshed = MarkdownTableGrid.snapshot(
            at: edit.blockRange.lowerBound,
            in: edit.source
        ), refreshed.rowCount == snapshot.rowCount,
        refreshed.columnCount == snapshot.columnCount,
        refreshed.cell(row: row, column: column)?.content == replacement else {
            throw MarkdownTableGridError.invalidTable
        }
        return edit
    }

    /// Runs one structural or alignment command against the captured table.
    public static func perform(
        _ command: MarkdownTableCommand,
        row: Int,
        column: Int,
        in snapshot: MarkdownTableSnapshot,
        source: String
    ) throws -> MarkdownTableGridEdit {
        guard snapshot.isCurrent(in: source) else {
            throw MarkdownTableGridError.staleTable
        }
        let cell = snapshot.cell(row: row, column: column)
        if cell == nil, needsCell(command) {
            // A short row has no cell here. Targeting the header's first
            // cell instead would delete or align the wrong column.
            throw MarkdownTableGridError.unknownCell
        }
        let offset: Int
        if let cell {
            offset = cell.range.lowerBound
        } else if row == 0 {
            offset = snapshot.table.header.range.lowerBound
        } else if row - 1 < snapshot.table.body.count {
            // A row command on a short row targets the row itself even
            // though this column has no authored cell. Without the row's
            // own line the editor resolved the table start as the header,
            // so Insert Row Below inserted at the top and Delete Row
            // refused with `headerRow`.
            offset = snapshot.table.body[row - 1].range.lowerBound
        } else {
            offset = snapshot.blockRange.lowerBound
        }
        let result = MarkdownTableEditor.edit(
            command,
            source: source,
            selection: offset..<offset
        )
        switch result.outcome {
        case .handled:
            guard let range = result.range,
                  let replacement = result.replacement else {
                throw MarkdownTableGridError.invalidTable
            }
            let newSource = (source as NSString).replacingCharacters(
                in: NSRange(location: range.lowerBound, length: range.count),
                with: replacement
            )
            if command == .deleteTable {
                // Nothing remains to rescan; the deletion point is the
                // grid's new empty block.
                let location = min(range.lowerBound, (newSource as NSString).length)
                return MarkdownTableGridEdit(
                    source: newSource,
                    selection: location..<location,
                    actionName: actionName(for: command),
                    blockRange: location..<location
                )
            }
            return try edit(
                newSource: newSource,
                actionName: actionName(for: command),
                target: (row: row, column: column),
                fallbackSelection: result.selection?.lowerBound
                    ?? snapshot.blockRange.lowerBound
            )
        case let .refused(reason):
            throw MarkdownTableGridError.refused(reason)
        case .notApplicable:
            throw MarkdownTableGridError.notApplicable
        }
    }

    /// Commands whose target is the row or the whole table, not one cell.
    private static func needsCell(_ command: MarkdownTableCommand) -> Bool {
        switch command {
        case .insertRowAbove, .insertRowBelow, .deleteRow, .deleteTable,
             .format, .insert:
            return false
        case .insertColumnLeft, .insertColumnRight, .deleteColumn,
             .setAlignment:
            return true
        }
    }

    /// Cell text is single-line Markdown; a literal pipe is escaped so the
    /// table cannot gain a column by accident.
    ///
    /// A run of backslashes at the very end of a cell is special: the cell is
    /// followed directly by the structural separator, so an odd run would
    /// escape that pipe and merge the neighbouring cells. Appending one
    /// backslash makes the run even — the separator stays structural and the
    /// pair renders as one literal backslash, which is also what the odd run
    /// rendered in a padded cell.
    static func normalizedCellText(_ text: String) -> String {
        var output = ""
        var backslashes = 0
        for character in text.replacingOccurrences(of: "\r", with: " ") {
            if character == "\n" || character == "\r" {
                output.append(" ")
                backslashes = 0
                continue
            }
            if character == "\\" {
                output.append(character)
                backslashes += 1
                continue
            }
            if character == "|" {
                if backslashes.isMultiple(of: 2) {
                    output.append("\\")
                }
                output.append(character)
                backslashes = 0
                continue
            }
            backslashes = 0
            output.append(character)
        }
        let trimmed = output.trimmingCharacters(in: .whitespaces)
        var trailing = 0
        for character in trimmed.reversed() {
            guard character == "\\" else { break }
            trailing += 1
        }
        return trailing.isMultiple(of: 2) ? trimmed : trimmed + "\\"
    }

    private static func edit(
        newSource: String,
        actionName: String,
        target: (row: Int, column: Int),
        fallbackSelection: Int
    ) throws -> MarkdownTableGridEdit {
        let ns = newSource as NSString
        // The table cannot have moved: the edit stayed inside its block. Rescan
        // from the block's start to get its post-edit range.
        let blockStart = min(fallbackSelection, ns.length)
        guard let table = MarkdownTableScanner.table(
            at: blockStart,
            in: newSource
        ) else {
            throw MarkdownTableGridError.invalidTable
        }
        let snapshot = MarkdownTableSnapshot(table: table)
        let selection: Range<Int>
        if let cell = snapshot.cell(row: target.row, column: target.column) {
            selection = cell.range.lowerBound..<cell.range.upperBound
        } else {
            let location = min(fallbackSelection, ns.length)
            selection = location..<location
        }
        return MarkdownTableGridEdit(
            source: newSource,
            selection: selection,
            actionName: actionName,
            blockRange: snapshot.blockRange
        )
    }

    private static func actionName(
        for command: MarkdownTableCommand
    ) -> String {
        switch command {
        case .insert:
            return "Insert Table"
        case .insertRowAbove:
            return "Insert Row Above"
        case .insertRowBelow:
            return "Insert Row Below"
        case .deleteRow:
            return "Delete Row"
        case .insertColumnLeft:
            return "Insert Column Left"
        case .insertColumnRight:
            return "Insert Column Right"
        case .deleteColumn:
            return "Delete Column"
        case .deleteTable:
            return "Delete Table"
        case .setAlignment:
            return "Change Table Alignment"
        case .format:
            return "Format Table"
        }
    }
}
