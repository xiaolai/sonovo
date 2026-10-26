import Foundation
import Testing
@testable import SonovoCore

@Suite("Mermaid")
struct MermaidTests {
    private func codeBlock(_ source: String) throws -> CodeBlock {
        let ast = MarkdownSyntaxAugmenter().augment(MarkdownParser.parseCanonical(source))
        guard case let .codeBlock(code, _) = ast.blocks.first else {
            Issue.record("expected a code block, got \(ast.blocks)")
            throw TestFailure()
        }
        return code
    }

    private struct TestFailure: Error {}

    private let validSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100%" viewBox="0 0 120 40" role="graphics-document document">
        <style>#m .node{fill:#eee;stroke:#333;}</style>
        <g class="nodes"><rect x="1" y="1" width="118" height="38" rx="4"></rect>
        <text x="60" y="25" text-anchor="middle">Hello</text></g>
        </svg>
        """

    // MARK: - Recognition

    @Test("A mermaid fence becomes diagram source")
    func fenceIsRecognized() throws {
        let code = try codeBlock("```mermaid\ngraph TD; A-->B;\n```\n")
        #expect(MermaidDiagramPolicy.source(from: code) == "graph TD; A-->B;\n")
    }

    @Test("The info string is matched case-insensitively on its first word")
    func infoStringVariants() throws {
        let upper = try codeBlock("```Mermaid\ngraph TD; A-->B;\n```\n")
        #expect(MermaidDiagramPolicy.source(from: upper) != nil)
        let extra = try codeBlock(
            "```mermaid title=\"Flow\"\ngraph TD; A-->B;\n```\n"
        )
        #expect(MermaidDiagramPolicy.source(from: extra) != nil)
    }

    @Test("Other fences and indented code stay code")
    func otherCodeIsNotADiagram() throws {
        let swift = try codeBlock("```swift\nlet x = 1\n```\n")
        #expect(MermaidDiagramPolicy.source(from: swift) == nil)
        let indented = try codeBlock("    graph TD; A-->B;\n")
        #expect(MermaidDiagramPolicy.source(from: indented) == nil)
    }

    // MARK: - Policy

    @Test("Directives and frontmatter are refused")
    func directivesAreRefused() {
        #expect(
            !MermaidDiagramPolicy.accepts(
                "graph TD; A-->B;\n%%{init: {\"theme\":\"dark\"}}%%"
            )
        )
        #expect(
            !MermaidDiagramPolicy.accepts(
                "---\ntitle: Flow\n---\ngraph TD; A-->B;"
            )
        )
    }

    @Test("Empty, oversized, and NUL sources are refused")
    func sizeAndContentCaps() {
        #expect(!MermaidDiagramPolicy.accepts("   \n"))
        #expect(
            !MermaidDiagramPolicy.accepts(
                String(
                    repeating: "a",
                    count: MarkdownLimits.maxMermaidSourceCharacters + 1
                )
            )
        )
        #expect(!MermaidDiagramPolicy.accepts("graph TD; A-->B;\u{0}"))
        #expect(MermaidDiagramPolicy.accepts("graph TD; A-->B;"))
    }

    // MARK: - Keys

    @Test("Cache keys are deterministic and palette-aware")
    func cacheKeys() {
        let light = MermaidDiagramKey.key(
            source: "graph TD; A-->B;",
            variant: .light
        )
        let again = MermaidDiagramKey.key(
            source: "graph TD; A-->B;",
            variant: .light
        )
        let dark = MermaidDiagramKey.key(
            source: "graph TD; A-->B;",
            variant: .dark
        )
        let other = MermaidDiagramKey.key(
            source: "graph TD; A-->C;",
            variant: .light
        )
        let versioned = MermaidDiagramKey.key(
            source: "graph TD; A-->B;",
            variant: .light,
            rendererVersion: "next"
        )
        #expect(light == again)
        #expect(light.count == 64)
        #expect(light != dark)
        #expect(light != other)
        #expect(light != versioned)
    }

    @Test("The document key ignores palette")
    func documentKey() {
        let key = MermaidDiagramKey.documentKey(source: "graph TD; A-->B;")
        let versioned = MermaidDiagramKey.documentKey(
            source: "graph TD; A-->B;",
            rendererVersion: "next"
        )
        #expect(key != versioned)
        #expect(key.count == 64)
    }

    @Test("The harness policy is script-inline and network-free")
    func harnessPolicy() {
        let csp = MermaidRendererPolicy.contentSecurityPolicy
        #expect(csp.contains("default-src 'none'"))
        #expect(csp.contains("script-src 'unsafe-inline'"))
        #expect(!csp.contains("unsafe-eval"))
        #expect(csp.contains("connect-src 'none'"))
        #expect(csp.contains("img-src data:"))
        #expect(csp.contains("base-uri 'none'"))

        let light = MermaidRendererPolicy.configurationJSON(variant: .light)
        #expect(light.contains("\"htmlLabels\":false"))
        #expect(light.contains("\"securityLevel\":\"strict\""))
        #expect(light.contains("\"theme\":\"default\""))
        #expect(light.contains("\"secure\""))
        let dark = MermaidRendererPolicy.configurationJSON(variant: .dark)
        #expect(dark.contains("\"theme\":\"dark\""))
    }

    // MARK: - Sanitizer

    @Test("A normal diagram survives with its size")
    func validSVGSurvives() throws {
        let result = try #require(SVGSanitizer.sanitize(validSVG))
        #expect(result.markup.contains("<svg"))
        #expect(result.markup.contains("<style>"))
        #expect(result.markup.contains("<text"))
        #expect(result.markup.contains("viewBox=\"0 0 120 40\""))
        #expect(result.width == 120)
        #expect(result.height == 40)
    }

    @Test("Scripts are removed with their contents")
    func scriptsAreRemoved() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
            <script>alert(1)</script><rect width="10" height="10"/>
            </svg>
            """
        let result = try #require(SVGSanitizer.sanitize(svg))
        #expect(!result.markup.lowercased().contains("<script"))
        #expect(!result.markup.contains("alert"))
        #expect(result.markup.contains("<rect"))
    }

    @Test("foreignObject and its HTML are removed")
    func foreignObjectIsRemoved() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
            <foreignObject width="10" height="10"><div>label</div></foreignObject>
            <circle cx="5" cy="5" r="4"/>
            </svg>
            """
        let result = try #require(SVGSanitizer.sanitize(svg))
        #expect(!result.markup.contains("foreignObject"))
        #expect(!result.markup.contains("label"))
        #expect(result.markup.contains("<circle"))
    }

    @Test("Event handlers and unknown attributes are dropped")
    func eventHandlersAreDropped() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
            <rect width="10" height="10" onload="alert(1)" onclick="x()" data-x="1"/>
            </svg>
            """
        let result = try #require(SVGSanitizer.sanitize(svg))
        #expect(!result.markup.contains("onload"))
        #expect(!result.markup.contains("onclick"))
        #expect(!result.markup.contains("data-x"))
    }

    @Test("Only local references survive")
    func referencesAreLocal() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
            <a href="https://example.com"><text>outside</text></a>
            <use href="#shape"/>
            <rect fill="url(https://example.com/p.svg#x)" width="1" height="1"/>
            <rect fill="url(#gradient)" width="1" height="1"/>
            </svg>
            """
        let result = try #require(SVGSanitizer.sanitize(svg))
        #expect(!result.markup.contains("href=\"https"))
        #expect(result.markup.contains("href=\"#shape\""))
        #expect(!result.markup.contains("example.com"))
        #expect(result.markup.contains("url(#gradient)"))
    }

    @Test("Inline styles keep only known, local declarations")
    func inlineStylesAreFiltered() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
            <rect width="10" height="10" style="fill: red; background-image: url(https://example.com/x.png); position: absolute"/>
            </svg>
            """
        let result = try #require(SVGSanitizer.sanitize(svg))
        #expect(result.markup.contains("fill: red"))
        #expect(!result.markup.contains("background-image"))
        #expect(!result.markup.contains("position"))
        #expect(!result.markup.contains("example.com"))
    }

    @Test("A stylesheet with a remote or scripting construct is dropped")
    func stylesheetsAreFiltered() throws {
        let remote = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
            <style>@import url(https://example.com/x.css);</style><rect width="1" height="1"/>
            </svg>
            """
        let result = try #require(SVGSanitizer.sanitize(remote))
        #expect(!result.markup.contains("@import"))
        #expect(!result.markup.contains("example.com"))
        #expect(result.markup.contains("<rect"))

        let local = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
            <style>#m .n{fill:url(#g);stroke:#333}</style><rect width="1" height="1"/>
            </svg>
            """
        let localResult = try #require(SVGSanitizer.sanitize(local))
        #expect(localResult.markup.contains("fill:url(#g)"))
    }

    @Test("Malformed, non-SVG, and doctype input fail closed")
    func malformedInput() {
        #expect(SVGSanitizer.sanitize("<svg><rect></svg>") == nil)
        #expect(SVGSanitizer.sanitize("<div>not svg</div>") == nil)
        #expect(
            SVGSanitizer.sanitize(
                "<!DOCTYPE svg [<!ENTITY x \"y\">]><svg viewBox=\"0 0 1 1\"/>"
            ) == nil
        )
        #expect(SVGSanitizer.sanitize("") == nil)
    }

    @Test("The sanitizer enforces its byte budget")
    func byteBudget() {
        let result = SVGSanitizer.sanitize(validSVG, maximumBytes: 32)
        #expect(result == nil)
    }

    @Test("Text and attribute values are re-escaped")
    func escaping() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
            <text title="a &amp; b &quot;c&quot;">a &lt; b &amp; c</text>
            </svg>
            """
        let result = try #require(SVGSanitizer.sanitize(svg))
        #expect(result.markup.contains("a &lt; b &amp; c"))
        // `title` is not an allowed attribute, so the value is dropped.
        #expect(!result.markup.contains("title="))
    }

    @Test("Named HTML entities parse as text")
    func namedEntities() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
            <text>a&nbsp;b</text>
            </svg>
            """
        let result = try #require(SVGSanitizer.sanitize(svg))
        #expect(result.markup.contains("a\u{00A0}b"))
    }

    @Test("A percentage width is not an intrinsic size")
    func percentageWidth() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="100%" height="50%"/>
            """
        let result = try #require(SVGSanitizer.sanitize(svg))
        #expect(result.width == nil)
        #expect(result.height == nil)
        #expect(result.markup.contains("width=\"100%\""))
    }

    @Test("Numeric width and height supply a size without a viewBox")
    func numericSize() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="240px" height="80"/>
            """
        let result = try #require(SVGSanitizer.sanitize(svg))
        #expect(result.width == 240)
        #expect(result.height == 80)
    }

    @Test("An invalid viewBox is dropped")
    func invalidViewBox() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 0 10" width="64"/>
            """
        let result = try #require(SVGSanitizer.sanitize(svg))
        #expect(!result.markup.contains("viewBox"))
        #expect(result.width == 64)
        #expect(result.height == nil)
    }
}
