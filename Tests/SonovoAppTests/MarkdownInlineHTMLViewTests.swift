import AppKit
import SwiftUI
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MarkdownInlineHTMLViewTests: XCTestCase {
    private var theme: MarkdownTheme {
        MarkdownThemeStore.shared.defaultTheme()
    }

    private func makeAST(_ source: String) -> SonovoAST {
        let parsed = MarkdownParser.parseCanonical(source)
        return MarkdownSyntaxAugmenter().augment(parsed)
    }

    private func paragraphInlines(_ source: String) throws -> [Inline] {
        let ast = makeAST(source)
        guard case let .paragraph(inlines, _) = ast.blocks.first else {
            throw XCTSkip("expected a paragraph")
        }
        return inlines
    }

    private func viewer(for ast: SonovoAST) -> MarkdownViewer {
        MarkdownViewer(
            ast: ast,
            headings: HeadingIndex(ast: ast),
            theme: theme
        )
    }

    // MARK: - Viewer

    func testViewerAppliesTheAllowlistedStyles() throws {
        let source = "前<mark>重点</mark><u>下划线</u><sup>1</sup><sub>2</sub>后"
        let ast = makeAST(source)
        let inlines = try paragraphInlines(source)
        let attributed = viewer(for: ast).attributed(inlines)
        let runs = Array(attributed.runs)

        XCTAssertTrue(
            runs.contains { $0.backgroundColor != nil },
            "mark needs a background"
        )
        XCTAssertTrue(
            runs.contains { $0.underlineStyle != nil },
            "u needs an underline"
        )
        XCTAssertTrue(
            runs.contains {
                abs(($0.baselineOffset ?? 0) - 4.5) < 0.001
            },
            "sup needs a raised baseline"
        )
        XCTAssertTrue(
            runs.contains {
                abs(($0.baselineOffset ?? 0) + 4.5) < 0.001
            },
            "sub needs a lowered baseline"
        )
        // The text survives; only the tags are structural.
        XCTAssertTrue(String(attributed.characters).contains("重点"))
        XCTAssertTrue(String(attributed.characters).contains("下划线"))
        XCTAssertFalse(String(attributed.characters).contains("<mark>"))
    }

    func testViewerNestsScriptInsideHighlight() throws {
        let source = "<mark>重点<sup>1</sup></mark>"
        let ast = makeAST(source)
        let inlines = try paragraphInlines(source)
        let attributed = viewer(for: ast).attributed(inlines)
        let runs = Array(attributed.runs)
        XCTAssertTrue(runs.allSatisfy { $0.backgroundColor != nil })
        XCTAssertTrue(
            runs.contains {
                abs(($0.baselineOffset ?? 0) - 4.5) < 0.001
            }
        )
    }

    func testViewerHidesUnknownInlineHTML() throws {
        let source = "前<script>alert(1)</script><b>粗</b>后"
        let ast = makeAST(source)
        let inlines = try paragraphInlines(source)
        let text = String(viewer(for: ast).attributed(inlines).characters)
        XCTAssertEqual(text, "前alert(1)粗后")
    }

    func testViewerDropsAttributeBearingTags() throws {
        let source = "<mark class=\"x\">重点</mark>"
        let ast = makeAST(source)
        let inlines = try paragraphInlines(source)
        let attributed = viewer(for: ast).attributed(inlines)
        XCTAssertEqual(String(attributed.characters), "重点")
        XCTAssertTrue(
            Array(attributed.runs).allSatisfy { $0.backgroundColor == nil }
        )
    }

    // MARK: - Export

    func testExportEmitsTheAllowlistedTags() {
        let source = "前<mark>重点</mark>，<u>下划线</u>，<sup>1</sup>，<sub>2</sub>。"
        let ast = makeAST(source)
        let html = MarkdownHTMLExporter.body(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme
            )
        )
        XCTAssertTrue(html.contains("<mark>重点</mark>"))
        XCTAssertTrue(html.contains("<u>下划线</u>"))
        XCTAssertTrue(html.contains("<sup>1</sup>"))
        XCTAssertTrue(html.contains("<sub>2</sub>"))
        XCTAssertFalse(html.contains("&lt;mark"))
    }

    func testExportHidesUnknownAndAttributeBearingTags() {
        let source = "a<script>alert(1)</script>b<mark class=\"x\">c</mark>"
        let ast = makeAST(source)
        let html = MarkdownHTMLExporter.body(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme
            )
        )
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("<mark"))
        XCTAssertFalse(html.contains("</mark>"))
        // The rejected tags disappear; their text stays as ordinary prose.
        XCTAssertTrue(html.contains("aalert(1)bc"))
    }

    func testExportedDocumentCarriesTheMarkTint() {
        let source = "前<mark>重点</mark>。"
        let ast = makeAST(source)
        let html = MarkdownHTMLExporter.document(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme
            )
        )
        XCTAssertTrue(html.contains("<mark>重点</mark>"))
        XCTAssertTrue(html.contains("mark {"))
        XCTAssertFalse(html.contains("<script"))
    }
}
