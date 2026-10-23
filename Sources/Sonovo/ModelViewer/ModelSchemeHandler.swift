import Foundation
import WebKit

enum ModelResourceError: Error {
    case tooLarge
    /// The aggregate in-flight read budget cannot accommodate another chunk.
    case budgetExceeded
}

/// Tracks the bytes buffered by in-flight reads.
///
/// A budget charged from a file's observed size can be beaten: the file may
/// grow between the metadata read and the read itself, so several
/// individually compliant reads can allocate the cap each. Charging the
/// bytes as they arrive bounds what is actually held.
final class ModelReadBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var used = 0

    init(limit: Int) {
        self.limit = limit
    }

    func charge(_ bytes: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard bytes > 0, bytes <= limit - used else {
            throw ModelResourceError.budgetExceeded
        }
        used += bytes
    }

    func release(_ bytes: Int) {
        lock.lock()
        used = max(0, used - bytes)
        lock.unlock()
    }
}

enum ModelResourceLimits {
    /// Viewer documents are small; model assets can be large but not
    /// unbounded. The cap is a memory bound, not a product size limit.
    static let maxViewerBytes = 16 * 1024 * 1024
    static let maxAssetBytes = 256 * 1024 * 1024
}

/// Serves the viewer bundle and the selected model over one custom-scheme
/// origin. The resolver decides what exists; this class only turns its answer
/// into an HTTP response and honors WebKit's stop contract.
@MainActor
final class ModelSchemeHandler: NSObject, WKURLSchemeHandler {
    private let resolver: ModelResourceResolver
    private let onResourceServed: ((URL) -> Void)?
    private var activeTasks: Set<ObjectIdentifier> = []
    /// The in-flight read for each task, so `stop` can cancel it instead of
    /// letting a detached read keep allocating for a request WebKit dropped.
    private var readTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Bytes actually buffered by in-flight reads. Each read is capped on
    /// its own; this bounds their sum.
    private let readBudget = ModelReadBudget(
        limit: 2 * ModelResourceLimits.maxAssetBytes
    )

    init(
        resolver: ModelResourceResolver,
        onResourceServed: ((URL) -> Void)? = nil
    ) {
        self.resolver = resolver
        self.onResourceServed = onResourceServed
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
            finish(identifier)
            return
        }

        switch resolver.resolve(requestURL) {
        case .badRequest:
            respond(task, identifier: identifier, status: 400, body: Data())
        case .forbidden, .notFound:
            // Do not distinguish "outside the root" from "absent": both look
            // identical to the page.
            respond(task, identifier: identifier, status: 404, body: Data())
        case .missingAsset(let url):
            // The model declared this sidecar even though it is absent.
            // Recording the absent revision makes a later creation reload
            // the model.
            onResourceServed?(url)
            respond(task, identifier: identifier, status: 404, body: Data())
        case .unsupportedType:
            respond(task, identifier: identifier, status: 415, body: Data())
        case .file(let resource):
            if resource.route == .asset {
                onResourceServed?(resource.url)
            }
            read(resource, for: task, identifier: identifier)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(task)
        readTasks.removeValue(forKey: identifier)?.cancel()
        finish(identifier)
    }

    private func read(
        _ resource: ModelResourceResolver.Resource,
        for task: WKURLSchemeTask,
        identifier: ObjectIdentifier
    ) {
        let url = resource.url
        let readTask = Task { @MainActor [weak self] in
            let cap = resource.route == .asset
                ? ModelResourceLimits.maxAssetBytes
                : ModelResourceLimits.maxViewerBytes
            let data: Data
            do {
                // Cancelling this task must reach the detached reader;
                // otherwise a stopped request keeps the read alive.
                let budget = self?.readBudget
                let worker = Task.detached(priority: .userInitiated) {
                    try await Self.readBounded(
                        url,
                        cap: cap,
                        budget: budget
                    )
                }
                data = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
            } catch is CancellationError {
                // WebKit stopped this request; `stop` already released it.
                return
            } catch ModelResourceError.tooLarge {
                guard let self, self.isActive(identifier) else { return }
                self.respond(
                    task,
                    identifier: identifier,
                    status: 413,
                    body: Data()
                )
                return
            } catch ModelResourceError.budgetExceeded {
                // Concurrent reads already hold the aggregate budget; this
                // one stops rather than allocating into it.
                guard let self, self.isActive(identifier) else { return }
                self.respond(
                    task,
                    identifier: identifier,
                    status: 503,
                    headers: ["Retry-After": "1"],
                    body: Data()
                )
                return
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
        readTasks[identifier] = readTask
    }

    /// Owned, bounded read. A mapped file can fault with SIGBUS if it is
    /// truncated while WebKit is consuming it; copying into owned bytes also
    /// makes the response independent of later disk changes.
    nonisolated static func readBounded(
        _ url: URL,
        cap: Int,
        budget: ModelReadBudget? = nil
    ) async throws -> Data {
        if let size = try? url.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize, size > cap {
            throw ModelResourceError.tooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = cap + 1
        var data = Data()
        // Charge what is buffered as it arrives; the observed size above
        // cannot be trusted, because the file may grow after it is read.
        var charged = 0
        defer {
            if charged > 0 { budget?.release(charged) }
        }
        while data.count < limit {
            // A stopped request must stop reading, not finish the budget.
            try Task.checkCancellation()
            let chunk = try handle.read(
                upToCount: min(1 << 20, limit - data.count)
            )
            guard let chunk, !chunk.isEmpty else { break }
            if let budget {
                try budget.charge(chunk.count)
                charged += chunk.count
            }
            data.append(chunk)
        }
        guard data.count <= cap else {
            throw ModelResourceError.tooLarge
        }
        return data
    }

    /// Releases everything a task holds. Safe to call more than once.
    private func finish(_ identifier: ObjectIdentifier) {
        activeTasks.remove(identifier)
        readTasks.removeValue(forKey: identifier)
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
            finish(identifier)
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
            finish(identifier)
            return
        }

        task.didReceive(response)
        if !body.isEmpty {
            task.didReceive(body)
        }
        task.didFinish()
        finish(identifier)
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
