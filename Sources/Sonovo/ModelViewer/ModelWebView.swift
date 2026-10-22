import AppKit
import SwiftUI
import WebKit

/// Hosts the three.js page for one loaded model. The parent gives this view a
/// new identity for every load generation, so a reload gets a fresh web view,
/// handler, and message token instead of trying to reason about stale pages.
struct ModelWebView: NSViewRepresentable {
    let document: Model3DDocument
    let theme: ColorScheme
    let grid: Bool
    let wireframe: Bool
    let upAxis: Model3DUpAxis
    let playing: Bool
    let clip: Int
    let scene: Int
    let fitRequest: UInt64
    @Environment(\.projectIsVisible) private var projectIsVisible

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        guard let renderableURL = document.renderableURL,
              let modelURL = ModelResourceResolver.assetURL(
                relativePath: renderableURL.lastPathComponent
              ),
              let viewerURL = ModelResourceResolver.viewerURL(),
              let viewerRoot = ModelViewerResources.root else {
            document.fail("The model viewer resources could not be located.")
            return NSView()
        }

        let resolver = ModelResourceResolver(
            viewerRoot: viewerRoot,
            assetRoot: renderableURL.deletingLastPathComponent(),
            primaryFile: renderableURL
        )
        let handler = ModelSchemeHandler(resolver: resolver) { [weak document] url in
            document?.recordResourceServed(url)
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.setURLSchemeHandler(
            handler,
            forURLScheme: ModelResourceResolver.scheme
        )
        configuration.userContentController.add(
            coordinator,
            name: Coordinator.messageName
        )

        let mtlURLs = document.materialPaths.compactMap {
            ModelResourceResolver.assetURL(relativePath: $0)?.absoluteString
        }
        let renderFormat = document.isConverted
            ? "glb"
            : document.format.rawValue
        guard let themeJSON = ModelViewerBridge.encodedString(
            theme == .dark ? "dark" : "light"
        ) else {
            document.fail("The model viewer configuration is invalid.")
            return NSView()
        }

        let payload = ModelViewerBridge.Configuration(
            token: coordinator.token,
            modelURL: modelURL.absoluteString,
            format: renderFormat,
            mtlURLs: mtlURLs,
            name: document.displayName,
            theme: theme == .dark ? "dark" : "light",
            grid: grid,
            wireframe: wireframe,
            upAxis: upAxis.rawValue,
            playing: playing,
            clip: clip,
            scene: document.sceneNames.isEmpty ? -1 : scene,
            active: projectIsVisible
        )
        guard let configJSON = ModelViewerBridge.configurationJSON(payload) else {
            document.fail("The model viewer configuration could not be encoded.")
            return NSView()
        }

        let source = """
        window.__SONOVO_MODEL__ = \(configJSON);
        document.documentElement.dataset.theme = \(themeJSON);
        """
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsMagnification = false
        webView.underPageBackgroundColor = AppTheme.AppKitColor.mediaCanvas
        webView.isInspectable = isDebugBuild
        coordinator.attach(webView)

        coordinator.load(viewerURL: viewerURL)
        return webView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.apply(
            theme: theme,
            grid: grid,
            wireframe: wireframe,
            upAxis: upAxis,
            playing: playing,
            clip: clip,
            scene: scene,
            fitRequest: fitRequest,
            active: projectIsVisible
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    private var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate,
        WKScriptMessageHandler {
        static let messageName = "sonovoModel"

        let token = UUID().uuidString
        private let document: Model3DDocument
        private weak var webView: WKWebView?
        private var loadTask: Task<Void, Never>?
        private var isReady = false
        /// Set by `teardown`. Every late WebKit callback checks it so a
        /// cancelled navigation cannot fail a document this coordinator no
        /// longer owns.
        private var isTornDown = false
        private var pending: [String: Any] = [:]
        private var lastTheme: String?
        private var lastGrid: Bool?
        private var lastWireframe: Bool?
        private var lastUpAxis: String?
        private var lastPlaying: Bool?
        private var lastClip: Int?
        private var lastScene: Int?
        private var lastFit: UInt64?
        private var lastActive: Bool?

        init(document: Model3DDocument) {
            self.document = document
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func load(viewerURL: URL) {
            loadTask?.cancel()
            loadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let rules = await ModelContentRules.ruleList()
                // Teardown may have run while the rule list compiled. Do
                // not fail a document that this coordinator no longer owns.
                guard !Task.isCancelled, !self.isTornDown,
                      let webView = self.webView else {
                    return
                }
                guard let rules else {
                    self.document.fail(
                        "The model viewer could not install its network block."
                    )
                    return
                }
                webView.configuration.userContentController.add(rules)
                webView.load(URLRequest(url: viewerURL))
            }
        }

        func apply(
            theme: ColorScheme,
            grid: Bool,
            wireframe: Bool,
            upAxis: Model3DUpAxis,
            playing: Bool,
            clip: Int,
            scene: Int,
            fitRequest: UInt64,
            active: Bool
        ) {
            var command: [String: Any] = [:]
            let themeName = theme == .dark ? "dark" : "light"
            if lastTheme != themeName {
                command["theme"] = themeName
                lastTheme = themeName
            }
            if lastGrid != grid {
                command["grid"] = grid
                lastGrid = grid
            }
            if lastWireframe != wireframe {
                command["wireframe"] = wireframe
                lastWireframe = wireframe
            }
            if lastUpAxis != upAxis.rawValue {
                command["upAxis"] = upAxis.rawValue
                lastUpAxis = upAxis.rawValue
            }
            if lastPlaying != playing {
                command["playing"] = playing
                lastPlaying = playing
            }
            if lastClip != clip {
                command["clip"] = clip
                lastClip = clip
            }
            if lastScene != scene {
                command["scene"] = scene
                lastScene = scene
            }
            if lastFit != fitRequest {
                command["fit"] = Int(clamping: fitRequest)
                lastFit = fitRequest
            }
            if lastActive != active {
                command["active"] = active
                lastActive = active
            }
            guard !command.isEmpty else { return }
            if isReady {
                send(command)
            } else {
                pending.merge(command) { _, new in new }
            }
        }

        private func send(_ command: [String: Any]) {
            guard let webView,
                  let json = ModelViewerBridge.commandJSON(command) else {
                return
            }
            webView.evaluateJavaScript(
                "window.sonovoViewer && window.sonovoViewer.apply(\(json));"
            )
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard !isTornDown,
                  message.name == Self.messageName,
                  message.webView === webView,
                  let event = ModelViewerBridge.decode(
                    message.body,
                    expectedToken: token
                  ) else {
                return
            }

            switch event {
            case .ready:
                isReady = true
                if !pending.isEmpty {
                    send(pending)
                    pending.removeAll()
                }
            case .progress(let loaded, let total):
                document.updateProgress(total > 0 ? loaded / total : nil)
            case .loaded(let stats, let animations, let scenes, let scene):
                document.apply(
                    stats: stats,
                    animations: animations,
                    scenes: scenes,
                    scene: scene
                )
            case .scene(let index, let stats, let animations):
                document.applyScene(
                    index: index,
                    stats: stats,
                    animations: animations
                )
            case .animation:
                // Native owns the animation controls; the page mirrors them.
                break
            case .warning(let message):
                document.setWarning(message)
            case .error(let message, _):
                document.fail(message)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            // A programmatic first load can report a nil target frame, so the
            // URL is the authority. New windows are denied separately by the
            // UI delegate; here any non-viewer URL is cancelled.
            guard let url = navigationAction.request.url,
                  ModelNavigationPolicy.allows(url) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable () -> Void
        ) {
            completionHandler()
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
        ) {
            completionHandler(false)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable (String?) -> Void
        ) {
            completionHandler(nil)
        }

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
        ) {
            completionHandler(nil)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            guard !isTornDown else { return }
            document.fail("The model viewer could not load: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            guard !isTornDown else { return }
            document.fail("The model viewer stopped loading: \(error.localizedDescription)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard !isTornDown else { return }
            document.fail("The model renderer stopped unexpectedly. Reload to continue.")
        }

        func teardown() {
            isTornDown = true
            loadTask?.cancel()
            loadTask = nil
            isReady = false
            pending.removeAll()
            // Detach first: stopLoading delivers a cancellation callback to
            // whoever is still installed as the navigation delegate.
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView?.stopLoading()
            webView?.configuration.userContentController
                .removeScriptMessageHandler(forName: Self.messageName)
            webView = nil
        }
    }
}
