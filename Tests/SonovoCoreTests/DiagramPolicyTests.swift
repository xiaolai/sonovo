import Foundation
import Testing
@testable import SonovoCore

@Suite("Diagram engines")
struct DiagramPolicyTests {
    private func codeBlock(_ source: String) throws -> CodeBlock {
        let ast = MarkdownSyntaxAugmenter()
            .augment(MarkdownParser.parseCanonical(source))
        guard case let .codeBlock(code, _) = ast.blocks.first else {
            Issue.record("expected a code block, got \(ast.blocks)")
            throw TestFailure()
        }
        return code
    }

    private struct TestFailure: Error {}

    // MARK: - Recognition

    @Test("Each diagram info string selects its engine")
    func engineRecognition() throws {
        let expectations: [(fence: String, engine: DiagramEngine, body: String)] = [
            ("mermaid", .mermaid, "graph TD; A-->B;"),
            ("dot", .graphviz, "digraph { A -> B }"),
            ("graphviz", .graphviz, "digraph { A -> B }"),
            ("markmap", .markmap, "# Root\n## Child"),
            ("svg", .svg, "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")
        ]
        for expectation in expectations {
            let code = try codeBlock(
                "```\(expectation.fence)\n\(expectation.body)\n```\n"
            )
            let diagram = try #require(DiagramPolicy.source(from: code))
            #expect(diagram.engine == expectation.engine)
            #expect(diagram.source == expectation.body + "\n")
        }
    }

    @Test("Diagram info strings are case-insensitive and tolerate attributes")
    func infoStringVariants() throws {
        let upper = try codeBlock("```DOT\ndigraph { A -> B }\n```\n")
        #expect(DiagramPolicy.source(from: upper)?.engine == .graphviz)
        let extra = try codeBlock("```svg title=\"Icon\"\n<svg></svg>\n```\n")
        #expect(DiagramPolicy.source(from: extra)?.engine == .svg)
    }

    @Test("Ordinary and indented code stays code")
    func otherCodeIsNotADiagram() throws {
        let swift = try codeBlock("```swift\nlet x = 1\n```\n")
        #expect(DiagramPolicy.source(from: swift) == nil)
        let indented = try codeBlock("    digraph { A -> B }\n")
        #expect(DiagramPolicy.source(from: indented) == nil)
    }

    @Test("Mermaid source still passes the Mermaid policy")
    func mermaidCompatibility() throws {
        let code = try codeBlock(
            "```mermaid\ngraph TD; A-->B;\n%%{init: {}}%%\n```\n"
        )
        // The Mermaid directive refuses the whole fence, including through the
        // general dispatcher; a regression here would render an unvetted
        // configuration.
        #expect(DiagramPolicy.source(from: code) == nil)
        let valid = try codeBlock("```mermaid\ngraph TD; A-->B;\n```\n")
        #expect(DiagramPolicy.source(from: valid)?.engine == .mermaid)
    }

    // MARK: - Source policy

    @Test("Empty, oversized, and NUL sources are refused per engine")
    func capsPerEngine() {
        #expect(!GraphvizDiagramPolicy.accepts("  \n"))
        #expect(!MarkmapDiagramPolicy.accepts("\n"))
        #expect(!SVGFencePolicy.accepts("\n"))

        #expect(
            !GraphvizDiagramPolicy.accepts(
                String(
                    repeating: "a",
                    count: MarkdownLimits.maxGraphvizSourceCharacters + 1
                )
            )
        )
        #expect(
            !MarkmapDiagramPolicy.accepts(
                String(
                    repeating: "a",
                    count: MarkdownLimits.maxMarkmapSourceCharacters + 1
                )
            )
        )
        #expect(
            !SVGFencePolicy.accepts(
                String(
                    repeating: "a",
                    count: MarkdownLimits.maxSVGFenceBytes + 1
                )
            )
        )

        #expect(!GraphvizDiagramPolicy.accepts("digraph {\u{0}}"))
        #expect(!MarkmapDiagramPolicy.accepts("#\u{0}"))
        #expect(!SVGFencePolicy.accepts("<svg>\u{0}</svg>"))

        #expect(GraphvizDiagramPolicy.accepts("digraph { A -> B }"))
        #expect(MarkmapDiagramPolicy.accepts("# Root"))
        #expect(SVGFencePolicy.accepts("<svg></svg>"))
    }

    @Test("The SVG fence cap is measured in bytes, not characters")
    func svgFenceMeasuresBytes() {
        // A multi-byte character can pass a character count while exceeding
        // the byte cap; the policy must not let that reach the parser.
        let scalar = "\u{1F600}" // four UTF-8 bytes
        let count = MarkdownLimits.maxSVGFenceBytes / 4 + 1
        let source = String(repeating: scalar, count: count)
        #expect(source.count < MarkdownLimits.maxSVGFenceBytes)
        #expect(source.utf8.count > MarkdownLimits.maxSVGFenceBytes)
        #expect(!SVGFencePolicy.accepts(source))
    }

    // MARK: - Keys

    @Test("The key includes the engine, the palette, and the renderer version")
    func keysSeparateEngines() {
        let source = "digraph { A -> B }"
        let mermaid = DiagramKey.key(
            engine: .mermaid,
            source: source,
            variant: .light
        )
        let graphviz = DiagramKey.key(
            engine: .graphviz,
            source: source,
            variant: .light
        )
        #expect(mermaid != graphviz)

        let dark = DiagramKey.key(
            engine: .graphviz,
            source: source,
            variant: .dark
        )
        #expect(graphviz != dark)

        let upgraded = DiagramKey.key(
            engine: .graphviz,
            source: source,
            variant: .light,
            rendererVersion: "diagrams-2"
        )
        #expect(graphviz != upgraded)

        #expect(
            DiagramKey.documentKey(engine: .graphviz, source: source)
                != DiagramKey.documentKey(engine: .markmap, source: source)
        )
    }

    @Test("The Mermaid key helpers agree with the general key")
    func mermaidKeyCompatibility() {
        let source = "graph TD; A-->B;"
        #expect(
            MermaidDiagramKey.key(source: source, variant: .light)
                == DiagramKey.key(
                    engine: .mermaid,
                    source: source,
                    variant: .light
                )
        )
        #expect(
            MermaidDiagramKey.documentKey(source: source)
                == DiagramKey.documentKey(engine: .mermaid, source: source)
        )
    }

    // MARK: - Renderer policy

    @Test("Graphviz allows WebAssembly compilation but not JavaScript eval")
    func graphvizPolicy() {
        let csp = GraphvizRendererPolicy.contentSecurityPolicy
        #expect(csp.contains("'wasm-unsafe-eval'"))
        #expect(!csp.contains("'unsafe-eval'"))
        #expect(csp.contains("default-src 'none'"))
        #expect(csp.contains("connect-src 'none'"))
        #expect(csp.contains("frame-src 'none'"))

        let light = GraphvizRendererPolicy.configurationJSON(variant: .light)
        let dark = GraphvizRendererPolicy.configurationJSON(variant: .dark)
        #expect(light.contains("\"engine\":\"dot\""))
        #expect(light.contains("\"theme\":\"light\""))
        #expect(dark.contains("\"theme\":\"dark\""))
    }

    @Test("Markmap carries the Mermaid CSP and per-palette text color")
    func markmapPolicy() {
        #expect(
            MarkmapRendererPolicy.contentSecurityPolicy
                == MermaidRendererPolicy.contentSecurityPolicy
        )
        let light = MarkmapRendererPolicy.configurationJSON(variant: .light)
        let dark = MarkmapRendererPolicy.configurationJSON(variant: .dark)
        #expect(light.contains("\"textColor\":\"#333333\""))
        #expect(dark.contains("\"textColor\":\"#E6E6E6\""))
        #expect(light.contains("\"width\":1200"))
        #expect(light.contains("\"height\":800"))
    }

    @Test("Limits cover every engine")
    func limitsCoverEveryEngine() {
        #expect(MarkdownLimits.maxRenderedDiagrams == 200)
        #expect(MarkdownLimits.maxDiagramExportBytes == 16 * 1024 * 1024)
        #expect(MarkdownLimits.maxGraphvizSourceCharacters > 0)
        #expect(MarkdownLimits.maxMarkmapSourceCharacters > 0)
        #expect(MarkdownLimits.maxSVGFenceBytes > 0)
    }
}

@Suite("SVG source extraction")
struct SVGSourceTests {
    @Test("A document ending exactly at the close tag is extracted")
    func trailingCloseTag() {
        #expect(SVGSource.document(from: "<svg></svg>") == "<svg></svg>")
        #expect(
            SVGSource.document(from: "<svg viewBox=\"0 0 1 1\"/>")
                == nil
        )
    }

    @Test("Prolog, doctype, comments, and trailing whitespace are trimmed")
    func surroundingContent() {
        let raw = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "x">
        <!-- generated -->
        <svg viewBox="0 0 1 1"><rect/></svg>

        """
        #expect(
            SVGSource.document(from: raw)
                == "<svg viewBox=\"0 0 1 1\"><rect/></svg>"
        )
    }

    @Test("Tags are found case-insensitively")
    func caseInsensitiveTags() {
        #expect(SVGSource.document(from: "<SVG></SVG>") == "<SVG></SVG>")
        #expect(
            SVGSource.document(from: "<svg></SVG>\n") == "<svg></SVG>"
        )
    }

    @Test("Missing open or close tags return nil")
    func missingTags() {
        #expect(SVGSource.document(from: "no markup") == nil)
        #expect(SVGSource.document(from: "<svg>") == nil)
        #expect(SVGSource.document(from: "</svg>") == nil)
    }

    @Test("The sanitizer falls back when its time limit expires")
    func sanitizerTimeLimit() {
        let svg = """
        <svg viewBox="0 0 10 10"><g><rect width="1" height="1"/></g></svg>
        """
        #expect(SVGSanitizer.sanitize(svg) != nil)
        #expect(SVGSanitizer.sanitize(svg, timeLimit: .zero) == nil)
    }
}
