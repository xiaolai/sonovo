import AppKit
import SwiftUI
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class DefinitionListViewTests: XCTestCase {
    private var theme: MarkdownTheme {
        MarkdownThemeStore.shared.defaultTheme()
    }

    private func makeAST(_ source: String) -> SonovoAST {
        let parsed = MarkdownParser.parseCanonical(source)
        return MarkdownSyntaxAugmenter().augment(parsed)
    }

    private func body(_ source: String) -> String {
        MarkdownHTMLExporter.body(
            makeAST(source),
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme
            )
        )
    }

    // MARK: - Viewer

    func testViewerLaysOutADefinitionList() {
        let ast = makeAST(
            """
            Term
            : Definition

            Alpha
            Beta
            : One
            : Two
            """
        )
        guard case .definitionList = ast.blocks.first else {
            return XCTFail("expected a definition list")
        }
        let viewer = MarkdownViewer(
            ast: ast,
            headings: HeadingIndex(ast: ast),
            theme: theme
        )
        let hosting = NSHostingView(rootView: viewer)
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
    }

    // MARK: - Export

    func testExportEmitsTermsAndDefinitions() {
        let html = body("Term\n: Definition\n")
        XCTAssertTrue(html.contains("<dl>"))
        XCTAssertTrue(html.contains("<dt>Term</dt>"))
        XCTAssertTrue(html.contains("<dd>Definition</dd>"))
        XCTAssertTrue(html.contains("definition-item"))
    }

    func testExportKeepsGroupingAndInlineMarkup() {
        let html = body(
            "Alpha\nBeta\n: **One** and [two](https://example.com)\n: `three`\n"
        )
        XCTAssertTrue(html.contains("<dt>Alpha</dt>"))
        XCTAssertTrue(html.contains("<dt>Beta</dt>"))
        XCTAssertTrue(html.contains("<strong>One</strong>"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\""))
        XCTAssertTrue(html.contains(">two</a>"))
        XCTAssertTrue(html.contains("<code>three</code>"))
        XCTAssertEqual(
            html.components(separatedBy: "<div class=\"definition-item\">")
                .count - 1,
            1
        )
    }

    func testExportNestedInBlockQuote() {
        let html = body("> Term\n> : Definition\n")
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<dt>Term</dt>"))
        XCTAssertTrue(html.contains("<dd>Definition</dd>"))
    }

    func testMalformedShapeStaysAParagraph() {
        let html = body("Term\nnot a definition\n")
        XCTAssertFalse(html.contains("<dl>"))
        XCTAssertTrue(html.contains("<p>Term\nnot a definition</p>"))
    }

    func testExportedDocumentCarriesDefinitionStyles() {
        let ast = makeAST("Term\n: Definition\n")
        let html = MarkdownHTMLExporter.document(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme
            )
        )
        XCTAssertTrue(html.contains("dt {"))
        XCTAssertTrue(html.contains("dd {"))
        XCTAssertTrue(html.contains("<dl>"))
    }
}
