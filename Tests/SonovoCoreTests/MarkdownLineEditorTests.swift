import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown line editor")
struct MarkdownLineEditorTests {
    private func caret(after needle: String, in source: String) -> Range<Int> {
        let ns = source as NSString
        let found = ns.range(of: needle)
        let offset = found.location + found.length
        return offset..<offset
    }

    private func selection(
        from start: String,
        to end: String,
        in source: String
    ) -> Range<Int> {
        let ns = source as NSString
        let first = ns.range(of: start)
        let last = ns.range(of: end)
        return first.location..<(last.location + last.length)
    }

    private func run(
        _ command: MarkdownLineCommand,
        _ source: String,
        _ selection: Range<Int>
    ) -> MarkdownLineEdit {
        MarkdownLineEditor.edit(
            command,
            source: source,
            selection: selection
        )
    }

    @Test("Move up swaps the selected line with the one above")
    func moveUp() {
        let source = "A\nB\nC\n"
        let edit = run(.moveUp, source, caret(after: "B", in: source))
        #expect(edit.outcome == .handled)
        #expect(edit.replacement == "B\nA\nC\n")
    }

    @Test("Move down swaps the selected line with the one below")
    func moveDown() {
        let source = "A\nB\nC\n"
        let edit = run(.moveDown, source, caret(after: "B", in: source))
        #expect(edit.outcome == .handled)
        #expect(edit.replacement == "A\nC\nB\n")
    }

    @Test("Move up at the first line refuses")
    func moveUpAtTop() {
        let source = "A\nB\n"
        let edit = run(.moveUp, source, caret(after: "A", in: source))
        #expect(edit.outcome == .refused)
    }

    @Test("Duplicate copies the selected line")
    func duplicate() {
        let source = "A\nB\n"
        let edit = run(.duplicate, source, caret(after: "A", in: source))
        #expect(edit.replacement == "A\nA\nB\n")
    }

    @Test("Delete removes the selected line")
    func delete() {
        let source = "A\nB\n"
        let edit = run(.delete, source, caret(after: "A", in: source))
        #expect(edit.replacement == "B\n")
    }

    @Test("Join collapses the selected lines into one")
    func join() {
        let source = "A\nB\n"
        let edit = run(
            .join,
            source,
            selection(from: "A", to: "B", in: source)
        )
        #expect(edit.replacement == "A B\n")
    }

    @Test("Blank-line cleanup")
    func blankLines() {
        let source = "A\n\n\nB\n"
        let all = 0..<(source as NSString).length
        #expect(run(.removeBlankLines, source, all).replacement == "A\nB\n")
        #expect(run(.collapseBlankLines, source, all).replacement == "A\n\nB\n")
    }

    @Test("Trailing spaces are removed outside protected regions")
    func trailingSpaces() {
        let source = "A  \nB\t\n"
        let all = 0..<(source as NSString).length
        #expect(run(.trimTrailingSpaces, source, all).replacement == "A\nB\n")

        let fenced = "```\ncode  \n```\n"
        let fencedAll = 0..<(fenced as NSString).length
        #expect(
            run(.trimTrailingSpaces, fenced, fencedAll).replacement
                == nil || run(.trimTrailingSpaces, fenced, fencedAll).replacement == fenced
        )

        let frontmatter = "---\ntitle: A  \n---\n\nBody  \n"
        let frontmatterAll = 0..<(frontmatter as NSString).length
        let trimmed = run(.trimTrailingSpaces, frontmatter, frontmatterAll)
        #expect(trimmed.replacement == "---\ntitle: A  \n---\n\nBody\n")
    }

    @Test("Sort orders the selected lines")
    func sort() {
        let source = "b\na\n"
        let all = 0..<(source as NSString).length
        #expect(run(.sortAscending, source, all).replacement == "a\nb\n")
        #expect(run(.sortDescending, "a\nb\n", all).replacement == "b\na\n")
    }

    @Test("Case transforms cover the selection")
    func caseTransforms() {
        let upper = "abc"
        #expect(
            run(.uppercase, upper, 0..<3).replacement == "ABC"
        )
        #expect(
            run(.lowercase, "ABC", 0..<3).replacement == "abc"
        )
        #expect(
            run(.titleCase, "hello world", 0..<11).replacement
                == "Hello World"
        )
        #expect(run(.toggleCase, "AbC", 0..<3).replacement == "aBc")
    }

    @Test("Case transforms skip inline code and URLs")
    func caseTransformsSkipProtected() {
        let source = "`abc` def https://example.com/abc"
        let all = 0..<(source as NSString).length
        let result = run(.uppercase, source, all).replacement
        #expect(result?.contains("`abc`") == true)
        #expect(result?.contains("https://example.com/abc") == true)
        #expect(result?.contains("DEF") == true)
    }

    @Test("A no-op cleanup is not an edit")
    func noOp() {
        let source = "A\nB\n"
        let all = 0..<(source as NSString).length
        #expect(run(.trimTrailingSpaces, source, all).outcome == .notApplicable)
    }
}
