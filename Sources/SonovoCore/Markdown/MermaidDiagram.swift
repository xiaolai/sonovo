import CryptoKit
import Foundation

/// The two palettes a diagram is rendered for.
///
/// The raw value is what the renderer reports in cache keys and diagnostics;
/// the engine theme names are app-level translations, so the cache does not
/// change when a bundled engine renames a theme.
public enum DiagramThemeVariant: String, CaseIterable, Sendable {
    case light
    case dark
}

/// The Mermaid name is kept for the RB-23 call sites and tests; both names
/// describe the same two palettes.
public typealias MermaidThemeVariant = DiagramThemeVariant

/// A renderer that produces one diagram format.
public enum DiagramEngine: String, CaseIterable, Sendable {
    case mermaid
    case graphviz
    case markmap
    case svg
}

/// A fenced block that a diagram renderer owns, with its source.
public struct DiagramSource: Equatable, Sendable {
    public let engine: DiagramEngine
    public let source: String

    public init(engine: DiagramEngine, source: String) {
        self.engine = engine
        self.source = source
    }
}

/// Dispatches a fenced code block to the engine named by its info string.
public enum DiagramPolicy {
    /// The first whitespace-separated token of the fence info string,
    /// lowercased. A tab separates tokens exactly as a space does.
    static func infoToken(_ code: CodeBlock) -> String {
        (code.info ?? code.language ?? "")
            .split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased() ?? ""
    }

    public static func source(from code: CodeBlock) -> DiagramSource? {
        guard code.fenced else { return nil }
        let info = infoToken(code)
        switch info {
        case "mermaid":
            guard MermaidDiagramPolicy.accepts(code.code) else { return nil }
            return DiagramSource(engine: .mermaid, source: code.code)
        case "dot", "graphviz":
            guard GraphvizDiagramPolicy.accepts(code.code) else { return nil }
            return DiagramSource(engine: .graphviz, source: code.code)
        case "markmap":
            guard MarkmapDiagramPolicy.accepts(code.code) else { return nil }
            return DiagramSource(engine: .markmap, source: code.code)
        case "svg":
            guard SVGFencePolicy.accepts(code.code) else { return nil }
            return DiagramSource(engine: .svg, source: code.code)
        default:
            return nil
        }
    }
}

/// Graphviz DOT source policy.
public enum GraphvizDiagramPolicy {
    public static func accepts(_ source: String) -> Bool {
        acceptsPlainText(
            source,
            limit: MarkdownLimits.maxGraphvizSourceCharacters
        )
    }
}

/// Markmap source policy.
public enum MarkmapDiagramPolicy {
    public static func accepts(_ source: String) -> Bool {
        acceptsPlainText(
            source,
            limit: MarkdownLimits.maxMarkmapSourceCharacters
        )
    }
}

/// The rule Graphviz and Markmap share: non-blank, within its character
/// limit, and free of NUL.
private func acceptsPlainText(_ source: String, limit: Int) -> Bool {
    guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        return false
    }
    guard source.count <= limit else { return false }
    return !source.unicodeScalars.contains(where: { $0.value == 0 })
}

/// A raw SVG fence is a diagram only when it is small enough to sanitize.
public enum SVGFencePolicy {
    public static func accepts(_ source: String) -> Bool {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        guard source.utf8.count <= MarkdownLimits.maxSVGFenceBytes else {
            return false
        }
        guard !source.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return false
        }
        return true
    }
}

/// What a fenced block must satisfy to become a diagram.
public enum MermaidDiagramPolicy {
    /// The diagram source for a fenced code block, or `nil` when the block is
    /// not a renderable Mermaid diagram.
    ///
    /// The fence info string is matched on its first token, case-insensitively,
    /// so ```` ```mermaid title="x" ```` still counts.
    public static func source(from code: CodeBlock) -> String? {
        guard code.fenced else { return nil }
        guard DiagramPolicy.infoToken(code) == "mermaid" else { return nil }
        guard accepts(code.code) else { return nil }
        return code.code
    }

    /// Whether the renderer may execute this source.
    ///
    /// Two constructs are refused outright:
    /// - Mermaid directives (`%%{…}%%`) and diagram frontmatter can change the
    ///   renderer's own configuration. The harness sets `secure`, but refusing
    ///   them keeps layout and palette deterministic and keeps the security
    ///   decision in this policy rather than in Mermaid's precedence rules.
    /// - A source over the character cap is not a reading diagram; rendering
    ///   it would spend the cache and the export budget on one fence.
    public static func accepts(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard source.count <= MarkdownLimits.maxMermaidSourceCharacters else {
            return false
        }
        guard !source.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return false
        }
        guard !source.contains("%%{") else { return false }
        guard !trimmed.hasPrefix("---") else { return false }
        return true
    }
}

/// Content-addressed identity for one rendered diagram.
///
/// The renderer version is part of the key: upgrading Mermaid or changing the
/// sanitizer must invalidate every cached SVG rather than serve bytes produced
/// under a different pipeline.
public enum MermaidDiagramKey {
    public static func key(
        source: String,
        variant: MermaidThemeVariant,
        rendererVersion: String = DiagramRendererPolicy.version
    ) -> String {
        DiagramKey.key(
            engine: .mermaid,
            source: source,
            variant: variant,
            rendererVersion: rendererVersion
        )
    }

    /// The identity of the diagram independent of palette. Export assets use
    /// it because one asset carries both palette variants.
    public static func documentKey(
        source: String,
        rendererVersion: String = DiagramRendererPolicy.version
    ) -> String {
        DiagramKey.documentKey(
            engine: .mermaid,
            source: source,
            rendererVersion: rendererVersion
        )
    }
}

/// Content-addressed identity for any diagram engine.
public enum DiagramKey {
    public static func key(
        engine: DiagramEngine,
        source: String,
        variant: DiagramThemeVariant,
        rendererVersion: String = DiagramRendererPolicy.version
    ) -> String {
        digest(
            "\(rendererVersion)\u{1F}\(engine.rawValue)\u{1F}"
                + "\(variant.rawValue)\u{1F}\(source)"
        )
    }

    public static func documentKey(
        engine: DiagramEngine,
        source: String,
        rendererVersion: String = DiagramRendererPolicy.version
    ) -> String {
        digest(
            "\(rendererVersion)\u{1F}\(engine.rawValue)\u{1F}document"
                + "\u{1F}\(source)"
        )
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// The contract between the app and the isolated Mermaid page.
///
/// The page is loaded with no base URL, no reachable network, and no host
/// bridge. These strings are public so tests can assert the exact policy the
/// renderer uses rather than a copy of it.
public enum DiagramRendererPolicy {
    /// Bumped when a bundled engine or the sanitizer changes.
    public static let version = "diagrams-1"
}

public enum MermaidRendererPolicy {
    /// The Mermaid bundle version and sanitizer generation.
    public static let rendererVersion = DiagramRendererPolicy.version

    /// Scripts and styles are inline; everything else is denied.
    ///
    /// `script-src` deliberately has no `'unsafe-eval'`: the bundled Mermaid
    /// 12.2.0 contains no `eval` or `new Function` call, so the page cannot
    /// compile new code. `connect-src`, `img-src`, `font-src`, `media-src`,
    /// `object-src`, and `frame-src` close every network path.
    public static let contentSecurityPolicy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'"

    /// The JSON handed to `mermaid.initialize` before every render.
    ///
    /// `htmlLabels` is top-level in Mermaid 12; the flowchart copy is kept for
    /// diagram types that still read their own section. `secure` stops a
    /// directive from overriding the security-relevant keys even though
    /// `MermaidDiagramPolicy` already refuses directives.
    public static func configurationJSON(
        variant: DiagramThemeVariant
    ) -> String {
        let configuration: [String: Any] = [
            "startOnLoad": false,
            "securityLevel": "strict",
            "suppressErrorRendering": true,
            "htmlLabels": false,
            "theme": variant == .dark ? "dark" : "default",
            "maxTextSize": MarkdownLimits.maxMermaidSourceCharacters,
            "maxEdges": MarkdownLimits.maxMermaidEdges,
            "secure": [
                "secure",
                "securityLevel",
                "startOnLoad",
                "htmlLabels",
                "maxTextSize",
                "maxEdges",
                "suppressErrorRendering"
            ],
            "flowchart": ["htmlLabels": false],
            "class": ["htmlLabels": false],
            "sequence": ["wrap": false]
        ]
        return json(configuration)
    }
}

/// The Graphviz page.
///
/// `@viz-js/viz` compiles its bundled Graphviz WebAssembly module at render
/// time, so `script-src` must allow WebAssembly compilation. It does not
/// allow JavaScript `eval`; the only WASM bytes available to the page are the
/// ones inlined in the pinned bundle.
public enum GraphvizRendererPolicy {
    public static let contentSecurityPolicy = "default-src 'none'; script-src 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'"

    public static func configurationJSON(
        variant: DiagramThemeVariant
    ) -> String {
        json([
            "engine": "dot",
            "theme": variant == .dark ? "dark" : "light"
        ])
    }
}

/// The Markmap page. The bundle renders Markdown into an SVG mindmap and
/// converts its HTML labels into SVG text before returning.
public enum MarkmapRendererPolicy {
    public static let contentSecurityPolicy = MermaidRendererPolicy.contentSecurityPolicy

    public static func configurationJSON(
        variant: DiagramThemeVariant
    ) -> String {
        json([
            "theme": variant.rawValue,
            "textColor": variant == .dark ? "#E6E6E6" : "#333333",
            "width": 1_200,
            "height": 800
        ])
    }
}

private func json(_ configuration: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(
        withJSONObject: configuration,
        options: [.sortedKeys]
    )) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}
