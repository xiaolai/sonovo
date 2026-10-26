import AppKit
import SwiftUI
import SonovoMDXKit
import WebKit

enum MDXPreviewAssets {
    /// Loaded once; the page inlines it so the preview has no external
    /// script request to allow.
    static let runtimeScript: String? = {
        guard let url = Bundle.module.url(
            forResource: "mdx-runtime-19.3.1",
            withExtension: "js"
        ) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }()
}

enum MDXPreviewError: Error, LocalizedError {
    case unavailable
    case loadFailed(String)
    case timedOut
    /// A newer load replaced this one before its navigation finished.
    case superseded

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The MDX preview runtime is missing from this build."
        case .loadFailed(let detail):
            "The MDX preview could not load: \(detail)"
        case .timedOut:
            "The MDX preview took too long to load."
        case .superseded:
            "The MDX preview was replaced by a newer load."
        }
    }
}

/// The security boundary for compiled MDX.
///
/// The web view has a non-persistent data store, no message handlers, no
/// navigation away from the page it was given, and a content security policy
/// that allows only inline script/style, `data:` images and fonts. The
/// compiled modules run as inline scripts the page carries; the loader uses
/// no evaluator. Nothing in the page can reach AppKit or the network.
@MainActor
final class MDXPreviewController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private var currentHTML: String?
    private var isProgrammaticLoad = false
    private var loadBox: OnceContinuation<Void>?
    /// Every load gets a serial; navigation callbacks only complete the box
    /// of the load they belong to, so a superseded navigation cannot finish
    /// or fail its replacement.
    private var loadSerial = 0
    private var activeSerial = 0
    private var loadBoxSerial = 0
    /// The navigation object the current load started. Callbacks carry their
    /// own navigation, and serials alone cannot tell an obsolete callback
    /// from the current one.
    private var activeNavigation: WKNavigation?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.suppressesIncrementalRendering = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = false
        webView.allowsBackForwardNavigationGestures = false
    }

    func makeWebView() -> WKWebView {
        webView
    }

    func load(html: String) {
        guard currentHTML != html else { return }
        loadSerial += 1
        forceLoad(html: html, serial: loadSerial)
    }

    private func forceLoad(html: String, serial: Int) {
        activeSerial = serial
        currentHTML = html
        isProgrammaticLoad = true
        activeNavigation = webView.loadHTMLString(html, baseURL: nil)
    }

    func loadAndWait(
        html: String,
        timeout: Duration = .seconds(10)
    ) async throws {
        let box = OnceContinuation<Void>()
        // A superseded load must not leave its caller suspended: its own
        // watchdog exits on the serial mismatch, so resume it here.
        loadBox?.resume(throwing: MDXPreviewError.superseded)
        loadBox = box
        loadSerial += 1
        let serial = loadSerial
        loadBoxSerial = serial
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            // A newer load has replaced this box; its own watchdog owns it.
            guard let self, self.loadBoxSerial == serial else { return }
            if box.resume(throwing: MDXPreviewError.timedOut) {
                self.loadBox = nil
            }
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            box.install(continuation)
            forceLoad(html: html, serial: serial)
        }
    }

    func tearDown() {
        loadBox?.resume(throwing: MDXPreviewError.unavailable)
        loadBox = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    // MARK: - Navigation

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard webView === self.webView else {
            return (.cancel, preferences)
        }
        let url = navigationAction.request.url
        let isInitial = isProgrammaticLoad
            && navigationAction.navigationType == .other
            && (url == nil || url?.absoluteString == "about:blank")
            && (navigationAction.targetFrame?.isMainFrame ?? true)
        return (isInitial ? .allow : .cancel, preferences)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, isCurrent(navigation) else { return }
        isProgrammaticLoad = false
        activeNavigation = nil
        guard activeSerial == loadBoxSerial else { return }
        loadBox?.resume(returning: ())
        loadBox = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        fail(error, navigation: navigation)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        fail(error, navigation: navigation)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        fail(
            MDXPreviewError.loadFailed("web content process terminated"),
            navigation: activeNavigation
        )
    }

    /// A callback belongs to the current load only when it names the
    /// navigation that load started.
    private func isCurrent(_ navigation: WKNavigation?) -> Bool {
        navigation === activeNavigation
    }

    private func fail(_ error: Error, navigation: WKNavigation?) {
        guard isCurrent(navigation) else { return }
        isProgrammaticLoad = false
        activeNavigation = nil
        // A failed or terminated load left no content: the next update with
        // byte-identical HTML must load again instead of being skipped.
        currentHTML = nil
        guard activeSerial == loadBoxSerial else { return }
        loadBox?.resume(
            throwing: MDXPreviewError.loadFailed(error.localizedDescription)
        )
        loadBox = nil
    }

    // MARK: - Dialogs

    // A document can call `alert`; showing a native panel would let
    // untrusted content drive app UI. Every dialog is suppressed.

    nonisolated func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        MainActor.assumeIsolated { completionHandler() }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        MainActor.assumeIsolated { completionHandler(false) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        MainActor.assumeIsolated { completionHandler(nil) }
    }

    // MARK: - Test hooks

    var webViewForTesting: WKWebView { webView }

    func loadForTesting(html: String) async throws {
        try await loadAndWait(html: html)
    }

    /// Asks the page to attempt each network path. A working policy reports
    /// `blocked` for every network entry.
    func probeNetworkForTesting() async throws -> [String: String] {
        let text = try await callAsync(
            script: MDXPreviewController.networkProbeScript
        )
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                  as? [String: String] else {
            throw MDXPreviewError.loadFailed("unreadable probe result")
        }
        return object
    }

    func rootTextForTesting() async throws -> String {
        try await callAsync(
            script: "return document.getElementById('root').innerText;"
        )
    }

    private func callAsync(
        timeout: Duration = .seconds(10),
        script: String
    ) async throws -> String {
        let box = OnceContinuation<String>()
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            box.resume(throwing: MDXPreviewError.timedOut)
        }
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            box.install(continuation)
            webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    box.resume(returning: value as? String ?? "")
                case .failure(let error):
                    box.resume(
                        throwing: MDXPreviewError.loadFailed(
                            error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    static let networkProbeScript = """
    return await (async function () {
      const result = {};
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
    })();
    """
}

struct MDXPreviewView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> MDXPreviewController {
        MDXPreviewController()
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.load(html: html)
        return context.coordinator.makeWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.load(html: html)
    }

    static func dismantleNSView(
        _ nsView: WKWebView,
        coordinator: MDXPreviewController
    ) {
        coordinator.tearDown()
    }
}
