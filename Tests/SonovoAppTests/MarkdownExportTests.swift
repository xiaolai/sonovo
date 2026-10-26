import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MarkdownExportTests: XCTestCase {
    private var theme: MarkdownTheme {
        MarkdownThemeStore.shared.defaultTheme()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func ast(_ source: String) -> SonovoAST {
        MarkdownSyntaxAugmenter().augment(MarkdownParser.parse(source))
    }

    private func body(
        _ source: String,
        documentURL: URL? = nil,
        workspaceRoot: URL? = nil,
        title: String = "Test"
    ) -> String {
        return MarkdownHTMLExporter.body(
            ast(source),
            context: MarkdownExportContext(
                title: title,
                documentURL: documentURL,
                workspaceRoot: workspaceRoot,
                theme: theme
            )
        )
    }

    private func document(
        _ source: String,
        title: String = "Test"
    ) -> String {
        return MarkdownHTMLExporter.document(
            ast(source),
            context: MarkdownExportContext(
                title: title,
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme
            )
        )
    }

    // MARK: - Snapshot

    func testSmallDocumentBodySnapshot() {
        let output = body("# Title\n\nHello **world** and *you*.\n")
        XCTAssertEqual(
            output,
            """
            <article class="sonovo">
            <h1 id="title">Title</h1>
            <p>Hello <strong>world</strong> and <em>you</em>.</p>
            </article>
            """
        )
    }

    // MARK: - Raw HTML and escaping

    func testRawHTMLIsHiddenAndTextIsEscaped() {
        let source = """
        <script>alert("x")</script>

        A < B & C > D

        Text <img src=x onerror=alert(1)> end
        """
        let output = body(source)
        XCTAssertFalse(output.contains("<script"))
        XCTAssertFalse(output.contains("alert"))
        XCTAssertFalse(output.contains("onerror"))
        XCTAssertTrue(output.contains("A &lt; B &amp; C &gt; D"))
        XCTAssertTrue(output.contains("<p>Text  end</p>"))
    }

    func testAttributesAreEscaped() {
        let output = body(
            "[link](https://example.com/?a=1&b=2 \"title & 'quote'\")\n"
        )
        XCTAssertTrue(
            output.contains(
                "href=\"https://example.com/?a=1&amp;b=2\""
            )
        )
        XCTAssertTrue(
            output.contains("title=\"title &amp; &#39;quote&#39;\"")
        )
    }

    // MARK: - Links

    func testLinkPolicyMatchesTheViewer() {
        let source = """
        [safe](https://example.com/a?b=1&c=2 "T") [js](javascript:alert(1)) [mail](mailto:a@b.c) [local](other.md) [hash](#intro) [proto](//evil.example)

        # Intro
        """
        let output = body(source)
        XCTAssertTrue(
            output.contains(
                "<a href=\"https://example.com/a?b=1&amp;c=2\" title=\"T\" rel=\"noopener noreferrer\">safe</a>"
            )
        )
        XCTAssertFalse(output.contains("href=\"javascript:"))
        XCTAssertTrue(output.contains("<a href=\"mailto:a@b.c\">mail</a>"))
        XCTAssertTrue(
            output.contains(
                "<span class=\"local-link\" data-destination=\"other.md\">local</span>"
            )
        )
        XCTAssertTrue(output.contains("<a href=\"#intro\">hash</a>"))
        XCTAssertTrue(
            output.contains("<span class=\"denied-link\">proto</span>")
        )
    }

    // MARK: - Code

    func testCodeBlockIsEscapedAndHighlighted() {
        let source = """
        ```swift
        let x = "<tag>" // hi
        ```
        """
        let output = body(source)
        XCTAssertTrue(output.contains("<pre><code class=\"language-swift\">"))
        XCTAssertTrue(output.contains("class=\"tok-keyword\">let</span>"))
        XCTAssertTrue(output.contains("&lt;tag&gt;"))
        XCTAssertFalse(output.contains("<tag>"))
        XCTAssertTrue(output.contains("<div class=\"code-header\">swift</div>"))
    }

    // MARK: - Tables and tasks

    func testTableAlignmentAndTaskList() {
        let source = """
        | A | B |
        |:--|:-:|
        | 1 | 2 |

        - [x] done
        - [ ] todo
        """
        let output = body(source)
        XCTAssertTrue(output.contains("<table>"))
        XCTAssertTrue(
            output.contains("<th style=\"text-align: left\">A</th>")
        )
        XCTAssertTrue(
            output.contains("<th style=\"text-align: center\">B</th>")
        )
        XCTAssertTrue(
            output.contains("<input type=\"checkbox\" disabled checked>")
        )
        XCTAssertTrue(output.contains("<input type=\"checkbox\" disabled>"))
    }

    // MARK: - Footnotes and details

    func testFootnotesGetReferencesAndBackLinks() {
        let output = body("Text[^a]\n\n[^a]: Note\n")
        XCTAssertTrue(
            output.contains(
                "<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup>"
            )
        )
        XCTAssertTrue(output.contains("<li id=\"fn-1\">"))
        XCTAssertTrue(output.contains("class=\"backref\""))
        XCTAssertTrue(output.contains("href=\"#fnref-1\""))
        XCTAssertTrue(output.contains("<p>Note <span class=\"backrefs\">"))
    }

    func testRepeatedFootnoteReferencesGetUniqueIDs() {
        let output = body("One[^a] and two[^a].\n\n[^a]: Note\n")
        XCTAssertTrue(output.contains("id=\"fnref-1\""))
        XCTAssertTrue(output.contains("id=\"fnref-1-2\""))
        XCTAssertTrue(output.contains("href=\"#fnref-1\""))
        XCTAssertTrue(output.contains("href=\"#fnref-1-2\""))
    }

    func testDetailsKeepTheirOpenStateAndBody() {
        let source = """
        <details open>
        <summary>More</summary>

        Inside

        </details>
        """
        let output = body(source)
        XCTAssertTrue(output.contains("<details open>"))
        XCTAssertTrue(output.contains("<summary>More</summary>"))
        XCTAssertTrue(output.contains("<p>Inside</p>"))
    }

    // MARK: - Alert

    func testGitHubAlertBecomesACallout() {
        let output = body("> [!NOTE]\n> Read this.\n")
        XCTAssertTrue(output.contains("<aside class=\"alert alert-note\">"))
        XCTAssertTrue(
            output.contains("<p class=\"alert-title\">Note</p>")
        )
        XCTAssertTrue(output.contains("Read this."))
        XCTAssertFalse(output.contains("[!NOTE]"))
    }

    // MARK: - TOC

    func testTOCLinksMatchHeadingIDs() {
        let output = body("[TOC]\n\n# One\n\n## Two\n")
        XCTAssertTrue(output.contains("<nav class=\"toc\""))
        XCTAssertTrue(output.contains("href=\"#one\""))
        XCTAssertTrue(output.contains("<h1 id=\"one\">One</h1>"))
        XCTAssertTrue(output.contains("href=\"#two\""))
        XCTAssertTrue(output.contains("<h2 id=\"two\">Two</h2>"))
    }

    // MARK: - Images

    func testLocalRasterImageIsEmbedded() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("pic.png")
        try tinyPNG.write(to: imageURL)
        let documentURL = directory.appendingPathComponent("doc.md")
        try Data("![Alt](pic.png)\n".utf8).write(to: documentURL)

        let output = body(
            "![Alt](pic.png)\n",
            documentURL: documentURL,
            workspaceRoot: directory
        )
        XCTAssertTrue(output.contains("src=\"data:image/png;base64,"))
        XCTAssertTrue(output.contains("alt=\"Alt\""))
        XCTAssertTrue(output.contains("<figure class=\"image\">"))
    }

    func testMissingAndRemoteImagesBecomePlaceholders() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("doc.md")

        let missing = body(
            "![Missing](nope.png)\n",
            documentURL: documentURL,
            workspaceRoot: directory
        )
        XCTAssertTrue(missing.contains("class=\"image-placeholder\""))
        XCTAssertTrue(missing.contains("Missing"))
        XCTAssertFalse(missing.contains("src="))

        let remote = body(
            "![Remote](https://example.com/x.png)\n",
            documentURL: documentURL,
            workspaceRoot: directory
        )
        XCTAssertTrue(remote.contains("class=\"image-placeholder\""))
        XCTAssertFalse(remote.contains("src=\"https"))
    }

    func testSVGIsNotEmbedded() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let svgURL = directory.appendingPathComponent("pic.svg")
        try Data(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>"
                .utf8
        ).write(to: svgURL)
        let documentURL = directory.appendingPathComponent("doc.md")

        let output = body(
            "![Vector](pic.svg)\n",
            documentURL: documentURL,
            workspaceRoot: directory
        )
        XCTAssertTrue(output.contains("class=\"image-placeholder\""))
        XCTAssertFalse(output.contains("image/svg+xml"))
        XCTAssertFalse(output.contains("<script"))
    }

    // MARK: - Self-contained document

    func testDocumentIsSelfContainedAndPoliciesAreExplicit() {
        let output = document(
            "# Title\n\nA paragraph.\n",
            title: "Test & Notes"
        )
        XCTAssertTrue(output.contains("<!DOCTYPE html>"))
        XCTAssertTrue(output.contains("<meta charset=\"utf-8\">"))
        XCTAssertTrue(output.contains("Content-Security-Policy"))
        XCTAssertTrue(output.contains("default-src 'none'"))
        XCTAssertTrue(output.contains("<title>Test &amp; Notes</title>"))
        XCTAssertTrue(output.contains("<style>"))
        XCTAssertTrue(output.contains("@media (prefers-color-scheme: dark)"))
        XCTAssertTrue(output.contains("@media print"))
        XCTAssertFalse(output.contains("<link"))
        XCTAssertFalse(output.contains("<script"))
        XCTAssertFalse(output.contains("@import"))
        XCTAssertFalse(output.contains("url(http"))
    }

    // MARK: - Service

    func testServiceWritesSelfContainedHTML() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("note.md")
        try Data("# Export\n\nBody.\n".utf8).write(to: sourceURL)
        let document = try MarkdownDocument(loading: sourceURL)
        let outputURL = directory.appendingPathComponent("note.html")

        try await MarkdownExportService.write(
            document: document,
            format: .html,
            to: outputURL,
            workspaceRoot: directory,
            theme: theme
        )

        let html = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(html.contains("<h1 id=\"export\">Export</h1>"))
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertFalse(html.contains("<script"))
    }

    // MARK: - Math

    func testInlineMathEmbedsImageWithBaselineAndAlt() {
        let ast = ast("Inline $x^2$ here.\n")
        let assets = MarkdownMathAssets.build(from: ast, theme: theme)
        XCTAssertEqual(assets.count, 1)
        let output = MarkdownHTMLExporter.body(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme,
                math: assets
            )
        )
        XCTAssertTrue(output.contains("<span class=\"math math-inline\">"))
        XCTAssertTrue(output.contains("<picture>"))
        XCTAssertTrue(
            // Screen only: a dark formula image chosen for a dark-mode
            // print would be unreadable on the forced light page.
            output.contains(
                "<source media=\"screen and (prefers-color-scheme: dark)\""
            )
        )
        XCTAssertTrue(output.contains("data:image/png;base64,"))
        XCTAssertTrue(output.contains("alt=\"x^2\""))
        XCTAssertTrue(output.contains("vertical-align: -"))
        XCTAssertFalse(output.contains("<script"))
    }

    func testDisplayMathBecomesACenteredBlock() {
        let ast = ast("$$\n\\frac{a}{b}\n$$\n")
        let assets = MarkdownMathAssets.build(from: ast, theme: theme)
        XCTAssertEqual(assets.count, 1)
        let output = MarkdownHTMLExporter.body(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme,
                math: assets
            )
        )
        XCTAssertTrue(output.contains("<div class=\"math math-display\">"))
        XCTAssertTrue(output.contains("<picture>"))
        XCTAssertFalse(output.contains("<p>"))
        XCTAssertFalse(output.contains("math-literal"))
    }

    func testMissingAssetFallsBackToLiteralSource() {
        let output = body("Inline $x^2$ here.\n")
        XCTAssertTrue(
            output.contains("<span class=\"math math-literal\">$x^2$</span>")
        )
        XCTAssertFalse(output.contains("data:image/png"))
    }

    func testDeniedFormulaFallsBackToLiteralSource() {
        let ast = ast("$\\href{https://example.com}{x}$\n")
        let assets = MarkdownMathAssets.build(from: ast, theme: theme)
        XCTAssertTrue(assets.isEmpty)
        let output = MarkdownHTMLExporter.body(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme,
                math: assets
            )
        )
        XCTAssertTrue(output.contains("href"))
        XCTAssertFalse(output.contains("math-inline"))
        XCTAssertFalse(output.contains("data:image/png"))
    }

    func testExportByteBudgetFallsBackToLiteralSource() {
        let ast = ast("Inline $x$ here.\n")
        let assets = MarkdownMathAssets.build(
            from: ast,
            theme: theme,
            byteBudget: 1
        )
        XCTAssertTrue(assets.isEmpty)
        let output = MarkdownHTMLExporter.body(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme,
                math: assets
            )
        )
        XCTAssertTrue(output.contains("math-literal"))
        XCTAssertFalse(output.contains("data:image/png"))
    }

    func testMathAltIsEscaped() {
        let ast = ast("$a < b$\n")
        let assets = MarkdownMathAssets.build(from: ast, theme: theme)
        let output = MarkdownHTMLExporter.body(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme,
                math: assets
            )
        )
        XCTAssertTrue(output.contains("alt=\"a &lt; b\""))
        XCTAssertFalse(output.contains("alt=\"a < b\""))
    }

    func testRawHTMLInsideMathCannotEscape() {
        let output = body("$x <script>alert(1)</script>$\n")
        XCTAssertFalse(output.contains("<script"))
        XCTAssertFalse(output.contains("</script>"))
    }

    func testDisplayMathInsideFootnoteDoesNotNestABlockInAParagraph() {
        let ast = ast("Text[^a]\n\n[^a]: $$x$$\n")
        let assets = MarkdownMathAssets.build(from: ast, theme: theme)
        let output = MarkdownHTMLExporter.body(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme,
                math: assets
            )
        )
        XCTAssertTrue(output.contains("math math-inline"))
        XCTAssertFalse(output.contains("<div class=\"math math-display\">"))
    }

    func testMathCSSKeepsFormulasInTheirLine() {
        let output = document("Inline $x$ here.\n")
        XCTAssertTrue(output.contains(".math-inline .math-image"))
        XCTAssertTrue(output.contains("display: inline"))
        XCTAssertTrue(output.contains(".math-display"))
        XCTAssertTrue(output.contains("text-align: center"))
    }

    func testPrintDocumentOmitsTheDarkMathVariant() {
        let ast = ast("$x$\n")
        let assets = MarkdownMathAssets.build(from: ast, theme: theme)
        let output = MarkdownHTMLExporter.document(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme,
                math: assets
            ),
            forPrint: true
        )
        XCTAssertTrue(output.contains("<span class=\"math math-inline\">"))
        XCTAssertFalse(output.contains("<picture>"))
        XCTAssertFalse(
            output.contains("<source media=\"(prefers-color-scheme: dark)\" srcset")
        )
    }

    func testServiceRendersMathIntoExportedHTML() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("math.md")
        try Data("# Math\n\n$E = mc^2$\n".utf8).write(to: sourceURL)
        let document = try MarkdownDocument(loading: sourceURL)
        let outputURL = directory.appendingPathComponent("math.html")

        try await MarkdownExportService.write(
            document: document,
            format: .html,
            to: outputURL,
            workspaceRoot: directory,
            theme: theme
        )

        let html = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(html.contains("math math-inline"))
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertFalse(html.contains("<span class=\"math math-literal\">"))
    }

    // MARK: - Fixtures

    private var tinyPNG: Data {
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        ) ?? Data()
    }
}
