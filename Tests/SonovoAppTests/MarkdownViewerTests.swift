import AppKit
import SwiftUI
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MarkdownViewerTests: XCTestCase {
    private func makeAST(_ source: String) -> (SonovoAST, HeadingIndex) {
        let parsed = MarkdownParser.parseCanonical(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        return (ast, HeadingIndex(ast: ast))
    }

    /// The rendered viewer used to lex a fence synchronously from its `.task`,
    /// which is main-actor work. The lexer must run detached.
    func testFenceHighlightLexesOffTheMainActor() async throws {
        let probe = FenceLexProbe()
        let result = await MarkdownFenceHighlighter.highlight(
            code: "let value = 1\n",
            languageName: "swift",
            probe: { probe.record() }
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(probe.count, 1)
        XCTAssertFalse(
            probe.ranOnMain,
            "the fence lexer ran on the main actor"
        )
    }

    /// A fence over the cap renders plain and never reaches the lexer.
    func testOversizedFenceIsNotLexed() async {
        let code = String(
            repeating: "a",
            count: MarkdownLimits.maxHighlightedFenceBytes + 1
        )
        let probe = FenceLexProbe()
        let result = await MarkdownFenceHighlighter.highlight(
            code: code,
            languageName: "swift",
            probe: { probe.record() }
        )
        XCTAssertNil(result)
        XCTAssertEqual(probe.count, 0)
    }

    func testWikiURLRoundTrips() throws {
        let link = WikiLink(
            target: "Act One",
            fragment: "Scene 2",
            alias: "the opening"
        )
        let url = try XCTUnwrap(MarkdownViewer.wikiURL(link))
        XCTAssertEqual(MarkdownViewer.parseWikiURL(url), link)
    }

    func testFootnoteURLRoundTrips() throws {
        let url = try XCTUnwrap(MarkdownViewer.footnoteURL(number: 12))
        XCTAssertEqual(url.scheme, "sonovo-footnote")
        XCTAssertEqual(MarkdownViewer.footnoteNumber(from: url), 12)
        XCTAssertNil(
            MarkdownViewer.footnoteNumber(
                from: URL(string: "https://example.com")!
            )
        )
    }

    func testDetailsMetadataAlignsWithReconcilerKeys() {
        let source = """
        # Top

        <details><summary>Outer</summary>

        <details><summary>Inner</summary>

        body
        </details>
        </details>

        ## Next

        <details><summary>Third</summary>text</details>
        """
        let (ast, _) = makeAST(source)
        let metadata = MarkdownViewer.detailsMetadata(for: ast)
        let keys = DetailsExpansionReconciler.keys(for: ast)

        XCTAssertEqual(metadata.map.count, keys.count)
        XCTAssertEqual(metadata.ranges.count, keys.count)
        XCTAssertEqual(Set(metadata.map.values), Set(0..<keys.count))
        XCTAssertEqual(Set(metadata.ranges.map(\.index)), Set(0..<keys.count))
    }

    func testViewerLaysOutAllBlockTypes() {
        let source = """
        ---
        title: Test
        ---

        # Heading

        Paragraph with **bold**, *italic*, `code`, [a link](https://example.com), and [[Wiki]].

        A footnote reference[^note].

        [Take 2](sonovo:take?path=assets/take-2.mov&seconds=12.5) and
        [Missing take](sonovo:take?path=assets/missing.mov).

        > A quote

        > [!NOTE]
        > A note callout.

        > [!WARNING]
        > A warning callout.

        > [!FOO]
        > An unknown marker stays an ordinary quote.

        - bullet
        - [x] task

        1. one

        ```swift
        let x = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        ---

        [TOC]

        <details open><summary>Summary</summary>

        Body inside.

        </details>

        <div>raw html is hidden</div>

        [^note]: The footnote body.
        """
        let (ast, headings) = makeAST(source)
        let viewer = MarkdownViewer(
            ast: ast,
            headings: headings,
            theme: MarkdownThemeStore.shared.defaultTheme()
        )
        let hosting = NSHostingView(rootView: viewer)
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        hosting.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
    }

    func testDisabledWikiLinkResolutionRendersWithoutCrashing() {
        let (ast, headings) = makeAST("See [[Missing Page]].\n")
        let viewer = MarkdownViewer(
            ast: ast,
            headings: headings,
            theme: MarkdownThemeStore.shared.defaultTheme(),
            wikiLinkState: { _ in .missing },
            onOpenWikiLink: { _ in }
        )
        let hosting = NSHostingView(rootView: viewer)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(hosting.fittingSize.width, 0)
    }
}

/// Records where the fence lexer ran. The probe crosses into `Task.detached`
/// and the test thread reads only after the await.
private final class FenceLexProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observations = 0
    private var mainThread = false

    func record() {
        lock.lock()
        observations += 1
        mainThread = mainThread || Thread.isMainThread
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return observations
    }

    var ranOnMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mainThread
    }
}
