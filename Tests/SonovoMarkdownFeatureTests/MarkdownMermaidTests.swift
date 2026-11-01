@testable import SonovoMarkdownFeature
@testable import SonovoDiagramUI
import SonovoDiagramEngine
import SonovoDesignSystem
import AppKit
import XCTest
import SonovoMarkdownEngine
import SonovoSubtitleEngine

@MainActor
final class MarkdownMermaidTests: XCTestCase {
    private var renderer: WebDiagramRenderer { MermaidRenderer.shared }
    private var theme: MarkdownTheme {
        MarkdownThemeStore.shared.defaultTheme()
    }

    override func setUp() async throws {
        renderer.clearCache()
    }

    private func ast(_ source: String) -> SonovoAST {
        MarkdownSyntaxAugmenter().augment(MarkdownParser.parseCanonical(source))
    }

    // MARK: - Rendering

















    // MARK: - Isolation







    // MARK: - Cache









    // MARK: - Export

    func testExportEmbedsSanitizedDiagrams() async throws {
        let ast = ast("```mermaid\ngraph TD; A-->B;\n```\n")
        let assets = await MarkdownMermaidAssets.build(
            from: ast,
            includeDark: true
        )
        XCTAssertEqual(assets.count, 1)
        let output = MarkdownHTMLExporter.body(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme,
                mermaid: assets
            )
        )
        XCTAssertTrue(output.contains("<figure class=\"mermaid-block\">"))
        XCTAssertTrue(output.contains("<svg"))
        XCTAssertTrue(output.contains("mermaid-light"))
        XCTAssertTrue(output.contains("mermaid-dark"))
        XCTAssertFalse(output.contains("<script"))
        XCTAssertFalse(output.contains("foreignObject"))
        XCTAssertFalse(output.contains("example.com"))
    }

    func testExportByteBudgetFallsBackToTheCodeBlock() async throws {
        let ast = ast("```mermaid\ngraph TD; A-->B;\n```\n")
        let assets = await MarkdownMermaidAssets.build(
            from: ast,
            includeDark: true,
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
                mermaid: assets
            )
        )
        XCTAssertTrue(output.contains("<div class=\"code-block\">"))
        XCTAssertFalse(output.contains("mermaid-block"))
    }

    func testMissingDiagramAssetFallsBackToTheCodeBlock() {
        let ast = ast("```mermaid\ngraph TD; A-->B;\n```\n")
        let output = MarkdownHTMLExporter.body(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme
            )
        )
        XCTAssertTrue(output.contains("<div class=\"code-block\">"))
        XCTAssertTrue(output.contains("language-mermaid"))
        XCTAssertFalse(output.contains("mermaid-block"))
        XCTAssertFalse(output.contains("<svg"))
    }

    func testPrintDocumentOmitsTheDarkVariant() async throws {
        let ast = ast("```mermaid\ngraph TD; A-->B;\n```\n")
        let assets = await MarkdownMermaidAssets.build(
            from: ast,
            includeDark: false
        )
        let output = MarkdownHTMLExporter.document(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme,
                mermaid: assets
            ),
            forPrint: true
        )
        XCTAssertTrue(output.contains("<figure class=\"mermaid-block\">"))
        XCTAssertTrue(output.contains("<svg"))
        XCTAssertFalse(output.contains("mermaid mermaid-dark"))
        // The light wrapper carries the `.mermaid svg` sizing rule; print
        // keeps it and drops only the palette it cannot use.
        XCTAssertTrue(output.contains("mermaid mermaid-light"))
        XCTAssertFalse(output.contains("<script"))
    }

    func testServiceRendersDiagramsIntoExportedHTML() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-mermaid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("diagram.md")
        try Data(
            "# Diagram\n\n```mermaid\ngraph TD; A-->B;\n```\n".utf8
        ).write(to: sourceURL)
        let document = try MarkdownDocument(loading: sourceURL)
        let outputURL = directory.appendingPathComponent("diagram.html")

        try await MarkdownExportService.write(
            document: document,
            format: .html,
            to: outputURL,
            workspaceRoot: directory,
            theme: theme
        )

        let html = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(html.contains("<figure class=\"mermaid-block\">"))
        XCTAssertTrue(html.contains("<svg"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertTrue(html.contains("Content-Security-Policy"))
    }

    func testRejectedDiagramStaysACodeBlockInExport() async throws {
        let source = """
        ```mermaid
        graph TD; A-->B;
        %%{init: {"theme":"dark"}}%%
        ```
        """
        let ast = ast(source)
        let assets = await MarkdownMermaidAssets.build(
            from: ast,
            includeDark: true
        )
        XCTAssertTrue(assets.isEmpty)
        let output = MarkdownHTMLExporter.body(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme,
                mermaid: assets
            )
        )
        XCTAssertTrue(output.contains("<div class=\"code-block\">"))
        XCTAssertFalse(output.contains("mermaid-block"))
    }
}
