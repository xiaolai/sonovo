import AppKit
import SonovoCore
import SwiftUI
import WebKit

/// Why a diagram did not render. The reader falls back to the fenced source
/// for every case; the distinction keeps diagnostics honest.
enum MarkdownDiagramError: Error, Equatable {
    case rejectedSource
    case unavailable
    case loadFailed(String)
    case timeout
    case renderFailed(String)
    case invalidOutput
}

/// The RB-23 name; both names describe the same errors.
typealias MarkdownMermaidError = MarkdownDiagramError

/// A bounded first-in-first-out cache shared by the web renderer and the
/// in-process SVG fence renderer. Both previously carried their own copy of
/// the same insertion, capacity, and batch-eviction rules.
struct DiagramCache<Value> {
    private var entries: [String: Value] = [:]
    private var insertionOrder: [String] = []
    private let limit: Int

    init(limit: Int = MarkdownLimits.maxMermaidRenderCacheEntries) {
        self.limit = max(1, limit)
    }

    subscript(key: String) -> Value? {
        entries[key]
    }

    var count: Int { entries.count }

    mutating func insert(_ value: Value, for key: String) {
        if entries[key] == nil {
            insertionOrder.append(key)
        }
        entries[key] = value
        if insertionOrder.count > limit {
            let removeCount = max(1, limit / 4)
            for stale in insertionOrder.prefix(removeCount) {
                entries.removeValue(forKey: stale)
            }
            insertionOrder.removeFirst(removeCount)
        }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        insertionOrder.removeAll(keepingCapacity: false)
    }
}

/// One diagram rendered for both palettes, ready for the HTML exporter.
///
/// `svg` documents carry one palette; the light bytes are reused for dark
/// because the author owns their colors.
struct MarkdownDiagramAsset: Sendable, Equatable {
    let engine: DiagramEngine
    let lightSVG: String
    let darkSVG: String
    let width: Double?
    let height: Double?
}

/// The RB-23 name.
typealias MarkdownMermaidAsset = MarkdownDiagramAsset

// MARK: - Engine specification

/// Everything that differs between the isolated diagram engines.
struct DiagramEngineSpec: Sendable {
    let engine: DiagramEngine
    /// Resource base names, in load order.
    let scriptResources: [String]
    let contentSecurityPolicy: String
    /// A syntactically valid base URL when the bundled script resolves one.
    /// It never names a reachable host; CSP denies every network request.
    let baseURL: URL?
    /// The inline script that defines `window.__sonovoRender`.
    let rendererScript: String
    let configurationJSON: @Sendable (DiagramThemeVariant) -> String

    static let mermaid = DiagramEngineSpec(
        engine: .mermaid,
        scriptResources: ["mermaid-12.2.0.min"],
        contentSecurityPolicy: MermaidRendererPolicy.contentSecurityPolicy,
        baseURL: nil,
        rendererScript: mermaidRendererScript,
        configurationJSON: MermaidRendererPolicy.configurationJSON
    )

    static let graphviz = DiagramEngineSpec(
        engine: .graphviz,
        scriptResources: ["viz-global-3.31.0.min"],
        contentSecurityPolicy: GraphvizRendererPolicy.contentSecurityPolicy,
        baseURL: URL(string: "https://sonovo.invalid/"),
        rendererScript: graphvizRendererScript,
        configurationJSON: GraphvizRendererPolicy.configurationJSON
    )

    static let markmap = DiagramEngineSpec(
        engine: .markmap,
        scriptResources: ["markmap-0.18.12.min"],
        contentSecurityPolicy: MarkmapRendererPolicy.contentSecurityPolicy,
        baseURL: nil,
        rendererScript: markmapRendererScript,
        configurationJSON: MarkmapRendererPolicy.configurationJSON
    )

    // MARK: Engine scripts

    private static let mermaidRendererScript = """
        window.__sonovoRender = async function(source, configuration, identifier) {
          try {
            mermaid.initialize(JSON.parse(configuration));
            const rendered = await mermaid.render(identifier, source);
            return JSON.stringify({ svg: rendered.svg });
          } catch (error) {
            return JSON.stringify({
              error: String((error && error.message) || error)
            });
          } finally {
            const leftovers = [
              document.getElementById(identifier),
              document.getElementById('d' + identifier)
            ];
            for (const node of leftovers) {
              if (node && node.parentNode) { node.parentNode.removeChild(node); }
            }
          }
        };
        """

    private static let graphvizRendererScript = """
        window.__sonovoRender = async function(source, configuration) {
          try {
            const options = JSON.parse(configuration || '{}');
            const viz = await Viz.instance();
            let svg = viz.renderString(source, {
              engine: options.engine || 'dot',
              format: 'svg'
            });
            if (options.theme === 'dark') {
              // Restyle default ink only. Plain Graphviz labels often carry
              // no fill attribute at all, while an explicit fill, stroke,
              // or fontcolor is the author's choice and must survive.
              const style = '<style>'
                + 'text:not([fill]),[fill="black"]{fill:#E6E6E6}'
                + '[stroke="black"]{stroke:#E6E6E6}'
                + 'polygon[fill="white"]{fill:transparent}</style>';
              const index = svg.lastIndexOf('</svg>');
              if (index >= 0) {
                svg = svg.slice(0, index) + style + svg.slice(index);
              }
            }
            return JSON.stringify({ svg: svg });
          } catch (error) {
            return JSON.stringify({
              error: String((error && error.message) || error)
            });
          }
        };
        """

    private static let markmapRendererScript = """
        window.__sonovoRender = async function(source, configuration, identifier) {
          return await window.__sonovoRenderMarkmap(source, identifier, configuration);
        };
        """
}

// MARK: - Script renderer

/// Renders one diagram engine in an isolated `WKWebView`.
///
/// The page is `loadHTMLString` with no reachable base URL: the engine bundle
/// is inlined, every script is inline, and the content security policy denies
/// network, files, frames, workers, and fonts. There are no message handlers,
/// so the page has no callable host surface, and the navigation delegate
/// cancels anything except the initial load. The SVG that comes back is passed
/// through `SVGSanitizer` before it is cached or displayed.
///
/// Each engine owns one web view and one render queue. A timeout discards the
/// page so a hung diagram cannot wedge every later one.
@MainActor
final class WebDiagramRenderer: NSObject, WKNavigationDelegate {
    static let mermaidScriptName = "mermaid-12.2.0.min"
    static let graphvizScriptName = "viz-global-3.31.0.min"
    static let markmapScriptName = "markmap-0.18.12.min"

    let spec: DiagramEngineSpec

    private var webView: WKWebView?
    private var isLoaded = false
    private var loadBox: OnceContinuation<Void>?
    private lazy var harness: String? = Self.buildHarness(spec: spec)
    private var tail: Task<Void, Never>?

    private var cache = DiagramCache<
        Result<SanitizedSVG, MarkdownDiagramError>
    >()

    /// Number of diagrams actually handed to the web view. Tests use it to
    /// prove a second request came from the cache.
    private(set) var renderCount = 0

    init(spec: DiagramEngineSpec) {
        self.spec = spec
        super.init()
    }

    /// Renders one diagram, applying the source policy and the SVG sanitizer.
    func render(
        source: String,
        variant: DiagramThemeVariant,
        timeout: Duration = .seconds(
            MarkdownLimits.mermaidRenderTimeoutSeconds
        )
    ) async throws -> SanitizedSVG {
        guard Self.accepts(source, engine: spec.engine) else {
            throw MarkdownDiagramError.rejectedSource
        }
        let key = DiagramKey.key(
            engine: spec.engine,
            source: source,
            variant: variant
        )
        if let cached = cache[key] {
            return try cached.get()
        }

        // Chain onto the previous render so the single web view is never
        // driven by two diagrams at once. Cancelling the caller cancels this
        // operation, which skips the engine if its turn has not come yet.
        let previous = tail
        let operation = Task { @MainActor [weak self] in
            await previous?.value
            try Task.checkCancellation()
            guard let self else { throw MarkdownDiagramError.unavailable }
            if let cached = self.cache[key] {
                return try cached.get()
            }
            return try await self.performRender(
                source: source,
                variant: variant,
                key: key,
                timeout: timeout
            )
        }
        tail = Task { _ = try? await operation.value }

        let result: Result<SanitizedSVG, MarkdownDiagramError>
        do {
            let svg = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            result = .success(svg)
        } catch is CancellationError {
            // A cancelled view is gone; do not cache its failure as if the
            // diagram were broken.
            throw CancellationError()
        } catch let error as MarkdownDiagramError {
            result = .failure(error)
        } catch {
            result = .failure(.renderFailed(error.localizedDescription))
        }
        if isCacheable(result) {
            store(key: key, result: result)
        }
        return try result.get()
    }

    func clearCache() {
        cache.removeAll()
    }

    var cacheCount: Int { cache.count }

    static func accepts(_ source: String, engine: DiagramEngine) -> Bool {
        switch engine {
        case .mermaid:
            return MermaidDiagramPolicy.accepts(source)
        case .graphviz:
            return GraphvizDiagramPolicy.accepts(source)
        case .workflow:
            // A workflow source is YAML; the DOT conversion happens in
            // DiagramRenderer before the Graphviz engine sees it.
            return WorkflowDetection.acceptsSource(source)
        case .markmap:
            return MarkmapDiagramPolicy.accepts(source)
        case .svg:
            return SVGFencePolicy.accepts(source)
        }
    }

    // MARK: Rendering

    private func performRender(
        source: String,
        variant: DiagramThemeVariant,
        key: String,
        timeout: Duration
    ) async throws -> SanitizedSVG {
        try await ensureLoaded(timeout: timeout)
        guard let webView else { throw MarkdownDiagramError.unavailable }
        renderCount += 1

        let identifier = "sonovo-diagram-" + String(key.prefix(16))
        let output = try await callAsync(
            webView: webView,
            script: "return await window.__sonovoRender(source, configuration, identifier);",
            arguments: [
                "source": source,
                "configuration": spec.configurationJSON(variant),
                "identifier": identifier
            ],
            timeout: timeout
        )
        guard let text = output,
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                HarnessOutput.self,
                from: data
              ) else {
            throw MarkdownDiagramError.invalidOutput
        }
        if let message = decoded.error {
            throw MarkdownDiagramError.renderFailed(message)
        }
        guard let raw = decoded.svg else {
            throw MarkdownDiagramError.invalidOutput
        }
        // Parsing and sanitizing a large SVG is seconds of CPU. The web
        // view only returned; doing this on the main actor stalls every
        // consumer of the diagram. The sanitizer keeps its own deadline.
        let sanitized: SanitizedSVG? = await Task.detached(
            priority: .userInitiated
        ) {
            guard let document = SVGSource.document(from: raw) else {
                return nil
            }
            return SVGSanitizer.sanitize(document, timeLimit: timeout)
        }.value
        guard let sanitized else {
            throw MarkdownDiagramError.invalidOutput
        }
        return sanitized
    }

    private struct HarnessOutput: Decodable {
        let svg: String?
        let error: String?
    }

    // MARK: Loading

    private func ensureLoaded(timeout: Duration) async throws {
        if isLoaded, webView != nil { return }
        guard let harness else { throw MarkdownDiagramError.unavailable }
        resetWebView()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.suppressesIncrementalRendering = true
        let webView = WKWebView(
            // token-exempt: offscreen render surface, not product layout
            frame: NSRect(x: 0, y: 0, width: 1_024, height: 768),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.isInspectable = false
        self.webView = webView

        let box = OnceContinuation<Void>()
        loadBox = box
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            if box.resume(throwing: MarkdownDiagramError.timeout) {
                self.resetWebView()
            }
        }
        defer { timeoutTask.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            box.install(continuation)
            webView.loadHTMLString(harness, baseURL: spec.baseURL)
        }
    }

    private func resetWebView() {
        loadBox?.resume(throwing: MarkdownDiagramError.unavailable)
        loadBox = nil
        guard let webView else {
            isLoaded = false
            return
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        isLoaded = false
    }

    // MARK: JavaScript

    private func callAsync(
        webView: WKWebView,
        script: String,
        arguments: [String: Any],
        timeout: Duration
    ) async throws -> String? {
        let box = OnceContinuation<String?>()
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            if box.resume(throwing: MarkdownDiagramError.timeout) {
                self.resetWebView()
            }
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String?, Error>) in
            box.install(continuation)
            webView.callAsyncJavaScript(
                script,
                arguments: arguments,
                in: nil,
                in: .page
            ) { result in
                switch result {
                case let .success(value):
                    box.resume(returning: value as? String)
                case let .failure(error):
                    // WebKit's own errors are transport failures — a dead
                    // process, a killed load — and say nothing about the
                    // diagram, so they must not be cached. A JavaScript
                    // exception is the diagram's own deterministic error.
                    let ns = error as NSError
                    if ns.domain == WKError.errorDomain,
                       ns.code != WKError.Code.javaScriptExceptionOccurred.rawValue {
                        box.resume(
                            throwing: MarkdownDiagramError.loadFailed(
                                error.localizedDescription
                            )
                        )
                        return
                    }
                    box.resume(
                        throwing: MarkdownDiagramError.renderFailed(
                            error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    // MARK: Cache

    private func isCacheable(
        _ result: Result<SanitizedSVG, MarkdownDiagramError>
    ) -> Bool {
        switch result {
        case .success:
            return true
        case let .failure(error):
            switch error {
            case .renderFailed, .invalidOutput, .rejectedSource:
                return true
            case .timeout, .unavailable, .loadFailed:
                return false
            }
        }
    }

    private func store(
        key: String,
        result: Result<SanitizedSVG, MarkdownDiagramError>
    ) {
        cache.insert(result, for: key)
    }

    // MARK: Navigation

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard webView === self.webView else {
            return (.cancel, preferences)
        }
        let url = navigationAction.request.url
        let isInitial = !isLoaded
            && navigationAction.navigationType == .other
            && (url == nil
                || url?.absoluteString == "about:blank"
                || url == spec.baseURL)
        return (isInitial ? .allow : .cancel, preferences)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, !isLoaded else { return }
        isLoaded = true
        loadBox?.resume(returning: ())
        loadBox = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        fail(webView, message: error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        fail(webView, message: error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail(webView, message: "web content process terminated")
    }

    /// Every failure path ends the same way: resume the waiter with a load
    /// error and drop the web view that produced it.
    private func fail(_ webView: WKWebView, message: String) {
        guard webView === self.webView else { return }
        loadBox?.resume(throwing: MarkdownDiagramError.loadFailed(message))
        loadBox = nil
        resetWebView()
    }

    // MARK: Harness

    static func buildHarness(spec: DiagramEngineSpec) -> String? {
        var scripts = ""
        for name in spec.scriptResources {
            guard let url = Bundle.module.url(
                forResource: name,
                withExtension: "js"
            ), let script = try? String(contentsOf: url, encoding: .utf8),
                  !script.isEmpty else {
                return nil
            }
            scripts += "<script>\n\(script)\n</script>\n"
        }
        let csp = spec.contentSecurityPolicy
        return """
        <!DOCTYPE html>
        <html lang="und">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="referrer" content="no-referrer">
        <style>
        html, body { margin: 0; padding: 0; background: transparent; }
        body { font-family: -apple-system, sans-serif; }
        #sonovo-root { position: absolute; left: -10000px; top: 0; }
        </style>
        </head>
        <body>
        <div id="sonovo-root" aria-hidden="true"></div>
        \(scripts)
        <script>
        \(spec.rendererScript)
        window.__sonovoNetworkProbe = async function() {
          const result = {};
          // Controls: a data: image is allowed by img-src, and a data: fetch
          // would succeed without CSP but is denied by connect-src. Together
          // they show the page works and the policy is what blocks network.
          try {
            await new Promise((resolve, reject) => {
              const image = new Image();
              image.onload = resolve;
              image.onerror = () => reject(new Error('blocked'));
              image.src = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
            });
            result.dataImage = 'allowed';
          } catch (error) { result.dataImage = 'blocked'; }
          try {
            await fetch('data:text/plain,ok');
            result.dataFetch = 'allowed';
          } catch (error) { result.dataFetch = 'blocked'; }
          try {
            await fetch('https://example.com/sonovo-probe');
            result.fetch = 'allowed';
          } catch (error) { result.fetch = 'blocked'; }
          try {
            await fetch('file:///etc/passwd');
            result.file = 'allowed';
          } catch (error) { result.file = 'blocked'; }
          try {
            const request = new XMLHttpRequest();
            request.open('GET', 'https://example.com/sonovo-probe', false);
            request.send();
            result.xhr = 'allowed';
          } catch (error) { result.xhr = 'blocked'; }
          try {
            const socket = new WebSocket('wss://example.com/sonovo-probe');
            result.websocket = 'allowed';
            socket.close();
          } catch (error) { result.websocket = 'blocked'; }
          try {
            await new Promise((resolve, reject) => {
              const image = new Image();
              image.onload = resolve;
              image.onerror = () => reject(new Error('blocked'));
              image.src = 'https://example.com/sonovo-probe.png';
            });
            result.image = 'allowed';
          } catch (error) { result.image = 'blocked'; }
          const handlers = window.webkit && window.webkit.messageHandlers
            ? Object.keys(window.webkit.messageHandlers)
            : [];
          result.messageHandlers = String(handlers.length);
          return JSON.stringify(result);
        };
        </script>
        </body>
        </html>
        """
    }

    // MARK: Test hooks

    /// Loads the isolated page without rendering. Tests drive the same page
    /// the renderer uses.
    func loadForTesting() async throws {
        try await ensureLoaded(
            timeout: .seconds(MarkdownLimits.mermaidRenderTimeoutSeconds)
        )
    }

    /// The live web view, for navigation-policy tests.
    var webViewForTesting: WKWebView? { webView }

    /// Asks the page to attempt each network path. Returns what the page
    /// observed; a working policy reports `blocked` for every network entry.
    func probeNetworkForTesting() async throws -> [String: String] {
        try await ensureLoaded(
            timeout: .seconds(MarkdownLimits.mermaidRenderTimeoutSeconds)
        )
        guard let webView else { throw MarkdownDiagramError.unavailable }
        let output = try await callAsync(
            webView: webView,
            script: "return await window.__sonovoNetworkProbe();",
            arguments: [:],
            timeout: .seconds(MarkdownLimits.mermaidRenderTimeoutSeconds)
        )
        guard let text = output,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                  as? [String: String] else {
            throw MarkdownDiagramError.invalidOutput
        }
        return object
    }
}

// MARK: - Resumable continuation

/// A continuation that can be resumed from either the completion handler or
/// the timeout task, at most once. Both callers run on the main actor.
@MainActor
final class OnceContinuation<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: Value) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(throwing: error)
        return true
    }
}

// MARK: - Renderers

/// The RB-23 Mermaid renderer facade.
@MainActor
enum MermaidRenderer {
    static let scriptName = WebDiagramRenderer.mermaidScriptName
    static let shared = WebDiagramRenderer(spec: .mermaid)

    static func harnessForTesting() -> String? {
        WebDiagramRenderer.buildHarness(spec: .mermaid)
    }
}

/// The RB-24 Graphviz renderer facade.
@MainActor
enum GraphvizRenderer {
    static let scriptName = WebDiagramRenderer.graphvizScriptName
    static let shared = WebDiagramRenderer(spec: .graphviz)

    static func harnessForTesting() -> String? {
        WebDiagramRenderer.buildHarness(spec: .graphviz)
    }
}

/// The RB-24 Markmap renderer facade.
@MainActor
enum MarkmapRenderer {
    static let scriptName = WebDiagramRenderer.markmapScriptName
    static let shared = WebDiagramRenderer(spec: .markmap)

    static func harnessForTesting() -> String? {
        WebDiagramRenderer.buildHarness(spec: .markmap)
    }
}

/// Dispatches a diagram to its engine. Raw SVG needs no web view.
@MainActor
enum DiagramRenderer {
    private static var svgCache = DiagramCache<
        Result<SanitizedSVG, MarkdownDiagramError>
    >()

    static func render(
        _ diagram: DiagramSource,
        variant: DiagramThemeVariant,
        timeout: Duration = .seconds(
            MarkdownLimits.mermaidRenderTimeoutSeconds
        )
    ) async throws -> SanitizedSVG {
        switch diagram.engine {
        case .mermaid:
            return try await MermaidRenderer.shared.render(
                source: diagram.source,
                variant: variant,
                timeout: timeout
            )
        case .graphviz:
            return try await GraphvizRenderer.shared.render(
                source: diagram.source,
                variant: variant,
                timeout: timeout
            )
        case .workflow:
            // Parsing YAML is real work; keep it off the main actor, which
            // the reader and the exporter both run on.
            let dot = await Task.detached(priority: .userInitiated) {
                WorkflowDiagramPolicy.dot(
                    from: diagram.source,
                    variant: variant
                )
            }.value
            try Task.checkCancellation()
            guard let dot else { throw MarkdownDiagramError.rejectedSource }
            return try await GraphvizRenderer.shared.render(
                source: dot,
                variant: variant,
                timeout: timeout
            )
        case .markmap:
            return try await MarkmapRenderer.shared.render(
                source: diagram.source,
                variant: variant,
                timeout: timeout
            )
        case .svg:
            return try await renderSVGFence(
                diagram.source,
                variant: variant,
                timeout: timeout
            )
        }
    }

    static func clearCaches() {
        MermaidRenderer.shared.clearCache()
        GraphvizRenderer.shared.clearCache()
        MarkmapRenderer.shared.clearCache()
        svgCache.removeAll()
    }

    static func renderSVGFence(
        _ source: String,
        variant: DiagramThemeVariant,
        timeout: Duration = .seconds(
            MarkdownLimits.mermaidRenderTimeoutSeconds
        )
    ) async throws -> SanitizedSVG {
        guard SVGFencePolicy.accepts(source) else {
            throw MarkdownDiagramError.rejectedSource
        }
        let key = DiagramKey.key(
            engine: .svg,
            source: source,
            variant: variant
        )
        if let cached = svgCache[key] {
            return try cached.get()
        }
        // Parsing and sanitizing a fence can take seconds of CPU; run it off
        // the main actor with the caller's budgeted deadline. The sanitizer
        // keeps its own shorter cap.
        let result = await Task.detached(priority: .userInitiated) {
            let result: Result<SanitizedSVG, MarkdownDiagramError>
            if let document = SVGSource.document(from: source),
               let sanitized = SVGSanitizer.sanitize(
                   document,
                   timeLimit: min(
                       timeout,
                       .seconds(MarkdownLimits.svgSanitizeTimeoutSeconds)
                   )
               ) {
                result = .success(sanitized)
            } else {
                result = .failure(.invalidOutput)
            }
            return result
        }.value
        svgCache.insert(result, for: key)
        return try result.get()
    }
}

// MARK: - AST collection

enum MarkdownDiagramNodes {
    /// Every distinct diagram in the document, in document order.
    static func sources(from ast: SonovoAST) -> [DiagramSource] {
        var seen = Set<String>()
        var result: [DiagramSource] = []

        func add(_ code: CodeBlock) {
            guard let diagram = DiagramPolicy.source(from: code) else {
                return
            }
            let identity = diagram.engine.rawValue + "\u{1F}" + diagram.source
            guard seen.insert(identity).inserted else { return }
            result.append(diagram)
        }

        func walk(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case let .codeBlock(code, _):
                    add(code)
                case let .blockQuote(children, _):
                    walk(children)
                case let .list(list, _):
                    for item in list.items { walk(item.blocks) }
                case let .details(details, _):
                    walk(details.blocks)
                default:
                    break
                }
            }
        }

        walk(ast.blocks)
        return result
    }

    /// The Mermaid slice, for the E2E marker.
    static func mermaidSources(from ast: SonovoAST) -> [String] {
        sources(from: ast)
            .filter { $0.engine == .mermaid }
            .map(\.source)
    }
}

// MARK: - Export assets

@MainActor
enum MarkdownDiagramAssets {
    /// Renders each diagram once for both palettes. A diagram that fails to
    /// render is absent, so the exporter falls back to the code block.
    static func build(
        from ast: SonovoAST,
        includeDark: Bool,
        byteBudget: Int = MarkdownLimits.maxDiagramExportBytes,
        deadline: Date? = nil
    ) async -> [String: MarkdownDiagramAsset] {
        let sources = MarkdownDiagramNodes.sources(from: ast)
            .prefix(MarkdownLimits.maxRenderedDiagrams)
        guard !sources.isEmpty else { return [:] }

        // One wall clock for the whole build. Every diagram used to get a
        // fresh 10 s, so 200 diagrams could hold an export for half an hour
        // before the PDF budget even started.
        let budgetDeadline = deadline ?? Date().addingTimeInterval(
            MarkdownLimits.pdfRenderTimeoutSeconds
        )
        var assets: [String: MarkdownDiagramAsset] = [:]
        assets.reserveCapacity(sources.count)
        var totalBytes = 0

        diagramLoop: for diagram in sources {
            let remaining = budgetDeadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let timeout = Duration.seconds(
                min(MarkdownLimits.mermaidRenderTimeoutSeconds, remaining)
            )
            let light: SanitizedSVG
            do {
                light = try await DiagramRenderer.render(
                    diagram,
                    variant: .light,
                    timeout: timeout
                )
            } catch let error as MarkdownDiagramError {
                // A timeout means the shared budget is spent; trying the
                // next diagram would only stall the export again.
                if error == .timeout { break }
                continue
            } catch {
                continue
            }
            var dark = light.markup
            if includeDark, diagram.engine != .svg {
                let darkRemaining = budgetDeadline.timeIntervalSinceNow
                guard darkRemaining > 0 else { break }
                let darkTimeout = Duration.seconds(
                    min(
                        MarkdownLimits.mermaidRenderTimeoutSeconds,
                        darkRemaining
                    )
                )
                do {
                    let rendered = try await DiagramRenderer.render(
                        diagram,
                        variant: .dark,
                        timeout: darkTimeout
                    )
                    dark = rendered.markup
                } catch let error as MarkdownDiagramError {
                    if error == .timeout { break diagramLoop }
                } catch {
                    // Keep the light variant.
                }
            }
            let bytes = light.markup.utf8.count + dark.utf8.count
            if totalBytes + bytes > byteBudget {
                break
            }
            assets[DiagramKey.documentKey(
                engine: diagram.engine,
                source: diagram.source
            )] = MarkdownDiagramAsset(
                engine: diagram.engine,
                lightSVG: light.markup,
                darkSVG: dark,
                width: light.width,
                height: light.height
            )
            totalBytes += bytes
        }
        return assets
    }
}

/// The RB-23 name.
@MainActor
enum MarkdownMermaidAssets {
    static func build(
        from ast: SonovoAST,
        includeDark: Bool,
        byteBudget: Int = MarkdownLimits.maxDiagramExportBytes
    ) async -> [String: MarkdownMermaidAsset] {
        await MarkdownDiagramAssets.build(
            from: ast,
            includeDark: includeDark,
            byteBudget: byteBudget
        )
    }
}
