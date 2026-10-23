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
