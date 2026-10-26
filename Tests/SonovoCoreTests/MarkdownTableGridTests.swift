import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown table grid")
struct MarkdownTableGridTests {
    private let source = """
    Intro.

    | Name | Note |
    | --- | :---: |
    | Alpha | one |
    | Beta | two |

    Outro.
    """

    private func snapshot(
        in source: String
    ) throws -> MarkdownTableSnapshot {
        let offset = (source as NSString).range(of: "|").location
        return try #require(
            MarkdownTableGrid.snapshot(at: offset, in: source)
        )
    }

    private func slice(
        _ range: Range<Int>,
        in source: String
    ) -> String {
        (source as NSString).substring(
            with: NSRange(location: range.lowerBound, length: range.count)
        )
    }

    @Test("Cells map to their exact source ranges")
    func cellMapping() throws {
        let snapshot = try snapshot(in: source)
        #expect(snapshot.rowCount == 3)
        #expect(snapshot.columnCount == 2)
        for row in 0..<snapshot.rowCount {
            for column in 0..<snapshot.columnCount {
                let cell = try #require(
                    snapshot.cell(row: row, column: column)
                )
                #expect(
                    slice(cell.range.lowerBound..<cell.range.upperBound,
                          in: source) == cell.content
                )
            }
        }
        #expect(snapshot.content(row: 1, column: 0) == "Alpha")
        #expect(snapshot.alignment(column: 1) == .center)
        #expect(snapshot.alignment(column: 0) == TableBlock.Alignment.none)
    }

    @Test("A cell commit changes only that cell's content")
    func setContent() throws {
        let snapshot = try snapshot(in: source)
        let edit = try MarkdownTableGrid.setContent(
            "Gamma",
            row: 2,
            column: 0,
            in: snapshot,
            source: source
        )
        let expected = source.replacingOccurrences(
            of: "| Beta | two |",
            with: "| Gamma | two |"
        )
        #expect(edit.source == expected)
        #expect(edit.actionName == "Edit Table Cell")
        #expect(
            slice(edit.selection, in: edit.source) == "Gamma"
        )
        let refreshed = try #require(
            MarkdownTableGrid.snapshot(
                at: edit.blockRange.lowerBound,
                in: edit.source
            )
        )
        #expect(refreshed.content(row: 2, column: 0) == "Gamma")
    }

    @Test("A pipe in cell text is escaped, not a new column")
    func pipeEscaping() throws {
        let snapshot = try snapshot(in: source)
        let edit = try MarkdownTableGrid.setContent(
            "a | b",
            row: 1,
            column: 1,
            in: snapshot,
            source: source
        )
        #expect(edit.source.contains("| Alpha | a \\| b |"))
        let refreshed = try #require(
            MarkdownTableGrid.snapshot(
                at: edit.blockRange.lowerBound,
                in: edit.source
            )
        )
        #expect(refreshed.columnCount == 2)
        #expect(refreshed.content(row: 1, column: 1) == "a \\| b")
    }

    @Test("A trailing backslash cannot escape the separator")
    func trailingBackslash() throws {
        // The body row is unpadded, so the cell's content ends directly at
        // the structural pipe. One trailing backslash would escape it; the
        // commit must double the run instead of merging the cells.
        let unpadded = """
        | A | B |
        | --- | --- |
        |c|d|
        """
        let grid = try snapshot(in: unpadded)
        let edit = try MarkdownTableGrid.setContent(
            "x\\",
            row: 1,
            column: 0,
            in: grid,
            source: unpadded
        )
        #expect(edit.source.contains("|x\\\\|d|"))
        let refreshed = try #require(
            MarkdownTableGrid.snapshot(
                at: edit.blockRange.lowerBound,
                in: edit.source
            )
        )
        #expect(refreshed.rowCount == 2)
        #expect(refreshed.columnCount == 2)
        #expect(refreshed.content(row: 1, column: 0) == "x\\\\")
        #expect(refreshed.content(row: 1, column: 1) == "d")
    }

    @Test("An even trailing backslash run is already safe")
    func trailingBackslashEven() {
        #expect(MarkdownTableGrid.normalizedCellText("x\\") == "x\\\\")
        #expect(MarkdownTableGrid.normalizedCellText("x\\\\") == "x\\\\")
        #expect(MarkdownTableGrid.normalizedCellText("x") == "x")
        // A backslash elsewhere is untouched, and a pipe is still escaped.
        #expect(MarkdownTableGrid.normalizedCellText("a\\b") == "a\\b")
        #expect(MarkdownTableGrid.normalizedCellText("a|b") == "a\\|b")
    }

    @Test("Newlines collapse to spaces; empty text clears the cell")
    func normalization() throws {
        let snapshot = try snapshot(in: source)
        let multiline = try MarkdownTableGrid.setContent(
            "line one\nline two",
            row: 1,
            column: 0,
            in: snapshot,
            source: source
        )
        #expect(multiline.source.contains("| line one line two | one |"))

        let cleared = try MarkdownTableGrid.setContent(
            "   ",
            row: 1,
            column: 0,
            in: snapshot,
            source: source
        )
        #expect(cleared.source.contains("|  | one |"))
        let refreshed = try #require(
            MarkdownTableGrid.snapshot(
                at: cleared.blockRange.lowerBound,
                in: cleared.source
            )
        )
        #expect(refreshed.content(row: 1, column: 0) == "")
    }

    @Test("Wide and CJK text keeps every other byte in place")
    func wideAndCJK() throws {
        let unicode = """
        | 名 | メモ |
        | --- | --- |
        | 😀 中文 | 值 |
        | B | 二 |
        """
        let unicodeSnapshot = try snapshot(in: unicode)
        let edit = try MarkdownTableGrid.setContent(
            "広い セル 😀 值",
            row: 1,
            column: 1,
            in: unicodeSnapshot,
            source: unicode
        )
        let refreshed = try #require(
            MarkdownTableGrid.snapshot(
                at: edit.blockRange.lowerBound,
                in: edit.source
            )
        )
        #expect(refreshed.content(row: 1, column: 0) == "😀 中文")
        #expect(refreshed.content(row: 1, column: 1) == "広い セル 😀 值")
        #expect(refreshed.content(row: 2, column: 1) == "二")

        let wide = String(repeating: "很宽", count: 200)
        let wideEdit = try MarkdownTableGrid.setContent(
            wide,
            row: 2,
            column: 0,
            in: unicodeSnapshot,
            source: unicode
        )
        let wideSnapshot = try #require(
            MarkdownTableGrid.snapshot(
                at: wideEdit.blockRange.lowerBound,
                in: wideEdit.source
            )
        )
        #expect(wideSnapshot.content(row: 2, column: 0) == wide)
    }

    @Test("A moved table refuses, and relocate finds it again")
    func staleAndRelocate() throws {
        let snapshot = try snapshot(in: source)
        let moved = "A new first line.\n\n" + source
        #expect(throws: MarkdownTableGridError.staleTable) {
            try MarkdownTableGrid.setContent(
                "Nope",
                row: 1,
                column: 0,
                in: snapshot,
                source: moved
            )
        }
        let relocated = try #require(
            MarkdownTableGrid.relocate(snapshot, in: moved)
        )
        let edit = try MarkdownTableGrid.setContent(
            "Alpha2",
            row: 1,
            column: 0,
            in: relocated,
            source: moved
        )
        #expect(edit.source.hasPrefix("A new first line.\n\nIntro."))
        #expect(edit.source.contains("| Alpha2 | one |"))
    }

    @Test("A duplicated table block is ambiguous to relocate")
    func ambiguousRelocate() throws {
        let snapshot = try snapshot(in: "| A | B |\n| --- | --- |\n| 1 | 2 |\n")
        let duplicated = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        #expect(MarkdownTableGrid.relocate(snapshot, in: duplicated) == nil)
    }

    @Test("Alignment rewrites only the delimiter cell")
    func alignment() throws {
        let snapshot = try snapshot(in: source)
        let edit = try MarkdownTableGrid.perform(
            .setAlignment(.right),
            row: 1,
            column: 0,
            in: snapshot,
            source: source
        )
        #expect(edit.source.contains("| ---: | :---: |"))
        #expect(edit.actionName == "Change Table Alignment")
        let refreshed = try #require(
            MarkdownTableGrid.snapshot(
                at: edit.blockRange.lowerBound,
                in: edit.source
            )
        )
        #expect(refreshed.alignment(column: 0) == .right)
        #expect(refreshed.alignment(column: 1) == .center)
    }

    @Test("Structural commands use the existing table editor")
    func structural() throws {
        let snapshot = try snapshot(in: source)
        let insertedRow = try MarkdownTableGrid.perform(
            .insertRowBelow,
            row: 1,
            column: 0,
            in: snapshot,
            source: source
        )
        let rowTable = try #require(
            MarkdownTableGrid.snapshot(
                at: insertedRow.blockRange.lowerBound,
                in: insertedRow.source
            )
        )
        #expect(rowTable.rowCount == 4)
        #expect(rowTable.content(row: 2, column: 0) == "")

        let insertedColumn = try MarkdownTableGrid.perform(
            .insertColumnRight,
            row: 0,
            column: 1,
            in: snapshot,
            source: source
        )
        let columnTable = try #require(
            MarkdownTableGrid.snapshot(
                at: insertedColumn.blockRange.lowerBound,
                in: insertedColumn.source
            )
        )
        #expect(columnTable.columnCount == 3)

        let deletedRow = try MarkdownTableGrid.perform(
            .deleteRow,
            row: 1,
            column: 0,
            in: snapshot,
            source: source
        )
        let deletedTable = try #require(
            MarkdownTableGrid.snapshot(
                at: deletedRow.blockRange.lowerBound,
                in: deletedRow.source
            )
        )
        #expect(deletedTable.rowCount == 2)
        #expect(deletedTable.content(row: 1, column: 0) == "Beta")
    }

    @Test("A short body row has no editable cell there")
    func shortRow() throws {
        let short = """
        | A | B |
        | --- | --- |
        | only |
        """
        let shortSnapshot = try snapshot(in: short)
        #expect(shortSnapshot.cell(row: 1, column: 1) == nil)
        #expect(throws: MarkdownTableGridError.unknownCell) {
            try MarkdownTableGrid.setContent(
                "x",
                row: 1,
                column: 1,
                in: shortSnapshot,
                source: short
            )
        }
    }

    @Test("A malformed table has no snapshot")
    func malformed() {
        let bad = "| A | B |\n| no delimiter |\n| 1 | 2 |\n"
        #expect(MarkdownTableGrid.snapshot(at: 0, in: bad) == nil)
        #expect(MarkdownTableGrid.snapshot(at: 0, in: "No table.") == nil)
    }
}
