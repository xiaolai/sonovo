import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown table editor")
struct MarkdownTableEditorTests {
    private func caret(after needle: String, in source: String) -> Range<Int> {
        let ns = source as NSString
        let found = ns.range(of: needle)
        let offset = found.location + found.length
        return offset..<offset
    }

    private let base = "| a | b |\n| --- | --- |\n| 1 | 2 |"

    @Test("Inserting a row below keeps every existing line byte-identical")
    func insertRowBelow() {
        let edit = MarkdownTableEditor.edit(
            .insertRowBelow,
            source: base,
            selection: caret(after: "2", in: base)
        )
        #expect(edit.outcome == .handled)
        #expect(edit.range == 0..<(base as NSString).length)
        #expect(
            edit.replacement
                == "| a | b |\n| --- | --- |\n| 1 | 2 |\n|     |     |"
        )
    }

    @Test("Inserting a row above a body row places it before that row")
    func insertRowAbove() {
        let edit = MarkdownTableEditor.edit(
            .insertRowAbove,
            source: base,
            selection: caret(after: "1", in: base)
        )
        #expect(edit.outcome == .handled)
        #expect(
            edit.replacement
                == "| a | b |\n| --- | --- |\n|     |     |\n| 1 | 2 |"
        )
    }

    @Test("Deleting a row removes exactly that line")
    func deleteRow() {
        let edit = MarkdownTableEditor.edit(
            .deleteRow,
            source: base,
            selection: caret(after: "1", in: base)
        )
        #expect(edit.outcome == .handled)
        #expect(edit.replacement == "| a | b |\n| --- | --- |")
    }

    @Test("The header row cannot be deleted")
    func deleteHeaderRefuses() {
        let edit = MarkdownTableEditor.edit(
            .deleteRow,
            source: base,
            selection: caret(after: "a", in: base)
        )
        #expect(edit.outcome == .refused(.headerRow))
        #expect(edit.range == nil)
    }

    @Test("Inserting a column right adds one cell to every row")
    func insertColumnRight() {
        let edit = MarkdownTableEditor.edit(
            .insertColumnRight,
            source: base,
            selection: caret(after: "a", in: base)
        )
        #expect(edit.outcome == .handled)
        #expect(
            edit.replacement
                == "| a |     | b |\n| --- | --- | --- |\n| 1 |     | 2 |"
        )
    }

    @Test("Deleting a column drops one cell from every row")
    func deleteColumn() {
        let edit = MarkdownTableEditor.edit(
            .deleteColumn,
            source: base,
            selection: caret(after: "b", in: base)
        )
        #expect(edit.outcome == .handled)
        #expect(edit.replacement == "| a |\n| --- |\n| 1 |")
    }

    @Test("An escaped pipe is never split by a column command")
    func escapedPipeSurvives() {
        let source = "| a | b |\n| --- | --- |\n| x \\| y | 2 |"
        let edit = MarkdownTableEditor.edit(
            .deleteColumn,
            source: source,
            selection: caret(after: "b", in: source)
        )
        #expect(edit.outcome == .handled)
        #expect(edit.replacement?.contains("x \\| y") == true)
    }

    @Test("Alignment regenerates only the delimiter cell")
    func setAlignment() {
        let edit = MarkdownTableEditor.edit(
            .setAlignment(.center),
            source: base,
            selection: caret(after: "a", in: base)
        )
        #expect(edit.outcome == .handled)
        #expect(
            edit.replacement
                == "| a | b |\n| :---: | --- |\n| 1 | 2 |"
        )
    }

    @Test("Format pads cells without dropping authored data")
    func format() {
        let source = "|a|b|\n|---|---|\n|1|2|"
        let edit = MarkdownTableEditor.edit(
            .format,
            source: source,
            selection: caret(after: "a", in: source)
        )
        #expect(edit.outcome == .handled)
        #expect(
            edit.replacement
                == "| a   | b   |\n| --- | --- |\n| 1   | 2   |"
        )
    }

    @Test("Format keeps an overlong row's extra authored cell")
    func formatKeepsOverlongCell() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 | 3 |"
        let edit = MarkdownTableEditor.edit(
            .format,
            source: source,
            selection: caret(after: "a", in: source)
        )
        #expect(edit.outcome == .handled)
        #expect(
            edit.replacement
                == "| a   | b   |\n| --- | --- |\n| 1   | 2   | 3 |"
        )
    }

    @Test("A malformed table refuses every semantic command")
    func malformedRefuses() {
        let source = "| a | b |\n| --- |\n| 1 | 2 |"
        for command: MarkdownTableCommand in [
            .insertRowAbove,
            .insertRowBelow,
            .deleteRow,
            .insertColumnLeft,
            .insertColumnRight,
            .deleteColumn,
            .deleteTable,
            .setAlignment(.left),
            .format
        ] {
            let edit = MarkdownTableEditor.edit(
                command,
                source: source,
                selection: caret(after: "a", in: source)
            )
            #expect(edit.outcome == .refused(.malformedTable))
        }
    }

    @Test("Deleting the table removes its lines and one trailing newline")
    func deleteTable() {
        let source = base + "\n"
        let edit = MarkdownTableEditor.edit(
            .deleteTable,
            source: source,
            selection: caret(after: "a", in: source)
        )
        #expect(edit.outcome == .handled)
        #expect(edit.replacement == "")
        #expect(edit.range == 0..<(source as NSString).length)
    }

    @Test("A command outside a table is not applicable")
    func outsideTable() {
        let source = "plain text"
        let edit = MarkdownTableEditor.edit(
            .deleteRow,
            source: source,
            selection: caret(after: "plain", in: source)
        )
        #expect(edit.outcome == .notApplicable)
    }

    @Test("Inserting a table on an empty line writes a two-column table")
    func insertTable() {
        let edit = MarkdownTableEditor.edit(
            .insert(rows: 2, columns: 2),
            source: "",
            selection: 0..<0
        )
        #expect(edit.outcome == .handled)
        #expect(
            edit.replacement
                == "| Column 1 | Column 2 |\n| --- | --- |\n|     |     |\n"
        )
    }

    @Test("A caret at the table's end still targets the last cell")
    func caretAtEnd() {
        let length = (base as NSString).length
        let edit = MarkdownTableEditor.edit(
            .insertRowBelow,
            source: base,
            selection: length..<length
        )
        #expect(edit.outcome == .handled)
        #expect(edit.replacement?.hasSuffix("|     |     |") == true)
    }
}
