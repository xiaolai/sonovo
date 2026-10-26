#if SONOVO_E2E_PROBE
import AppKit
import ApplicationServices
import Darwin
import PDFKit
import SwiftUI
import SonovoCore
import SonovoMDXKit

/// The acceptance probe for the R1 surface.
///
/// Compiled only with `-DSONOVO_E2E_PROBE` and run only when
/// `SONOVO_E2E_PROBE=1`. It mounts the real workspace view on the dedicated
/// E2E Mac, drives AppKit insertion and mouse events, and writes PASS/FAIL
/// lines to `SONOVO_E2E_LOG`.
@MainActor
enum E2EProbe {
    private static var logURL: URL {
        URL(
            fileURLWithPath: ProcessInfo.processInfo
                .environment["SONOVO_E2E_LOG"]
                ?? "/tmp/sonovo-e2e.log"
        )
    }

    private static func log(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    static func run() {
        try? Data().write(to: logURL)
        let path = ProcessInfo.processInfo
            .environment["SONOVO_E2E_FIXTURE"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("sonovo-e2e/fixture.md").path
        let url = URL(fileURLWithPath: path)
        let workspace = MarkdownWorkspace()
        workspace.setWorkspaceRoot(url.deletingLastPathComponent())
        guard let document = workspace.open(url: url) else {
            log("FAIL fixture did not open")
            finish()
            return
        }
        document.mode = .rendered

        let window = NSWindow(
            // token-exempt: E2E probe window geometry, not product design
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sonovo E2E"
        window.contentView = NSHostingView(
            rootView: MarkdownWorkspaceView(workspace: workspace)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)

        Task { @MainActor in
            await runChecks(workspace, document, window)
            finish()
        }
    }

    private static func finish() {
        NSApp.terminate(nil)
    }

    private static func waitUntil(
        _ timeout: TimeInterval,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func runChecks(
        _ workspace: MarkdownWorkspace,
        _ document: MarkdownDocument,
        _ window: NSWindow
    ) async {
        log("INFO macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        let parsed = await waitUntil(15) {
            if case .ready = workspace.parseCoordinator
                .state(for: document.id) {
                return true
            }
            return false
        }
        log((parsed ? "PASS" : "FAIL") + " parse ready")
        guard parsed,
              case let .ready(output) = workspace.parseCoordinator
                  .state(for: document.id) else {
            return
        }

        let renderedRecorded = await waitUntil(10) {
            workspace.storedReadingAnchors(for: document).rendered != nil
        }
        let renderedAnchor = workspace.storedReadingAnchors(for: document)
            .rendered
        log(
            (renderedRecorded ? "PASS" : "FAIL")
                + " rendered anchor recorded"
                + (renderedAnchor.map {
                    " block=\($0.blockOffset) kind=\($0.blockKind.rawValue)"
                        + " fraction=\(String(format: "%.3f", $0.fraction))"
                } ?? "")
        )

        // RB-01: the details default goes through the registry on the real
        // parse and source the viewer is showing.
        if let details = output.ast.blocks.compactMap({ block in
            if case .details(_, let range) = block { return range }
            return nil
        }).first {
            workspace.setDetailsOpenDefault(
                at: details,
                expectedSource: output.parsed.source,
                open: true,
                in: document
            )
            let opened = await waitUntil(3) {
                document.source.contains("<details open>")
            }
            log((opened ? "PASS" : "FAIL") + " details open default")
            document.undoManager.undo()
            _ = await waitUntil(3) {
                !document.source.contains("<details open>")
            }
        } else {
            log("FAIL fixture has no details block")
        }

        // RB-03: auto-pair through the real text view.
        workspace.setMode(.source, for: document)
        try? await Task.sleep(for: .milliseconds(400))
        let controller = workspace.controller(for: document)
        let ns = document.source as NSString
        let paragraphRange = ns.range(of: "Paragraph 1 ")
        if paragraphRange.location != NSNotFound {
            let caret = paragraphRange.location + paragraphRange.length
            controller.textView.setSelectedRange(
                NSRange(location: caret, length: 0)
            )
            controller.textView.insertText(
                "(",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            let paired = document.source.contains("Paragraph 1 (")
            log((paired ? "PASS" : "FAIL") + " auto-pair inserts both")
            document.undoManager.undo()
            let undone = await waitUntil(2) {
                !document.source.contains("Paragraph 1 (")
            }
            log((undone ? "PASS" : "FAIL") + " auto-pair one undo")
        } else {
            log("FAIL fixture has no paragraph target")
        }

        // RB-04: surface anchors survive a rendered -> source -> rendered
        // round trip, including the viewer consuming its restore anchor.
        let renderedBefore = workspace.storedReadingAnchors(for: document)
            .rendered
        let sectionRange = ns.range(of: "Section 60")
        let target = sectionRange.location
        controller.select(range: target..<target)
        workspace.setMode(.rendered, for: document)
        let sourceCaptured = workspace.storedReadingAnchors(for: document)
            .source
        let pending = workspace.pendingRenderedAnchors[document.id]
        log(
            (pending != nil ? "PASS" : "FAIL")
                + " rendered restore requested"
                + (pending == renderedBefore ? "" : " (anchor moved)")
        )
        let consumed = await waitUntil(8) {
            workspace.pendingRenderedAnchors[document.id] == nil
        }
        log((consumed ? "PASS" : "FAIL") + " rendered restore consumed")
        workspace.setMode(.source, for: document)
        let restoredSelection = document.selection
        log(
            (restoredSelection == target..<target ? "PASS" : "FAIL")
                + " source selection restored"
                + " expected=\(target) actual=\(String(describing: restoredSelection))"
        )
        let sourceAfter = workspace.storedReadingAnchors(for: document).source
        log(
            (sourceAfter?.lineOffset == sourceCaptured?.lineOffset
                ? "PASS" : "FAIL")
                + " source line restored"
                + " expected=\(String(describing: sourceCaptured?.lineOffset))"
                + " actual=\(String(describing: sourceAfter?.lineOffset))"
        )

        // RB-05: the find bar opens seeded after Find in Files. Use the real
        // project search so the line/column convention is the shipped one.
        let seedRange = ns.range(of: "value-60")
        let searchResult = await workspace.findInFiles("value-60")
        if let match = searchResult?.matches.first(where: {
            $0.url == document.fileURL
        }), seedRange.location != NSNotFound {
            workspace.openResult(
                url: match.url,
                line: match.line,
                column: match.column,
                query: "value-60"
            )
            let immediate = controller.textView.selectedRange()
            try? await Task.sleep(for: .milliseconds(600))
            let later = controller.textView.selectedRange()
            log(
                "INFO seed match line=\(match.line) column=\(match.column)"
                    + " expected=\(seedRange.location)"
                    + " immediate=\(immediate) later=\(later)"
                    + " mode=\(document.mode.rawValue)"
            )
            let atMatch = later.location == seedRange.location
                && (later.length == 0
                    || later.length == "value-60".utf16.count)
            log((atMatch ? "PASS" : "FAIL") + " find bar seed lands on the match")
        } else {
            log("FAIL find in files returned no fixture match")
        }

        // RB-06: the find bar and its controls expose labels. SwiftUI builds
        // its accessibility tree for AX clients, not for a plain subview
        // walk, so query the app through the system AX API.
        workspace.setMode(.rendered, for: document)
        try? await Task.sleep(for: .milliseconds(800))
        workspace.showRenderedFind()
        try? await Task.sleep(for: .milliseconds(800))
        var processLabels: [String] = []
        if let root = window.contentView {
            collectLabels(root, into: &processLabels)
        }
        let axLabels = collectAXLabels()
        let labels = processLabels + axLabels
        let needed = ["Previous match", "Next match", "Close find"]
        let missing = needed.filter { !labels.contains($0) }
        log(
            "INFO accessibility trusted=\(AXIsProcessTrusted())"
                + " processLabels=\(processLabels.count)"
                + " axLabels=\(axLabels.count)"
        )
        log(
            (missing.isEmpty ? "PASS" : "FAIL")
                + " find bar labels"
                + " collected=\(labels.count)"
                + (missing.isEmpty ? "" : " missing=\(missing)")
        )

        // RB-05: double-click a rendered block switches to Source.
        workspace.renderedFind(for: document).close()
        try? await Task.sleep(for: .milliseconds(400))
        if let view = window.contentView {
            let size = view.bounds.size
            for offset in [90.0, 140.0, 190.0] {
                sendDoubleClick(
                    window: window,
                    // token-exempt: E2E click point, not product design
                    point: NSPoint(
                        x: size.width / 2,
                        y: size.height - offset
                    )
                )
                try? await Task.sleep(for: .milliseconds(300))
                if document.mode == .source { break }
            }
        }
        log((document.mode == .source ? "PASS" : "FAIL") + " double-click edits in source")

        // RB-17: Source and Rendered side by side, with exact scroll sync.
        await runSplitViewChecks(
            workspace: workspace,
            document: document,
            window: window
        )

        // RB-18: two document panes, focus routing, and close semantics.
        await runTwoPaneChecks(
            workspace: workspace,
            document: document,
            window: window
        )

        // RB-20: focus mode, typewriter, and line numbers.
        await runDisplayModeChecks(
            workspace: workspace,
            document: document,
            window: window
        )

        // RB-21: export the rendered document as self-contained HTML and PDF.
        await runExportChecks(workspace: workspace, document: document)

        // RB-23: the isolated diagram renderer, its policy, and its exports.
        await runMermaidChecks()

        // RB-24: the Graphviz, Markmap, and SVG fence paths.
        await runDiagramEngineChecks()

        // RB-28: the sandboxed MDX compile and the isolated preview.
        await runMDXChecks()

        // RB-19: viewer virtualization cost on a long document.
        await runVirtualizationProbe(
            workspace: workspace,
            document: document,
            window: window
        )

        // Hold the rendered surface with the find bar open so an external
        // accessibility client can inspect labels while the app is alive.
        workspace.setMode(.rendered, for: document)
        try? await Task.sleep(for: .milliseconds(800))
        workspace.showRenderedFind()
        // Park the held screenshot on the fixture's own feature: diagrams when
        // the fixture has one, formulas otherwise.
        let diagrams = MarkdownDiagramNodes.sources(from: output.ast)
        let hasDiagram = !diagrams.isEmpty
        let hasMermaid = diagrams.contains { $0.engine == .mermaid }
        workspace.renderedFind(for: document).query = hasDiagram
            ? (hasMermaid ? "E2E-MERMAID" : "E2E-DIAGRAM")
            : "E2E-MATH-INLINE"
        try? await Task.sleep(for: .milliseconds(1_200))
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(400))
        log("HOLD")
        try? await Task.sleep(for: .seconds(20))
    }

    // MARK: - RB-17 split view

    private static func runSplitViewChecks(
        workspace: MarkdownWorkspace,
        document: MarkdownDocument,
        window: NSWindow
    ) async {
        workspace.setMode(.rendered, for: document)
        try? await Task.sleep(for: .milliseconds(600))

        let revision = document.revision
        workspace.parseCoordinator.request(
            documentID: document.id,
            identityGeneration: document.identityGeneration,
            revision: revision,
            source: document.source
        )
        let parsed = await waitUntil(10) {
            if case let .ready(output) = workspace.parseCoordinator.state(
                for: document.id
            ), output.revision == revision {
                return true
            }
            return false
        }
        guard parsed,
              case let .ready(output) = workspace.parseCoordinator.state(
                  for: document.id
              ),
              let target = output.ast.blocks.enumerated().first(where: {
                  $0.offset > 4 && $0.element.range != nil
              }) else {
            log("FAIL split view parse")
            return
        }
        let targetRange = target.element.range!
        let controller = workspace.controller(for: document)

        workspace.setSplitView(true, for: document)
        try? await Task.sleep(for: .milliseconds(900))
        log(
            (workspace.isSplitView(document)
                && document.mode == .source
                && controller.scrollView.window != nil
                && controller.scrollView.superview != nil
                ? "PASS" : "FAIL")
                + " split mounts source and rendered"
                + " mode=\(document.mode.rawValue)"
                + " window=\(controller.scrollView.window != nil)"
        )

        workspace.scrollTargets[document.id] = nil
        controller.scrollToSourceOffset(targetRange.lowerBound)
        // The viewer consumes its scroll target and clears the binding, so
        // the observable result is where it reports the rendered top block.
        _ = await waitUntil(3) {
            workspace.storedReadingAnchors(for: document).rendered?
                .blockOffset == targetRange.lowerBound
        }
        let renderedTarget = workspace.storedReadingAnchors(for: document)
            .rendered?.blockOffset
        log(
            (renderedTarget == targetRange.lowerBound ? "PASS" : "FAIL")
                + " split source scroll targets rendered"
                + " expected=\(targetRange.lowerBound)"
                + " actual=\(String(describing: renderedTarget))"
        )

        workspace.isSplitScrollSynced = false
        workspace.scrollTargets[document.id] = nil
        if let last = output.ast.blocks.last?.range {
            controller.scrollToSourceOffset(last.lowerBound)
        }
        try? await Task.sleep(for: .milliseconds(600))
        log(
            (workspace.scrollTargets[document.id] == nil ? "PASS" : "FAIL")
                + " split sync off leaves rendered still"
        )
        workspace.isSplitScrollSynced = true

        workspace.sourceScrollTargets[document.id] = nil
        workspace.renderedDidScroll(
            RenderedReadingAnchor(
                blockOffset: targetRange.lowerBound,
                blockKind: ReadingBlockKind(target.element),
                fraction: 0
            ),
            in: document
        )
        let sourceTarget = workspace.sourceScrollTargets[document.id]
        log(
            (sourceTarget == targetRange.lowerBound ? "PASS" : "FAIL")
                + " split rendered scroll targets source"
                + " expected=\(targetRange.lowerBound)"
                + " actual=\(String(describing: sourceTarget))"
        )

        workspace.setSplitView(false, for: document)
        try? await Task.sleep(for: .milliseconds(500))
        log(
            (!workspace.isSplitView(document) && document.mode == .rendered
                ? "PASS" : "FAIL")
                + " split closes to the mode it came from"
                + " mode=\(document.mode.rawValue)"
        )
        window.makeFirstResponder(nil)
    }

    // MARK: - RB-18 two-document panes

    private static func runTwoPaneChecks(
        workspace: MarkdownWorkspace,
        document: MarkdownDocument,
        window: NSWindow
    ) async {
        let secondURL = URL(
            fileURLWithPath: "/tmp/sonovo-e2e-second.md"
        )
        let secondSource = "# Second\n\nSecond body.\n"
        try? Data(secondSource.utf8).write(to: secondURL)
        guard let second = workspace.open(url: secondURL) else {
            log("FAIL two-pane second document did not open")
            return
        }
        workspace.show(document, inPane: .primary)
        workspace.show(second, inPane: .secondary)
        workspace.setMode(.source, for: document)
        workspace.setMode(.source, for: second)
        try? await Task.sleep(for: .milliseconds(900))

        let firstController = workspace.controller(for: document)
        let secondController = workspace.controller(for: second)
        log(
            (workspace.secondaryDocument === second
                && workspace.primaryDocument === document
                && workspace.documents.count == 2
                ? "PASS" : "FAIL")
                + " two panes show two documents"
                + " primary=\(workspace.primaryDocument?.fileURL?.lastPathComponent ?? "nil")"
                + " secondary=\(workspace.secondaryDocument?.fileURL?.lastPathComponent ?? "nil")"
        )
        log(
            (firstController.scrollView.window != nil
                && secondController.scrollView.window != nil
                ? "PASS" : "FAIL")
                + " both source editors are mounted"
        )

        workspace.focus(document)
        let firstFocused = workspace.selectedDocument === document
        workspace.focus(second)
        let secondFocused = workspace.selectedDocument === second
        log(
            (firstFocused && secondFocused ? "PASS" : "FAIL")
                + " focus routes the selected document"
        )

        let firstRange = (document.source as NSString)
            .range(of: "Paragraph 1")
        let secondRange = (second.source as NSString)
            .range(of: "Second body")
        if firstRange.location != NSNotFound,
           secondRange.location != NSNotFound {
            firstController.textView.setSelectedRange(firstRange)
            secondController.textView.setSelectedRange(secondRange)
            workspace.perform(.toggleStrong, on: document)
            workspace.perform(.toggleStrong, on: second)
            let firstEdited = document.source.contains("**Paragraph 1**")
            let secondEdited = second.source.contains("**Second body**")
            second.undoManager.undo()
            log(
                (firstEdited && secondEdited
                    && document.source.contains("**Paragraph 1**")
                    && second.source == secondSource
                    ? "PASS" : "FAIL")
                    + " undo history is isolated per pane"
            )
            document.undoManager.undo()
        } else {
            log("FAIL two-pane edit targets")
        }

        workspace.closeSplitPane()
        try? await Task.sleep(for: .milliseconds(400))
        log(
            (workspace.secondaryDocument == nil
                && workspace.documents.count == 2
                ? "PASS" : "FAIL")
                + " closing a pane keeps both documents open"
        )

        workspace.discardAndClose(second)
        try? FileManager.default.removeItem(at: secondURL)
        try? await Task.sleep(for: .milliseconds(400))
        log(
            (workspace.documents.count == 1
                && workspace.primaryDocument === document
                ? "PASS" : "FAIL")
                + " closing the secondary document collapses to the survivor"
        )
        workspace.setMode(.rendered, for: document)
        window.makeFirstResponder(nil)
    }

    // MARK: - RB-20 display modes

    private static func runDisplayModeChecks(
        workspace: MarkdownWorkspace,
        document: MarkdownDocument,
        window: NSWindow
    ) async {
        workspace.setMode(.source, for: document)
        try? await Task.sleep(for: .milliseconds(500))
        let controller = workspace.controller(for: document)
        window.makeFirstResponder(controller.textView)
        let revision = document.revision
        workspace.parseCoordinator.request(
            documentID: document.id,
            identityGeneration: document.identityGeneration,
            revision: revision,
            source: document.source
        )
        let parsed = await waitUntil(10) {
            controller.lastHighlightedRevision == revision
        }
        guard parsed,
              case let .ready(output) = workspace.parseCoordinator.state(
                  for: document.id
              ), output.revision == revision else {
            log("FAIL display-mode parse")
            return
        }
        let originalSource = document.source
        let originalRevision = document.revision
        let originalCanUndo = document.undoManager.canUndo

        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "sonovo.markdownFocusMode")
        defaults.set(true, forKey: "sonovo.markdownTypewriter")
        defaults.set(true, forKey: "sonovo.markdownLineNumbers")
        NotificationCenter.default.post(
            name: .sonovoEditorPreferencesChanged,
            object: nil
        )
        try? await Task.sleep(for: .milliseconds(700))
        log(
            (controller.isFocusModeEnabled
                && controller.isTypewriterEnabled
                && controller.reviewRulerView.showsLineNumbers
                ? "PASS" : "FAIL")
                + " display settings apply to the open editor"
        )

        let blocks = output.ast.blocks
        guard let target = blocks.enumerated().first(where: {
            index, block in
            guard index > 4,
                  case .paragraph = block,
                  block.range != nil else { return false }
            return true
        }), let targetRange = target.element.range else {
            log("FAIL display-mode targets")
            return
        }
        let ns = controller.textView.string as NSString
        let caret = min(targetRange.lowerBound + 2, ns.length - 1)
        controller.textView.setSelectedRange(
            NSRange(location: caret, length: 0)
        )
        try? await Task.sleep(for: .milliseconds(500))
        let storage = controller.textView.textStorage
        let dim = NSColor(AppTheme.MarkdownChrome.Focus.dim)
        let inside = storage?.attribute(
            .foregroundColor,
            at: caret,
            effectiveRange: nil
        ) as? NSColor
        // Focus dims only the visible range, so the control point must be a
        // fully visible block outside the caret block.
        let visible = controller.textView.visibleRect
        let top = controller.textView.characterIndexForInsertion(
            at: NSPoint(x: 0, y: visible.minY)
        )
        let bottom = controller.textView.characterIndexForInsertion(
            // token-exempt: E2E hit-test point, not product design
            at: NSPoint(x: 0, y: max(visible.minY, visible.maxY - 1))
        )
        let outsideRange = blocks.compactMap(\.range).first { range in
            guard range.lowerBound >= top,
                  range.upperBound <= bottom else {
                return false
            }
            return range.upperBound <= targetRange.lowerBound
                || range.lowerBound >= targetRange.upperBound
        }
        var outsideColor: NSColor?
        if let outsideRange {
            let outsideOffset = min(
                outsideRange.lowerBound + 1,
                ns.length - 1
            )
            outsideColor = storage?.attribute(
                .foregroundColor,
                at: outsideOffset,
                effectiveRange: nil
            ) as? NSColor
        }
        log(
            (outsideColor == dim && inside != dim ? "PASS" : "FAIL")
                + " focus dims outside the caret block"
                + " inside=\(String(describing: inside))"
                + " outside=\(String(describing: outsideColor))"
                + " dim=\(String(describing: dim))"
        )

        let targetOffset = ns.range(of: "Section 60").location
        if targetOffset != NSNotFound {
            controller.textView.setSelectedRange(
                NSRange(location: targetOffset, length: 0)
            )
            controller.keepCaretNearTypewriterLine()
            try? await Task.sleep(for: .milliseconds(400))
            let visible = controller.scrollView.contentView.bounds
            let line = controller.textView.visibleCodeLines()
                .last(where: { $0.documentOffset <= targetOffset })
            let fraction = line.map {
                ($0.rect.minY - visible.minY) / max(1, visible.height)
            }
            let fractionText = fraction.map {
                String(format: "%.2f", $0)
            } ?? "nil"
            log(
                (fraction.map { $0 > 0.2 && $0 < 0.6 } ?? false
                    ? "PASS" : "FAIL")
                    + " typewriter keeps the caret near 40%"
                    + " fraction=\(fractionText)"
            )
        } else {
            log("FAIL typewriter target")
        }

        let expectedRulerWidth = AppTheme.Code.lineNumberWidth
            + AppTheme.MarkdownChrome.Comments.gutterWidth
        log(
            (controller.scrollView.rulersVisible
                && abs(
                    controller.reviewRulerView.ruleThickness
                        - expectedRulerWidth
                ) < 0.5
                && controller.lineNumber(at: 0) == 1
                && !controller.textView.visibleCodeLines().isEmpty
                ? "PASS" : "FAIL")
                + " line-number ruler is visible and aligned"
        )

        defaults.set(false, forKey: "sonovo.markdownFocusMode")
        defaults.set(false, forKey: "sonovo.markdownTypewriter")
        defaults.set(false, forKey: "sonovo.markdownLineNumbers")
        NotificationCenter.default.post(
            name: .sonovoEditorPreferencesChanged,
            object: nil
        )
        try? await Task.sleep(for: .milliseconds(500))
        log(
            (!controller.isFocusModeEnabled
                && !controller.isTypewriterEnabled
                && !controller.reviewRulerView.showsLineNumbers
                ? "PASS" : "FAIL")
                + " display modes toggle off"
        )
        log(
            (document.source == originalSource
                && document.revision == originalRevision
                && document.undoManager.canUndo == originalCanUndo
                ? "PASS" : "FAIL")
                + " display modes leave text and undo untouched"
        )
        window.makeFirstResponder(nil)
    }

    // MARK: - RB-21 export

    private static func runExportChecks(
        workspace: MarkdownWorkspace,
        document: MarkdownDocument
    ) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-e2e-export-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            log("FAIL export directory: \(error)")
            return
        }
        let htmlURL = directory.appendingPathComponent("fixture.html")
        let pdfURL = directory.appendingPathComponent("fixture.pdf")
        let theme = MarkdownReadingSettings.currentTheme()

        // RB-22: prove the native typesetter runs in the shipped app on this
        // OS, independent of the export path.
        let mathSource = "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}"
        switch MarkdownMathRenderer.shared.layout(
            source: mathSource,
            display: true,
            fontSize: theme.bodySize,
            color: theme.palette(for: .light).ink.nsColor
        ) {
        case let .success(layout):
            log(
                "PASS math typeset"
                    + " width=\(String(format: "%.1f", layout.width))"
                    + " height=\(String(format: "%.1f", layout.height))"
                    + " descent=\(String(format: "%.1f", layout.descent))"
            )
        case let .failure(error):
            log("FAIL math typeset \(String(describing: error))")
        }

        do {
            try await MarkdownExportService.write(
                document: document,
                format: .html,
                to: htmlURL,
                workspaceRoot: workspace.workspaceRoot,
                theme: theme
            )
            let html = try String(contentsOf: htmlURL, encoding: .utf8)
            let longFixture = html.contains("Paragraph 1 ")
            var checks = [
                html.contains("<!DOCTYPE html>"),
                html.contains("Content-Security-Policy"),
                html.contains("<article class=\"sonovo\">"),
                !html.contains("<script"),
                !html.contains("<link ")
            ]
            if longFixture {
                checks.append(html.contains("Paragraph 120"))
            }
            log(
                (checks.allSatisfy { $0 } ? "PASS" : "FAIL")
                    + " HTML export self-contained"
                    + " bytes=\(html.utf8.count)"
                    + " path=\(htmlURL.path)"
                    + (checks.allSatisfy { $0 }
                        ? ""
                        : " checks=\(checks)")
            )
            // RB-22: both display styles must be rasterized into the file;
            // a literal span means the renderer rejected a formula.
            let mathChecks = [
                html.contains("math math-inline"),
                html.contains("math math-display"),
                html.contains("data:image/png;base64,"),
                !html.contains("<span class=\"math math-literal\">")
            ]
            log(
                (mathChecks.allSatisfy { $0 } ? "PASS" : "FAIL")
                    + " HTML math export"
                    + " inline=\(mathChecks[0])"
                    + " display=\(mathChecks[1])"
                    + " image=\(mathChecks[2])"
                    + " literal=\(!mathChecks[3])"
            )
        } catch {
            log("FAIL HTML export: \(error)")
        }

        do {
            try await MarkdownExportService.write(
                document: document,
                format: .pdf,
                to: pdfURL,
                workspaceRoot: workspace.workspaceRoot,
                theme: theme
            )
            let data = try Data(contentsOf: pdfURL)
            let pdf = PDFDocument(url: pdfURL)
            let pageCount = pdf?.pageCount ?? 0
            let firstPage = pdf?.page(at: 0)
            let size = firstPage?.bounds(for: .mediaBox).size
                ?? .zero
            let text = pdf?.string ?? ""
            let firstPageText = pdf?.page(at: 0)?.string ?? ""
            let lastPageText = pageCount > 1
                ? pdf?.page(at: pageCount - 1)?.string ?? ""
                : ""
            let expectedWidth = AppTheme.MarkdownChrome.Export.paperWidth
            let expectedHeight = AppTheme.MarkdownChrome.Export.paperHeight
            let a4 = abs(size.width - expectedWidth) <= 2
                && abs(size.height - expectedHeight) <= 2
            let longFixture = text.contains("Paragraph 1 ")
            var checks = [
                data.prefix(4) == Data("%PDF".utf8),
                pageCount >= 1,
                a4
            ]
            if longFixture {
                checks.append(contentsOf: [
                    pageCount >= 2,
                    text.contains("Paragraph 120"),
                    firstPageText.contains("Paragraph 1 "),
                    lastPageText.contains("Paragraph 120")
                ])
            }
            log(
                (checks.allSatisfy { $0 } ? "PASS" : "FAIL")
                    + " PDF export paginated"
                    + " bytes=\(data.count)"
                    + " pages=\(pageCount)"
                    + " size=\(String(format: "%.1fx%.1f", size.width, size.height))"
                    + " text=\(text.utf8.count)"
                    + " path=\(pdfURL.path)"
                    + (checks.allSatisfy { $0 } ? "" : " checks=\(checks)")
            )
        } catch {
            log("FAIL PDF export: \(error)")
        }

        let htmlOpened = NSWorkspace.shared.open(htmlURL)
        let pdfOpened = NSWorkspace.shared.open(pdfURL)
        log(
            (htmlOpened && pdfOpened ? "PASS" : "FAIL")
                + " exported files open"
                + " html=\(htmlOpened) pdf=\(pdfOpened)"
        )
        try? await Task.sleep(for: .seconds(1))
    }

    // MARK: - RB-23 diagrams

    private static func runMermaidChecks() async {
        let source = "flowchart LR\n  A[Author] --> B[Reader]\n  B --> C[Export]"

        do {
            let svg = try await MermaidRenderer.shared.render(
                source: source,
                variant: .light
            )
            let checks = [
                svg.markup.contains("<svg"),
                svg.markup.contains("<text"),
                svg.markup.contains("<style"),
                !svg.markup.lowercased().contains("<script"),
                !svg.markup.contains("foreignObject"),
                (svg.width ?? 0) > 0,
                (svg.height ?? 0) > 0
            ]
            log(
                (checks.allSatisfy { $0 } ? "PASS" : "FAIL")
                    + " mermaid render"
                    + " bytes=\(svg.markup.utf8.count)"
                    + " width=\(String(format: "%.1f", svg.width ?? 0))"
                    + " height=\(String(format: "%.1f", svg.height ?? 0))"
                    + " text=\(checks[1])"
                    + " style=\(checks[2])"
                    + " script=\(!checks[3])"
                    + " foreignObject=\(checks[4])"
            )
        } catch {
            log("FAIL mermaid render \(error)")
        }

        do {
            let results = try await MermaidRenderer.shared
                .probeNetworkForTesting()
            let checks = [
                results["fetch"] == "blocked",
                results["xhr"] == "blocked",
                results["websocket"] == "blocked",
                results["image"] == "blocked",
                results["dataFetch"] == "blocked",
                results["file"] == "blocked",
                results["dataImage"] == "allowed",
                results["messageHandlers"] == "0"
            ]
            log(
                (checks.allSatisfy { $0 } ? "PASS" : "FAIL")
                    + " mermaid isolation"
                    + " fetch=\(results["fetch"] ?? "?")"
                    + " xhr=\(results["xhr"] ?? "?")"
                    + " websocket=\(results["websocket"] ?? "?")"
                    + " image=\(results["image"] ?? "?")"
                    + " dataFetch=\(results["dataFetch"] ?? "?")"
                    + " file=\(results["file"] ?? "?")"
                    + " dataImage=\(results["dataImage"] ?? "?")"
                    + " handlers=\(results["messageHandlers"] ?? "?")"
            )
        } catch {
            log("FAIL mermaid isolation \(error)")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-e2e-mermaid-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            log("FAIL mermaid export directory: \(error)")
            return
        }
        let sourceURL = directory.appendingPathComponent("diagram.md")
        let htmlURL = directory.appendingPathComponent("diagram.html")
        let pdfURL = directory.appendingPathComponent("diagram.pdf")
        let markdown = """
        # Diagram

        ```mermaid
        \(source)
        ```

        After the diagram.
        """
        do {
            try Data(markdown.utf8).write(to: sourceURL)
            let document = try MarkdownDocument(loading: sourceURL)
            let theme = MarkdownReadingSettings.currentTheme()
            try await MarkdownExportService.write(
                document: document,
                format: .html,
                to: htmlURL,
                workspaceRoot: directory,
                theme: theme
            )
            let html = try String(contentsOf: htmlURL, encoding: .utf8)
            let checks = [
                html.contains("mermaid-block"),
                html.contains("<svg"),
                html.contains("<text"),
                html.contains("mermaid-light"),
                html.contains("mermaid-dark"),
                !html.contains("<script"),
                !html.contains("foreignObject"),
                !html.contains("example.com")
            ]
            log(
                (checks.allSatisfy { $0 } ? "PASS" : "FAIL")
                    + " mermaid HTML export"
                    + " bytes=\(html.utf8.count)"
                    + " svg=\(checks[1])"
                    + " text=\(checks[2])"
                    + " light=\(checks[3])"
                    + " dark=\(checks[4])"
                    + " script=\(!checks[5])"
                    + " foreignObject=\(checks[6])"
                    + " path=\(htmlURL.path)"
            )

            try await MarkdownExportService.write(
                document: document,
                format: .pdf,
                to: pdfURL,
                workspaceRoot: directory,
                theme: theme
            )
            let data = try Data(contentsOf: pdfURL)
            let pdf = PDFDocument(url: pdfURL)
            let pageCount = pdf?.pageCount ?? 0
            let size = pdf?.page(at: 0)?.bounds(for: .mediaBox).size ?? .zero
            let expectedWidth = AppTheme.MarkdownChrome.Export.paperWidth
            let expectedHeight = AppTheme.MarkdownChrome.Export.paperHeight
            let pdfChecks = [
                data.prefix(4) == Data("%PDF".utf8),
                pageCount >= 1,
                abs(size.width - expectedWidth) <= 2
                    && abs(size.height - expectedHeight) <= 2,
                data.count > 1_000
            ]
            log(
                (pdfChecks.allSatisfy { $0 } ? "PASS" : "FAIL")
                    + " mermaid PDF export"
                    + " bytes=\(data.count)"
                    + " pages=\(pageCount)"
                    + " size=\(String(format: "%.1fx%.1f", size.width, size.height))"
                    + " path=\(pdfURL.path)"
            )
        } catch {
            log("FAIL mermaid export: \(error)")
        }
    }

    // MARK: - RB-24 diagram engines

    private static func runDiagramEngineChecks() async {
        do {
            let source = "digraph G { rankdir=LR; Reader -> Export; }"
            let light = try await GraphvizRenderer.shared.render(
                source: source,
                variant: .light
            )
            let dark = try await GraphvizRenderer.shared.render(
                source: source,
                variant: .dark
            )
            let checks = [
                light.markup.contains("<svg"),
                light.markup.contains("<text"),
                !light.markup.lowercased().contains("<script"),
                (light.width ?? 0) > 0,
                (light.height ?? 0) > 0,
                dark.markup.contains("#E6E6E6")
            ]
            log(
                (checks.allSatisfy { $0 } ? "PASS" : "FAIL")
                    + " graphviz render"
                    + " bytes=\(light.markup.utf8.count)"
                    + " width=\(String(format: "%.1f", light.width ?? 0))"
                    + " height=\(String(format: "%.1f", light.height ?? 0))"
                    + " darkTheme=\(checks[5])"
            )
        } catch {
            log("FAIL graphviz render \(error)")
        }

        do {
            let source = "# Reader\n## Graphviz\n## Markmap"
            let svg = try await MarkmapRenderer.shared.render(
                source: source,
                variant: .light
            )
            let checks = [
                svg.markup.contains("<svg"),
                svg.markup.contains("<text"),
                !svg.markup.contains("foreignObject"),
                !svg.markup.lowercased().contains("<script"),
                svg.width == 1_200,
                svg.height == 800
            ]
            log(
                (checks.allSatisfy { $0 } ? "PASS" : "FAIL")
                    + " markmap render"
                    + " bytes=\(svg.markup.utf8.count)"
                    + " width=\(String(format: "%.1f", svg.width ?? 0))"
                    + " height=\(String(format: "%.1f", svg.height ?? 0))"
                    + " foreignObject=\(!checks[2])"
            )
        } catch {
            log("FAIL markmap render \(error)")
        }

        do {
            let svg = try DiagramRenderer.renderSVGFence(
                """
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 20">
                <script>alert(1)</script>
                <text x="1" y="12">SVG</text>
                </svg>
                """,
                variant: .light
            )
            let checks = [
                svg.markup.contains("<text"),
                !svg.markup.lowercased().contains("<script"),
                svg.width == 40,
                svg.height == 20
            ]
            log(
                (checks.allSatisfy { $0 } ? "PASS" : "FAIL")
                    + " svg fence"
                    + " bytes=\(svg.markup.utf8.count)"
                    + " width=\(String(format: "%.1f", svg.width ?? 0))"
                    + " height=\(String(format: "%.1f", svg.height ?? 0))"
                    + " script=\(!checks[1])"
            )
        } catch {
            log("FAIL svg fence \(error)")
        }

        for (name, renderer) in [
            ("graphviz", GraphvizRenderer.shared),
            ("markmap", MarkmapRenderer.shared)
        ] {
            do {
                let results = try await renderer.probeNetworkForTesting()
                let checks = [
                    results["fetch"] == "blocked",
                    results["xhr"] == "blocked",
                    results["websocket"] == "blocked",
                    results["image"] == "blocked",
                    results["dataFetch"] == "blocked",
                    results["file"] == "blocked",
                    results["dataImage"] == "allowed",
                    results["messageHandlers"] == "0"
                ]
                log(
                    (checks.allSatisfy { $0 } ? "PASS" : "FAIL")
                        + " \(name) isolation"
                        + " fetch=\(results["fetch"] ?? "?")"
                        + " xhr=\(results["xhr"] ?? "?")"
                        + " websocket=\(results["websocket"] ?? "?")"
                        + " image=\(results["image"] ?? "?")"
                        + " dataFetch=\(results["dataFetch"] ?? "?")"
                        + " file=\(results["file"] ?? "?")"
                        + " dataImage=\(results["dataImage"] ?? "?")"
                        + " handlers=\(results["messageHandlers"] ?? "?")"
                )
            } catch {
                log("FAIL \(name) isolation \(error)")
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-e2e-diagrams-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            log("FAIL diagram export directory: \(error)")
            return
        }
        let sourceURL = directory.appendingPathComponent("engines.md")
        let htmlURL = directory.appendingPathComponent("engines.html")
        let markdown = """
        # Engines

        ```mermaid
        flowchart LR
          A[One] --> B[Two]
        ```

        ```dot
        digraph G { rankdir=LR; Reader -> Export; }
        ```

        ```markmap
        # Reader
        ## Graphviz
        ## Markmap
        ```

        ```svg
        <svg viewBox="0 0 40 20"><text x="1" y="12">SVG</text></svg>
        ```
        """
        do {
            try Data(markdown.utf8).write(to: sourceURL)
            let document = try MarkdownDocument(loading: sourceURL)
            let theme = MarkdownReadingSettings.currentTheme()
            try await MarkdownExportService.write(
                document: document,
                format: .html,
                to: htmlURL,
                workspaceRoot: directory,
                theme: theme
            )
            let html = try String(contentsOf: htmlURL, encoding: .utf8)
            let checks = [
                html.contains("mermaid-block"),
                html.contains("graphviz-block"),
                html.contains("markmap-block"),
                html.contains("svg-fence"),
                !html.contains("<script"),
                !html.contains("foreignObject"),
                !html.contains("example.com")
            ]
            log(
                (checks.allSatisfy { $0 } ? "PASS" : "FAIL")
                    + " diagram engines HTML export"
                    + " bytes=\(html.utf8.count)"
                    + " mermaid=\(checks[0])"
                    + " graphviz=\(checks[1])"
                    + " markmap=\(checks[2])"
                    + " svg=\(checks[3])"
                    + " path=\(htmlURL.path)"
            )
        } catch {
            log("FAIL diagram engines export: \(error)")
        }
    }

    // MARK: - RB-28 MDX component documents

    private static func runMDXChecks() async {
        guard let compiler = MDXHelperCompiler.appDefault() else {
            log("FAIL MDX helper or compiler missing")
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-e2e-mdx-\(UUID().uuidString)")
        let entry = root.appendingPathComponent("entry.mdx")
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            try """
            import Button from "./Button.jsx"

            # E2E-MDX

            <Button label="E2E-MDX-COMPONENT" />
            """.write(to: entry, atomically: true, encoding: .utf8)
            try """
            export default function Button(props) {
              return <button>{props.label}</button>;
            }
            """.write(
                to: root.appendingPathComponent("Button.jsx"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            log("FAIL MDX fixture: \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = MDXWorkspace(
            service: MDXCompileService(compiler: compiler)
        )
        workspace.setWorkspaceRoot(root)
        guard let document = workspace.open(url: entry) else {
            log("FAIL MDX document did not open")
            return
        }
        workspace.setPreviewEnabled(true)
        await workspace.compileNow(document)
        guard case .ready(let modules) =
            workspace.previewState(for: document) else {
            log(
                "FAIL MDX compile: "
                    + "\(workspace.previewState(for: document))"
            )
            return
        }
        log("PASS MDX compile modules=\(modules.count)")

        let preserved = (try? String(contentsOf: entry, encoding: .utf8))?
            .contains("E2E-MDX") == true
        log((preserved ? "PASS" : "FAIL") + " MDX source preserved")

        guard let runtime = MDXPreviewAssets.runtimeScript else {
            log("FAIL MDX preview runtime missing")
            return
        }
        let html = MDXPreviewPage.html(
            title: "E2E MDX",
            entry: document.relativePath,
            modules: modules,
            runtimeScript: runtime,
            theme: .light
        )
        let controller = MDXPreviewController()
        do {
            try await controller.loadForTesting(html: html)
            let results = try await controller.probeNetworkForTesting()
            let blocked = [
                "fetch", "xhr", "websocket", "image", "dataFetch", "file"
            ].allSatisfy { results[$0] == "blocked" }
            let boundary = blocked
                && results["dataImage"] == "allowed"
                && results["messageHandlers"] == "0"
            log(
                (boundary ? "PASS" : "FAIL")
                    + " MDX preview network blocked"
                    + " handlers=\(results["messageHandlers"] ?? "?")"
            )
            // The preview must run in WebKit's WebContent process, not the
            // app process. The SPI is confined to this probe build, which is
            // never shipped; absence is reported as UNVERIFIED, not a pass.
            let webView = controller.webViewForTesting
            let appPID = ProcessInfo.processInfo.processIdentifier
            if webView.responds(
                to: NSSelectorFromString("_webProcessIdentifier")
            ) {
                let webPID = webView
                    .value(forKey: "_webProcessIdentifier") as? Int
                let separated = webPID.map {
                    $0 > 0 && $0 != Int(appPID)
                } ?? false
                log(
                    (separated ? "PASS" : "FAIL")
                        + " MDX webcontent process"
                        + " web=\(webPID.map(String.init) ?? "nil")"
                        + " app=\(appPID)"
                )
            } else {
                log("UNVERIFIED MDX webcontent process")
            }
            var text = ""
            for _ in 0..<40 {
                text = try await controller.rootTextForTesting()
                if text.contains("E2E-MDX-COMPONENT") { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let rendered = text.contains("E2E-MDX")
                && text.contains("E2E-MDX-COMPONENT")
            log((rendered ? "PASS" : "FAIL") + " MDX preview render")
            let hasButton = try await controller.webViewForTesting
                .evaluateJavaScript(
                    "document.querySelector('button') !== null"
                ) as? Bool
            log(
                (hasButton == true ? "PASS" : "FAIL")
                    + " MDX local component import"
            )
        } catch {
            log("FAIL MDX preview: \(error.localizedDescription)")
        }
    }

    // MARK: - RB-19 viewer virtualization

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
                / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private static func runVirtualizationProbe(
        workspace: MarkdownWorkspace,
        document: MarkdownDocument,
        window: NSWindow
    ) async {
        let longURL = URL(fileURLWithPath: "/tmp/sonovo-e2e-long.md")
        var source = ""
        for index in 0..<3_000 {
            source += "## Section \(index)\n\n"
            source += "Paragraph \(index) body text for layout.\n\n"
        }
        try? Data(source.utf8).write(to: longURL)
        let baseline = residentBytes()
        guard let long = workspace.open(url: longURL) else {
            log("FAIL virtualization document did not open")
            return
        }
        workspace.setMode(.rendered, for: long)
        let revision = long.revision
        workspace.parseCoordinator.request(
            documentID: long.id,
            identityGeneration: long.identityGeneration,
            revision: revision,
            source: long.source
        )
        let parsed = await waitUntil(20) {
            if case let .ready(output) = workspace.parseCoordinator.state(
                for: long.id
            ), output.revision == revision {
                return true
            }
            return false
        }
        guard parsed,
              case let .ready(output) = workspace.parseCoordinator.state(
                  for: long.id
              ) else {
            log("FAIL virtualization parse")
            return
        }
        try? await Task.sleep(for: .milliseconds(1_500))
        let mounted = residentBytes()
        let blockCount = output.ast.blocks.count
        workspace.scrollTargets[long.id] = "block-\(blockCount - 1)"
        let started = ProcessInfo.processInfo.systemUptime
        let scrolled = await waitUntil(10) {
            workspace.scrollTargets[long.id] == nil
        }
        let scrollMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        try? await Task.sleep(for: .milliseconds(500))
        let afterScroll = residentBytes()
        let mountedMB = Double(mounted &- baseline) / 1_048_576
        let afterScrollMB = Double(afterScroll &- baseline) / 1_048_576
        log(
            "VIRT bytes=\(source.utf8.count)"
                + " blocks=\(blockCount)"
                + " baseline=\(baseline)"
                + " mounted=\(mounted)"
                + " deltaMB=\(String(format: "%.1f", mountedMB))"
                + " afterScrollMB=\(String(format: "%.1f", afterScrollMB))"
                + " scrollMS=\(String(format: "%.1f", scrollMS))"
                + " scrolled=\(scrolled)"
        )
        // The gate leaves roughly 9x headroom on mount, 2x after a full
        // scroll, and 3x on scroll time for a slower E2E Mac.
        let budget = mountedMB <= 100
            && afterScrollMB <= 350
            && scrollMS <= 1_500
            && scrolled
        log(
            (budget ? "PASS" : "FAIL")
                + " virtualization budget"
                + " mountedMB=\(String(format: "%.1f", mountedMB))"
                + " afterScrollMB=\(String(format: "%.1f", afterScrollMB))"
                + " scrollMS=\(String(format: "%.1f", scrollMS))"
        )

        workspace.discardAndClose(long)
        try? FileManager.default.removeItem(at: longURL)
        workspace.show(document, inPane: .primary)
        workspace.setMode(.rendered, for: document)
        try? await Task.sleep(for: .milliseconds(600))
        window.makeFirstResponder(nil)
    }

    private static func lineNumber(at offset: Int, in source: String) -> Int {
        var line = 1
        let ns = source as NSString
        for index in 0..<min(offset, ns.length)
        where ns.character(at: index) == 0x0A {
            line += 1
        }
        return line
    }

    private static func column(at offset: Int, in source: String) -> Int {
        let ns = source as NSString
        var lineStart = min(offset, ns.length)
        while lineStart > 0, ns.character(at: lineStart - 1) != 0x0A {
            lineStart -= 1
        }
        return offset - lineStart + 1
    }

    private static func collectLabels(_ element: Any, into labels: inout [String]) {
        if let accessible = element as? NSAccessibilityProtocol {
            if let label = accessible.accessibilityLabel(),
               !label.isEmpty {
                labels.append(label)
            }
            for child in accessible.accessibilityChildren() ?? [] {
                collectLabels(child, into: &labels)
            }
        }
        if let view = element as? NSView {
            for child in view.subviews {
                collectLabels(child, into: &labels)
            }
        }
    }

    /// Reads the accessibility tree the way VoiceOver does: through the
    /// system AX server. SwiftUI materializes its accessibility elements only
    /// for such a client, so a plain subview walk sees just the AppKit-hosted
    /// controls and misses the SwiftUI find bar.
    private static func collectAXLabels() -> [String] {
        let app = AXUIElementCreateApplication(getpid())
        var labels: [String] = []
        var budget = 5_000
        walkAX(app, depth: 0, budget: &budget, labels: &labels)
        return labels
    }

    private static func walkAX(
        _ element: AXUIElement,
        depth: Int,
        budget: inout Int,
        labels: inout [String]
    ) {
        guard depth < 40, budget > 0 else { return }
        budget -= 1
        for attribute in ["AXTitle", "AXDescription", "AXHelp"] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &value
            ) == .success,
               let text = value as? String,
               !text.isEmpty {
                labels.append(text)
            }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXChildren" as CFString,
            &children
        ) == .success,
              let elements = children as? [AXUIElement] else {
            return
        }
        for child in elements {
            walkAX(child, depth: depth + 1, budget: &budget, labels: &labels)
        }
    }

    private static func sendDoubleClick(window: NSWindow, point: NSPoint) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        for count in [1, 2] {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type,
                    location: point,
                    modifierFlags: [],
                    timestamp: timestamp,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: count,
                    pressure: type == .leftMouseDown ? 1 : 0
                ) else { continue }
                window.sendEvent(event)
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
    }
}
#endif
