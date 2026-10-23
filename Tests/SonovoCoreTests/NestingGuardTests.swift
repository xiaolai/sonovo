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
