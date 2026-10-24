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

    func testWikiURLRoundTrips() throws {
        let link = WikiLink(
            target: "Act One",
            fragment: "Scene 2",
            alias: "the opening"
        )
        let url = try XCTUnwrap(MarkdownViewer.wikiURL(link))
        XCTAssertEqual(MarkdownViewer.parseWikiURL(url), link)
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

        > A quote

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
