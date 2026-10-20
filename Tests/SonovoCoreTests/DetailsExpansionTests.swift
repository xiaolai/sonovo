import Testing
@testable import SonovoCore

@Suite("Details expansion reconciliation")
struct DetailsExpansionTests {
    private func keys(_ source: String) -> [DetailsContentKey] {
        let parsed = MarkdownParser.parseCanonical(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        return DetailsExpansionReconciler.keys(for: ast)
    }

    @Test("Heading rename transfers state by unique body hash")
    func headingRename() {
        let old = keys("""
        # A

        <details><summary>S</summary>

        body
        </details>
        """)
        let new = keys("""
        # B

        <details><summary>S</summary>

        body
        </details>
        """)
        #expect(old.count == 1)
        #expect(new.count == 1)

        let result = DetailsExpansionReconciler.reconcile(
            old: old,
            oldExpansion: [true],
            new: new
        )
        #expect(result == [true])
    }

    @Test("Prepending a different block does not inherit state")
    func prependDifferentBlock() {
        let old = keys("""
        # A

        <details><summary>S</summary>

        body
        </details>
        """)
        let new = keys("""
        # A

        <details><summary>Other</summary>

        other body
        </details>

        <details><summary>S</summary>

        body
        </details>
        """)
        #expect(new.count == 2)

        let result = DetailsExpansionReconciler.reconcile(
            old: old,
            oldExpansion: [true],
            new: new
        )
        #expect(result == [false, true])
    }

    @Test("Identical duplicates reset together as an ambiguous class")
    func identicalDuplicatesReset() {
        let source = """
        <details open><summary>S</summary>body</details>

        <details open><summary>S</summary>body</details>
        """
        let old = keys(source)
        let new = keys(source)
        #expect(old.count == 2)

        let result = DetailsExpansionReconciler.reconcile(
            old: old,
            oldExpansion: [true, true],
            new: new
        )
        #expect(result == [true, true])

        // A non-authored duplicate class resets to closed, not to old state.
        let closed = source.replacingOccurrences(of: "<details open>", with: "<details>")
        let closedKeys = keys(closed)
        let reset = DetailsExpansionReconciler.reconcile(
            old: old,
            oldExpansion: [true, true],
            new: closedKeys
        )
        #expect(reset == [false, false])
    }

    @Test("A third identical block resets the whole class and inherits nothing")
    func thirdIdenticalBlock() {
        let old = keys("""
        <details><summary>S</summary>body</details>

        <details><summary>S</summary>body</details>
        """)
        let new = keys("""
        <details><summary>S</summary>body</details>

        <details><summary>S</summary>body</details>

        <details><summary>S</summary>body</details>
        """)
        #expect(new.count == 3)

        let result = DetailsExpansionReconciler.reconcile(
            old: old,
            oldExpansion: [true, true],
            new: new
        )
        #expect(result == [false, false, false])
    }

    @Test("Duplicate summaries with unique bodies keep their own state")
    func duplicateSummaryUniqueBody() {
        let old = keys("""
        <details><summary>S</summary>one</details>

        <details><summary>S</summary>two</details>
        """)
        let new = keys("""
        <details><summary>S</summary>one</details>

        <details><summary>S</summary>two</details>
        """)
        let result = DetailsExpansionReconciler.reconcile(
            old: old,
            oldExpansion: [false, true],
            new: new
        )
        #expect(result == [false, true])
    }

    @Test("One old and one new block transfer by anchor and summary")
    func singleRemainingBlock() {
        let old = keys("""
        # A

        <details><summary>S</summary>old body</details>
        """)
        let new = keys("""
        # A

        <details><summary>S</summary>new body</details>
        """)
        let result = DetailsExpansionReconciler.reconcile(
            old: old,
            oldExpansion: [true],
            new: new
        )
        #expect(result == [true])
    }

    @Test("A unique pair reaches Tier 4 when anchor and body both change")
    func uniquePairFallsThroughToSummary() {
        let old = [
            DetailsContentKey(
                anchorSlug: "a",
                summaryHash: 7,
                bodyHash: 1,
                authoredOpen: false
            )
        ]
        let new = [
            DetailsContentKey(
                anchorSlug: "b",
                summaryHash: 7,
                bodyHash: 2,
                authoredOpen: false
            )
        ]
        let result = DetailsExpansionReconciler.reconcile(
            old: old,
            oldExpansion: [true],
            new: new
        )
        #expect(result == [true])
    }

    @Test("An unmatched block uses its authored open state")
    func authoredFallback() {
        let old = keys("<details><summary>Old</summary>old</details>")
        let new = keys("<details open><summary>New</summary>new</details>")
        let result = DetailsExpansionReconciler.reconcile(
            old: old,
            oldExpansion: [false],
            new: new
        )
        #expect(result == [true])
    }

    @Test("A heading inside a blockquote anchors a following details block")
    func headingInBlockquoteAnchorsSibling() {
        let result = keys("""
        > # Heading

        <details><summary>S</summary>body</details>
        """)
        #expect(result.first?.anchorSlug == "heading")
    }

    @Test("Nested details are keyed in pre-order")
    func nestedOrder() {
        let result = keys("""
        <details><summary>Outer</summary>

        <details><summary>Inner</summary>

        body
        </details>
        </details>
        """)
        #expect(result.count == 2)
        #expect(result[0].summaryHash != result[1].summaryHash)
    }

    @Test("A table with an empty row does not hash like one without rows")
    func tableRowCountsAreHashed() {
        let withEmptyRow = keys("""
        <details><summary>S</summary>

        | a |
        |---|
        |   |

        </details>
        """)
        let withoutRows = keys("""
        <details><summary>S</summary>

        | a |
        |---|

        </details>
        """)
        #expect(withEmptyRow.count == 1)
        #expect(withoutRows.count == 1)
        #expect(withEmptyRow[0].bodyHash != withoutRows[0].bodyHash)
    }
}
