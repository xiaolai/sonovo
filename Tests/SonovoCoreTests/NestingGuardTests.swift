import Testing
@testable import SonovoCore

@Suite("Nesting guard")
struct NestingGuardTests {
    @Test("A backtick in the fence info string is not a fence")
    func invalidFenceInfoIsNotAFence() {
        let run = String(repeating: "*", count: 20_000)
        // CommonMark: a backtick fence's info string may not contain a
        // backtick, so this line does not open a fence and the delimiter
        // run behind it must still reach the guard.
        #expect(
            NestingGuard.exceedsInlineLimit(
                "``` `\n\n" + run + "x" + run,
                limit: 100
            )
        )
        // A valid fence does hide its content from the scanner.
        #expect(
            !NestingGuard.exceedsInlineLimit(
                "```swift\n" + run + "\n```\n",
                limit: 100
            )
        )
    }

    @Test("Four spaces of indentation is not a fence")
    func overIndentedFenceIsNotAFence() {
        let run = String(repeating: "*", count: 20_000)
        // An indented code block, not a fence: its content must be scanned.
        #expect(
            NestingGuard.exceedsInlineLimit(
                "    ```\n" + run + "x" + run,
                limit: 100
            )
        )
    }

    @Test("A single long run cannot hide behind weighting")
    func longRunDepth() {
        let source = String(repeating: "*", count: 512) + "x\n"
            + String(repeating: "a*\n", count: 512)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("Single tildes count as delimiter characters")
    func singleTildeNesting() {
        // cmark-gfm pairs single tildes across lines; excluding them let a
        // document nest without being counted.
        let source = String(repeating: "~a\n", count: 300) + "x"
            + String(repeating: "\na~", count: 300)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("A combining mark after a delimiter does not hide it")
    func combiningMarkDelimiter() {
        // Swift groups the mark into the same grapheme as the asterisk;
        // cmark sees the asterisk as the delimiter. Compare by first scalar.
        let source = String(repeating: "*\u{0301}a\n", count: 300) + "x"
            + String(repeating: "\na*", count: 300)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("The monotone opener budget bounds balanced text too")
    func openerBudgetIsSound() {
        // Every pair is balanced, so the stack stays empty; the opener
        // count cannot fall, and it is what the sound bound relies on.
        let source = String(
            repeating: "*a* ",
            count: MarkdownLimits.maxInlineOpenerBudget / 2 + 100
        )
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("A non-ASCII declaration does not open a raw-HTML block")
    func declarationRequiresASCII() {
        let source = "<!\u{00C4}\n"
            + String(repeating: ">", count: 300) + " x"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("List markers count toward container depth")
    func listMarkersCountTowardDepth() {
        // 128 quote markers plus one list marker exceed the limit, even
        // though only the quote markers are `>` characters.
        let source = "<a / garbage>\n- "
            + String(repeating: ">", count: 128) + " x"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("A delimiter inside a same-line code span is literal")
    func codeSpanContentIsLiteral() {
        // The span closes on the line, so cmark pairs exactly these two
        // runs; its content cannot close the opener before it.
        let source = String(repeating: "*a `x*` b\n", count: 300)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("A tag's delimiters count as openers")
    func tagDelimitersCountAsOpeners() {
        // Whether cmark treats the tag as literal or as markup, counting
        // its delimiters as openers cannot let a real opener disappear.
        let source = String(repeating: "<b x*>\n", count: 300)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("A cross-line code span makes closers uncertain")
    func multilineCodeSpanUncertainty() {
        // cmark hides the closer inside a cross-line code span; counting it
        // as a closer would remove an opener the reference parser keeps.
        let source = String(repeating: "*a `b*\n `\n", count: 300) + "x"
            + String(repeating: "\na*", count: 300)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("Inline HTML tag content is not markup")
    func inlineHTMLTagContent() {
        let source = String(
            repeating: "*a <b title=\"x* \">\n",
            count: 300
        ) + "x" + String(repeating: "\na*", count: 300)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("A combining mark after a delimiter still opens")
    func combiningMarkStillOpens() {
        let source = String(repeating: "*\u{0301}\n", count: 300) + "x"
            + String(repeating: "\na*", count: 300)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("Brackets and emphasis share one depth budget")
    func combinedBracketAndEmphasisDepth() {
        let source = String(repeating: "*a\n", count: 200)
            + String(repeating: "![a\n", count: 100)
            + "x"
            + String(repeating: "\na](x)", count: 100)
            + String(repeating: "\na*", count: 200)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("A raw-HTML block cannot hide container nesting")
    func htmlBlockCannotHideContainers() {
        for opener in ["<a / garbage>\n", "a\n<a>\n"] {
            let source = opener + String(repeating: ">", count: 300) + " x"
            #expect(NestingGuard.exceedsLimit(source, limit: 100))
        }
    }

    @Test("A container-scoped HTML block ends when its container does")
    func containerScopedHTMLWithoutBlankLine() {
        // A list item's HTML block ends at the first unindented line, even
        // without a blank line before it.
        let source = "- <script>\n"
            + String(repeating: ">", count: 300) + " x"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("A container-scoped HTML block ends with its container")
    func containerScopedHTMLBlock() {
        // The `<script>` block sits inside a blockquote. Its own terminator
        // never appears, but the blank line ends the container and the
        // block with it; the next line's quote markers must still be
        // counted.
        let source = "> <script>\n\n"
            + String(repeating: ">", count: 200) + " x"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))

        // A top-level raw-text block still runs to its own terminator.
        let topLevel = "<script>\n\n"
            + String(repeating: ">", count: 200) + " x\n</script>"
        #expect(!NestingGuard.exceedsLimit(topLevel, limit: 100))
    }

    @Test("Emphasis nesting is tracked across lines")
    func multilineEmphasisNesting() {
        // Each line opens two delimiters that only the tail closes; cmark
        // pairs them into hundreds of nested nodes even though no line
        // exceeds the per-line cap.
        let source = String(repeating: "*a _a\n", count: 200)
            + "x"
            + String(repeating: "\na_ a*", count: 200)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))

        // Balanced emphasis on every line stays well inside the depth.
        let balanced = String(repeating: "*a* _b_\n", count: 200)
        #expect(!NestingGuard.exceedsInlineLimit(balanced, limit: 100))
    }
}
