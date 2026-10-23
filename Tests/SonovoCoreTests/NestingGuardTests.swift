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

    @Test("A hidden deep line is caught by its own markers")
    func hiddenDeepLineBackstop() {
        // The fence is misclassified after a tab, so comment state hides
        // the last line from the block walkers; the line's own markers
        // still bound its depth.
        let source = "> \t```\n> <!--\n> ```\n"
            + String(repeating: ">", count: 129) + " x\n"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("A blank line after a list fence does not trap")
    func blankLineAfterListFence() {
        // The sibling check used to subscript the end index of a blank
        // line.
        #expect(!NestingGuard.exceedsLimit("- ```\n\n", limit: 100))
    }

    @Test("A fence hides HTML recognition inside it")
    func fenceHidesHTMLRecognition() {
        let source = "```\n<!--\n```\n-->\n"
            + String(repeating: "*a\n", count: 300) + "x"
            + String(repeating: "\na*", count: 300)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("A sibling item behind a quote ends the fence")
    func quotedSiblingItemEndsFence() {
        let source = "> - ```\n> - "
            + String(repeating: ">", count: 129) + " x"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("A tabled HTML indentation is measured in columns")
    func tabIndentedHTML() {
        let source = ">\t\t<script>\n"
            + String(repeating: ">", count: 129) + " x\n"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("A quoted sibling item ends the HTML block")
    func quotedSiblingItemEndsHTML() {
        let source = "> - <!--\n> - "
            + String(repeating: ">", count: 129) + " x"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("An HTML opening line's delimiters are counted")
    func htmlOpeningLineDelimiters() {
        // The whole markup can sit inside one tag-shaped line. Skipping it
        // without counting its delimiters hides the nesting.
        let source = "<b " + String(repeating: "*a ", count: 5_000)
            + "x" + String(repeating: " a*", count: 5_000) + ">\n"
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("A sibling list item ends a fence opened inside the list")
    func siblingItemEndsFence() {
        let source = "- ```\n- "
            + String(repeating: ">", count: 129) + " x\n"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("A sibling list item ends an HTML block opened inside the list")
    func siblingItemEndsHTMLBlock() {
        let source = "- <!--\n- "
            + String(repeating: ">", count: 129) + " x\n"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("An over-indented HTML block is not a block")
    func overIndentedHTMLBlock() {
        let source = ">     <script>\n"
            + String(repeating: ">", count: 129) + " x\n"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("Backticks inside an HTML comment do not open a fence")
    func backticksInsideHTMLComment() {
        let source = "<!--\n```\n-->\n"
            + String(repeating: "*a\n", count: 5_000) + "x"
            + String(repeating: "\na*", count: 5_000)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("A fence cannot outlive the list it opened inside")
    func fenceScopeIncludesList() {
        let source = "> - ```\n"
            + String(repeating: ">", count: 129) + " x\n"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("A fence indented past three columns inside a container is not a fence")
    func containerFenceIndentation() {
        let source = ">     ```\n"
            + String(repeating: ">", count: 129) + " x\n"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("A format character does not hide a delimiter from the count")
    func formatCharacterDelimiter() {
        // U+0600 joins the asterisk into one grapheme; cmark sees the
        // asterisk, so the opener has to count.
        let source = String(
            repeating: "\u{0600}*x*\n",
            count: MarkdownLimits.maxInlineOpenerBudget + 100
        )
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("A backtick run longer than cmark's cap is not a code span")
    func longBacktickRunIsNotACodeSpan() {
        let fenceRun = String(repeating: "`", count: 1_001)
        let source = "a " + fenceRun + " " + String(repeating: "*a ", count: 5_000)
            + fenceRun + "\nx" + String(repeating: "\na*", count: 5_000)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("An escaped combining mark does not swallow the next delimiter")
    func escapedCombiningMark() {
        // The backslash escapes the combining scalar, not the asterisk.
        let source = String(repeating: "a \\\u{0301}*a\n", count: 300) + "x"
            + String(repeating: "\na*", count: 300)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("Mixed tab and space indentation advances by columns")
    func mixedTabIndentation() {
        let lists = (0..<200).map { level -> String in
            let prefix = level % 2 == 0
                ? String(repeating: "  \t", count: level / 2)
                : String(repeating: "  ", count: level)
            return prefix + "- x\n"
        }.joined()
        #expect(NestingGuard.exceedsLimit(lists, limit: 100))
    }

    @Test("A line opening a fence still counts its containers")
    func fenceOpeningLineContainers() {
        let source = String(repeating: ">", count: 129) + " ```\n"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("A combining mark does not merge inline backtick runs")
    func combiningInsideInlineRun() {
        // Each line's backticks are two runs of one scalar, not a two-run
        // span; the emphasis between them is real and must be counted.
        let line = "`\u{0301}` " + String(repeating: "*a ", count: 7)
            + "`\u{0301}`x\n"
        let source = String(repeating: line, count: 1_000) + "x"
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("The HTML opening line's own containers count")
    func htmlOpeningLineContainers() {
        let lists = (1..<129).map { level in
            String(repeating: "  ", count: level) + "- x\n"
        }.joined()
        let source = "- <a / garbage>\n" + lists
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("Tab indentation still accumulates container depth")
    func tabIndentedContainers() {
        let lists = (0..<129).map { level in
            String(repeating: "\t", count: level) + "- x\n"
        }.joined()
        #expect(NestingGuard.exceedsLimit(lists, limit: 100))
    }

    @Test("A four-space indented fence is not a fence")
    func indentedFenceIsNotAFence() {
        let source = "    ```\n"
            + String(repeating: ">", count: 129) + " x\n"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("A combining mark inside a backtick run does not open a fence")
    func combiningInsideFenceRun() {
        // cmark counts code points: two backticks, a combining mark, one
        // backtick is not a run of three. A grapheme-based count invented a
        // fence and hid the rest of the document.
        let source = "``\u{0301}`\n"
            + String(repeating: "*a\n", count: 300) + "x"
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("A tag containing a backtick is not skipped")
    func tagWithBacktickIsNotSkipped() {
        let source = "<b `>\n"
            + String(repeating: "*a\n", count: 300) + "x"
            + String(repeating: "\na*", count: 300)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("Brackets inside a tag count toward the opener budget")
    func tagBracketsCountTowardBudget() {
        let source = String(
            repeating: "a <b ![\u{0301}a >\n",
            count: MarkdownLimits.maxInlineOpenerBudget + 10
        ) + "x"
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
    }

    @Test("Skipped HTML lines still accumulate container depth")
    func htmlSkipAccumulatesContainers() {
        // Each line opens one more list level; the HTML recognizer must not
        // stop the depth stack from following them.
        let lines = (0..<129).map { level in
            String(repeating: "  ", count: level) + "- x\n"
        }
        let source = "<a / garbage>\n" + lines.joined()
        #expect(NestingGuard.exceedsLimit(source, limit: 100))
    }

    @Test("A span after a cross-line opener is not skipped")
    func spanAfterCrossLineOpener() {
        // The first line's backtick can pair with this line's, making the
        // following text inline. Once the paragraph is uncertain, skipping
        // same-line spans would hide openers cmark uses.
        let source = "`x\n"
            + String(repeating: "` *a `x\n", count: 300)
            + "` x"
            + String(repeating: "\na*", count: 300)
        #expect(NestingGuard.exceedsInlineLimit(source, limit: 100))
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
