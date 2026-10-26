import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

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

    func testRendererProducesASanitizedSVG() async throws {
        let svg = try await renderer.render(
            source: "graph TD; A-->B;",
            variant: .light
        )
        XCTAssertTrue(svg.markup.contains("<svg"))
        XCTAssertTrue(svg.markup.contains("<text"))
        XCTAssertFalse(svg.markup.lowercased().contains("<script"))
        XCTAssertFalse(svg.markup.contains("foreignObject"))
        XCTAssertFalse(svg.markup.contains("onclick"))
        // Mermaid's class-based styling and its authored max width must
        // survive; otherwise diagrams lose their colors and sizing.
        XCTAssertTrue(svg.markup.contains("<style"))
        XCTAssertTrue(svg.markup.contains("max-width"))
        let width = try XCTUnwrap(svg.width)
        let height = try XCTUnwrap(svg.height)
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThan(height, 0)
    }

    func testSanitizedSVGLoadsAsAnImage() async throws {
        let svg = try await renderer.render(
            source: "graph TD; A-->B;",
            variant: .light
        )
        let image = try XCTUnwrap(NSImage(data: Data(svg.markup.utf8)))
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testDiagramImagePaintsItsStyledColors() async throws {
        let svg = try await renderer.render(
            source: "graph TD; A-->B;",
            variant: .light
        )
        let image = try XCTUnwrap(NSImage(data: Data(svg.markup.utf8)))
        let side = 240
        let representation = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: side,
                pixelsHigh: side,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let context = try XCTUnwrap(
            NSGraphicsContext(bitmapImageRep: representation)
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side)
        )
        NSGraphicsContext.restoreGraphicsState()

        var painted = 0
        var colored = 0
        for y in stride(from: 0, to: side, by: 2) {
            for x in stride(from: 0, to: side, by: 2) {
                guard let color = representation
                    .colorAt(x: x, y: y)?
                    .usingColorSpace(.sRGB) else { continue }
                guard color.alphaComponent > 0.1 else { continue }
                painted += 1
                let maximum = max(
                    color.redComponent,
                    max(color.greenComponent, color.blueComponent)
                )
                let minimum = min(
                    color.redComponent,
                    min(color.greenComponent, color.blueComponent)
                )
                if color.alphaComponent > 0.5,
                   maximum - minimum > 0.05,
                   maximum > 0.3 {
                    colored += 1
                }
            }
        }
        XCTAssertGreaterThan(painted, 100)
        // Mermaid's node fill and accents come from its <style> block. A
        // black-only render means the sanitizer dropped the stylesheet or
        // NSImage ignored it.
        XCTAssertGreaterThan(colored, 20)
    }

    func testSequenceDiagramRenders() async throws {
        let svg = try await renderer.render(
            source: "sequenceDiagram\nAlice->>Bob: Hi",
            variant: .light
        )
        XCTAssertTrue(svg.markup.contains("<text"))
        XCTAssertFalse(svg.markup.contains("foreignObject"))
    }

    func testClassAndStateDiagramsUseTextLabels() async throws {
        let classDiagram = try await renderer.render(
            source: "classDiagram\n  class Animal {\n    +String name\n  }",
            variant: .light
        )
        XCTAssertTrue(classDiagram.markup.contains("<text"))
        XCTAssertFalse(classDiagram.markup.contains("foreignObject"))

        let stateDiagram = try await renderer.render(
            source: "stateDiagram-v2\n  [*] --> Still\n  Still --> [*]",
            variant: .light
        )
        XCTAssertTrue(stateDiagram.markup.contains("<text"))
        XCTAssertFalse(stateDiagram.markup.contains("foreignObject"))
    }

    func testInvalidDiagramFails() async throws {
        do {
            _ = try await renderer.render(
                source: "graph TD; A-->",
                variant: .light
            )
            XCTFail("expected the invalid diagram to fail")
        } catch let error as MarkdownMermaidError {
            guard case .renderFailed = error else {
                return XCTFail("expected renderFailed, got \(error)")
            }
        }
    }

    func testDirectiveSourceIsRejectedWithoutRendering() async throws {
        let before = renderer.renderCount
        do {
            _ = try await renderer.render(
                source: "graph TD; A-->B;\n%%{init: {\"theme\":\"dark\"}}%%",
                variant: .light
            )
            XCTFail("expected the directive to be rejected")
        } catch let error as MarkdownMermaidError {
            XCTAssertEqual(error, .rejectedSource)
        }
        XCTAssertEqual(renderer.renderCount, before)
    }

    func testMaliciousLabelCannotEscapeTheSVG() async throws {
        let svg = try await renderer.render(
            source: "graph TD; A[\"<img src=x onerror=alert(1)>\"]-->B;",
            variant: .light
        )
        let lowered = svg.markup.lowercased()
        XCTAssertFalse(lowered.contains("<script"))
        XCTAssertFalse(lowered.contains("onerror"))
        XCTAssertFalse(lowered.contains("<img"))
        XCTAssertFalse(lowered.contains("javascript:"))
    }

    // MARK: - Isolation

    func testHarnessCarriesTheContentSecurityPolicy() throws {
        let harness = try XCTUnwrap(MermaidRenderer.harnessForTesting())
        XCTAssertTrue(harness.contains("Content-Security-Policy"))
        XCTAssertTrue(
            harness.contains(MermaidRendererPolicy.contentSecurityPolicy)
        )
        XCTAssertTrue(harness.contains("mermaid.initialize"))
        XCTAssertFalse(harness.contains("unsafe-eval"))
    }

    func testNetworkPathsAreBlocked() async throws {
        let results = try await renderer.probeNetworkForTesting()
        XCTAssertEqual(results["fetch"], "blocked")
        XCTAssertEqual(results["xhr"], "blocked")
        XCTAssertEqual(results["websocket"], "blocked")
        XCTAssertEqual(results["image"], "blocked")
        // Controls in the same page: the allowed image proves the page is
        // functional, and the denied data: fetch proves the CSP is blocking
        // requests rather than the environment being offline.
        XCTAssertEqual(results["dataImage"], "allowed")
        XCTAssertEqual(results["dataFetch"], "blocked")
        XCTAssertEqual(results["file"], "blocked")
        XCTAssertEqual(results["messageHandlers"], "0")
    }

    func testForeignNavigationIsCancelled() async throws {
        try await renderer.loadForTesting()
        let webView = try XCTUnwrap(renderer.webViewForTesting)
        let before = webView.url?.absoluteString
        try? await webView.evaluateJavaScript(
            "location.href = 'https://example.com/sonovo-escape'"
        )
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(webView.url?.absoluteString, before)
        XCTAssertEqual(webView.url?.absoluteString, "about:blank")
    }

    // MARK: - Cache

    func testSecondRenderComesFromTheCache() async throws {
        let first = try await renderer.render(
            source: "graph TD; A-->B;",
            variant: .light
        )
        let count = renderer.renderCount
        let second = try await renderer.render(
            source: "graph TD; A-->B;",
            variant: .light
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(renderer.renderCount, count)
        XCTAssertEqual(renderer.cacheCount, 1)
    }

    func testCacheInvalidatesOnSourceAndPalette() async throws {
        _ = try await renderer.render(
            source: "graph TD; A-->B;",
            variant: .light
        )
        let afterFirst = renderer.renderCount
        _ = try await renderer.render(
            source: "graph TD; A-->C;",
            variant: .light
        )
        XCTAssertEqual(renderer.renderCount, afterFirst + 1)
        _ = try await renderer.render(
            source: "graph TD; A-->B;",
            variant: .dark
        )
        XCTAssertEqual(renderer.renderCount, afterFirst + 2)
        XCTAssertEqual(renderer.cacheCount, 3)
    }

    func testConcurrentRequestsShareTheSerializedRenderer() async throws {
        let renderer = MermaidRenderer.shared
        async let first = renderer.render(
            source: "graph TD; A-->B;",
            variant: .light
        )
        async let second = renderer.render(
            source: "graph TD; A-->C;",
            variant: .light
        )
        let (one, two) = try await (first, second)
        XCTAssertNotEqual(one.markup, two.markup)
        XCTAssertEqual(renderer.cacheCount, 2)
    }

    func testPaletteVariantsDiffer() async throws {
        let light = try await renderer.render(
            source: "graph TD; A-->B;",
            variant: .light
        )
        let dark = try await renderer.render(
            source: "graph TD; A-->B;",
            variant: .dark
        )
        XCTAssertNotEqual(light.markup, dark.markup)
    }

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
