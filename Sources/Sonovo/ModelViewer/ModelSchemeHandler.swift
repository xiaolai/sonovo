import Foundation
import WebKit

/// Serves the viewer bundle and the selected model over one custom-scheme
/// origin. The resolver decides what exists; this class only turns its answer
/// into an HTTP response and honors WebKit's stop contract.
@MainActor
final class ModelSchemeHandler: NSObject, WKURLSchemeHandler {
    private let resolver: ModelResourceResolver
    private var activeTasks: Set<ObjectIdentifier> = []

    init(resolver: ModelResourceResolver) {
        self.resolver = resolver
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(task)
        activeTasks.insert(identifier)

        guard (task.request.httpMethod ?? "GET").uppercased() == "GET" else {
            respond(
                task,
                identifier: identifier,
                status: 405,
                headers: ["Allow": "GET"],
                body: Data()
            )
            return
        }
        guard let requestURL = task.request.url else {
            activeTasks.remove(identifier)
            return
        }

        switch resolver.resolve(requestURL) {
        case .badRequest:
            respond(task, identifier: identifier, status: 400, body: Data())
        case .forbidden, .notFound:
            // Do not distinguish "outside the root" from "absent": both look
            // identical to the page.
            respond(task, identifier: identifier, status: 404, body: Data())
        case .unsupportedType:
            respond(task, identifier: identifier, status: 415, body: Data())
        case .file(let resource):
            read(resource, for: task, identifier: identifier)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(task))
    }

    private func read(
        _ resource: ModelResourceResolver.Resource,
        for task: WKURLSchemeTask,
        identifier: ObjectIdentifier
    ) {
        let url = resource.url
        Task { @MainActor [weak self] in
            let data: Data
            do {
                data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
            } catch {
                guard let self, self.isActive(identifier) else { return }
                self.respond(
                    task,
                    identifier: identifier,
                    status: 500,
                    body: Data()
                )
                return
            }

            guard let self, self.isActive(identifier) else { return }

            if resource.route == .viewer,
               resource.url.pathExtension.lowercased() == "html" {
                guard let html = String(data: data, encoding: .utf8),
                      html.contains(Self.noncePlaceholder) else {
                    // A missing placeholder means the CSP would silently
                    // block the import map. Fail loudly instead.
                    self.respond(
                        task,
                        identifier: identifier,
                        status: 500,
                        body: Data()
                    )
                    return
                }
                let nonce = Self.makeNonce()
                let body = Data(
                    html.replacingOccurrences(
                        of: Self.noncePlaceholder,
                        with: nonce
                    ).utf8
                )
                self.respond(
                    task,
                    identifier: identifier,
                    status: 200,
                    headers: [
                        "Content-Type": resource.mimeType,
                        "Content-Security-Policy": Self.contentSecurityPolicy(
                            nonce: nonce
                        )
                    ],
                    body: body
                )
                return
            }

            self.respond(
                task,
                identifier: identifier,
                status: 200,
                headers: ["Content-Type": resource.mimeType],
                body: data
            )
        }
    }

    private func isActive(_ identifier: ObjectIdentifier) -> Bool {
        activeTasks.contains(identifier)
    }

    private func respond(
        _ task: WKURLSchemeTask,
        identifier: ObjectIdentifier,
        status: Int,
        headers: [String: String] = [:],
        body: Data
    ) {
        guard isActive(identifier), let requestURL = task.request.url else {
            activeTasks.remove(identifier)
            return
        }

        var fields = headers
        fields["Content-Length"] = String(body.count)
        fields["Cache-Control"] = "no-store"
        fields["X-Content-Type-Options"] = "nosniff"
        if fields["Content-Type"] == nil {
            fields["Content-Type"] = "text/plain; charset=utf-8"
        }

        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: fields
        ) else {
            activeTasks.remove(identifier)
            return
        }

        task.didReceive(response)
        if !body.isEmpty {
            task.didReceive(body)
        }
        task.didFinish()
        activeTasks.remove(identifier)
    }

    private static let noncePlaceholder = "__CSP_NONCE__"

    private static func makeNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func contentSecurityPolicy(nonce: String) -> String {
        // 'unsafe-eval' is load-bearing: WebKit refuses to initialize the
        // Basis/KTX2 transcoder's WebAssembly inside its worker without it.
        // 'wasm-unsafe-eval' alone is not enough on this engine. Everything
        // else stays closed: no network, no external scripts, no frames.
        [
            "default-src 'none'",
            "script-src 'self' 'nonce-\(nonce)' 'wasm-unsafe-eval' 'unsafe-eval'",
            "style-src 'self'",
            "img-src 'self' data: blob:",
            "connect-src 'self' blob:",
            "worker-src 'self' blob:",
            "font-src 'self'",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
            "frame-ancestors 'none'"
        ].joined(separator: "; ")
    }
}

enum ModelNavigationPolicy {
    /// Only the bundled viewer is a navigation target. Everything else —
    /// links, redirects, and new windows — is cancelled.
    static func allows(_ url: URL) -> Bool {
        url.scheme == ModelResourceResolver.scheme
            && url.host == ModelResourceResolver.host
            && url.path.hasPrefix("/viewer/")
    }
}

/// A process-wide cache for the content rule list that blocks every external
/// scheme before a request can leave the web view.
@MainActor
enum ModelContentRules {
    private static let identifier = "sonovo.model.block-external.v1"
    private static var cached: WKContentRuleList?
    private static var pending: Task<WKContentRuleList?, Never>?

    private static let encodedRules = """
    [
      {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^file://"},"action":{"type":"block"}}
    ]
    """

    static func ruleList() async -> WKContentRuleList? {
        if let cached {
            return cached
        }
        if let pending {
            return await pending.value
        }

        let task = Task<WKContentRuleList?, Never> { @MainActor in
            await withCheckedContinuation { continuation in
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: encodedRules
                ) { list, _ in
                    continuation.resume(returning: list)
                }
            }
        }
        pending = task
        let list = await task.value
        pending = nil
        cached = list
        return list
    }
}
