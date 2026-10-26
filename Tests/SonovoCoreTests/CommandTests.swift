import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown commands")
struct CommandTests {
    private let registry = MarkdownCommandRegistry()

    private func apply(
        _ command: MarkdownCommandKind,
        to source: String,
        selection: Range<Int>
    ) throws -> MarkdownCommandResult {
        try registry.apply(
            command,
            to: MarkdownCommandContext(
                source: source,
                selection: selection
            )
        )
    }

    @Test("A table command rewrites only the table block")
    func tableCommand() throws {
        let source = "before\n| a | b |\n| --- | --- |\n| 1 | 2 |\nafter"
        let caret = (source as NSString).range(of: "1").location
        let result = try apply(
            .insertTableRowBelow,
            to: source,
            selection: caret..<caret
        )
        #expect(result.source.hasPrefix("before\n"))
        #expect(result.source.hasSuffix("\nafter"))
        #expect(result.source.contains("| 1 | 2 |\n|     |     |"))
        #expect(result.actionName == "Insert Row Below")
    }

    @Test("Line commands run through the one command path")
    func lineCommand() throws {
        let moved = try apply(
            .lineUp,
            to: "A\nB\n",
            selection: 3..<3
        )
        #expect(moved.source == "B\nA\n")
        let upper = try apply(.uppercase, to: "abc", selection: 0..<3)
        #expect(upper.source == "ABC")
        #expect(upper.actionName == "Uppercase")
    }

    @Test("Frontmatter replacement touches only its range")
    func frontmatterReplace() throws {
        let source = "---\ntitle: A\n---\n\nBody\n"
        let parsed = MarkdownParser.parseCanonical(source)
        let frontmatter = try #require(parsed.ast.frontmatter?.range)
        let range: Range<Int> = frontmatter.lowerBound..<frontmatter.upperBound
        let result = try apply(
            .replaceFrontmatter(
                range: range,
                text: "---\ntitle: B\n---"
            ),
            to: source,
            selection: 0..<0
        )
        #expect(result.source == "---\ntitle: B\n---\n\nBody\n")
        #expect(result.actionName == "Edit Frontmatter")
    }

    @Test("A malformed table refuses a semantic command")
    func malformedTableCommand() {
        let source = "| a | b |\n| --- |\n| 1 | 2 |"
        let caret = (source as NSString).range(of: "a").location
        #expect(throws: MarkdownCommandError.tableRefused("malformedTable")) {
            try apply(
                .deleteTableRow,
                to: source,
                selection: caret..<caret
            )
        }
    }

    @Test("A table command outside a table is not applicable")
    func tableCommandOutside() {
        #expect(throws: MarkdownCommandError.notApplicable("Delete Row")) {
            try apply(
                .deleteTableRow,
                to: "plain",
                selection: 0..<0
            )
        }
    }

    @Test("Wrapping toggles are fixed points and preserve whitespace")
    func wrapping() throws {
        let bold = try apply(
            .toggleStrong,
            to: "x hello y",
            selection: 1..<8
        )
        #expect(bold.source == "x **hello** y")
        #expect(bold.selection == 4..<9)

        let unwrapped = try apply(
            .toggleStrong,
            to: bold.source,
            selection: bold.selection
        )
        #expect(unwrapped.source == "x hello y")

        let italic = try apply(.toggleEmphasis, to: "abc", selection: 0..<3)
        #expect(italic.source == "*abc*")
        let strike = try apply(.toggleStrikethrough, to: "abc", selection: 0..<3)
        #expect(strike.source == "~~abc~~")
    }

    @Test("Inline code uses a fence longer than embedded backticks")
    func inlineCodeWithBackticks() throws {
        let result = try apply(.toggleInlineCode, to: "a`b", selection: 0..<3)
        #expect(result.source == "``a`b``")
        let unwrapped = try apply(
            .toggleInlineCode,
            to: result.source,
            selection: result.selection
        )
        #expect(unwrapped.source == "a`b")
    }

    @Test("Unwrapping a marker-inclusive selection keeps the inner location")
    func unwrapInclusiveSelection() throws {
        let result = try apply(
            .toggleStrong,
            to: "x **hello** y",
            selection: 2..<11
        )
        #expect(result.source == "x hello y")
        #expect(result.selection == 2..<7)
    }

    @Test("Inline code pads content that starts with a backtick")
    func inlineCodePadding() throws {
        let result = try apply(.toggleInlineCode, to: "`a", selection: 0..<2)
        #expect(result.source == "`` `a ``")

        let unwrapped = try apply(
            .toggleInlineCode,
            to: result.source,
            selection: result.selection
        )
        #expect(unwrapped.source == "`a")
    }

    @Test("Inserted link labels and destinations are escaped")
    func linkEscaping() throws {
        let label = try apply(
            .insertLink(destination: "https://example.com"),
            to: "a]b",
            selection: 0..<3
        )
        #expect(label.source == "[a\\]b](https://example.com)")

        let destination = try apply(
            .insertLink(destination: "https://example.com/a b"),
            to: "x",
            selection: 0..<1
        )
        #expect(destination.source == "[x](<https://example.com/a b>)")

        let entity = try apply(
            .insertLink(destination: "https://example.com/?a=1&b=2"),
            to: "x",
            selection: 0..<1
        )
        #expect(entity.source == "[x](https://example.com/?a=1\\&b=2)")

        #expect(throws: MarkdownCommandError.self) {
            _ = try apply(
                .insertLink(destination: "https://example.com/a\nb"),
                to: "x",
                selection: 0..<1
            )
        }
    }

    @Test("An all-space code span keeps its content")
    func allSpaceInlineCode() throws {
        let result = try apply(
            .toggleInlineCode,
            to: "``  ``",
            selection: 0..<6
        )
        #expect(result.source == "  ")
    }

    @Test("A code fence outgrows backtick runs in the selection")
    func codeFenceOutgrowsBody() throws {
        let result = try apply(.insertCodeFence, to: "```\n", selection: 0..<4)
        #expect(result.source.hasPrefix("````\n```\n````\n"))
    }

    @Test("Block quote toggles on for an empty document")
    func emptyBlockQuote() throws {
        let result = try apply(.toggleBlockQuote, to: "", selection: 0..<0)
        #expect(result.source == "> ")
    }

    @Test("Italic inside bold adds italic instead of removing bold")
    func italicInsideBold() throws {
        let result = try apply(
            .toggleEmphasis,
            to: "**word**",
            selection: 2..<6
        )
        #expect(result.source == "***word***")
    }

    @Test("Heading removal leaves blank separators untouched")
    func headingRemovalKeepsBlankLines() throws {
        let result = try apply(
            .toggleHeading(level: 2),
            to: "## a\n\n## b",
            selection: 0..<10
        )
        #expect(result.source == "a\n\nb")
    }

    @Test("Wiki targets reject delimiters that change their meaning")
    func wikiTargetDelimiters() {
        #expect(throws: MarkdownCommandError.self) {
            _ = try apply(
                .insertWikiLink(target: "a|b", alias: nil),
                to: "",
                selection: 0..<0
            )
        }
        #expect(throws: MarkdownCommandError.self) {
            _ = try apply(
                .insertWikiLink(target: "a\nb", alias: nil),
                to: "",
                selection: 0..<0
            )
        }
    }

    @Test("Details insertion escapes the summary and forms a block")
    func detailsInsertionSafety() throws {
        let result = try apply(
            .insertDetails(summary: "A</summary>B"),
            to: "aa",
            selection: 1..<1
        )
        #expect(
            result.source.contains(
                "<summary>A&lt;/summary&gt;B</summary>"
            )
        )
        #expect(result.source.contains("\n\n<details open>"))
        #expect(result.source.contains("</details>\n\n"))
    }

    @Test("Heading toggles on and off per line")
    func headings() throws {
        let on = try apply(.toggleHeading(level: 2), to: "a\nb", selection: 0..<3)
        #expect(on.source == "## a\n## b")

        let off = try apply(
            .toggleHeading(level: 2),
            to: on.source,
            selection: 0..<8
        )
        #expect(off.source == "a\nb")

        let changed = try apply(
            .toggleHeading(level: 3),
            to: "## a",
            selection: 0..<4
        )
        #expect(changed.source == "### a")
    }

    @Test("Blockquote toggles on and off")
    func blockquote() throws {
        let on = try apply(.toggleBlockQuote, to: "a\nb", selection: 0..<3)
        #expect(on.source == "> a\n> b")
        let off = try apply(
            .toggleBlockQuote,
            to: on.source,
            selection: 0..<7
        )
        #expect(off.source == "a\nb")
    }

    @Test("Lists toggle on and off with numbering and task markers")
    func lists() throws {
        let bullet = try apply(.toggleList(kind: .bullet), to: "a\nb", selection: 0..<3)
        #expect(bullet.source == "- a\n- b")

        let ordered = try apply(.toggleList(kind: .ordered), to: "a\nb", selection: 0..<3)
        #expect(ordered.source == "1. a\n2. b")

        let task = try apply(.toggleList(kind: .task), to: "a\nb", selection: 0..<3)
        #expect(task.source == "- [ ] a\n- [ ] b")

        let off = try apply(
            .toggleList(kind: .bullet),
            to: bullet.source,
            selection: 0..<7
        )
        #expect(off.source == "a\nb")

        let started = try apply(.toggleList(kind: .bullet), to: "", selection: 0..<0)
        #expect(started.source == "- ")
    }

    @Test("Link and image insertion validate destinations")
    func linkInsertion() throws {
        let link = try apply(
            .insertLink(destination: "https://example.com"),
            to: "click",
            selection: 0..<5
        )
        #expect(link.source == "[click](https://example.com)")

        let image = try apply(
            .insertImage(destination: "assets/a.png", alt: "alt"),
            to: "",
            selection: 0..<0
        )
        #expect(image.source == "![alt](assets/a.png)")

        #expect(throws: MarkdownCommandError.self) {
            _ = try apply(
                .insertLink(destination: "javascript:alert(1)"),
                to: "click",
                selection: 0..<5
            )
        }
    }

    @Test("Code fence and rule insert boundaries")
    func fenceAndRule() throws {
        let fence = try apply(.insertCodeFence, to: "code", selection: 0..<4)
        #expect(fence.source == "```\ncode\n```")

        let rule = try apply(.insertRule, to: "abc", selection: 3..<3)
        #expect(rule.source == "abc\n\n---")
    }

    @Test("Wiki links use the selection as target or alias")
    func wikiLinkInsertion() throws {
        let plain = try apply(
            .insertWikiLink(target: "", alias: nil),
            to: "Page",
            selection: 0..<4
        )
        #expect(plain.source == "[[Page]]")

        let aliased = try apply(
            .insertWikiLink(target: "Other", alias: nil),
            to: "Page",
            selection: 0..<4
        )
        #expect(aliased.source == "[[Other|Page]]")

        let explicit = try apply(
            .insertWikiLink(target: "Other", alias: "Alias"),
            to: "",
            selection: 0..<0
        )
        #expect(explicit.source == "[[Other|Alias]]")

        #expect(throws: MarkdownCommandError.self) {
            _ = try apply(
                .insertWikiLink(target: "../secret", alias: nil),
                to: "",
                selection: 0..<0
            )
        }
    }

    @Test("Details insertion keeps the required blank line")
    func detailsInsertion() throws {
        let result = try apply(
            .insertDetails(summary: "Summary"),
            to: "body",
            selection: 0..<4
        )
        #expect(result.source.contains("<details open>"))
        #expect(result.source.contains("<summary>Summary</summary>"))
        #expect(result.source.contains("</summary>\n\nbody"))
        #expect(result.source.hasSuffix("</details>"))
    }

    @Test("TOC insertion is a standalone paragraph")
    func tocInsertion() throws {
        let atStart = try apply(.insertTOC, to: "", selection: 0..<0)
        #expect(atStart.source == "[TOC]")

        let afterText = try apply(.insertTOC, to: "abc", selection: 3..<3)
        #expect(afterText.source == "abc\n\n[TOC]")
    }

    @Test("Replace-all honors case sensitivity")
    func replaceAll() throws {
        let sensitive = try apply(
            .replaceAll(query: "a", replacement: "b", caseSensitive: true),
            to: "aAa",
            selection: 0..<0
        )
        #expect(sensitive.source == "bAb")

        let insensitive = try apply(
            .replaceAll(query: "a", replacement: "b", caseSensitive: false),
            to: "aAa",
            selection: 0..<0
        )
        #expect(insensitive.source == "bbb")
    }

    @Test("Details open attribute is edited in place")
    func detailsOpenAttribute() throws {
        let source = "<details><summary>S</summary>\n\nbody\n</details>"
        let opened = try apply(
            .setDetailsOpen(true),
            to: source,
            selection: 30..<30
        )
        #expect(opened.source.hasPrefix("<details open>"))

        let closed = try apply(
            .setDetailsOpen(false),
            to: opened.source,
            selection: 30..<30
        )
        #expect(closed.source.hasPrefix("<details>"))

        let withClass = "<details open class=\"x\"><summary>S</summary>\n\nbody\n</details>"
        let cursor = (withClass as NSString).range(of: "body").location
        let classClosed = try apply(
            .setDetailsOpen(false),
            to: withClass,
            selection: cursor..<cursor
        )
        #expect(classClosed.source.hasPrefix("<details class=\"x\">"))
    }

    @Test("Fake details tags are not structural targets")
    func fakeDetailsTargets() {
        let escaped = "\\<details><summary>S</summary>\n\nbody\n</details>"
        let escapedCursor = (escaped as NSString).range(of: "body").location
        #expect(throws: MarkdownCommandError.self) {
            _ = try apply(
                .setDetailsOpen(false),
                to: escaped,
                selection: escapedCursor..<escapedCursor
            )
        }

        let indented = "    <details>\n\nbody\n"
        let indentedCursor = (indented as NSString).range(of: "body").location
        #expect(throws: MarkdownCommandError.self) {
            _ = try apply(
                .setDetailsOpen(false),
                to: indented,
                selection: indentedCursor..<indentedCursor
            )
        }

        let attribute = "<div title=\"<details>\">\n\nbody\n"
        let attributeCursor = (attribute as NSString).range(of: "body").location
        #expect(throws: MarkdownCommandError.self) {
            _ = try apply(
                .setDetailsOpen(false),
                to: attribute,
                selection: attributeCursor..<attributeCursor
            )
        }

        let quotedFence = "> ```\n> <details>\n> ```\n\nbody\n"
        let fenceCursor = (quotedFence as NSString).range(of: "body").location
        #expect(throws: MarkdownCommandError.self) {
            _ = try apply(
                .setDetailsOpen(false),
                to: quotedFence,
                selection: fenceCursor..<fenceCursor
            )
        }
    }

    @Test("Availability respects read-only, IME, and viewer mode")
    func availability() {
        let command = MarkdownCommandKind.toggleStrong
        #expect(registry.isAvailable(
            command,
            in: MarkdownCommandContext(source: "a", selection: 0..<1)
        ))
        #expect(!registry.isAvailable(
            command,
            in: MarkdownCommandContext(source: "a", selection: 0..<1, isReadOnly: true)
        ))
        #expect(!registry.isAvailable(
            command,
            in: MarkdownCommandContext(source: "a", selection: 0..<1, hasMarkedText: true)
        ))
        #expect(!registry.isAvailable(
            command,
            in: MarkdownCommandContext(source: "a", selection: 0..<1, mode: .rendered)
        ))
    }

    @Test("Changed range is minimal")
    func changedRange() throws {
        let result = try apply(
            .toggleStrong,
            to: "abc",
            selection: 0..<3
        )
        #expect(result.changedRange == 0..<7)
    }

    @Test("Nested emphasis toggles restore the inner style")
    func nestedEmphasis() throws {
        let italic = try apply(
            .toggleEmphasis,
            to: "**word**",
            selection: 2..<6
        )
        #expect(italic.source == "***word***")

        let restored = try apply(
            .toggleEmphasis,
            to: italic.source,
            selection: 3..<7
        )
        #expect(restored.source == "**word**")

        let bold = try apply(
            .toggleStrong,
            to: "*word*",
            selection: 1..<5
        )
        #expect(bold.source == "***word***")
        let back = try apply(
            .toggleStrong,
            to: bold.source,
            selection: 3..<7
        )
        #expect(back.source == "*word*")
    }

    @Test("Code span toggle refuses to unwrap a multi-span selection")
    func codeSpanMultiSpan() throws {
        let result = try apply(
            .toggleInlineCode,
            to: "`a`b`",
            selection: 0..<5
        )
        #expect(result.source == "`` `a`b` ``")
    }

    @Test("Heading toggle accepts an empty heading")
    func emptyHeading() throws {
        let removed = try apply(
            .toggleHeading(level: 2),
            to: "##",
            selection: 0..<2
        )
        #expect(removed.source == "")

        let added = try apply(
            .toggleHeading(level: 2),
            to: "",
            selection: 0..<0
        )
        #expect(added.source == "##")

        let trailingSpace = try apply(
            .toggleHeading(level: 2),
            to: "## ",
            selection: 0..<3
        )
        #expect(trailingSpace.source == "")
    }

    @Test("Escaped markers are literal, not delimiters to unwrap")
    func escapedMarkers() throws {
        let italic = try apply(
            .toggleEmphasis,
            to: "\\*hello*",
            selection: 2..<7
        )
        #expect(italic.source == "\\**hello**")
    }

    @Test("An empty list marker toggles off instead of doubling")
    func emptyListMarker() throws {
        let result = try apply(
            .toggleList(kind: .bullet),
            to: "-",
            selection: 1..<1
        )
        #expect(result.source == "")
    }

    @Test("ATX closing hashes are syntax, not content")
    func atxClosingHashes() throws {
        let result = try apply(
            .toggleHeading(level: 2),
            to: "## Title ##",
            selection: 0..<11
        )
        #expect(result.source == "Title")
    }

    @Test("A changed range never splits a surrogate pair")
    func surrogateChangedRange() {
        let result = MarkdownCommandResult(
            source: "😁",
            selection: 0..<0,
            actionName: "Edit",
            previousSource: "😀"
        )
        #expect(result.changedRange == 0..<2)
    }

    @Test("Task formatting preserves checked state in a mixed selection")
    func taskCheckedState() throws {
        let result = try apply(
            .toggleList(kind: .task),
            to: "- [x] done\nplain",
            selection: 0..<16
        )
        #expect(result.source == "- [x] done\n- [ ] plain")

        let emptyChecked = try apply(
            .toggleList(kind: .task),
            to: "- [x]\nplain",
            selection: 0..<11
        )
        #expect(emptyChecked.source == "- [x]\n- [ ] plain")
    }

    @Test("A stale action target refuses before applying")
    func staleTargetRefuses() throws {
        let id = UUID()
        let target = MarkdownActionTarget(
            documentID: id,
            identityGeneration: 1,
            sourceRevision: 7,
            range: 1..<4,
            expectedSlice: "abc",
            rootGeneration: 2
        )
        let current = MarkdownCommandContext(
            source: "xabcx",
            selection: 1..<4,
            documentID: id,
            identityGeneration: 1,
            sourceRevision: 7,
            rootGeneration: 2,
            target: target
        )
        #expect(registry.isAvailable(.toggleStrong, in: current))
        let result = try registry.apply(.toggleStrong, to: current)
        #expect(result.source == "x**abc**x")

        var newerRevision = current
        newerRevision.sourceRevision = 8
        #expect(!registry.isAvailable(.toggleStrong, in: newerRevision))
        #expect(throws: MarkdownCommandError.staleTarget) {
            try registry.apply(.toggleStrong, to: newerRevision)
        }

        var changedSlice = current
        changedSlice.source = "xabdx"
        #expect(!registry.isAvailable(.toggleStrong, in: changedSlice))
        #expect(throws: MarkdownCommandError.staleTarget) {
            try registry.apply(.toggleStrong, to: changedSlice)
        }

        var differentRoot = current
        differentRoot.rootGeneration = 3
        #expect(throws: MarkdownCommandError.staleTarget) {
            try registry.apply(.toggleStrong, to: differentRoot)
        }
    }
}
