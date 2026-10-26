import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown table scanner")
struct MarkdownTableScannerTests {
    private func onlyTable(
        _ source: String
    ) -> MarkdownTable {
        let tables = MarkdownTableScanner.tables(in: source)
        #expect(tables.count == 1)
        return tables[0]
    }

    private func astCellCounts(
        _ source: String
    ) -> (header: Int, rows: [Int])? {
        let parsed = MarkdownParser.parse(source)
        for block in parsed.ast.blocks {
            if case .table(let table, _) = block {
                return (table.header.count, table.rows.map(\.count))
            }
        }
        return nil
    }

    @Test("A basic table has exact authored cells")
    func basic() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let table = onlyTable(source)
        #expect(table.isValid)
        #expect(table.header.cells.count == 2)
        #expect(table.delimiter.cells.count == 2)
        #expect(table.body.count == 1)
        #expect(table.body[0].cells.map(\.content) == ["1", "2"])
        #expect(table.header.cells.map(\.content) == ["a", "b"])
        #expect(table.header.leadingPipe)
        #expect(table.header.trailingPipe)
        #expect(table.sourceText == source)
    }

    @Test("A short row keeps its authored cell and reports the mismatch")
    func shortRow() {
        let source = "| a | b |\n| --- | --- |\n| 1 |"
        let table = onlyTable(source)
        #expect(table.isValid)
        #expect(table.body[0].cells.count == 1)
        #expect(table.columnMismatchRows == [0])
        #expect(table.body[0].cells[0].content == "1")
    }

    @Test("An overlong row keeps every authored cell")
    func overlongRow() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 | 3 |"
        let table = onlyTable(source)
        #expect(table.isValid)
        #expect(table.body[0].cells.count == 3)
        #expect(table.body[0].cells.map(\.content) == ["1", "2", "3"])
        #expect(table.columnMismatchRows == [0])
    }

    @Test("An authored empty cell is distinct from a missing cell")
    func emptyCell() {
        let source = "| a | b | c |\n| --- | --- | --- |\n| 1 || 3 |"
        let table = onlyTable(source)
        #expect(table.body[0].cells.count == 3)
        #expect(table.body[0].cells[1].content.isEmpty)
        #expect(table.body[0].cells[1].range.isEmpty)
        #expect(table.body[0].cells[0].content == "1")
        #expect(table.body[0].cells[2].content == "3")
    }

    @Test("Absent outer pipes are preserved")
    func absentOuterPipes() {
        let source = "a | b\n--- | ---\n1 | 2"
        let table = onlyTable(source)
        #expect(!table.header.leadingPipe)
        #expect(!table.header.trailingPipe)
        #expect(table.header.cells.count == 2)
        #expect(table.body[0].cells.map(\.content) == ["1", "2"])
        #expect(table.sourceText == source)
    }

    @Test("An escaped pipe stays inside one cell")
    func escapedPipe() {
        let source = "| a \\| b | c |\n| --- | --- |\n| 1 | 2 |"
        let table = onlyTable(source)
        #expect(table.header.cells.count == 2)
        #expect(table.header.cells[0].content == "a \\| b")
        #expect(table.header.cells[1].content == "c")
    }

    @Test("An unescaped pipe splits even inside a code span")
    func codeSpanPipe() {
        let source = "| `a|b` | c |\n| --- | --- |\n| 1 | 2 |"
        let table = onlyTable(source)
        #expect(table.header.cells.count == 3)
        #expect(table.header.cells.map(\.content) == ["`a", "b`", "c"])

        let escaped = onlyTable(
            "| `a\\|b` | c |\n| --- | --- |\n| 1 | 2 |"
        )
        #expect(escaped.header.cells.count == 2)
        #expect(escaped.header.cells[0].content == "`a\\|b`")
    }

    @Test("Alignment markers map to the table model")
    func alignment() {
        let source = "| a | b | c | d |\n" +
            "| :--- | :---: | ---: | --- |\n" +
            "| 1 | 2 | 3 | 4 |"
        let table = onlyTable(source)
        #expect(table.alignments == [.left, .center, .right, .none])
    }

    @Test("A malformed delimiter is invalid but still editable")
    func malformedDelimiter() {
        let source = "| a | b |\n| --- |\n| 1 | 2 |"
        let table = onlyTable(source)
        #expect(!table.isValid)
        #expect(table.header.cells.count == 2)
        #expect(table.delimiter.cells.count == 1)
        #expect(table.body.count == 1)
        #expect(table.body[0].cells.count == 2)
    }

    @Test("A table at EOF terminates cleanly")
    func atEOF() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let table = onlyTable(source)
        #expect(table.range.upperBound == (source as NSString).length)
        #expect(table.body[0].cells.map(\.content) == ["1", "2"])
    }

    @Test("A blockquote table keeps its container prefix")
    func blockquote() {
        let source = "> | a | b |\n> | --- | --- |\n> | 1 | 2 |"
        let table = onlyTable(source)
        #expect(table.header.containerPrefix == "> ")
        #expect(table.header.cells.map(\.content) == ["a", "b"])
        #expect(table.body[0].cells.map(\.content) == ["1", "2"])
        #expect(table.sourceText == source)
    }

    @Test("Leaving a blockquote ends its table")
    func blockquoteEnds() {
        let source = "> | a | b |\n> | --- | --- |\n> | 1 | 2 |\noutside | text"
        let table = onlyTable(source)
        #expect(table.body.count == 1)
        #expect(table.range.upperBound < (source as NSString).length)
    }

    @Test("CJK content and ranges stay in UTF-16")
    func cjk() {
        let source = "| 标题 | 值 |\n| --- | --- |\n| 一 | 二 |"
        let table = onlyTable(source)
        #expect(table.header.cells.map(\.content) == ["标题", "值"])
        #expect(table.body[0].cells.map(\.content) == ["一", "二"])
        let ns = source as NSString
        let header = table.header.cells[0]
        #expect(
            ns.substring(
                with: NSRange(
                    location: header.range.lowerBound,
                    length: header.range.length
                )
            ) == "标题"
        )
    }

    @Test("Valid tables agree with the pinned parser's cell counts")
    func parserAgreement() {
        let fixtures = [
            "| a | b |\n| --- | --- |\n| 1 | 2 |",
            "a | b\n--- | ---\n1 | 2",
            "| 标题 | 值 |\n| --- | --- |\n| 一 | 二 |"
        ]
        for source in fixtures {
            let table = onlyTable(source)
            let ast = astCellCounts(source)
            #expect(ast != nil)
            #expect(ast?.header == table.header.cells.count)
            #expect(ast?.rows == table.body.map(\.cells.count))
        }
    }

    @Test("A table is found at a caret offset")
    func lookup() {
        let source = "before\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nafter"
        let offset = (source as NSString).range(of: "1").location
        let table = MarkdownTableScanner.table(at: offset, in: source)
        #expect(table != nil)
        #expect(table?.body[0].cells[0].content == "1")
        #expect(MarkdownTableScanner.table(at: 1, in: source) == nil)
    }

    @Test("A row with no cell is not a table")
    func singlePipeIsNotATable() {
        #expect(MarkdownTableScanner.tables(in: "|\n|").isEmpty)
    }
}
