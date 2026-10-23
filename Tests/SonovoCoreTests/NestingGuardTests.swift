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
}
