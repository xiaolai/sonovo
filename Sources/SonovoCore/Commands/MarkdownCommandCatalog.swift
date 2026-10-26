import Foundation

/// Every command the palette may offer, grouped for display.
///
/// The palette shows a command only when the registry's availability
/// predicate is true for the current context; this catalog is the complete
/// list, and each kind appears exactly once.
public enum MarkdownCommandCatalog {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let command: MarkdownCommandKind
        public let category: String

        public var id: MarkdownCommandKind { command }
    }

    public static let entries: [Entry] = [
        entry(.toggleEmphasis, "Format"),
        entry(.toggleStrong, "Format"),
        entry(.toggleInlineCode, "Format"),
        entry(.toggleStrikethrough, "Format"),
        entry(.toggleHeading(level: 1), "Heading"),
        entry(.toggleHeading(level: 2), "Heading"),
        entry(.toggleHeading(level: 3), "Heading"),
        entry(.toggleHeading(level: 4), "Heading"),
        entry(.toggleHeading(level: 5), "Heading"),
        entry(.toggleHeading(level: 6), "Heading"),
        entry(.toggleBlockQuote, "Block"),
        entry(.toggleList(kind: .bullet), "List"),
        entry(.toggleList(kind: .ordered), "List"),
        entry(.toggleList(kind: .task), "List"),
        entry(.insertLink(destination: ""), "Insert"),
        entry(.insertImage(destination: "", alt: ""), "Insert"),
        entry(.insertWikiLink(target: "", alias: nil), "Insert"),
        entry(.insertCodeFence, "Insert"),
        entry(.insertRule, "Insert"),
        entry(.insertDetails(summary: "Details"), "Insert"),
        entry(.insertTOC, "Insert"),
        entry(.insertTable(rows: 2, columns: 2), "Table"),
        entry(.insertTableRowAbove, "Table"),
        entry(.insertTableRowBelow, "Table"),
        entry(.deleteTableRow, "Table"),
        entry(.insertTableColumnLeft, "Table"),
        entry(.insertTableColumnRight, "Table"),
        entry(.deleteTableColumn, "Table"),
        entry(.setTableAlignment(.left), "Table"),
        entry(.setTableAlignment(.center), "Table"),
        entry(.setTableAlignment(.right), "Table"),
        entry(.setTableAlignment(.none), "Table"),
        entry(.formatTable, "Table"),
        entry(.deleteTable, "Table"),
        entry(.lineUp, "Lines"),
        entry(.lineDown, "Lines"),
        entry(.duplicateLine, "Lines"),
        entry(.deleteLine, "Lines"),
        entry(.joinLines, "Lines"),
        entry(.removeBlankLines, "Lines"),
        entry(.sortLinesAscending, "Lines"),
        entry(.sortLinesDescending, "Lines"),
        entry(.uppercase, "Case"),
        entry(.lowercase, "Case"),
        entry(.titleCase, "Case"),
        entry(.toggleCase, "Case"),
        entry(.trimTrailingSpaces, "Lines"),
        entry(.collapseBlankLines, "Lines"),
        entry(.setDetailsOpen(true), "Details"),
        entry(.setDetailsOpen(false), "Details")
    ]

    /// Commands that take an argument from UI the palette cannot supply
    /// (a query, a frontmatter range) are excluded.
    public static func paletteEntries(
        isAvailable: (MarkdownCommandKind) -> Bool
    ) -> [Entry] {
        entries.filter { entry in
            switch entry.command {
            case .replaceAll, .replaceFrontmatter:
                return false
            default:
                return isAvailable(entry.command)
            }
        }
    }

    private static func entry(
        _ command: MarkdownCommandKind,
        _ category: String
    ) -> Entry {
        Entry(command: command, category: category)
    }
}
