import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MarkdownDiagramTests: XCTestCase {
    private var graphviz: WebDiagramRenderer { GraphvizRenderer.shared }
    private var markmap: WebDiagramRenderer { MarkmapRenderer.shared }
    private var theme: MarkdownTheme {
        MarkdownThemeStore.shared.defaultTheme()
    }

    private let graphvizSource = "digraph G { rankdir=LR; A -> B; B -> C; }"
    private let markmapSource = "# Root\n## Alpha\n## Beta"

    override func setUp() async throws {
        DiagramRenderer.clearCaches()
    }

    private func ast(_ source: String) -> SonovoAST {
        MarkdownSyntaxAugmenter().augment(MarkdownParser.parseCanonical(source))
    }

    private func exportBody(
        _ source: String,
        includeDark: Bool = true,
        byteBudget: Int = MarkdownLimits.maxDiagramExportBytes
    ) async -> (assets: [String: MarkdownDiagramAsset], html: String) {
        let ast = ast(source)
        let assets = await MarkdownDiagramAssets.build(
            from: ast,
            includeDark: includeDark,
            byteBudget: byteBudget
        )
        let html = MarkdownHTMLExporter.body(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme,
                diagrams: assets
            )
        )
        return (assets, html)
    }

    // MARK: - Graphviz

    func testGraphvizRendersASanitizedSVG() async throws {
        let svg = try await graphviz.render(
            source: graphvizSource,
            variant: .light
        )
        XCTAssertTrue(svg.markup.contains("<svg"))
        XCTAssertTrue(svg.markup.contains("<text"))
        XCTAssertTrue(svg.markup.contains(">A<"))
        XCTAssertFalse(svg.markup.lowercased().contains("<script"))
        XCTAssertFalse(svg.markup.contains("foreignObject"))
        XCTAssertFalse(svg.markup.contains("example.com"))
        let width = try XCTUnwrap(svg.width)
        let height = try XCTUnwrap(svg.height)
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThan(height, 0)
    }

    func testGraphvizSVGLoadsAsAnImage() async throws {
        let svg = try await graphviz.render(
            source: graphvizSource,
            variant: .light
        )
        let image = try XCTUnwrap(NSImage(data: Data(svg.markup.utf8)))
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testGraphvizDarkThemeRenders() async throws {
        let light = try await graphviz.render(
            source: graphvizSource,
            variant: .light
        )
        let dark = try await graphviz.render(
            source: graphvizSource,
            variant: .dark
        )
        XCTAssertNotEqual(light.markup, dark.markup)
        // The dark pass rewrites Graphviz's black default ink; a dropped
        // style would leave the diagram invisible on dark paper.
        XCTAssertTrue(dark.markup.contains("#E6E6E6"))
    }

    func testInvalidDOTFails() async throws {
        do {
            _ = try await graphviz.render(
                source: "digraph { A -> }",
                variant: .light
            )
            XCTFail("expected the invalid DOT source to fail")
        } catch let error as MarkdownDiagramError {
            guard case .renderFailed = error else {
                return XCTFail("expected renderFailed, got \(error)")
            }
        }
    }

    func testGraphvizLabelCannotEscapeTheSVG() async throws {
        let svg = try await graphviz.render(
            source: "digraph { A [label=\"<img src=x onerror=alert(1)>\"] }",
            variant: .light
        )
        let lowered = svg.markup.lowercased()
        XCTAssertFalse(lowered.contains("<script"))
        XCTAssertFalse(lowered.contains("<img"))
        XCTAssertFalse(lowered.contains("javascript:"))
        // The markup survives only as escaped text: no element and no
        // attribute can be built from it.
        XCTAssertTrue(lowered.contains("&lt;img src=x onerror=alert(1)&gt;"))
    }

    func testOversizedDOTIsRejectedWithoutRendering() async throws {
        let before = graphviz.renderCount
        let source = String(
            repeating: "a",
            count: MarkdownLimits.maxGraphvizSourceCharacters + 1
        )
        do {
            _ = try await graphviz.render(source: source, variant: .light)
            XCTFail("expected the source cap to reject the diagram")
        } catch let error as MarkdownDiagramError {
            XCTAssertEqual(error, .rejectedSource)
        }
        XCTAssertEqual(graphviz.renderCount, before)
    }

    // MARK: - Markmap

    func testMarkmapRendersTextLabels() async throws {
        let svg = try await markmap.render(
            source: markmapSource,
            variant: .light
        )
        XCTAssertTrue(svg.markup.contains("<svg"))
        XCTAssertTrue(svg.markup.contains("<text"))
        XCTAssertTrue(svg.markup.contains("Root"))
        XCTAssertFalse(svg.markup.contains("foreignObject"))
        XCTAssertFalse(svg.markup.lowercased().contains("<script"))
        let width = try XCTUnwrap(svg.width)
        let height = try XCTUnwrap(svg.height)
        XCTAssertEqual(width, 1_200)
        XCTAssertEqual(height, 800)
    }

    func testMarkmapSVGLoadsAsAnImage() async throws {
        let svg = try await markmap.render(
            source: markmapSource,
            variant: .light
        )
        let image = try XCTUnwrap(NSImage(data: Data(svg.markup.utf8)))
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testMarkmapVariantsUseTheirTextColor() async throws {
        let light = try await markmap.render(
            source: markmapSource,
            variant: .light
        )
        let dark = try await markmap.render(
            source: markmapSource,
            variant: .dark
        )
        XCTAssertTrue(light.markup.contains("#333333"))
        XCTAssertTrue(dark.markup.contains("#E6E6E6"))
    }

    func testMarkmapSourceWithMarkupIsSanitized() async throws {
        let svg = try await markmap.render(
            source: "# Root\n## <script>alert(1)</script>",
            variant: .light
        )
        let lowered = svg.markup.lowercased()
        XCTAssertFalse(lowered.contains("<script"))
        XCTAssertFalse(lowered.contains("onerror"))
        // Markmap's transformer drops raw HTML, so the tag never reaches the
        // label; only its text survives, and only as a text node.
        XCTAssertTrue(lowered.contains("<text"))
        XCTAssertTrue(svg.markup.contains(">alert(1)<"))
    }

    // MARK: - SVG fences

    func testSVGFenceIsSanitizedWithoutAWebView() throws {
        let source = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 20">
        <script>alert(1)</script>
        <rect width="10" height="10" onload="alert(2)" fill="red"/>
        <text x="1" y="12">Hi</text>
        </svg>
        """
        let svg = try DiagramRenderer.renderSVGFence(
            source,
            variant: .light
        )
        XCTAssertTrue(svg.markup.contains("<rect"))
        XCTAssertTrue(svg.markup.contains("<text"))
        XCTAssertFalse(svg.markup.lowercased().contains("<script"))
        XCTAssertFalse(svg.markup.contains("onload"))
        XCTAssertFalse(svg.markup.contains("alert"))
        XCTAssertEqual(svg.width, 40)
        XCTAssertEqual(svg.height, 20)
    }

    func testSVGFenceRejectsRemoteAndMalformedContent() throws {
        let remote = """
        <svg xmlns="http://www.w3.org/2000/svg">
        <image href="https://example.com/x.png"/>
        <use href="#local"/>
        </svg>
        """
        let sanitized = try DiagramRenderer.renderSVGFence(
            remote,
            variant: .light
        )
        XCTAssertFalse(sanitized.markup.contains("example.com"))
        XCTAssertTrue(sanitized.markup.contains("#local"))

        XCTAssertThrowsError(
            try DiagramRenderer.renderSVGFence(
                "<svg><rect></svg>",
                variant: .light
            )
        ) { error in
            XCTAssertEqual(error as? MarkdownDiagramError, .invalidOutput)
        }
    }

    func testSVGFenceCacheReturnsTheSameResult() throws {
        let source = "<svg viewBox=\"0 0 10 10\"><rect width=\"1\" height=\"1\"/></svg>"
        let first = try DiagramRenderer.renderSVGFence(
            source,
            variant: .light
        )
        let second = try DiagramRenderer.renderSVGFence(
            source,
            variant: .light
        )
        XCTAssertEqual(first, second)
    }

    func testOversizedSVGFenceIsRejectedByTheDispatcher() async throws {
        let source = String(
            repeating: "a",
            count: MarkdownLimits.maxSVGFenceBytes + 1
        )
        do {
            _ = try await DiagramRenderer.render(
                DiagramSource(engine: .svg, source: source),
                variant: .light
            )
            XCTFail("expected the byte cap to reject the fence")
        } catch let error as MarkdownDiagramError {
            XCTAssertEqual(error, .rejectedSource)
        }
    }

    func testSVGFenceUsesTheDiagramDispatcher() async throws {
        let source = "<svg viewBox=\"0 0 12 8\"><circle r=\"3\"/></svg>"
        let svg = try await DiagramRenderer.render(
            DiagramSource(engine: .svg, source: source),
            variant: .light
        )
        XCTAssertTrue(svg.markup.contains("<circle"))
        XCTAssertEqual(svg.width, 12)
        XCTAssertEqual(svg.height, 8)
    }

    // MARK: - Isolation

    func testEachHarnessCarriesItsOwnPolicy() throws {
        let graphvizHarness = try XCTUnwrap(
            GraphvizRenderer.harnessForTesting()
        )
        XCTAssertTrue(
            graphvizHarness.contains(
                GraphvizRendererPolicy.contentSecurityPolicy
            )
        )
        XCTAssertTrue(graphvizHarness.contains("'wasm-unsafe-eval'"))
        XCTAssertFalse(graphvizHarness.contains("mermaid.initialize"))
        XCTAssertFalse(graphvizHarness.contains("src=\"http"))

        let markmapHarness = try XCTUnwrap(MarkmapRenderer.harnessForTesting())
        XCTAssertTrue(
            markmapHarness.contains(
                MarkmapRendererPolicy.contentSecurityPolicy
            )
        )
        XCTAssertTrue(markmapHarness.contains("__sonovoRenderMarkmap"))
        XCTAssertFalse(markmapHarness.contains("src=\"http"))
    }

    func testGraphvizPageBlocksNetworkAndHasNoHostBridge() async throws {
        let results = try await graphviz.probeNetworkForTesting()
        XCTAssertEqual(results["fetch"], "blocked")
        XCTAssertEqual(results["xhr"], "blocked")
        XCTAssertEqual(results["websocket"], "blocked")
        XCTAssertEqual(results["image"], "blocked")
        XCTAssertEqual(results["dataImage"], "allowed")
        XCTAssertEqual(results["dataFetch"], "blocked")
        XCTAssertEqual(results["file"], "blocked")
        XCTAssertEqual(results["messageHandlers"], "0")
    }

    func testMarkmapPageBlocksNetworkAndHasNoHostBridge() async throws {
        let results = try await markmap.probeNetworkForTesting()
        XCTAssertEqual(results["fetch"], "blocked")
        XCTAssertEqual(results["xhr"], "blocked")
        XCTAssertEqual(results["websocket"], "blocked")
        XCTAssertEqual(results["image"], "blocked")
        XCTAssertEqual(results["dataImage"], "allowed")
        XCTAssertEqual(results["dataFetch"], "blocked")
        XCTAssertEqual(results["file"], "blocked")
        XCTAssertEqual(results["messageHandlers"], "0")
    }

    func testMarkmapNavigationIsCancelled() async throws {
        try await markmap.loadForTesting()
        let webView = try XCTUnwrap(markmap.webViewForTesting)
        let before = webView.url?.absoluteString
        try? await webView.evaluateJavaScript(
            "location.href = 'https://example.com/sonovo-escape'"
        )
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(webView.url?.absoluteString, before)
        XCTAssertEqual(webView.url?.absoluteString, "about:blank")
    }

    // MARK: - Cache

    func testEachEngineCachesItsOwnRenders() async throws {
        _ = try await graphviz.render(source: graphvizSource, variant: .light)
        let afterFirst = graphviz.renderCount
        _ = try await graphviz.render(source: graphvizSource, variant: .light)
        XCTAssertEqual(graphviz.renderCount, afterFirst)
        XCTAssertEqual(graphviz.cacheCount, 1)
        // The Mermaid cache must not satisfy a Graphviz request.
        XCTAssertEqual(MermaidRenderer.shared.cacheCount, 0)
    }

    func testConcurrentGraphvizRequestsSerialize() async throws {
        let renderer = GraphvizRenderer.shared
        async let first = renderer.render(
            source: "digraph { A -> B }",
            variant: .light
        )
        async let second = renderer.render(
            source: "digraph { A -> C }",
            variant: .light
        )
        let (one, two) = try await (first, second)
        XCTAssertNotEqual(one.markup, two.markup)
        XCTAssertEqual(renderer.cacheCount, 2)
    }

    // MARK: - AST collection

    func testDocumentCollectionKeepsOrderAndRemovesDuplicates() {
        let ast = ast(
            """
            ```markmap
            # One
            ```

            ```dot
            digraph { A -> B }
            ```

            > ```svg
            > <svg viewBox="0 0 4 4"></svg>
            > ```

            ```markmap
            # One
            ```
            """
        )
        let sources = MarkdownDiagramNodes.sources(from: ast)
        XCTAssertEqual(sources.map(\.engine), [.markmap, .graphviz, .svg])
        XCTAssertEqual(sources.first?.source, "# One\n")
        XCTAssertEqual(
            MarkdownDiagramNodes.mermaidSources(from: ast).isEmpty,
            true
        )
    }

    // MARK: - Export

    func testExportEmbedsEveryEngine() async throws {
        let source = """
        ```mermaid
        graph TD; A-->B;
        ```

        ```dot
        digraph { A -> B }
        ```

        ```markmap
        # Root
        ## Child
        ```

        ```svg
        <svg viewBox="0 0 10 10"><rect width="3" height="3"/></svg>
        ```
        """
        let result = await exportBody(source)
        XCTAssertEqual(result.assets.count, 4)
        XCTAssertTrue(result.html.contains("<figure class=\"mermaid-block\">"))
        XCTAssertTrue(
            result.html.contains("<figure class=\"diagram-block graphviz-block\">")
        )
        XCTAssertTrue(
            result.html.contains("<figure class=\"diagram-block markmap-block\">")
        )
        XCTAssertTrue(result.html.contains("<figure class=\"svg-fence\">"))
        XCTAssertTrue(result.html.contains("<rect"))
        XCTAssertFalse(result.html.contains("<script"))
        XCTAssertFalse(result.html.contains("foreignObject"))
        XCTAssertFalse(result.html.contains("example.com"))
    }

    func testGraphvizExportCarriesBothPalettes() async throws {
        let result = await exportBody("```dot\ndigraph { A -> B }\n```\n")
        XCTAssertEqual(result.assets.count, 1)
        XCTAssertTrue(result.html.contains("diagram diagram-light"))
        XCTAssertTrue(result.html.contains("diagram diagram-dark"))
        XCTAssertTrue(result.html.contains("#E6E6E6"))
    }

    func testFailedGraphvizFallsBackToItsCodeBlock() async throws {
        let result = await exportBody("```dot\ndigraph { A -> }\n```\n")
        XCTAssertTrue(result.assets.isEmpty)
        XCTAssertTrue(result.html.contains("<div class=\"code-block\">"))
        XCTAssertTrue(result.html.contains("language-dot"))
        XCTAssertFalse(result.html.contains("graphviz-block"))
        XCTAssertFalse(result.html.contains("<svg"))
    }

    func testDiagramExportByteBudgetFallsBack() async throws {
        let result = await exportBody(
            "```dot\ndigraph { A -> B }\n```\n",
            byteBudget: 1
        )
        XCTAssertTrue(result.assets.isEmpty)
        XCTAssertTrue(result.html.contains("<div class=\"code-block\">"))
        XCTAssertFalse(result.html.contains("graphviz-block"))
    }

    func testSVGFenceExportKeepsAuthoredColors() async throws {
        let result = await exportBody(
            "```svg\n<svg viewBox=\"0 0 10 10\"><rect width=\"3\" height=\"3\" fill=\"#123456\"/></svg>\n```\n",
            includeDark: true
        )
        XCTAssertEqual(result.assets.count, 1)
        XCTAssertTrue(result.html.contains("fill=\"#123456\""))
        // One palette only: the author's colors are reused for both themes.
        XCTAssertEqual(
            result.html.components(separatedBy: "<figure class=\"svg-fence\">")
                .count - 1,
            1
        )
        XCTAssertFalse(result.html.contains("diagram-dark"))
    }

    func testPrintDocumentShowsOneGraphvizVariant() async throws {
        let ast = ast("```dot\ndigraph { A -> B }\n```\n")
        let assets = await MarkdownDiagramAssets.build(
            from: ast,
            includeDark: false
        )
        let html = MarkdownHTMLExporter.document(
            ast,
            context: MarkdownExportContext(
                title: "Test",
                documentURL: nil,
                workspaceRoot: nil,
                theme: theme,
                diagrams: assets
            ),
            forPrint: true
        )
        XCTAssertTrue(html.contains("diagram diagram-light"))
        XCTAssertFalse(html.contains("diagram diagram-dark"))
        XCTAssertFalse(html.contains("<script"))
    }
}
