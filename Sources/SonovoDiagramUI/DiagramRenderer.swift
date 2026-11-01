import SonovoDocumentSupport
import SonovoWorkflowEngine
import SonovoDomainTypes
import AppKit
import SonovoDomainTypes
import SonovoFileIO
import SonovoDiagramEngine
import SwiftUI
import WebKit

/// Why a diagram did not render. The reader falls back to the fenced source
/// for every case; the distinction keeps diagnostics honest.
package enum MarkdownDiagramError: Error, Equatable {
    case rejectedSource
    case unavailable
    case loadFailed(String)
    case timeout
    case renderFailed(String)
    case invalidOutput
}

/// The RB-23 name; both names describe the same errors.
package typealias MarkdownMermaidError = MarkdownDiagramError

/// A bounded first-in-first-out cache shared by the web renderer and the
/// in-process SVG fence renderer. Both previously carried their own copy of
/// the same insertion, capacity, and batch-eviction rules.
package struct DiagramCache<Value> {
    private var entries: [String: Value] = [:]
    private var insertionOrder: [String] = []
    private let limit: Int

    package init(limit: Int = DiagramLimits.maxMermaidRenderCacheEntries) {
        self.limit = max(1, limit)
    }

    package subscript(key: String) -> Value? {
        entries[key]
    }

    package var count: Int { entries.count }

    package mutating func insert(_ value: Value, for key: String) {
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

    package mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        insertionOrder.removeAll(keepingCapacity: false)
    }
}

/// One diagram rendered for both palettes, ready for the HTML exporter.
///
/// `svg` documents carry one palette; the light bytes are reused for dark
/// because the author owns their colors.
package struct MarkdownDiagramAsset: Sendable, Equatable {
    package init(engine: DiagramEngine, lightSVG: String, darkSVG: String, width: Double?, height: Double?) {
        self.engine = engine
        self.lightSVG = lightSVG
        self.darkSVG = darkSVG
        self.width = width
        self.height = height
    }

    package let engine: DiagramEngine
    package let lightSVG: String
    package let darkSVG: String
    package let width: Double?
    package let height: Double?
}

/// The RB-23 name.
package typealias MarkdownMermaidAsset = MarkdownDiagramAsset

// MARK: - Engine specification

/// Everything that differs between the isolated diagram engines.
package struct DiagramEngineSpec: Sendable {
    package let engine: DiagramEngine
    /// Resource base names, in load order.
    package let scriptResources: [String]
    package let contentSecurityPolicy: String
    /// A syntactically valid base URL when the bundled script resolves one.
    /// It never names a reachable host; CSP denies every network request.
    package let baseURL: URL?
    /// The inline script that defines `window.__sonovoRender`.
    package let rendererScript: String
    package let configurationJSON: @Sendable (DiagramThemeVariant) -> String

    package static let mermaid = DiagramEngineSpec(
        engine: .mermaid,
        scriptResources: ["mermaid-12.2.0.min"],
        contentSecurityPolicy: MermaidRendererPolicy.contentSecurityPolicy,
        baseURL: nil,
        rendererScript: mermaidRendererScript,
        configurationJSON: MermaidRendererPolicy.configurationJSON
    )

    package static let graphviz = DiagramEngineSpec(
        engine: .graphviz,
        scriptResources: ["viz-global-3.31.0.min"],
        contentSecurityPolicy: GraphvizRendererPolicy.contentSecurityPolicy,
        baseURL: URL(string: "https://sonovo.invalid/"),
        rendererScript: graphvizRendererScript,
        configurationJSON: GraphvizRendererPolicy.configurationJSON
    )

    package static let markmap = DiagramEngineSpec(
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
package final class WebDiagramRenderer: NSObject, WKNavigationDelegate {
    package static let mermaidScriptName = "mermaid-12.2.0.min"
    package static let graphvizScriptName = "viz-global-3.31.0.min"
    package static let markmapScriptName = "markmap-0.18.12.min"

    package let spec: DiagramEngineSpec

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

    package init(spec: DiagramEngineSpec) {
        self.spec = spec
        super.init()
    }

    /// Renders one diagram, applying the source policy and the SVG sanitizer.
    package func render(
        source: String,
        variant: DiagramThemeVariant,
        timeout: Duration = .seconds(
            DiagramLimits.mermaidRenderTimeoutSeconds
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

    package func clearCache() {
        cache.removeAll()
    }

    package var cacheCount: Int { cache.count }

    package static func accepts(_ source: String, engine: DiagramEngine) -> Bool {
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

    package func webView(
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

    package func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, !isLoaded else { return }
        isLoaded = true
        loadBox?.resume(returning: ())
        loadBox = nil
    }

    package func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        fail(webView, message: error.localizedDescription)
    }

    package func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        fail(webView, message: error.localizedDescription)
    }

    package func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
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

    package static func buildHarness(spec: DiagramEngineSpec) -> String? {
        var scripts = ""
        for name in spec.scriptResources {
            guard let bundle = ResourceBundleLocator.find(
                named: "Sonovo_SonovoDiagramUI", relativeTo: Bundle(for: DiagramResourceAnchor.self)
            ), let url = bundle.url(
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
    package func loadForTesting() async throws {
        try await ensureLoaded(
            timeout: .seconds(DiagramLimits.mermaidRenderTimeoutSeconds)
        )
    }

    /// The live web view, for navigation-policy tests.
    package var webViewForTesting: WKWebView? { webView }

    /// Asks the page to attempt each network path. Returns what the page
    /// observed; a working policy reports `blocked` for every network entry.
    package func probeNetworkForTesting() async throws -> [String: String] {
        try await ensureLoaded(
            timeout: .seconds(DiagramLimits.mermaidRenderTimeoutSeconds)
        )
        guard let webView else { throw MarkdownDiagramError.unavailable }
        let output = try await callAsync(
            webView: webView,
            script: "return await window.__sonovoNetworkProbe();",
            arguments: [:],
            timeout: .seconds(DiagramLimits.mermaidRenderTimeoutSeconds)
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

// MARK: - Renderers

/// The RB-23 Mermaid renderer facade.
@MainActor
package enum MermaidRenderer {
    package static let scriptName = WebDiagramRenderer.mermaidScriptName
    package static let shared = WebDiagramRenderer(spec: .mermaid)

    package static func harnessForTesting() -> String? {
        WebDiagramRenderer.buildHarness(spec: .mermaid)
    }
}

/// The RB-24 Graphviz renderer facade.
@MainActor
package enum GraphvizRenderer {
    package static let scriptName = WebDiagramRenderer.graphvizScriptName
    package static let shared = WebDiagramRenderer(spec: .graphviz)

    package static func harnessForTesting() -> String? {
        WebDiagramRenderer.buildHarness(spec: .graphviz)
    }
}

/// The RB-24 Markmap renderer facade.
@MainActor
package enum MarkmapRenderer {
    package static let scriptName = WebDiagramRenderer.markmapScriptName
    package static let shared = WebDiagramRenderer(spec: .markmap)

    package static func harnessForTesting() -> String? {
        WebDiagramRenderer.buildHarness(spec: .markmap)
    }
}

/// Dispatches a diagram to its engine. Raw SVG needs no web view.
@MainActor
package enum DiagramRenderer {
    private static var svgCache = DiagramCache<
        Result<SanitizedSVG, MarkdownDiagramError>
    >()

    package static func render(
        _ diagram: DiagramSource,
        variant: DiagramThemeVariant,
        timeout: Duration = .seconds(
            DiagramLimits.mermaidRenderTimeoutSeconds
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

    package static func clearCaches() {
        MermaidRenderer.shared.clearCache()
        GraphvizRenderer.shared.clearCache()
        MarkmapRenderer.shared.clearCache()
        svgCache.removeAll()
    }

    package static func renderSVGFence(
        _ source: String,
        variant: DiagramThemeVariant,
        timeout: Duration = .seconds(
            DiagramLimits.mermaidRenderTimeoutSeconds
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
                       .seconds(DiagramLimits.svgSanitizeTimeoutSeconds)
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


private final class DiagramResourceAnchor: NSObject {}
