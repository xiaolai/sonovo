import AppKit
import SwiftUI
import WebKit

@MainActor
struct LocalDocumentView: View {
    let asset: ProjectAsset

    @State private var failure: String?

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header
            Divider()
            if let failure {
                failureState(failure)
            } else {
                LocalDocumentWebView(
                    documentURL: asset.url,
                    onFailure: { failure = $0 }
                )
            }
        }
        .viewerCard()
    }

    private var header: some View {
        AssetViewerHeader(
            asset: asset,
            subtitle: "\(asset.fileExtension.uppercased()) · Local · No network"
        ) {
            Button("Open in Default App") {
                NSWorkspace.shared.open(asset.url)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "doc.badge.exclamationmark")
                .font(
                    .system(
                        size: AppTheme.TypeScale.displayLarge,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(AppTheme.Palette.needsReview)
            Text("Could not display this document")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
            Text(message)
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LocalDocumentWebView: NSViewRepresentable {
    let documentURL: URL
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onFailure)
    }

    func makeNSView(context: Context) -> NSView {
        let root = documentURL.deletingLastPathComponent()
        guard let pageURL = LocalDocumentResolver.documentURL(
            fileName: documentURL.lastPathComponent
        ) else {
            onFailure("The document path could not be encoded.")
            return NSView()
        }

        let resolver = LocalDocumentResolver(root: root)
        let handler = LocalDocumentSchemeHandler(resolver: resolver)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.setURLSchemeHandler(
            handler,
            forURLScheme: LocalDocumentResolver.scheme
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.isInspectable = isDebugBuild
        context.coordinator.attach(webView)
        context.coordinator.load(pageURL: pageURL)
        return webView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The parent gives this view a new identity for each revision.
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
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let onFailure: (String) -> Void
        private weak var webView: WKWebView?

        init(onFailure: @escaping (String) -> Void) {
            self.onFailure = onFailure
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func load(pageURL: URL) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let rules = await ModelContentRules.ruleList() else {
                    self.onFailure(
                        "The document viewer could not install its network block."
                    )
                    return
                }
                guard let webView = self.webView else { return }
                webView.configuration.userContentController.add(rules)
                webView.load(URLRequest(url: pageURL))
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  LocalDocumentResolver.isDocumentNavigation(url) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (
                WKNavigationResponsePolicy
            ) -> Void
        ) {
            guard navigationResponse.isForMainFrame else {
                decisionHandler(.allow)
                return
            }
            if let response = navigationResponse.response
                as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                onFailure(Self.message(for: response.statusCode))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private static func message(for status: Int) -> String {
            switch status {
            case 400:
                return "The document request was malformed."
            case 404:
                return "The document could not be found or is outside "
                    + "the project."
            case 415:
                return "This document type cannot be previewed."
            default:
                return "The document could not be loaded (HTTP \(status))."
            }
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
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onFailure("The document could not load: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            onFailure("The document stopped loading: \(error.localizedDescription)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onFailure("The document renderer stopped unexpectedly.")
        }

        func teardown() {
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView = nil
        }
    }
}
