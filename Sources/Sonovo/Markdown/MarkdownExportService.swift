import AppKit
import Foundation
import PDFKit
import SonovoCore
import UniformTypeIdentifiers
import WebKit

/// The two files the Markdown surface can write.
enum MarkdownExportFormat: String, CaseIterable, Sendable {
    case html
    case pdf

    var displayName: String {
        switch self {
        case .html: "HTML"
        case .pdf: "PDF"
        }
    }

    var fileExtension: String {
        switch self {
        case .html: "html"
        case .pdf: "pdf"
        }
    }

    var contentType: UTType {
        switch self {
        case .html: .html
        case .pdf: .pdf
        }
    }
}

enum MarkdownExportError: LocalizedError, Equatable {
    case unrenderable
    case pdfRenderingUnavailable

    var errorDescription: String? {
        switch self {
        case .unrenderable:
            "This document is too large or too deeply nested to render, so it cannot be exported."
        case .pdfRenderingUnavailable:
            "The PDF renderer could not be created."
        }
    }
}

/// Builds and writes the exported files.
///
/// The HTML projection is the one the reader sees: the same tree, theme,
/// security policy, and syntax lexer. The PDF uses the same HTML and CSS with
/// a print layout; WebKit captures the whole document at the printable width
/// and the exporter slices that capture into A4 pages at block boundaries.
@MainActor
enum MarkdownExportService {
    static func title(for document: MarkdownDocument) -> String {
        guard let url = document.fileURL else { return "Untitled" }
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "Untitled" : name
    }

    static func html(
        for document: MarkdownDocument,
        workspaceRoot: URL?,
        theme: MarkdownTheme,
        forPrint: Bool = false,
        deadline: Date? = nil
    ) async throws -> String {
        let source = document.source
        // Capture the identity with the source: a Save As while this export
        // is parsing must not pair the old bytes with a new title, and the
        // relative assets resolve against the directory the text came from.
        let documentURL = document.fileURL
        let exportTitle = title(for: document)
        // Parse through the service, not `MarkdownParser` directly: the same
        // large-stack path and the same custom-syntax augmentation the reader
        // sees must produce the exported tree.
        let service = MarkdownParseService()
        guard let output = await service.parse(
            MarkdownParseInput(
                documentID: UUID(),
                revision: 0,
                source: source
            )
        ) else {
            throw MarkdownExportError.unrenderable
        }
        guard !output.parsed.exceededNestingLimit else {
            throw MarkdownExportError.unrenderable
        }
        // Formulas rasterize on the main actor because AppKit typesetting is
        // main-actor bound; the HTML string itself is built off the main
        // actor.
        let math = MarkdownMathAssets.build(from: output.ast, theme: theme)
        // Diagrams render out of process. The printed document carries the
        // light variant only; a themed document carries both.
        let diagrams = await MarkdownDiagramAssets.build(
            from: output.ast,
            includeDark: !forPrint,
            deadline: deadline
        )
        let context = MarkdownExportContext(
            title: exportTitle,
            documentURL: documentURL,
            workspaceRoot: workspaceRoot,
            theme: theme,
            math: math,
            diagrams: diagrams
        )
        return await Task.detached(priority: .userInitiated) {
            MarkdownHTMLExporter.document(
                output.ast,
                context: context,
                forPrint: forPrint
            )
        }.value
    }

    static func pdfData(
        forHTML html: String,
        deadline: Date? = nil
    ) async throws -> Data {
        let renderer = MarkdownPDFRenderer()
        return try await renderer.render(html: html, deadline: deadline)
    }

    static func write(
        document: MarkdownDocument,
        format: MarkdownExportFormat,
        to url: URL,
        workspaceRoot: URL?,
        theme: MarkdownTheme
    ) async throws {
        let data: Data
        switch format {
        case .html:
            let html = try await html(
                for: document,
                workspaceRoot: workspaceRoot,
                theme: theme
            )
            try Task.checkCancellation()
            data = Data(html.utf8)
        case .pdf:
            // Arm the export budget before the diagram phase. Diagrams used
            // to run first with their own per-diagram timeouts, and only
            // then did the PDF renderer start its 60 s clock.
            let deadline = Date().addingTimeInterval(
                MarkdownLimits.pdfRenderTimeoutSeconds
            )
            let html = try await html(
                for: document,
                workspaceRoot: workspaceRoot,
                theme: theme,
                forPrint: true,
                deadline: deadline
            )
            try Task.checkCancellation()
            data = try await pdfData(
                forHTML: html,
                deadline: deadline
            )
        }
        // A cancelled export must not leave a partial file behind.
        try Task.checkCancellation()
        let write = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try data.write(to: url, options: .atomic)
        }
        try await withTaskCancellationHandler {
            try await write.value
        } onCancel: {
            // `Task.value` does not propagate the caller's cancellation, so
            // the detached task must be cancelled explicitly; its own check
            // then fires before it commits the file.
            write.cancel()
        }
        try Task.checkCancellation()
    }
}

// MARK: - PDF renderer

/// Captures the print HTML as one tall PDF page, then slices it into A4
/// pages at block boundaries.
///
/// `WKWebView.printOperation` is not used: on macOS 27 it can spend minutes
/// rendering a single short document and never returns. `createPDF` is the
/// capture path WebKit supports for programmatic use. Slicing preserves the
/// vector content and the same CSS layout the HTML export uses.
@MainActor
private final class MarkdownPDFRenderer: NSObject, WKNavigationDelegate {
    private struct Metrics {
        let height: CGFloat
        let blockBottoms: [CGFloat]
        let headingBottoms: Set<CGFloat>
    }

    /// A sanity bound on the tall capture. A document that needs more than
    /// this is not a reading export.
    private static let maximumContentHeight: CGFloat = 100_000

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Data, Error>?
    private var hasFinished = false
    /// Inner `createPDF` and `callAsyncJavaScript` completions that have not
    /// fired yet. `finish` drains them so a timed-out or cancelled render
    /// cannot leave those continuations suspended with the renderer alive.
    private typealias PendingCompletion = @MainActor (Error) -> Void
    private var pendingCompletions: [UUID: PendingCompletion] = [:]
    /// Ends a capture that never finishes on its own: a stalled load, a
    /// dead web-content process, or a cancelled export must not leave the
    /// checked continuation suspended forever.
    private var timeoutTask: Task<Void, Never>?

    /// A Sendable carrier for a WebKit or PDFKit error crossing back from a
    /// completion handler.
    private struct RenderFailure: Error, LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    func render(html: String, deadline: Date? = nil) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // The wait and measurement scripts run in the page world. The
        // document itself has `script-src 'none'`, so content cannot execute.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: AppTheme.MarkdownChrome.Export.printableWidth,
                height: AppTheme.MarkdownChrome.Export.printableHeight
            ),
            configuration: configuration
        )
        webView.navigationDelegate = self
        // The capture is a web-process snapshot; a window would clamp the
        // view to the screen and cut off the document.
        self.webView = webView

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    // The cancellation handler may have finished the render
                    // before this body ran; resuming here keeps the
                    // continuation from being left suspended.
                    guard !hasFinished else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    let remaining = deadline.map {
                        max(0, $0.timeIntervalSinceNow)
                    } ?? MarkdownLimits.pdfRenderTimeoutSeconds
                    self.timeoutTask = Task { @MainActor [weak self] in
                        do {
                            try await Task.sleep(
                                for: .seconds(max(AppTheme.Time.minimumTimeout, remaining))
                            )
                        } catch {
                            return
                        }
                        self?.finish(
                            .failure(
                                RenderFailure(
                                    message: "PDF rendering timed out."
                                )
                            )
                        )
                    }
                    webView.loadHTMLString(html, baseURL: nil)
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.finish(.failure(CancellationError()))
                }
            }
        } catch {
            finish(.failure(error))
            throw error
        }
    }

    // MARK: Navigation

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation?
    ) {
        Task { @MainActor in
            do {
                try await waitForContent()
                let metrics = try await measure()
                try await prepareLayout(metrics)
                let starts = pageStarts(metrics)
                let data = try await capturePages(
                    starts: starts,
                    contentHeight: metrics.height
                )
                finish(.success(data))
            } catch {
                finish(.failure(error))
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(
            .failure(
                RenderFailure(message: "The PDF web content process ended.")
            )
        )
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    // MARK: Capture

    private func waitForContent() async throws {
        _ = try await evaluate(
            """
            await Promise.all(Array.from(document.images).map((image) => {
              if (image.complete) { return Promise.resolve(); }
              return new Promise((resolve) => {
                image.addEventListener('load', resolve, { once: true });
                image.addEventListener('error', resolve, { once: true });
              });
            }));
            await document.fonts.ready;
            return "ok";
            """
        )
    }

    private func measure() async throws -> Metrics {
        let script = """
        const root = document.documentElement;
        const selector = 'p, h1, h2, h3, h4, h5, h6, pre, li, tr, figure, .toc, .alert, .image-placeholder, .math-display, .mermaid-block, .diagram-block, .svg-fence, .footnotes > ol > li, summary';
        const blocks = Array.from(document.querySelectorAll(selector)).map((element) => {
          const rect = element.getBoundingClientRect();
          return {
            top: rect.top + window.scrollY,
            bottom: rect.bottom + window.scrollY,
            heading: /^H[1-6]$/.test(element.tagName)
          };
        });
        return JSON.stringify({
          height: Math.max(root.scrollHeight, document.body.scrollHeight),
          blocks: blocks
        });
        """
        guard let json = try await evaluate(script) else {
            throw RenderFailure(message: "PDF metrics script returned no value")
        }
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data)
                  as? [String: Any],
              let height = (object["height"] as? NSNumber)?.doubleValue,
              let blocks = object["blocks"] as? [[String: Any]] else {
            throw RenderFailure(
                message: "PDF metrics invalid: \(json.prefix(200))"
            )
        }

        var bottoms: Set<CGFloat> = []
        var headings: Set<CGFloat> = []
        for block in blocks {
            guard let top = (block["top"] as? NSNumber)?.doubleValue,
                  let bottom = (block["bottom"] as? NSNumber)?.doubleValue,
                  bottom > top
                    + Double(AppTheme.MarkdownChrome.Export.geometryEpsilon)
            else {
                continue
            }
            let value = CGFloat(bottom)
            bottoms.insert(value)
            if block["heading"] as? Bool == true {
                headings.insert(value)
            }
        }
        return Metrics(
            height: max(CGFloat(height), 1),
            blockBottoms: bottoms.sorted(),
            headingBottoms: headings
        )
    }

    private func prepareLayout(_ metrics: Metrics) async throws {
        guard let webView else {
            throw MarkdownExportError.pdfRenderingUnavailable
        }
        guard metrics.height <= Self.maximumContentHeight else {
            throw MarkdownExportError.unrenderable
        }
        let size = NSSize(
            width: AppTheme.MarkdownChrome.Export.printableWidth,
            height: metrics.height
        )
        webView.frame = NSRect(origin: .zero, size: size)
        webView.layoutSubtreeIfNeeded()
        // Let WebKit finish the reflow at the capture height before asking
        // for the PDF.
        try await Task.sleep(for: .milliseconds(100))
    }

    // MARK: Pagination

    /// Page starts in document coordinates, chosen so pages end between
    /// blocks whenever a whole block fits.
    private func pageStarts(_ metrics: Metrics) -> [CGFloat] {
        let contentHeight = metrics.height
        let pageHeight = AppTheme.MarkdownChrome.Export.printableHeight
        let epsilon = AppTheme.MarkdownChrome.Export.geometryEpsilon
        let candidates = metrics.blockBottoms
            .filter { $0 > epsilon && $0 < contentHeight - epsilon }
            .sorted()
        let headingBottoms = metrics.headingBottoms

        var starts: [CGFloat] = []
        var cursor: CGFloat = 0
        while cursor < contentHeight - epsilon {
            let limit = min(cursor + pageHeight, contentHeight)
            if limit >= contentHeight - epsilon {
                starts.append(cursor)
                break
            }
            var cut = candidates.last(where: {
                $0 <= limit && $0 > cursor + epsilon
            }) ?? limit
            if cut <= cursor + epsilon {
                cut = limit
            }
            // Do not leave a heading alone at the bottom of a page.
            if headingBottoms.contains(where: { abs($0 - cut) < epsilon }),
               let previous = candidates.last(where: {
                   $0 < cut - epsilon && $0 > cursor + epsilon
               }) {
                cut = previous
            }
            if cut <= cursor + epsilon {
                cut = limit
            }
            starts.append(cursor)
            cursor = cut
        }
        return starts.isEmpty ? [0] : starts
    }

    /// Captures one PDF page per start and composes the pages on A4.
    ///
    /// A single capture of the whole document is clipped by WebKit at about
    /// 14,400 points, which silently drops the tail; one capture per page
    /// stays below that ceiling and gives each page its own block-aware
    /// boundaries.
    private func capturePages(
        starts: [CGFloat],
        contentHeight: CGFloat
    ) async throws -> Data {
        guard starts.count <= 2_000 else {
            throw MarkdownExportError.unrenderable
        }
        let pageHeight = AppTheme.MarkdownChrome.Export.printableHeight
        let paperWidth = AppTheme.MarkdownChrome.Export.paperWidth
        let paperHeight = AppTheme.MarkdownChrome.Export.paperHeight
        let margin = AppTheme.MarkdownChrome.Export.printMargin

        let output = PDFDocument()
        var sources: [PDFDocument] = []
        sources.reserveCapacity(starts.count)

        for (index, start) in starts.enumerated() {
            // The next page's start is this page's end. Using the full page
            // height would let a safe break overlap the next capture.
            let end = index + 1 < starts.count
                ? starts[index + 1]
                : contentHeight
            let height = min(pageHeight, end - start)
            guard height > AppTheme.MarkdownChrome.Export.geometryEpsilon else {
                continue
            }
            let document = try await capturePage(
                index: index,
                start: start,
                height: height
            )
            sources.append(document)
            guard let page = document.page(at: 0) else {
                throw RenderFailure(
                    message: "PDF page \(index) has no page object"
                )
            }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else {
                throw RenderFailure(
                    message: "PDF page \(index) empty: \(bounds.width)x\(bounds.height)"
                )
            }
            let box = CGRect(
                x: -margin,
                y: bounds.height + margin - paperHeight,
                width: paperWidth,
                height: paperHeight
            )
            page.setBounds(box, for: .mediaBox)
            page.setBounds(box, for: .cropBox)
            output.insert(page, at: output.pageCount)
        }

        guard output.pageCount == starts.count,
              let data = output.dataRepresentation() else {
            throw RenderFailure(
                message: "PDF pagination produced \(output.pageCount) of \(starts.count) pages"
            )
        }
        _ = sources
        return data
    }

    private func capturePage(
        index: Int,
        start: CGFloat,
        height: CGFloat
    ) async throws -> PDFDocument {
        guard let webView else {
            throw MarkdownExportError.pdfRenderingUnavailable
        }
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(
            x: 0,
            y: start,
            width: AppTheme.MarkdownChrome.Export.printableWidth,
            height: height
        )
        let data = try await awaitCompletion { completion in
            webView.createPDF(configuration: configuration) { result in
                switch result {
                case .success(let data):
                    completion(.success(data))
                case .failure(let error):
                    completion(
                        .failure(
                            RenderFailure(
                                message: error.localizedDescription
                            )
                        )
                    )
                }
            }
        }
        guard let document = PDFDocument(data: data),
              let page = document.page(at: 0) else {
            throw RenderFailure(
                message: "PDF page \(index) capture unreadable"
            )
        }
        let bounds = page.bounds(for: .mediaBox)
        guard abs(bounds.width - AppTheme.MarkdownChrome.Export.printableWidth) < 2,
              abs(bounds.height - height) < 2 else {
            throw RenderFailure(
                message: "PDF page \(index) wrong size: \(bounds.width)x\(bounds.height)"
                    + " expected \(AppTheme.MarkdownChrome.Export.printableWidth)x\(height)"
            )
        }
        return document
    }

    // MARK: JavaScript

    private func evaluate(_ script: String) async throws -> String? {
        guard let webView else {
            throw MarkdownExportError.pdfRenderingUnavailable
        }
        return try await awaitCompletion { completion in
            webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    completion(.success(value as? String))
                case .failure(let error):
                    completion(
                        .failure(
                            RenderFailure(
                                message: error.localizedDescription
                            )
                        )
                    )
                }
            }
        }
    }

    /// Awaits one WebKit completion-driven operation and resumes its
    /// continuation exactly once, whichever of WebKit's callback, task
    /// cancellation, or `finish` arrives first.
    private func awaitCompletion<T: Sendable>(
        _ start: (@escaping @Sendable (Result<T, RenderFailure>) -> Void) -> Void
    ) async throws -> T {
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Ownership of the token is the one-shot guard: whoever
                // removes it resumes; everyone else observes nil and returns.
                let resumeOnce: @MainActor @Sendable (
                    Result<T, RenderFailure>
                ) -> Void = { result in
                    guard self.pendingCompletions.removeValue(forKey: token)
                        != nil else { return }
                    continuation.resume(with: result.mapError { $0 as Error })
                }
                pendingCompletions[token] = { error in
                    // `finish` and `onCancel` take the entry out first, so
                    // this closure runs at most once.
                    continuation.resume(
                        throwing: RenderFailure(
                            message: error.localizedDescription
                        )
                    )
                }
                start { result in
                    Task { @MainActor in
                        resumeOnce(result)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingCompletions.removeValue(forKey: token)?(
                    CancellationError()
                )
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !hasFinished else { return }
        hasFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        continuation?.resume(with: result)
        continuation = nil
        let pending = pendingCompletions
        pendingCompletions.removeAll()
        for complete in pending.values {
            complete(
                RenderFailure(
                    message: "The PDF render ended before this operation completed."
                )
            )
        }
    }
}
