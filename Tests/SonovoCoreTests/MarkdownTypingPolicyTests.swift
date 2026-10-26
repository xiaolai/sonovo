import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown typing policy")
struct MarkdownTypingPolicyTests {
    private func range(of needle: String, in source: String) -> Range<Int> {
        let ns = source as NSString
        let found = ns.range(of: needle)
        return found.location..<(found.location + found.length)
    }

    private func caret(after needle: String, in source: String) -> Range<Int> {
        let ns = source as NSString
        let found = ns.range(of: needle)
        let offset = found.location + found.length
        return offset..<offset
    }

    @Test("Tab indents a list item and keeps the caret")
    func listIndent() {
        let source = "- item"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: caret(after: "-", in: source),
            backwards: false
        )
        #expect(plan.outcome == .handled)
        #expect(plan.range == 0..<0)
        #expect(plan.replacement == "  ")
        #expect(plan.selection == 3..<3)
    }

    @Test("Shift-Tab outdents a list item")
    func listOutdent() {
        let source = "  - item"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: caret(after: "-", in: source),
            backwards: true
        )
        #expect(plan.outcome == .handled)
        #expect(plan.range == 0..<2)
        #expect(plan.replacement == "")
        #expect(plan.selection == 1..<1)
    }

    @Test("Tab escapes a closing bracket")
    func bracketEscape() {
        let source = "f(|)"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 3..<3,
            backwards: false
        )
        #expect(plan.outcome == .handled)
        #expect(plan.range == nil)
        #expect(plan.selection == 4..<4)
    }

    @Test("Shift-Tab moves before an opening bracket")
    func bracketBack() {
        let source = "f(|)"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 2..<2,
            backwards: true
        )
        #expect(plan.outcome == .handled)
        #expect(plan.selection == 1..<1)
    }

    @Test("Tab falls back to spaces")
    func tabFallback() {
        let source = "text"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 4..<4,
            backwards: false
        )
        #expect(plan.outcome == .handled)
        #expect(plan.replacement == "    ")
        #expect(plan.selection == 8..<8)
    }

    @Test("Tab inside a fence is not custom")
    func fenceExcluded() {
        let source = "```\n- item\n```"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: caret(after: "-", in: source),
            backwards: false
        )
        #expect(plan.outcome == .notApplicable)
    }

    @Test("Backspace deletes an empty pair")
    func emptyPair() {
        let source = "f()"
        let plan = MarkdownTypingPolicy.backspace(
            source: source,
            selection: 2..<2
        )
        #expect(plan.outcome == .handled)
        #expect(plan.range == 1..<3)
        #expect(plan.selection == 1..<1)
    }

    @Test("Backspace removes an empty list item")
    func emptyListItem() {
        let source = "- "
        let plan = MarkdownTypingPolicy.backspace(
            source: source,
            selection: 2..<2
        )
        #expect(plan.outcome == .handled)
        #expect(plan.range == 0..<2)
        #expect(plan.replacement == "")
    }

    @Test("Backspace lifts a nested item at content start")
    func liftNestedItem() {
        let source = "  - item"
        let offset = (source as NSString).range(of: "item").location
        let plan = MarkdownTypingPolicy.backspace(
            source: source,
            selection: offset..<offset
        )
        #expect(plan.outcome == .handled)
        #expect(plan.range == 0..<2)
    }

    @Test("Backspace refuses a table pipe in a valid table")
    func tablePipeProtected() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let ns = source as NSString
        let pipe = ns.range(of: "|", options: [], range: NSRange(location: 10, length: 8))
        let offset = pipe.location + 1
        let plan = MarkdownTypingPolicy.backspace(
            source: source,
            selection: offset..<offset
        )
        #expect(plan.outcome == .refused)
    }

    @Test("Backspace still repairs a malformed table")
    func malformedTableRepair() {
        let source = "| a | b |\n| --- |\n| 1 | 2 |"
        let ns = source as NSString
        let pipe = ns.range(of: "|", options: [], range: NSRange(location: 14, length: 8))
        let offset = pipe.location + 1
        let plan = MarkdownTypingPolicy.backspace(
            source: source,
            selection: offset..<offset
        )
        #expect(plan.outcome != .refused)
    }

    @Test("Delete forward refuses a table pipe")
    func deleteForwardPipe() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let ns = source as NSString
        let pipe = ns.range(of: "|", options: [], range: NSRange(location: 2, length: 5))
        let plan = MarkdownTypingPolicy.deleteForward(
            source: source,
            selection: pipe.location..<pipe.location
        )
        #expect(plan.outcome == .refused)
    }

    @Test("Backspace on ordinary text is native")
    func ordinaryText() {
        let source = "hello"
        let plan = MarkdownTypingPolicy.backspace(
            source: source,
            selection: 5..<5
        )
        #expect(plan.outcome == .notApplicable)
    }
}

@Suite("Markdown typing policy audit regressions")
struct MarkdownTypingPolicyAuditTests {
    @Test("Shift-Tab at the start of an indented item never goes negative")
    func shiftTabAtZeroClamps() {
        let plan = MarkdownTypingPolicy.tab(
            source: "  - item",
            selection: 0..<0,
            backwards: true
        )
        #expect(plan.outcome == .handled)
        #expect(plan.selection == 0..<0)
    }

    @Test("Delete forward inside a fence is native")
    func deleteForwardInsideFence() {
        let source = "```\n| a | b |\n| --- | --- |\n| 1 | 2 |\n```"
        let ns = source as NSString
        let pipe = ns.range(of: "|", options: [], range: NSRange(location: 4, length: 20))
        let plan = MarkdownTypingPolicy.deleteForward(
            source: source,
            selection: pipe.location..<pipe.location
        )
        #expect(plan.outcome == .notApplicable)
    }

    @Test("A shorter fence does not close a longer fence")
    func fenceLengthMatters() {
        // The caret sits after the three-backtick line, which is exactly
        // where the old tracker had already closed the four-backtick fence.
        let source = "````\ntext\n```\n- item\n````"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 16..<16,
            backwards: false
        )
        #expect(plan.outcome == .notApplicable)
    }

    @Test("A four-space-indented run cannot close a top-level fence")
    func indentedFenceDoesNotClose() {
        let source = "````\ntext\n    ````\n- item"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 24..<24,
            backwards: false
        )
        #expect(plan.outcome == .notApplicable)
    }

    @Test("A four-space-indented run cannot close a fence opened at one space")
    func shallowOpenFenceDoesNotCloseFourIndented() {
        let source = " ```\ntext\n    ```\n- item"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 20..<20,
            backwards: false
        )
        #expect(plan.outcome == .notApplicable)
    }

    @Test("A fence nested in a list still closes at its own indentation")
    func nestedFenceCloses() {
        // A fence four columns deep inside a nested list item must still
        // close; a fixed three-column limit would swallow the rest of the
        // document.
        let source = "- parent\n  - child\n\n    ```\n    code\n    ```\n- after"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 46..<46,
            backwards: false
        )
        #expect(plan.outcome == .handled)
        #expect(plan.replacement == "  ")
    }

    @Test("A closing run is measured from the list item's content column")
    func listCloserMeasuresFromContentColumn() {
        // The list content starts at column 2, so a closer at column 4 is
        // within three columns of the item and closes the fence.
        let source = "- item\n\n  ```\n  code\n    ```\n  - after"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 31..<31,
            backwards: false
        )
        #expect(plan.outcome == .handled)
    }

    @Test("Dedenting out of the list ends an unclosed fence")
    func dedentEndsFence() {
        let source = "- item\n\n  ```\n  code\n\n- after"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 24..<24,
            backwards: false
        )
        #expect(plan.outcome == .handled)
    }

    @Test("A dedented delimiter opens a new top-level fence")
    func dedentedDelimiterOpensNewFence() {
        let source = "- item\n\n  ```\n  code\n```\n- after"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 27..<27,
            backwards: false
        )
        #expect(plan.outcome == .notApplicable)
    }

    @Test("A four-space-indented delimiter does not open a fence")
    func indentedDelimiterDoesNotOpen() {
        let source = "    ```\n- item"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 10..<10,
            backwards: false
        )
        #expect(plan.outcome == .handled)
    }

    @Test("A fence opened after a list marker is tracked")
    func fenceAfterListMarker() {
        let source = "- ```\n  - item\n  ```"
        let tab = MarkdownTypingPolicy.tab(
            source: source,
            selection: 10..<10,
            backwards: false
        )
        #expect(tab.outcome == .notApplicable)
        let backspace = MarkdownTypingPolicy.backspace(
            source: source,
            selection: 10..<10
        )
        #expect(backspace.outcome == .notApplicable)
    }

    @Test("A fence after two markers on one line is tracked")
    func nestedMarkersOnOneLine() {
        let source = "- - ```\n    - item\n    ```"
        let tab = MarkdownTypingPolicy.tab(
            source: source,
            selection: 14..<14,
            backwards: false
        )
        #expect(tab.outcome == .notApplicable)
        let backspace = MarkdownTypingPolicy.backspace(
            source: source,
            selection: 14..<14
        )
        #expect(backspace.outcome == .notApplicable)
    }

    @Test("Tab padding after a marker counts columns, not characters")
    func tabPaddedMarkerColumn() {
        let source = "-\t```\n    code\n      ```\n    - after"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 31..<31,
            backwards: false
        )
        #expect(plan.outcome == .handled)
    }

    @Test("A sibling item at a line-start caret ends the fence")
    func lineStartCaretEndsFence() {
        let source = "- ```\n- after"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 6..<6,
            backwards: false
        )
        #expect(plan.outcome == .handled)
    }

    @Test("Five spaces after a marker leave the content column at two")
    func wideMarkerPaddingKeepsContentColumn() {
        // With more than four spaces of padding the content is an indented
        // code block, so the item's content column stays one space past the
        // marker — not where the text happens to start.
        let source = "-     item\n\n  ```\n  code\n- after"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 27..<27,
            backwards: false
        )
        #expect(plan.outcome == .handled)
    }

    @Test("An empty item keeps its content column one space past the marker")
    func emptyItemContentColumn() {
        let source = "-    \n  ```\n  code\n- after"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 26..<26,
            backwards: false
        )
        #expect(plan.outcome == .handled)
    }

    @Test("Wide padding makes the rest of the line code, not a nested item")
    func widePaddingStopsMarkerStripping() {
        let source = "-     - ```\n        - after"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 27..<27,
            backwards: false
        )
        #expect(plan.outcome == .handled)
    }

    @Test("A marker four columns deep at top level is indented code")
    func deepMarkerIsNotAListItem() {
        let source = "    - ```\n      - after"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 23..<23,
            backwards: false
        )
        #expect(plan.outcome == .handled)
    }

    @Test("A CRLF closing fence is recognized")
    func crlfFenceCloses() {
        let source = "```\r\ncode\r\n```\r\n- after"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 23..<23,
            backwards: false
        )
        #expect(plan.outcome == .handled)
    }

    @Test("A bare marker is an empty list item")
    func bareMarkerIsAnItem() {
        let source = "-\n  ```\n  code\n- after"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 22..<22,
            backwards: false
        )
        #expect(plan.outcome == .handled)
    }

    @Test("A caret inside leading whitespace still sees the line's dedent")
    func caretInsideIndentationDedents() {
        let source = "- ```\n - after"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 7..<7,
            backwards: false
        )
        #expect(plan.outcome == .handled)
    }

    @Test("A line cut short by the caret does not close a fence")
    func partialLineDoesNotClose() {
        // Only "```" is visible before the caret; the full line "```x" is
        // not a closing fence.
        let source = "```\n```x\n- item"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 7..<7,
            backwards: false
        )
        #expect(plan.outcome == .notApplicable)
    }

    @Test("A backtick fence's info string may not contain a backtick")
    func backtickInfoStringDoesNotOpen() {
        let source = "```foo`bar\n- item"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 14..<14,
            backwards: false
        )
        #expect(plan.outcome == .handled)
        #expect(plan.replacement == "  ")
    }

    @Test("Two markers with a space are a list item, not a rule")
    func twoMarkersAreAListItem() {
        let item = MarkdownTypingPolicy.tab(
            source: "- -",
            selection: 2..<2,
            backwards: false
        )
        #expect(item.outcome == .handled)
        #expect(item.range == 0..<0)
        #expect(item.replacement == "  ")

        let rule = MarkdownTypingPolicy.tab(
            source: "- - -",
            selection: 2..<2,
            backwards: false
        )
        #expect(rule.outcome == .handled)
        #expect(rule.replacement == "    ")
    }

    @Test("Tab and Shift-Tab move between table cells")
    func tableCellNavigation() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let a = (source as NSString).range(of: "a")
        let b = (source as NSString).range(of: "b")
        let caret = a.location + 1

        let forward = MarkdownTypingPolicy.tab(
            source: source,
            selection: caret..<caret,
            backwards: false
        )
        #expect(forward.outcome == .handled)
        #expect(
            forward.selection == b.location..<(b.location + b.length)
        )

        let back = MarkdownTypingPolicy.tab(
            source: source,
            selection: (b.location + 1)..<(b.location + 1),
            backwards: true
        )
        #expect(back.outcome == .handled)
        #expect(
            back.selection == a.location..<(a.location + a.length)
        )
    }

    @Test("Tab in the last cell appends a row")
    func tableTabAppendsRow() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let two = (source as NSString).range(of: "2")
        let caret = two.location + 1
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: caret..<caret,
            backwards: false
        )
        #expect(plan.outcome == .handled)
        #expect(plan.range != nil)
        #expect(plan.replacement.hasSuffix("|     |     |"))
    }

    @Test("Shift-Tab in the first cell does nothing")
    func tableShiftTabAtFirstCell() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let a = (source as NSString).range(of: "a")
        let caret = (a.location + 1)..<(a.location + 1)
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: caret,
            backwards: true
        )
        #expect(plan.outcome == .handled)
        #expect(plan.range == nil)
        #expect(plan.selection == caret)
    }

    @Test("Tab in a malformed table refuses without falling through")
    func tableTabMalformed() {
        let source = "| a | b |\n| --- |\n| 1 | 2 |"
        let a = (source as NSString).range(of: "a")
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: (a.location + 1)..<(a.location + 1),
            backwards: false
        )
        #expect(plan.outcome == .refused)
    }

    @Test("An escaped table pipe is text, not a separator")
    func escapedTablePipe() {
        let source = "| a | b |\n| --- | --- |\n| x \\| y | 2 |"
        let backspace = MarkdownTypingPolicy.backspace(
            source: source,
            selection: 30..<30
        )
        #expect(backspace.outcome == .notApplicable)
        let forward = MarkdownTypingPolicy.deleteForward(
            source: source,
            selection: 29..<29
        )
        #expect(forward.outcome == .notApplicable)
    }

    @Test("A second angle bracket on a quoted line is text")
    func quoteTextAngleBracket() {
        let source = "> a > b"
        let plan = MarkdownTypingPolicy.backspace(
            source: source,
            selection: 5..<5
        )
        #expect(plan.outcome == .notApplicable)
        let leading = MarkdownTypingPolicy.backspace(
            source: source,
            selection: 1..<1
        )
        #expect(leading.outcome == .refused)
    }

    @Test("Shift-Tab at a line start never drifts into the previous line")
    func outdentAtLineStartStaysPut() {
        let source = "abc\n  - item"
        let plan = MarkdownTypingPolicy.tab(
            source: source,
            selection: 4..<4,
            backwards: true
        )
        #expect(plan.outcome == .handled)
        #expect(plan.selection == 4..<4)
    }
}
