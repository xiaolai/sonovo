import AppKit
import WebKit
import XCTest
import SonovoDiagramEngine
@testable import SonovoDiagramUI

@MainActor final class DiagramRendererTests: XCTestCase {
    private var renderer: WebDiagramRenderer { MermaidRenderer.shared }
    private var graphviz: WebDiagramRenderer { GraphvizRenderer.shared }
    private var markmap: WebDiagramRenderer { MarkmapRenderer.shared }
    private let graphvizSource = "digraph G { rankdir=LR; A -> B; B -> C; }"
    private let markmapSource = "# Root\n## Alpha\n## Beta"
    override func setUp() async throws { DiagramRenderer.clearCaches() }
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
        // Default Graphviz text has no fill attribute; the dark restyle must
        // still reach it without touching explicit author colours.
        XCTAssertTrue(dark.markup.contains("text:not([fill])"))
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
            count: DiagramLimits.maxGraphvizSourceCharacters + 1
        )
        do {
            _ = try await graphviz.render(source: source, variant: .light)
            XCTFail("expected the source cap to reject the diagram")
        } catch let error as MarkdownDiagramError {
            XCTAssertEqual(error, .rejectedSource)
        }
        XCTAssertEqual(graphviz.renderCount, before)
    }

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
}
