#if SONOVO_E2E_PROBE
import AppKit
import ApplicationServices
import Carbon
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

        // MC-00: the multi-cursor plan's evidence gate. Probe-only checks for
        // caret geometry parity, IME span capture, and the echo rule.
        await runMultiCursorFeasibilityChecks(window: window)
        runMultiCursorCaretChecks()
        await runMultiCursorEditingChecks()
        await runMultiCursorIMEProbe()
        runMultiCursorMovementProbe()
        runMultiCursorPlacementProbe()
        await runMultiCursorGuardProbe()
        runMultiCursorAXProbe()
        await runMultiCursorBudgetProbe()

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

    // MARK: - MC-00 multi-cursor feasibility probes
    //
    // Evidence for the multi-cursor plan's gate: caret geometry parity, IME
    // span capture, and the echo rule. Probe-only code; it ships nowhere.

    // token-exempt: E2E probe geometry tolerance, not product design
    nonisolated private static let geometryTolerance: CGFloat = 1.0

    private static func runMultiCursorFeasibilityChecks(
        window: NSWindow
    ) async {
        runGeometryParity()
        await runCompositionProbe()
        await runEchoProbe()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Geometry parity

    private struct MCGeometryMeasurement {
        let name: String
        let offset: Int
        let upstream: Bool
        let gated: Bool
        let native: NSRect?
        let nativeActual: NSRange?
        let reference: NSRect?
        let charRect: NSRect?
        let candidate: NSRect?
        let note: String
        let debug: String

        var passed: Bool {
            guard gated else { return true }
            guard let reference, let candidate else { return false }
            return abs(candidate.minX - reference.minX) <= geometryTolerance
                && abs(candidate.minY - reference.minY) <= geometryTolerance
                && abs(candidate.height - reference.height)
                    <= geometryTolerance
        }
    }

    private static func makeProbeTextView(
        _ text: String,
        font: NSFont
    ) -> (window: NSWindow, view: MultiCursorProbeTextView) {
        // token-exempt: E2E probe measurement surface, not product design
        let width: CGFloat = 520
        // token-exempt: E2E probe measurement surface, not product design
        let height: CGFloat = 360
        let scroll = NSScrollView(
            // token-exempt: E2E probe measurement surface, not product design
            frame: NSRect(x: 0, y: 0, width: width, height: height)
        )
        scroll.hasVerticalScroller = true
        let view = MultiCursorProbeTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.minSize = NSSize.zero
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.lineFragmentPadding =
            AppTheme.Editor.lineFragmentPadding
        let probeInsetWidth = AppTheme.Reading.sourceInsetHorizontal
        let probeInsetHeight = AppTheme.Reading.sourceInsetVertical
        view.textContainerInset = NSSize(
            width: probeInsetWidth,
            height: probeInsetHeight
        )
        // A fixed container width makes wrapping deterministic: the probe
        // measures the same geometry the editor would draw at this width.
        let containerTextWidth = width - probeInsetWidth * 2
        view.textContainer?.containerSize = NSSize(
            width: containerTextWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.allowsUndo = false
        view.drawsBackground = false

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = AppTheme.Reading.sourceLineHeightMultiple
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        view.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        view.typingAttributes = attributes
        scroll.documentView = view

        let window = NSWindow(
            // token-exempt: E2E probe measurement surface, not product design
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        window.makeFirstResponder(view)
        view.layoutSubtreeIfNeeded()
        if let layout = view.textLayoutManager,
           let content = layout.textContentManager {
            layout.ensureLayout(for: content.documentRange)
        }
        return (window, view)
    }

    private static func nativeCaretRect(
        _ view: NSTextView,
        at offset: Int
    ) -> (rect: NSRect?, actual: NSRange?, charRect: NSRect?) {
        guard let window = view.window else { return (nil, nil, nil) }
        var actual = NSRange(location: NSNotFound, length: 0)
        let screen = view.firstRect(
            forCharacterRange: NSRange(location: offset, length: 0),
            actualRange: &actual
        )
        var charRect: NSRect?
        let length = (view.string as NSString).length
        if offset < length {
            let charScreen = view.firstRect(
                forCharacterRange: NSRange(location: offset, length: 1),
                actualRange: nil
            )
            if !charScreen.isNull, charScreen.height > 0 {
                charRect = view.convert(
                    window.convertFromScreen(charScreen),
                    from: nil
                )
            }
        }
        guard !screen.isNull, screen.height > 0 else {
            return (nil, actual, charRect)
        }
        let rect = view.convert(window.convertFromScreen(screen), from: nil)
        return (rect, actual, charRect)
    }

    private static func characterRect(
        _ view: NSTextView,
        at index: Int
    ) -> NSRect? {
        guard let window = view.window else { return nil }
        let length = (view.string as NSString).length
        guard index >= 0, index < length else { return nil }
        let screen = view.firstRect(
            forCharacterRange: NSRange(location: index, length: 1),
            actualRange: nil
        )
        guard !screen.isNull, screen.height > 0 else { return nil }
        return view.convert(window.convertFromScreen(screen), from: nil)
    }

    private static func isRightToLeft(
        _ text: NSString,
        at index: Int
    ) -> Bool {
        var cursor = min(index, text.length - 1)
        while cursor >= 0 {
            let unit = Int(text.character(at: cursor))
            if (0x0590...0x08FF).contains(unit)
                || (0xFB1D...0xFDFF).contains(unit)
                || (0xFE70...0xFEFF).contains(unit) {
                return true
            }
            if (0x0041...0x005A).contains(unit)
                || (0x0061...0x007A).contains(unit)
                || (0x00C0...0x024F).contains(unit) {
                return false
            }
            cursor -= 1
        }
        return false
    }

    /// The caret position the glyph layout implies, derived from a character
    /// bounding rect rather than `firstRect`'s insertion point. On macOS 27
    /// `firstRect` displaces insertion points for right-aligned RTL
    /// fragments by the fragment origin, so the character rect is the
    /// trustworthy native reference.
    private static func nativeReferenceRect(
        _ view: NSTextView,
        at offset: Int,
        firstRect: NSRect?
    ) -> NSRect? {
        let text = view.string as NSString
        guard text.length > 0 else { return firstRect }
        if offset == text.length,
           text.character(at: text.length - 1) == 0x0A {
            return firstRect
        }
        var charIndex = offset
        var trailing = false
        if offset >= text.length || text.character(at: offset) == 0x0A {
            charIndex = offset - 1
            trailing = true
        }
        while charIndex > 0, text.character(at: charIndex) == 0x0A {
            charIndex -= 1
            trailing = true
        }
        guard charIndex >= 0, charIndex < text.length,
              text.character(at: charIndex) != 0x0A,
              let rect = characterRect(view, at: charIndex) else {
            return firstRect
        }
        let rtl = isRightToLeft(text, at: charIndex)
        let x: CGFloat
        if trailing {
            x = rtl ? rect.minX : rect.maxX
        } else {
            x = rtl ? rect.maxX : rect.minX
        }
        // token-exempt: E2E probe measurement surface, not product design
        return NSRect(x: x, y: rect.minY, width: 2, height: rect.height)
    }

    private static func segmentCaretRect(
        _ view: NSTextView,
        at offset: Int,
        upstream: Bool
    ) -> (rect: NSRect, debug: String)? {
        guard let layout = view.textLayoutManager,
              let content = layout.textContentManager,
              let start = content.location(
                  content.documentRange.location,
                  offsetBy: offset
              ) else { return nil }
        layout.ensureLayout(for: content.documentRange)
        let range = NSTextRange(location: start)
        var options: NSTextLayoutManager.SegmentOptions = [.rangeNotRequired]
        if upstream { options.insert(.upstreamAffinity) }
        var found: CGRect?
        layout.enumerateTextSegments(
            in: range,
            type: .selection,
            options: options
        ) { _, rect, _, _ in
            found = rect
            return false
        }
        guard let found else { return nil }
        let inset = view.textContainerInset
        // token-exempt: E2E probe measurement surface, not product design
        let rect = NSRect(
            x: inset.width + found.minX,
            y: inset.height + found.minY,
            width: max(found.width, 2),
            height: found.height
        )
        let debug = String(
            format: "segment=(%.2f,%.2f,%.2f,%.2f)",
            found.minX,
            found.minY,
            found.width,
            found.height
        )
        return (rect, debug)
    }

    private static func candidateCaretRect(
        _ view: NSTextView,
        at offset: Int,
        upstream: Bool
    ) -> (rect: NSRect, path: String, debug: String)? {
        let line = lineFragmentCaretRect(
            view,
            at: offset,
            upstream: upstream
        )
        if let segment = segmentCaretRect(
            view,
            at: offset,
            upstream: upstream
        ) {
            var debug = segment.debug
            if let line {
                debug += String(
                    format: " lineX=%.2f lineY=%.2f",
                    line.rect.minX,
                    line.rect.minY
                )
            }
            return (segment.rect, "segment", debug)
        }
        return line
    }

    private static func lineFragmentCaretRect(
        _ view: NSTextView,
        at offset: Int,
        upstream: Bool
    ) -> (rect: NSRect, path: String, debug: String)? {
        guard let layout = view.textLayoutManager,
              let content = layout.textContentManager else { return nil }
        layout.ensureLayout(for: content.documentRange)
        guard let location = content.location(
            content.documentRange.location,
            offsetBy: offset
        ) else { return nil }
        var path = "exact"
        var fragment = layout.textLayoutFragment(for: location)
        if fragment == nil, offset > 0,
           let previous = content.location(
               content.documentRange.location,
               offsetBy: offset - 1
           ) {
            fragment = layout.textLayoutFragment(for: previous)
            path = "previous"
        }
        guard let fragment else { return nil }
        var line = fragment.textLineFragment(
            for: location,
            isUpstreamAffinity: upstream
        )
        if line == nil {
            line = upstream
                ? fragment.textLineFragments.last
                : fragment.textLineFragments.first
            path += "+edge"
        }
        guard let line else { return nil }
        let fragmentStart = content.offset(
            from: content.documentRange.location,
            to: fragment.rangeInElement.location
        )
        let lineStart = fragmentStart + line.characterRange.location
        let index = offset - lineStart
        let bounds = line.typographicBounds
        let frame = fragment.layoutFragmentFrame
        let inset = view.textContainerInset
        let point: CGPoint
        if index >= 0, index <= line.characterRange.length {
            point = line.locationForCharacter(at: index)
        } else if upstream {
            point = CGPoint(x: bounds.minX, y: 0)
            path += "+left"
        } else {
            point = CGPoint(x: bounds.maxX, y: 0)
            path += "+right"
        }
        var docIndexPoint: CGPoint?
        if offset <= line.characterRange.length {
            docIndexPoint = line.locationForCharacter(at: offset)
        }
        func format(_ point: CGPoint) -> String {
            String(format: "(%.2f,%.2f)", point.x, point.y)
        }
        var debug = "lineStart=\(lineStart)"
            + " lineLength=\(line.characterRange.length)"
            + " index=\(index) point=\(format(point))"
        if let docIndexPoint {
            debug += " docIndexPoint=\(format(docIndexPoint))"
        }
        // token-exempt: E2E probe measurement surface, not product design
        let rect = NSRect(
            x: frame.minX + inset.width + bounds.minX + point.x,
            y: frame.minY + inset.height + bounds.minY,
            width: 2,
            height: bounds.height
        )
        return (rect, path, debug)
    }

    private static func measureGeometry(
        _ name: String,
        view: MultiCursorProbeTextView,
        offset: Int,
        upstream: Bool,
        gated: Bool,
        note: String = ""
    ) -> MCGeometryMeasurement {
        let native = nativeCaretRect(view, at: offset)
        let reference = nativeReferenceRect(
            view,
            at: offset,
            firstRect: native.rect
        )
        let candidate = candidateCaretRect(
            view,
            at: offset,
            upstream: upstream
        )
        return MCGeometryMeasurement(
            name: name,
            offset: offset,
            upstream: upstream,
            gated: gated,
            native: native.rect,
            nativeActual: native.actual,
            reference: reference,
            charRect: native.charRect,
            candidate: candidate?.rect,
            note: (note + " path=" + (candidate?.path ?? "nil"))
                .trimmingCharacters(in: .whitespaces),
            debug: candidate?.debug ?? "no candidate"
        )
    }

    private static func logGeometry(_ measurement: MCGeometryMeasurement) {
        func describe(_ rect: NSRect?) -> String {
            guard let rect else { return "nil" }
            return String(
                format: "x=%.2f y=%.2f h=%.2f",
                rect.minX,
                rect.minY,
                rect.height
            )
        }
        func describeRange(_ range: NSRange?) -> String {
            guard let range else { return "nil" }
            if range.location == NSNotFound { return "not-found" }
            return "\(range.location)+\(range.length)"
        }
        let verdict = measurement.passed ? "ok" : "MISMATCH"
        let native = describe(measurement.native)
        let reference = describe(measurement.reference)
        let actual = describeRange(measurement.nativeActual)
        let char = describe(measurement.charRect)
        let candidate = describe(measurement.candidate)
        let line = "INFO SPIKE2 geometry case=\(measurement.name)"
            + " offset=\(measurement.offset)"
            + " upstream=\(measurement.upstream)"
            + " first=[\(native)] ref=[\(reference)] actual=\(actual)"
            + " char=[\(char)] candidate=[\(candidate)] \(verdict)"
            + " \(measurement.note) \(measurement.debug)"
        log(line)
    }

    private static func probeLines(
        _ view: NSTextView
    ) -> [(start: Int, end: Int, text: String)] {
        guard let layout = view.textLayoutManager,
              let content = layout.textContentManager else { return [] }
        layout.ensureLayout(for: content.documentRange)
        var lines: [(Int, Int, String)] = []
        layout.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { fragment in
            let fragmentStart = content.offset(
                from: content.documentRange.location,
                to: fragment.rangeInElement.location
            )
            for line in fragment.textLineFragments {
                let start = fragmentStart + line.characterRange.location
                lines.append(
                    (
                        start,
                        start + line.characterRange.length,
                        line.attributedString.string
                    )
                )
            }
            return true
        }
        return lines
    }

    private static func runGeometryParity() {
        let mono = "a\tb\n"
            + String(repeating: "wrap-word ", count: 24) + "\n"
            + "alpha\n"
            + "שלום עולם\n"
        let monoFont = NSFont.monospacedSystemFont(
            ofSize: Preferences.editorFontSize,
            weight: .regular
        )
        var probes: [(window: NSWindow, view: MultiCursorProbeTextView)] = []
        var measurements: [MCGeometryMeasurement] = []

        let monoProbe = makeProbeTextView(mono, font: monoFont)
        probes.append(monoProbe)
        monoProbe.window.makeKeyAndOrderFront(nil)
        monoProbe.view.layoutSubtreeIfNeeded()
        let ns = mono as NSString
        let containerWidth = monoProbe.view.textContainer?.size.width ?? -1
        let inset = monoProbe.view.textContainerInset
        log(
            "INFO SPIKE2 geometry container frame="
                + "\(monoProbe.view.frame.width)x\(monoProbe.view.frame.height)"
                + " container=\(containerWidth)"
                + " inset=\(inset.width)/\(inset.height)"
        )
        for line in probeLines(monoProbe.view).prefix(10) {
            let text = line.text
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
            log(
                "INFO SPIKE2 geometry line start=\(line.start)"
                    + " end=\(line.end) text=\"\(text.prefix(40))\""
            )
        }

        let tabOffset = ns.range(of: "\tb").location + 1
        measurements.append(
            measureGeometry(
                "tab",
                view: monoProbe.view,
                offset: tabOffset,
                upstream: false,
                gated: true
            )
        )

        let lines = probeLines(monoProbe.view)
        // A wrapped line continues at the next line's start and does not end
        // with a newline in the document. The fragment's attributed string
        // may carry the paragraph terminator even for a wrapped line, so the
        // document text is the authority.
        func hardBreak(_ index: Int) -> Bool {
            let end = lines[index].end
            return end > 0 && ns.character(at: end - 1) == 0x0A
        }
        let adjacent = lines.indices.dropLast().filter {
            lines[$0].end == lines[$0 + 1].start
        }
        log(
            "INFO SPIKE2 geometry wrap lines=\(lines.count) adjacent="
                + adjacent.map {
                    "\(lines[$0].end):\(hardBreak($0) ? 1 : 0)"
                }.joined(separator: ",")
        )
        if let index = lines.indices.dropLast().first(where: { index in
            lines[index].end == lines[index + 1].start
                && !hardBreak(index)
        }) {
            let wrapEnd = lines[index].end
            let nextStart = lines[index + 1].start
            measurements.append(
                measureGeometry(
                    "wrapped-end",
                    view: monoProbe.view,
                    offset: wrapEnd - 1,
                    upstream: true,
                    gated: true
                )
            )
            measurements.append(
                measureGeometry(
                    "wrapped-next",
                    view: monoProbe.view,
                    offset: nextStart + 1,
                    upstream: false,
                    gated: true
                )
            )
            measurements.append(
                measureGeometry(
                    "wrap-boundary-upstream",
                    view: monoProbe.view,
                    offset: wrapEnd,
                    upstream: true,
                    gated: false
                )
            )
            measurements.append(
                measureGeometry(
                    "wrap-boundary-downstream",
                    view: monoProbe.view,
                    offset: wrapEnd,
                    upstream: false,
                    gated: false
                )
            )
        } else {
            measurements.append(
                MCGeometryMeasurement(
                    name: "wrapped-line",
                    offset: -1,
                    upstream: false,
                    gated: true,
                    native: nil,
                    nativeActual: nil,
                    reference: nil,
                    charRect: nil,
                    candidate: nil,
                    note: "no soft wrap found",
                    debug: ""
                )
            )
        }

        let alphaEnd = ns.range(of: "alpha").location + "alpha".utf16.count
        measurements.append(
            measureGeometry(
                "trailing-newline",
                view: monoProbe.view,
                offset: alphaEnd,
                upstream: true,
                gated: true
            )
        )
        measurements.append(
            measureGeometry(
                "empty-last-line",
                view: monoProbe.view,
                offset: ns.length,
                upstream: true,
                gated: true
            )
        )

        let rtl = ns.range(of: "שלום עולם")
        if rtl.location != NSNotFound {
            measurements.append(
                measureGeometry(
                    "rtl",
                    view: monoProbe.view,
                    offset: rtl.location + 4,
                    upstream: true,
                    gated: true
                )
            )
        } else {
            measurements.append(
                MCGeometryMeasurement(
                    name: "rtl",
                    offset: -1,
                    upstream: false,
                    gated: true,
                    native: nil,
                    nativeActual: nil,
                    reference: nil,
                    charRect: nil,
                    candidate: nil,
                    note: "rtl run missing",
                    debug: ""
                )
            )
        }

        // token-exempt: E2E probe ligature font, not product design
        let ligatureFont = NSFont(name: "Times New Roman", size: 14)
            ?? monoFont
        let ligatureProbe = makeProbeTextView(
            "office fit",
            font: ligatureFont
        )
        probes.append(ligatureProbe)
        ligatureProbe.window.makeKeyAndOrderFront(nil)
        ligatureProbe.view.layoutSubtreeIfNeeded()
        measurements.append(
            measureGeometry(
                "ligature",
                view: ligatureProbe.view,
                offset: 3,
                upstream: false,
                gated: true,
                note: "font=\(ligatureFont.fontName)"
            )
        )

        for measurement in measurements {
            logGeometry(measurement)
        }
        let gated = measurements.filter(\.gated)
        let failed = gated.filter { !$0.passed }
        if gated.count >= 6, failed.isEmpty {
            log(
                "PASS SPIKE2 geometry cases=\(gated.count)"
                    + " tolerance=\(geometryTolerance)"
            )
        } else {
            log(
                "FAIL SPIKE2 geometry cases=\(gated.count)"
                    + " failed=[\(failed.map(\.name).joined(separator: ","))]"
            )
        }
        for probe in probes {
            probe.window.orderOut(nil)
            probe.window.close()
        }
    }

    // MARK: Composition span capture

    private static func runCompositionProbe() async {
        let monoFont = NSFont.monospacedSystemFont(
            ofSize: Preferences.editorFontSize,
            weight: .regular
        )
        let probe = makeProbeTextView("alpha beta gamma", font: monoFont)
        probe.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        probe.window.makeFirstResponder(probe.view)
        probe.view.setSelectedRange(NSRange(location: 0, length: 0))
        try? await Task.sleep(for: .milliseconds(150))

        guard let input = await preparePinyinSource(
            prefix: "SPIKE2 composition"
        ) else {
            probe.window.close()
            return
        }
        let activeID = input.activeID
        let activeIsPinyin = input.activeIsPinyin

        let before = probe.view.string
        probe.view.compositionEvents.removeAll()
        let trusted = AXIsProcessTrusted()
        var driver = "none"
        if activeIsPinyin {
            let codes: [CGKeyCode] = [45, 34, 4, 0, 31, 49, 36]
            if trusted {
                driver = "cgevent"
                await typeKeys(codes)
            } else {
                driver = "nsevent"
                typeKeysThroughWindow(codes, window: probe.window)
                try? await Task.sleep(for: .milliseconds(1_200))
            }
        }
        let after = probe.view.string
        let events = probe.view.compositionEvents
        let marked = events.contains {
            $0.kind == "setMarkedText" && !$0.marked.isEmpty
        }
        let committed = containsCJK(after) && after != before
        let span = compositionSpan(events)
        let delta = deltaSpan(before: before, after: after)
        var spanMatches = false
        if let span, let delta {
            spanMatches = span.location == delta.location
                && span.length == delta.length
        }
        log(
            "INFO SPIKE2 composition utf16=\(utf16Count(before))->\(utf16Count(after))"
                + " events=\(events.count) marked=\(marked)"
                + " committed=\(committed) span=\(describe(span))"
                + " delta=\(describe(delta)) trusted=\(trusted)"
        )
        for event in events.prefix(10) {
            log(
                "INFO SPIKE2 composition event \(event.kind)"
                    + " marked=\(event.marked.utf16.count)"
                    + " selected=\(describe(event.selectedRange))"
                    + " replacement=\(describe(event.replacementRange))"
                    + " selectionBefore=\(describe(event.selectionBefore))"
            )
        }

        // A composition whose explicit replacement range differs from the
        // selection: the exact case the plan's IME translation depends on.
        let explicit = makeProbeTextView("alpha beta gamma", font: monoFont)
        explicit.window.orderFront(nil)
        explicit.window.makeFirstResponder(explicit.view)
        explicit.view.setSelectedRange(NSRange(location: 0, length: 0))
        explicit.view.compositionEvents.removeAll()
        let target = NSRange(location: 6, length: 4)
        explicit.view.setMarkedText(
            "に",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: target
        )
        explicit.view.insertText(
            "日本",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let explicitEvent = explicit.view.compositionEvents.first {
            $0.kind == "setMarkedText" && $0.replacementRange == target
        }
        let explicitOK = explicit.view.string == "alpha 日本 gamma"
            && explicitEvent != nil
            && explicitEvent?.selectionBefore
                == NSRange(location: 0, length: 0)
        log(
            "INFO SPIKE2 composition explicit source=\(explicit.view.string)"
                + " event=\(explicitEvent != nil)"
        )

        // Cancellation must produce an observable completion path even though
        // the document text does not change.
        let cancel = makeProbeTextView("alpha beta gamma", font: monoFont)
        cancel.window.orderFront(nil)
        cancel.view.compositionEvents.removeAll()
        cancel.view.setMarkedText(
            "に",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: target
        )
        // An empty commit is the cancellation path the controller translates:
        // it ends marked mode AND removes the text the composition replaced.
        // That is AppKit's own model for an explicit replacement range —
        // measured here as "alpha に gamma" -> "alpha  gamma" — and a marked
        // check alone passed even when the commit removed nothing, so assert
        // the postimage as well.
        cancel.view.insertText(
            "",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let cancelMarked = cancel.view.hasMarkedText()
        let cancelApplied = !cancelMarked
            && cancel.view.string == "alpha  gamma"
        let cancelObserved = cancel.view.compositionEvents.contains {
            $0.kind == "insertText" && $0.marked.isEmpty
        }
        log(
            "INFO SPIKE2 composition cancel source=\(cancel.view.string)"
                + " marked=\(cancelMarked)"
        )

        restoreInputSource(input, prefix: "SPIKE2 composition")

        let passed = activeIsPinyin && marked && committed && spanMatches
            && explicitOK && cancelApplied && cancelObserved
        log(
            (passed ? "PASS" : "FAIL")
                + " SPIKE2 composition source=\(activeID)"
                + " driver=\(driver) marked=\(marked)"
                + " committed=\(committed) spanMatches=\(spanMatches)"
                + " explicit=\(explicitOK)"
                + " cancel=\(cancelApplied)/\(cancelObserved)"
        )
        for view in [probe, explicit, cancel] {
            view.window.orderOut(nil)
            view.window.close()
        }
    }

    private struct ProbeInputSource {
        let source: TISInputSource
        let previous: TISInputSource?
        let enabledForProbe: Bool
        let activeID: String
        let activeIsPinyin: Bool
    }

    /// Selects a Pinyin input method for the probe, enabling one if every
    /// candidate is disabled. The caller restores the previous source.
    private static func preparePinyinSource(
        prefix: String
    ) async -> ProbeInputSource? {
        let previous = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let previousID = previous.flatMap(inputSourceID) ?? "unknown"
        let candidates = pinyinInputSources()
        log(
            "INFO \(prefix) previous=\(previousID) candidates="
                + candidates.map { source in
                    (inputSourceID(source) ?? "?")
                        + "(enabled=\(isEnabledInputSource(source))"
                        + ",selectable=\(isSelectCapable(source)))"
                }.joined(separator: ",")
        )
        var enabledForProbe = false
        let pinyin: TISInputSource
        if let ready = candidates.first(where: {
            isEnabledInputSource($0) && isSelectCapable($0)
        }) {
            pinyin = ready
        } else if let candidate = candidates.first(where: isSelectCapable) {
            let enableStatus = TISEnableInputSource(candidate)
            enabledForProbe = enableStatus == noErr
            log("INFO \(prefix) enable status=\(enableStatus)")
            guard enabledForProbe else {
                log("FAIL \(prefix) reason=pinyin source not enabled")
                return nil
            }
            pinyin = candidate
        } else {
            log("FAIL \(prefix) reason=no selectable pinyin source")
            return nil
        }
        let pinyinID = inputSourceID(pinyin) ?? "unknown"
        let selectStatus = TISSelectInputSource(pinyin)
        try? await Task.sleep(for: .milliseconds(400))
        let activeID = currentInputSourceID()
        log(
            "INFO \(prefix) selected=\(pinyinID)"
                + " status=\(selectStatus) active=\(activeID)"
        )
        return ProbeInputSource(
            source: pinyin,
            previous: previous,
            enabledForProbe: enabledForProbe,
            activeID: activeID,
            activeIsPinyin: isPinyinID(activeID)
        )
    }

    private static func restoreInputSource(
        _ state: ProbeInputSource,
        prefix: String
    ) {
        if state.enabledForProbe {
            let disableStatus = TISDisableInputSource(state.source)
            log("INFO \(prefix) disabled=\(disableStatus)")
        }
        if let previous = state.previous {
            TISSelectInputSource(previous)
        }
        let restoredID = currentInputSourceID()
        log("INFO \(prefix) restored=\(restoredID)")
    }

    private static func typeKeys(_ codes: [CGKeyCode]) async {
        let source = CGEventSource(stateID: .hidSystemState)
        for code in codes {
            for down in [true, false] {
                if let event = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: code,
                    keyDown: down
                ) {
                    event.post(tap: .cghidEventTap)
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        try? await Task.sleep(for: .milliseconds(900))
    }

    private static func typeKeysThroughWindow(
        _ codes: [UInt16],
        window: NSWindow
    ) {
        for code in codes {
            for down in [true, false] {
                guard let event = NSEvent.keyEvent(
                    with: down ? .keyDown : .keyUp,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: "",
                    charactersIgnoringModifiers: "",
                    isARepeat: false,
                    keyCode: code
                ) else { continue }
                window.sendEvent(event)
            }
            usleep(80_000)
        }
    }

    private static func inputSourceID(_ source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceID
        ) else { return nil }
        return Unmanaged<CFString>
            .fromOpaque(pointer)
            .takeUnretainedValue() as String
    }

    private static func currentInputSourceID() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?
            .takeRetainedValue() else { return "unknown" }
        return inputSourceID(source) ?? "unknown"
    }

    private static func pinyinInputSources() -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, true)?
            .takeRetainedValue() else { return [] }
        let sources = (list as? [TISInputSource]) ?? []
        return sources.filter { source in
            guard let id = inputSourceID(source) else { return false }
            return isPinyinID(id) && isInputMethodSource(source)
        }
    }

    private static func stringProperty(
        _ source: TISInputSource,
        _ key: CFString
    ) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        return Unmanaged<CFString>
            .fromOpaque(pointer)
            .takeUnretainedValue() as String
    }

    private static func isInputMethodSource(_ source: TISInputSource) -> Bool {
        guard let type = stringProperty(
            source,
            kTISPropertyInputSourceType
        ) else { return false }
        return type.lowercased().contains("input")
    }

    private static func isSelectCapable(_ source: TISInputSource) -> Bool {
        guard let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceIsSelectCapable
        ) else { return false }
        return Unmanaged<CFBoolean>
            .fromOpaque(pointer)
            .takeUnretainedValue() == kCFBooleanTrue
    }

    private static func isPinyinID(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("pinyin") || lower.contains("scim.itabc")
    }

    private static func isEnabledInputSource(_ source: TISInputSource) -> Bool {
        guard let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceIsEnabled
        ) else { return false }
        return Unmanaged<CFBoolean>
            .fromOpaque(pointer)
            .takeUnretainedValue() == kCFBooleanTrue
    }

    private static func compositionSpan(
        _ events: [MCCompositionEvent]
    ) -> NSRange? {
        for event in events where event.kind == "setMarkedText"
            || event.kind == "insertText" {
            if event.replacementRange.location != NSNotFound {
                return event.replacementRange
            }
            if event.selectionBefore.location != NSNotFound {
                return event.selectionBefore
            }
        }
        return nil
    }

    private static func deltaSpan(before: String, after: String) -> NSRange? {
        let old = before as NSString
        let new = after as NSString
        guard old.length != new.length || !old.isEqual(to: new as String) else {
            return nil
        }
        let limit = min(old.length, new.length)
        var prefix = 0
        while prefix < limit,
              old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < limit - prefix,
              old.character(at: old.length - 1 - suffix)
                == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }
        return NSRange(
            location: prefix,
            length: old.length - prefix - suffix
        )
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    private static func utf16Count(_ text: String) -> Int {
        (text as NSString).length
    }

    private static func describe(_ range: NSRange?) -> String {
        guard let range else { return "nil" }
        if range.location == NSNotFound { return "not-found" }
        return "\(range.location)+\(range.length)"
    }

    // MARK: Echo rule

    private static func runEchoProbe() async {
        let monoFont = NSFont.monospacedSystemFont(
            ofSize: Preferences.editorFontSize,
            weight: .regular
        )
        let probe = makeProbeTextView(
            "alpha beta gamma delta epsilon",
            font: monoFont
        )
        probe.window.makeKeyAndOrderFront(nil)
        probe.window.makeFirstResponder(probe.view)
        let model = ProbeEchoModel(offsets: [0, 6, 11], primary: 1)
        NotificationCenter.default.addObserver(
            model,
            selector: #selector(ProbeEchoModel.selectionChanged(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: probe.view
        )
        defer {
            NotificationCenter.default.removeObserver(model)
            probe.window.orderOut(nil)
            probe.window.close()
        }

        probe.view.setSelectedRange(model.primaryRange)
        let echo = model.collapses == 0 && model.offsets.count == 3

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            probe.view.setSelectedRange(model.primaryRange)
        }
        try? await Task.sleep(for: .milliseconds(300))
        let restored = model.collapses == 0 && model.offsets.count == 3

        let firstBatch = applyProbeBatch(
            view: probe.view,
            model: model,
            insertion: "X"
        )
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            probe.view.setSelectedRange(model.primaryRange)
        }
        try? await Task.sleep(for: .milliseconds(300))
        let survivedFirst = model.collapses == 0 && model.offsets.count == 3

        let secondBatch = applyProbeBatch(
            view: probe.view,
            model: model,
            insertion: "Y"
        )
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            probe.view.setSelectedRange(model.primaryRange)
        }
        try? await Task.sleep(for: .milliseconds(300))
        let survivedSecond = model.collapses == 0 && model.offsets.count == 3

        probe.view.setSelectedRange(NSRange(location: 20, length: 0))
        let collapsed = model.collapses >= 1 && model.offsets.count == 1

        log(
            "INFO SPIKE2 echo source=\(probe.view.string)"
                + " offsets=\(model.offsets) collapses=\(model.collapses)"
                + " batches=\(firstBatch)/\(secondBatch)"
        )
        let passed = echo && restored && survivedFirst && survivedSecond
            && collapsed && firstBatch && secondBatch
        if passed {
            log("PASS SPIKE2 echo carets=3 batches=2 collapses=\(model.collapses)")
        } else {
            log(
                "FAIL SPIKE2 echo echo=\(echo) restored=\(restored)"
                    + " first=\(survivedFirst) second=\(survivedSecond)"
                    + " userCollapse=\(collapsed)"
                    + " collapses=\(model.collapses)"
            )
        }
    }

    private static func applyProbeBatch(
        view: NSTextView,
        model: ProbeEchoModel,
        insertion: String
    ) -> Bool {
        let offsets = model.offsets.sorted()
        guard !offsets.isEmpty,
              let storage = view.textStorage,
              offsets.allSatisfy({ $0 >= 0 && $0 <= storage.length })
        else { return false }
        var shifted: [Int] = []
        var accumulated = 0
        for offset in offsets {
            accumulated += insertion.utf16.count
            shifted.append(offset + accumulated)
        }
        model.offsets = shifted
        model.suppressing = true
        storage.beginEditing()
        for offset in offsets.reversed() {
            storage.replaceCharacters(
                in: NSRange(location: offset, length: 0),
                with: insertion
            )
        }
        storage.endEditing()
        view.setSelectedRange(model.primaryRange)
        view.didChangeText()
        model.suppressing = false
        return true
    }

    // MARK: - MC-03 overlay and selection painting

    private static func runMultiCursorCaretChecks() {
        runProductCaretParity()
        runSelectionBackgroundProbe()
    }

    /// Parity for the product geometry (`CaretGeometry`) against the same
    /// glyph-derived reference the MC-00 probe established.
    private static func runProductCaretParity() {
        let mono = "a\tb\n"
            + String(repeating: "wrap-word ", count: 24) + "\n"
            + "alpha\n"
            + "שלום עולם\n"
        let monoFont = NSFont.monospacedSystemFont(
            ofSize: Preferences.editorFontSize,
            weight: .regular
        )
        let probe = makeProbeTextView(mono, font: monoFont)
        probe.window.makeKeyAndOrderFront(nil)
        probe.view.layoutSubtreeIfNeeded()
        let ns = mono as NSString
        let lines = probeLines(probe.view)
        func hardBreak(_ index: Int) -> Bool {
            let end = lines[index].end
            return end > 0 && ns.character(at: end - 1) == 0x0A
        }
        guard let wrap = lines.indices.dropLast().first(where: {
            lines[$0].end == lines[$0 + 1].start && !hardBreak($0)
        }), let rtl = Optional(ns.range(of: "שלום עולם")),
              rtl.location != NSNotFound else {
            log("FAIL mc caret parity reason=fixture shape")
            probe.window.close()
            return
        }
        let cases: [(name: String, offset: Int, upstream: Bool)] = [
            ("tab", ns.range(of: "\tb").location + 1, false),
            ("wrapped-end", lines[wrap].end - 1, true),
            ("wrapped-next", lines[wrap + 1].start + 1, false),
            ("trailing-newline", ns.range(of: "alpha").location + 5, true),
            ("empty-last-line", ns.length, true),
            ("rtl", rtl.location + 4, true)
        ]
        var passed = 0
        for item in cases {
            if checkCaretParity(
                item.name,
                view: probe.view,
                offset: item.offset,
                upstream: item.upstream
            ) {
                passed += 1
            }
        }
        // token-exempt: E2E probe ligature font, not product design
        let ligatureFont = NSFont(name: "Times New Roman", size: 14)
            ?? monoFont
        let ligature = makeProbeTextView("office fit", font: ligatureFont)
        ligature.window.makeKeyAndOrderFront(nil)
        ligature.view.layoutSubtreeIfNeeded()
        if checkCaretParity(
            "ligature",
            view: ligature.view,
            offset: 3,
            upstream: false
        ) {
            passed += 1
        }
        let total = 7
        log(
            (passed == total ? "PASS" : "FAIL")
                + " mc caret parity \(passed)/\(total)"
        )
        for view in [probe, ligature] {
            view.window.orderOut(nil)
            view.window.close()
        }
    }

    private static func checkCaretParity(
        _ name: String,
        view: MultiCursorProbeTextView,
        offset: Int,
        upstream: Bool
    ) -> Bool {
        let native = nativeCaretRect(view, at: offset)
        guard let reference = nativeReferenceRect(
            view,
            at: offset,
            firstRect: native.rect
        ), let rect = CaretGeometry.rect(
            at: offset,
            upstream: upstream,
            in: view
        ) else {
            log("INFO mc caret \(name) offset=\(offset) missing")
            return false
        }
        let dx = abs(rect.minX - reference.minX)
        let dy = abs(rect.minY - reference.minY)
        let dh = abs(rect.height - reference.height)
        let ok = dx <= geometryTolerance
            && dy <= geometryTolerance
            && dh <= geometryTolerance
        log(
            "INFO mc caret \(name) offset=\(offset)"
                + " dx=\(String(format: "%.2f", dx))"
                + " dy=\(String(format: "%.2f", dy))"
                + " dh=\(String(format: "%.2f", dh))"
                + " \(ok ? "ok" : "MISMATCH")"
        )
        return ok
    }

    private static func runSelectionBackgroundProbe() {
        let text = "alpha beta gamma"
        let storage = NSTextStorage(string: text)
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(
                ofSize: Preferences.editorFontSize,
                weight: .regular
            ),
            .foregroundColor: NSColor.labelColor
        ]
        let full = NSRange(location: 0, length: (text as NSString).length)
        storage.setAttributes(base, range: full)
        let cellColor = NSColor.systemYellow
        let selectionColor = AppTheme.MultiCursor.selectionColor
        let cell = MarkdownDecoration(
            layer: .cell,
            range: NSRange(location: 0, length: 10),
            attributes: [.backgroundColor: cellColor]
        )
        let selection = MarkdownDecoration(
            layer: .selection,
            range: NSRange(location: 4, length: 4),
            attributes: [.backgroundColor: selectionColor]
        )
        MarkdownDecorationCompositor.apply(
            syntax: { _ in },
            decorations: MarkdownDecorationSet(
                cell: [cell],
                selection: [selection]
            ),
            to: storage,
            affectedRange: full,
            baseAttributes: base
        )
        func background(_ location: Int) -> NSColor? {
            storage.attribute(
                .backgroundColor,
                at: location,
                effectiveRange: nil
            ) as? NSColor
        }
        let wins = background(4) == selectionColor
            && background(0) == cellColor
            && background(8) == cellColor
        MarkdownDecorationCompositor.apply(
            syntax: { _ in },
            decorations: MarkdownDecorationSet(cell: [cell]),
            to: storage,
            affectedRange: full,
            baseAttributes: base
        )
        let clears = background(4) == cellColor
        log(
            (wins && clears ? "PASS" : "FAIL")
                + " mc selection background wins=\(wins) clears=\(clears)"
        )
    }

    // MARK: - MC-04 editing entry points

    private static func makeProbeEditor(
        source: String
    ) -> (document: MarkdownDocument, controller: MarkdownEditorController) {
        let document = MarkdownDocument(untitledWith: MarkdownFileStore())
        try? document.replaceSource(source)
        let cache = MarkdownEditorCache()
        let controller = cache.entry(
            for: document,
            parseCoordinator: MarkdownParseCoordinator(
                service: MarkdownParseService()
            ),
            parseDebounce: 0
        ).controller
        return (document, controller)
    }

    private static func probeModel(
        _ offsets: [Int],
        primary: Int = 0,
        source: String
    ) -> MultiCursorSelection? {
        try? MultiCursorSelection(
            offsets.map {
                MultiCursorSelection.Caret(anchor: $0, active: $0)
            },
            primary: primary,
            source: source
        )
    }

    private static func runMultiCursorEditingChecks() async {
        runTypingProbe()
        runDeleteProbe()
        runPasteCopyCutProbe()
        await runUndoProbe()
        runChokePointProbe()
        runNoOpProbe()
    }

    private static func runTypingProbe() {
        let source = "alpha beta gamma"
        let (document, controller) = makeProbeEditor(source: source)
        guard let model = probeModel([0, 6, 11], primary: 1, source: source)
        else {
            log("FAIL mc typing reason=model")
            return
        }
        controller.adoptMultiCursor(model)
        let revision = document.revision
        controller.textView.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let ok = controller.textView.string == "Xalpha Xbeta Xgamma"
            && controller.multiCursorSelection?.ranges
                == [1..<1, 8..<8, 14..<14]
            && document.revision == revision + 1
            && document.undoManager.canUndo
            && document.undoManager.undoActionName == "Typing"
        log(
            (ok ? "PASS" : "FAIL")
                + " mc typing source=\(controller.textView.string)"
                + " revisions=\(document.revision - revision)"
                + " undo=\(document.undoManager.undoActionName)"
        )
    }

    private static func runDeleteProbe() {
        let source = "abc def ghi"
        let (document, controller) = makeProbeEditor(source: source)
        guard let model = probeModel([3, 7, 11], source: source) else {
            log("FAIL mc delete reason=model")
            return
        }
        controller.adoptMultiCursor(model)
        let revision = document.revision
        let handled = controller.textView(
            controller.textView,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        )
        let ok = handled
            && controller.textView.string == "ab de gh"
            && controller.multiCursorSelection?.ranges
                == [2..<2, 5..<5, 8..<8]
            && document.revision == revision + 1
        log(
            (ok ? "PASS" : "FAIL")
                + " mc delete source=\(controller.textView.string)"
        )
    }

    /// The clipboard rows run on a scratch pasteboard injected into each
    /// controller. The probe used to snapshot and restore the general
    /// pasteboard, but a snapshot cannot materialise every representation,
    /// and an ignored restore failure destroyed the user's clipboard. The
    /// controller's clipboard is injectable, so the real one is never
    /// touched.
    private static func runPasteCopyCutProbe() {
        let source = "alpha beta gamma"
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("SonovoProbe.pasteCopyCut")
        )
        pasteboard.clearContents()

        let (_, pasteController) = makeProbeEditor(source: source)
        pasteController.clipboard = pasteboard
        guard let pasteModel = probeModel([0, 6], source: source) else {
            log("FAIL mc paste reason=model")
            return
        }
        pasteController.adoptMultiCursor(pasteModel)
        pasteboard.clearContents()
        pasteboard.setString("12", forType: .string)
        pasteController.textView.paste(nil)
        let pasteOK = pasteController.textView.string == "12alpha 12beta gamma"
        log(
            (pasteOK ? "PASS" : "FAIL")
                + " mc paste source=\(pasteController.textView.string)"
        )

        let (_, copyController) = makeProbeEditor(source: source)
        copyController.clipboard = pasteboard
        guard let copyModel = try? MultiCursorSelection(
            [
                MultiCursorSelection.Caret(anchor: 0, active: 5),
                MultiCursorSelection.Caret(anchor: 6, active: 10)
            ],
            primary: 0,
            source: source
        ) else {
            log("FAIL mc copy cut reason=model")
            return
        }
        copyController.adoptMultiCursor(copyModel)
        copyController.textView.copy(nil)
        let copied = pasteboard.string(forType: .string)
        // A distinct sentinel before the cut: the copy row left the expected
        // payload behind, so a cut that only deleted text still read as the
        // copied string.
        pasteboard.clearContents()
        pasteboard.setString("sentinel", forType: .string)
        copyController.textView.cut(nil)
        let cutCopied = pasteboard.string(forType: .string)
        let cutOK = copied == "alphabeta"
            && cutCopied == "alphabeta"
            && copyController.textView.string == "  gamma"
        log(
            (cutOK ? "PASS" : "FAIL")
                + " mc copy cut copied=\(copied ?? "nil")"
                + " cutCopied=\(cutCopied ?? "nil")"
                + " source=\(copyController.textView.string)"
        )
    }

    private static func runUndoProbe() async {
        let source = "alpha beta gamma"
        let (document, controller) = makeProbeEditor(source: source)
        guard let model = probeModel([0, 6, 11], primary: 1, source: source)
        else {
            log("FAIL mc undo reason=model")
            return
        }
        controller.adoptMultiCursor(model)
        controller.textView.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        // Both the model and the view must settle: the editor syncs from the
        // document in a separate MainActor task, so a fixed sleep could read
        // the model's new source beside the view's old text and pass a redo
        // that never reached the screen.
        document.undoManager.undo()
        let undone = await waitUntil(2) {
            document.source == source
                && controller.textView.string == source
        }
        document.undoManager.redo()
        let redone = await waitUntil(2) {
            document.source == "Xalpha Xbeta Xgamma"
                && controller.textView.string == "Xalpha Xbeta Xgamma"
        }
        log(
            (undone && redone ? "PASS" : "FAIL")
                + " mc undo undo=\(undone) redo=\(redone)"
        )
    }

    private static func runChokePointProbe() {
        let source = "alpha beta gamma"
        let (document, controller) = makeProbeEditor(source: source)
        guard let model = probeModel([0, 6, 11], source: source) else {
            log("FAIL mc choke point reason=model")
            return
        }
        controller.adoptMultiCursor(model)
        let revision = document.revision
        let refused = !controller.textView(
            controller.textView,
            shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementString: "Z"
        )
        let unchanged = controller.textView.string == source
            && controller.multiCursorSelection?.count == 3
            && document.revision == revision
        log(
            (refused && unchanged ? "PASS" : "FAIL")
                + " mc choke point refused=\(refused)"
                + " unchanged=\(unchanged)"
        )
    }

    private static func runNoOpProbe() {
        let source = "alpha beta"
        let (document, controller) = makeProbeEditor(source: source)
        guard let model = probeModel([0, 5], source: source) else {
            log("FAIL mc no-op reason=model")
            return
        }
        controller.adoptMultiCursor(model)
        let revision = document.revision
        let canUndo = document.undoManager.canUndo
        controller.textView.insertText(
            "",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let ok = document.revision == revision
            && document.undoManager.canUndo == canUndo
            && controller.textView.string == source
        log((ok ? "PASS" : "FAIL") + " mc no-op")
    }

    // MARK: - MC-05 IME translation

    private static func describeCarets(
        _ ranges: [Range<Int>]?
    ) -> String {
        guard let ranges else { return "nil" }
        return ranges
            .map { "\($0.lowerBound)+\($0.count)" }
            .joined(separator: ",")
    }

    private static func runMultiCursorIMEProbe() async {
        guard let prepared = await preparePinyinSource(prefix: "mc ime") else {
            log("FAIL mc ime source=pinyin reason=no input source")
            return
        }
        defer { restoreInputSource(prepared, prefix: "mc ime") }
        log(
            (prepared.activeIsPinyin ? "PASS" : "FAIL")
                + " mc ime source=pinyin active=\(prepared.activeID)"
        )
        guard prepared.activeIsPinyin else { return }

        let source = "alpha beta gamma"
        // The measured Pinyin shapes go through the same AppKit entry points
        // the input method uses. Hosting a controller-backed text view in a
        // probe window destabilises this macOS build (the app exits a few
        // seconds later), so the editor stays windowless; MC-00 verified the
        // real key path and recorded these shapes.
        log("INFO mc ime driver=measured-shapes")

        // Confirm: three carets, the primary at 6.
        let (confirmDocument, confirmController) = makeProbeEditor(
            source: source
        )
        guard let confirmModel = probeModel(
            [0, 6, 11],
            primary: 1,
            source: source
        ) else {
            log("FAIL mc ime confirm reason=model")
            return
        }
        confirmController.adoptMultiCursor(confirmModel)
        let revision = confirmDocument.revision
        confirmController.textView.setMarkedText(
            "に",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        confirmController.textView.insertText(
            "日本",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let after = confirmController.textView.string
        let delta = (after as NSString).length - (source as NSString).length
        let ranges = confirmController.multiCursorSelection?.ranges
        let expected = delta > 0
            ? [0..<0, 6 + delta..<6 + delta, 11 + delta..<11 + delta]
            : nil
        let primaryOK = confirmController.textView.selectedRange()
            == NSRange(location: 6 + delta, length: 0)
        let confirmOK = containsCJK(after)
            && delta > 0
            && after.hasPrefix("alpha ")
            && after.hasSuffix("beta gamma")
            && ranges == expected
            && primaryOK
            && confirmDocument.source == after
            && confirmDocument.revision == revision + 1
        log(
            (confirmOK ? "PASS" : "FAIL")
                + " mc ime confirm delta=\(delta)"
                + " source=\"\(after)\""
                + " carets=\(describeCarets(ranges))"
                + " revisions=\(confirmDocument.revision - revision)"
                + (confirmController.multiCursorSelection == nil
                    ? " fallback=collapse" : "")
        )

        // Cancel: the same composition, then an empty commit; nothing moves.
        let (cancelDocument, cancelController) = makeProbeEditor(
            source: source
        )
        guard let cancelModel = probeModel(
            [0, 6, 11],
            primary: 1,
            source: source
        ) else {
            log("FAIL mc ime cancel reason=model")
            return
        }
        cancelController.adoptMultiCursor(cancelModel)
        let cancelRevision = cancelDocument.revision
        cancelController.textView.setMarkedText(
            "に",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        cancelController.textView.insertText(
            "",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let cancelAfter = cancelController.textView.string
        let cancelRanges = cancelController.multiCursorSelection?.ranges
        let cancelOK = cancelAfter == source
            && cancelRanges == [0..<0, 6..<6, 11..<11]
            && cancelDocument.source == source
            && cancelDocument.revision == cancelRevision
        log(
            (cancelOK ? "PASS" : "FAIL")
                + " mc ime cancel source=\"\(cancelAfter)\""
                + " carets=\(describeCarets(cancelRanges))"
                + " revisions=\(cancelDocument.revision - cancelRevision)"
        )

        // Explicit replacement range: the input method names a span that
        // covers the secondary at 5. The primary moves natively; the covered
        // secondary is dropped.
        let (explicitDocument, explicitController) = makeProbeEditor(
            source: source
        )
        guard let explicitModel = probeModel(
            [0, 5, 6],
            primary: 2,
            source: source
        ) else {
            log("FAIL mc ime explicit range reason=model")
            return
        }
        explicitController.adoptMultiCursor(explicitModel)
        explicitController.textView.setMarkedText(
            "に",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: 4, length: 3)
        )
        explicitController.textView.insertText(
            "日本",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let explicitAfter = explicitController.textView.string
        let explicitRanges = explicitController.multiCursorSelection?.ranges
        let explicitOK = explicitAfter == "alph日本eta gamma"
            && explicitRanges == [0..<0, 6..<6]
            && explicitDocument.source == explicitAfter
        log(
            (explicitOK ? "PASS" : "FAIL")
                + " mc ime explicit range source=\"\(explicitAfter)\""
                + " carets=\(describeCarets(explicitRanges))"
        )
    }

    // MARK: - MC-06 movement

    private static func configureMovementProbe(
        _ controller: MarkdownEditorController
    ) {
        // token-exempt: E2E probe measurement surface, not product design
        let width: CGFloat = 400
        // token-exempt: E2E probe measurement surface, not product design
        let height: CGFloat = 400
        controller.textView.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: height
        )
        controller.textView.textContainer?.widthTracksTextView = false
        controller.textView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private static func runMovementCommand(
        _ controller: MarkdownEditorController,
        _ selector: Selector
    ) -> Bool {
        controller.textView(controller.textView, doCommandBy: selector)
    }

    private static func runMultiCursorMovementProbe() {
        let source = "abcdefghij\nabcdefghij\nabcdefghij\nabc"
        let (document, controller) = makeProbeEditor(source: source)
        configureMovementProbe(controller)
        guard let model = probeModel(
            [2, 5, 8, 13, 16],
            primary: 0,
            source: source
        ) else {
            log("FAIL mc move reason=model")
            return
        }
        controller.adoptMultiCursor(model)
        let revision = document.revision
        let canUndo = document.undoManager.canUndo

        _ = runMovementCommand(
            controller,
            #selector(NSResponder.moveDown(_:))
        )
        let down1 = controller.multiCursorSelection?.ranges
        _ = runMovementCommand(
            controller,
            #selector(NSResponder.moveDown(_:))
        )
        let down2 = controller.multiCursorSelection?.ranges
        _ = runMovementCommand(
            controller,
            #selector(NSResponder.moveUp(_:))
        )
        let up = controller.multiCursorSelection?.ranges

        let moveOK = down1 == [13..<13, 16..<16, 19..<19, 24..<24, 27..<27]
            && down2 == [24..<24, 27..<27, 30..<30, 35..<35, 36..<36]
            && up == down1
            && document.revision == revision
            && document.undoManager.canUndo == canUndo
        log(
            (moveOK ? "PASS" : "FAIL")
                + " mc move down1=\(describeCarets(down1))"
                + " down2=\(describeCarets(down2))"
                + " up=\(describeCarets(up))"
        )

        // The goal column survives the short last line and returns with Up:
        // column 5 on line 2 -> clamped to the end of "abc" -> back to 5.
        let (_, columnController) = makeProbeEditor(source: source)
        configureMovementProbe(columnController)
        guard let columnModel = probeModel(
            [8, 27],
            primary: 0,
            source: source
        ) else {
            log("FAIL mc move column reason=model")
            return
        }
        columnController.adoptMultiCursor(columnModel)
        _ = runMovementCommand(
            columnController,
            #selector(NSResponder.moveDown(_:))
        )
        let columnA = columnController.multiCursorSelection?.ranges
        _ = runMovementCommand(
            columnController,
            #selector(NSResponder.moveDown(_:))
        )
        let columnB = columnController.multiCursorSelection?.ranges
        _ = runMovementCommand(
            columnController,
            #selector(NSResponder.moveUp(_:))
        )
        let columnC = columnController.multiCursorSelection?.ranges
        let columnOK = columnA == [19..<19, 36..<36]
            && columnB == [30..<30, 36..<36]
            && columnC == [19..<19, 27..<27]
        log(
            (columnOK ? "PASS" : "FAIL")
                + " mc move column a=\(describeCarets(columnA))"
                + " b=\(describeCarets(columnB))"
                + " c=\(describeCarets(columnC))"
        )

        // Shift extends every caret from its own anchor; Escape collapses.
        let (anchorDocument, anchorController) = makeProbeEditor(source: source)
        configureMovementProbe(anchorController)
        guard let anchorModel = probeModel(
            [2, 13, 24],
            primary: 1,
            source: source
        ) else {
            log("FAIL mc move anchor reason=model")
            return
        }
        anchorController.adoptMultiCursor(anchorModel)
        let anchorRevision = anchorDocument.revision
        let anchorUndo = anchorDocument.undoManager.canUndo
        _ = runMovementCommand(
            anchorController,
            #selector(NSResponder.moveRightAndModifySelection(_:))
        )
        let extended = anchorController.multiCursorSelection
        _ = runMovementCommand(
            anchorController,
            #selector(NSResponder.moveLeftAndModifySelection(_:))
        )
        let contracted = anchorController.multiCursorSelection
        let anchors = extended?.carets.map(\.anchor)
        let anchorOK = extended?.ranges == [2..<3, 13..<14, 24..<25]
            && anchors == [2, 13, 24]
            && contracted?.ranges == [2..<2, 13..<13, 24..<24]
            && anchorDocument.revision == anchorRevision
            && anchorDocument.undoManager.canUndo == anchorUndo
        anchorController.textView.cancelOperation(nil)
        let collapsed = anchorController.multiCursorSelection == nil
            && anchorController.textView.selectedRange()
                == NSRange(location: 13, length: 0)
        log(
            (anchorOK && collapsed ? "PASS" : "FAIL")
                + " mc move anchor extended=\(describeCarets(extended?.ranges))"
                + " anchors=\(anchors.map { $0.map(String.init).joined(separator: ",") } ?? "nil")"
                + " collapsed=\(collapsed)"
        )
    }
    // MARK: - MC-07 placement gestures

    /// The view point of the caret before `offset`, from the same layout
    /// fragments the line provider reads.
    private static func placementPoint(
        forOffset offset: Int,
        in textView: NSTextView
    ) -> NSPoint? {
        guard let layout = textView.textLayoutManager,
              let content = layout.textContentManager else {
            return nil
        }
        layout.ensureLayout(for: content.documentRange)
        let inset = textView.textContainerInset
        var result: NSPoint?
        layout.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { fragment in
            let base = content.offset(
                from: content.documentRange.location,
                to: fragment.rangeInElement.location
            ) ?? 0
            for line in fragment.textLineFragments {
                let lower = base + line.characterRange.location
                let upper = lower + line.characterRange.length
                guard offset >= lower, offset <= upper else { continue }
                result = NSPoint(
                    x: fragment.layoutFragmentFrame.minX + inset.width
                        + line.locationForCharacter(at: offset - lower).x,
                    y: fragment.layoutFragmentFrame.minY + inset.height
                        + line.typographicBounds.midY
                )
                return false
            }
            return true
        }
        return result
    }

    /// A real Command-click event through the text view's override, so the
    /// modifier check and the controller callback are the paths under test.
    private static func placementClick(
        _ textView: NSTextView,
        at point: NSPoint
    ) -> Bool {
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: textView.convert(point, to: nil),
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            return false
        }
        textView.mouseDown(with: event)
        return true
    }

    private static func runMultiCursorPlacementProbe() {
        let source = "alpha beta gamma"
        let (document, controller) = makeProbeEditor(source: source)
        configureMovementProbe(controller)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let revision = document.revision
        var clicked = true
        for offset in [2, 7, 13] {
            guard let point = placementPoint(
                forOffset: offset,
                in: controller.textView
            ) else {
                log("FAIL mc placement reason=layout")
                return
            }
            clicked = clicked && placementClick(controller.textView, at: point)
        }
        let placed = controller.multiCursorSelection
        let rects = placed?.carets.map { caret -> String in
            guard let rect = CaretGeometry.rect(
                at: caret.active,
                upstream: true,
                in: controller.textView
            ) else { return "nil" }
            return "\(Int(rect.minX.rounded()))+\(Int(rect.height.rounded()))"
        }.joined(separator: ",") ?? "nil"
        // A second Command-click on an existing caret toggles it off.
        if let point = placementPoint(forOffset: 7, in: controller.textView) {
            clicked = clicked && placementClick(controller.textView, at: point)
        }
        let toggled = controller.multiCursorSelection
        let placementOK = clicked
            && placed?.ranges == [0..<0, 2..<2, 7..<7, 13..<13]
            && placed?.primaryRange == 13..<13
            && toggled?.ranges == [0..<0, 2..<2, 13..<13]
            && toggled?.primaryRange == 13..<13
            && controller.textView.selectedRange()
                == NSRange(location: 13, length: 0)
            && document.revision == revision
        log(
            (placementOK ? "PASS" : "FAIL")
                + " mc placement carets=\(describeCarets(placed?.ranges))"
                + " primary=\(placed.map { "\($0.primaryRange.lowerBound)+\($0.primaryRange.count)" } ?? "nil")"
                + " rects=\(rects)"
                + " toggled=\(describeCarets(toggled?.ranges))"
        )

        let occurrencesSource = "alpha beta alpha gamma alpha"
        let (occurrenceDocument, occurrenceController) = makeProbeEditor(
            source: occurrencesSource
        )
        occurrenceController.textView.setSelectedRange(
            NSRange(location: 2, length: 0)
        )
        let occurrenceRevision = occurrenceDocument.revision
        let added1 = occurrenceController.perform(.addNextOccurrence)
        let after1 = occurrenceController.multiCursorSelection?.ranges
        let added2 = occurrenceController.perform(.addNextOccurrence)
        let after2 = occurrenceController.multiCursorSelection?.ranges
        let refused = occurrenceController.perform(.addNextOccurrence)
        let after3 = occurrenceController.multiCursorSelection?.ranges

        let (allDocument, allController) = makeProbeEditor(
            source: occurrencesSource
        )
        allController.textView.setSelectedRange(
            NSRange(location: 13, length: 0)
        )
        let allRevision = allDocument.revision
        let selectedAll = allController.perform(.selectAllOccurrences)
        let allRanges = allController.multiCursorSelection?.ranges
        let allPrimary = allController.multiCursorSelection?.primaryRange
        let occurrencesOK = added1
            && after1 == [0..<5, 11..<16]
            && added2
            && after2 == [0..<5, 11..<16, 23..<28]
            && !refused
            && after3 == after2
            && selectedAll
            && allRanges == [0..<5, 11..<16, 23..<28]
            && allPrimary == 11..<16
            && occurrenceDocument.revision == occurrenceRevision
            && allDocument.revision == allRevision
        log(
            (occurrencesOK ? "PASS" : "FAIL")
                + " mc occurrences first=\(describeCarets(after1))"
                + " second=\(describeCarets(after2))"
                + " refused=\(!refused)"
                + " all=\(describeCarets(allRanges))"
                + " primary=\(allPrimary.map { "\($0.lowerBound)+\($0.count)" } ?? "nil")"
                + " revisions=\(occurrenceDocument.revision - occurrenceRevision)"
        )

        occurrenceController.textView.cancelOperation(nil)
        let collapsed = occurrenceController.multiCursorSelection == nil
            && occurrenceController.textView.selectedRange()
                == NSRange(location: 23, length: 5)
        log(
            (collapsed ? "PASS" : "FAIL")
                + " mc collapse carets=\(describeCarets(occurrenceController.multiCursorSelection?.ranges))"
                + " native=\(occurrenceController.textView.selectedRange().location)+\(occurrenceController.textView.selectedRange().length)"
        )
    }

    // MARK: - MC-10 latency gates

    /// A deterministic Markdown fixture of roughly `targetBytes`.
    private static func multiCursorFixture(targetBytes: Int) -> String {
        var builder = ""
        builder.reserveCapacity(targetBytes + 256)
        var index = 0
        while builder.utf8.count < targetBytes {
            builder += "Paragraph \(index) carries MARK text for the latency probe.\n\n"
            index += 1
        }
        return builder
    }

    private static func lineStartOffsets(in source: String) -> [Int] {
        let ns = source as NSString
        var starts: [Int] = []
        var cursor = 0
        while cursor < ns.length {
            starts.append(cursor)
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let next = NSMaxRange(line)
            guard next > cursor else { break }
            cursor = next
        }
        return starts
    }

    private static func percentile(
        _ values: [Double],
        _ fraction: Double
    ) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let raw = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(sorted.count - 1, max(0, raw))]
    }

    private static func milliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    /// Ensures layout for the caret's own line: the windowless proxy for the
    /// first visible draw. The probe cannot host a controller-backed text
    /// view in a window — the app exits a few seconds later on this macOS
    /// build (the MC-05 platform constraint) — so rasterisation is not
    /// measured; layout is the per-keystroke term that grows with the
    /// document, and the viewport is a fixed 400×400.
    private static func ensureLineLayout(
        at offset: Int,
        in textView: NSTextView
    ) {
        guard let layout = textView.textLayoutManager,
              let content = layout.textContentManager,
              let start = content.location(
                  content.documentRange.location,
                  offsetBy: min(
                      offset,
                      (textView.string as NSString).length
                  )
              ) else { return }
        layout.ensureLayout(for: NSTextRange(location: start))
    }

    private static func runMultiCursorBudgetProbe() async {
        let sizes: [(name: String, bytes: Int)] = [
            ("220KB", 220 * 1024),
            ("1MB", 1024 * 1024)
        ]
        let caretCounts = [1, 10, 100]
        var p50: [String: Double] = [:]
        var worstTurn = 0.0

        for size in sizes {
            let fixture = multiCursorFixture(targetBytes: size.bytes)
            let starts = lineStartOffsets(in: fixture)
            for offscreen in [false, true] {
                let placement = offscreen ? "offscreen" : "visible"
                for count in caretCounts {
                    guard starts.count >= count else {
                        log("FAIL mc budget \(size.name) \(placement) carets=\(count) reason=lines")
                        continue
                    }
                    let offsets = offscreen
                        ? Array(starts.suffix(count))
                        : Array(starts.prefix(count))
                    let (document, controller) = makeProbeEditor(source: fixture)
                    configureMovementProbe(controller)
                    if count > 1 {
                        guard let model = probeModel(
                            offsets,
                            source: fixture
                        ) else {
                            log("FAIL mc budget \(size.name) \(placement) carets=\(count) reason=model")
                            continue
                        }
                        controller.adoptMultiCursor(model)
                    } else {
                        controller.textView.setSelectedRange(
                            NSRange(location: offsets[0], length: 0)
                        )
                    }
                    var batches: [Double] = []
                    // The synchronous slice of each keystroke: insertion plus
                    // the layout its first visible draw needs. The probe
                    // cannot host the editor in a window (the MC-05
                    // constraint), so rasterisation is not measured; layout
                    // is the term that scales with the document.
                    var syncTurns: [Double] = []
                    // The 50 ms gate is per main-thread turn, and deferred
                    // work belongs to a turn too. The timer measures every
                    // runloop iteration's busy span (beforeSources to
                    // beforeWaiting), so a slow highlight pass on the last
                    // revision counts even though it runs after the batch.
                    let turnTimer = MainTurnTimer()
                    var refused = false
                    for _ in 0..<10 {
                        let lengthBefore = (controller.textView.string as NSString).length
                        let revisionBefore = document.revision
                        let start = CFAbsoluteTimeGetCurrent()
                        controller.textView.insertText(
                            "x",
                            replacementRange: NSRange(
                                location: NSNotFound,
                                length: 0
                            )
                        )
                        batches.append(milliseconds(since: start))
                        let caret = count > 1
                            ? (controller.multiCursorSelection?.primaryRange.lowerBound
                                ?? controller.textView.selectedRange().location)
                            : controller.textView.selectedRange().location
                        ensureLineLayout(at: caret, in: controller.textView)
                        syncTurns.append(milliseconds(since: start))
                        let grew = (controller.textView.string as NSString).length
                            == lengthBefore + count
                        if !grew || document.revision != revisionBefore + 1 {
                            refused = true
                            break
                        }
                        // One runloop turn between samples. Ten insertions
                        // back to back formed one long turn; the timer needs
                        // the deferred work to land in a measured iteration.
                        await Task.yield()
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                    let target = document.revision
                    let settled = await waitUntil(5) {
                        controller.lastHighlightedRevision == target
                    }
                    let maxTurn = turnTimer.maxBusyMS
                    guard !refused, batches.count == 10 else {
                        log("FAIL mc budget \(size.name) \(placement) carets=\(count) reason=batch")
                        continue
                    }
                    // Without the deferred pass the turn bound is unproven,
                    // not passed: an unfinished highlight contributes no
                    // measured turn.
                    guard settled else {
                        log("FAIL mc budget \(size.name) \(placement) carets=\(count) reason=settle")
                        continue
                    }
                    let cold = batches[0]
                    let warmed = Array(batches.dropFirst())
                    let p50Value = percentile(warmed, 0.5)
                    p50["\(size.name)-\(placement)-\(count)"] = p50Value
                    let maxValue = batches.max() ?? 0
                    // The turn bound includes the cold sample and every
                    // measured turn: a 100 ms cold insertion, or a slow
                    // deferred highlight, used to pass because only warmed
                    // insertions were counted. The synchronous slices are a
                    // lower bound even if the observer misses a span.
                    worstTurn = max(
                        worstTurn,
                        turnTimer.peakBusyMS,
                        syncTurns.max() ?? 0
                    )
                    log(
                        "PASS mc budget \(size.name) \(placement) carets=\(count)"
                            + " coldMS=\(String(format: "%.2f", cold))"
                            + " p50=\(String(format: "%.2f", p50Value))"
                            + " p95=\(String(format: "%.2f", percentile(warmed, 0.95)))"
                            + " max=\(String(format: "%.2f", maxValue))"
                            + " syncMax=\(String(format: "%.2f", syncTurns.max() ?? 0))"
                            + " turnMax=\(String(format: "%.2f", maxTurn))"
                            + " turns=\(turnTimer.turns)"
                    )
                }
            }
        }

        let singleVisible = p50["220KB-visible-1"] ?? 0
        let tenVisible = p50["220KB-visible-10"] ?? 0
        let hundredVisible = p50["220KB-visible-100"] ?? 0
        let singleOff = p50["220KB-offscreen-1"] ?? 0
        let tenOff = p50["220KB-offscreen-10"] ?? 0
        let hundredOff = p50["220KB-offscreen-100"] ?? 0
        let ratio10 = singleVisible > 0 ? tenVisible / singleVisible : .infinity
        let ratio100 = singleVisible > 0
            ? hundredVisible / singleVisible
            : .infinity
        let ratio10Off = singleOff > 0 ? tenOff / singleOff : .infinity
        let ratio100Off = singleOff > 0 ? hundredOff / singleOff : .infinity
        let latencyOK = ratio10 <= 1.5
            && ratio100 <= 3
            && ratio10Off <= 1.5
            && ratio100Off <= 3
        log(
            (latencyOK ? "PASS" : "FAIL")
                + " mc latency ratio10=\(String(format: "%.2f", ratio10))"
                + " ratio100=\(String(format: "%.2f", ratio100))"
                + " ratio10off=\(String(format: "%.2f", ratio10Off))"
                + " ratio100off=\(String(format: "%.2f", ratio100Off))"
        )
        let turnOK = worstTurn <= 50
        log(
            (turnOK ? "PASS" : "FAIL")
                + " mc turn 1mb maxMS=\(String(format: "%.2f", worstTurn))"
        )

        // Phase split for the slowest synchronous path: the engine, the whole
        // document update, and the storage bridge.
        for (name, bytes) in [("220KB", 220 * 1024), ("1MB", 1024 * 1024)] {
            let fixture = multiCursorFixture(targetBytes: bytes)
            let offsets = Array(lineStartOffsets(in: fixture).prefix(100))
            guard let model = probeModel(offsets, source: fixture) else {
                continue
            }
            var applyMS = 0.0
            for _ in 0..<10 {
                let start = CFAbsoluteTimeGetCurrent()
                _ = MultiCursorEdit.apply(
                    .insert("x"),
                    to: fixture,
                    selection: model
                )
                applyMS += milliseconds(since: start)
            }
            let (_, phaseController) = makeProbeEditor(source: fixture)
            configureMovementProbe(phaseController)
            phaseController.adoptMultiCursor(model)
            var totalMS = 0.0
            for _ in 0..<10 {
                let start = CFAbsoluteTimeGetCurrent()
                _ = phaseController.applyMultiCursor(.insert("x"))
                totalMS += milliseconds(since: start)
            }
            let bare = MarkdownDocument(untitledWith: MarkdownFileStore())
            try? bare.replaceSource(fixture)
            var toggle = false
            var replaceMS = 0.0
            for _ in 0..<10 {
                toggle.toggle()
                let start = CFAbsoluteTimeGetCurrent()
                try? bare.replaceSource(fixture + (toggle ? "x" : "y"))
                replaceMS += milliseconds(since: start)
            }
            var bridgeMS = 0.0
            for _ in 0..<10 {
                let start = CFAbsoluteTimeGetCurrent()
                _ = phaseController.textView.string.utf8.count
                bridgeMS += milliseconds(since: start)
            }
            log(
                "INFO mc phase \(name) apply=\(String(format: "%.2f", applyMS / 10))"
                    + " total=\(String(format: "%.2f", totalMS / 10))"
                    + " replace=\(String(format: "%.2f", replaceMS / 10))"
                    + " bridge=\(String(format: "%.2f", bridgeMS / 10))"
            )
        }

        // Highlight completion on the largest document: measured in runloop
        // turns (1 ms yields) from the batch until the highlighted revision
        // catches up. The post-output count must be at most two turns.
        let fixture = multiCursorFixture(targetBytes: 1024 * 1024)
        let starts = lineStartOffsets(in: fixture)
        let (document, controller) = makeProbeEditor(source: fixture)
        configureMovementProbe(controller)
        let offsets = Array(starts.prefix(100))
        guard let model = probeModel(offsets, source: fixture) else {
            log("FAIL mc highlight 1mb reason=model")
            return
        }
        controller.adoptMultiCursor(model)
        // The gate is defined in runloop turns, so count real ones: a
        // CFRunLoop observer at beforeSources fires once per iteration,
        // including iterations that process ready sources without sleeping.
        // The milestones are recorded by the controller's own callbacks at
        // the exact assignments; polling the published properties could see
        // publication and highlight after both had happened, making a
        // three-turn delay read as zero.
        let turnCounter = RunloopTurnCounter()
        var watchedRevision: UInt64 = 0
        var publishedTurn: Int?
        var highlightedTurn: Int?
        controller.onParsePublished = { revision in
            guard revision == watchedRevision, publishedTurn == nil else {
                return
            }
            publishedTurn = turnCounter.turns
        }
        controller.onHighlightApplied = { revision in
            guard revision == watchedRevision, highlightedTurn == nil else {
                return
            }
            highlightedTurn = turnCounter.turns
        }
        controller.textView.insertText(
            "x",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let revision = document.revision
        watchedRevision = revision
        var iterations = 0
        while iterations < 3000, highlightedTurn == nil {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
            iterations += 1
        }
        controller.onParsePublished = nil
        controller.onHighlightApplied = nil
        let highlighted = controller.lastHighlightedRevision == revision
        let outputObserved = publishedTurn != nil
        let highlightObserved = highlightedTurn != nil
        let turns = turnCounter.turns
        // Measured between the two real milestones. An unobserved milestone
        // is unknown, not zero: treating it as zero let a highlight that
        // arrived without a visible parse pass.
        let postOutput: Int
        if let publishedTurn, let highlightedTurn {
            postOutput = max(0, highlightedTurn - publishedTurn)
        } else {
            postOutput = .max
        }
        // If the loop waited at all, at least one turn must have been seen;
        // otherwise the instrumentation itself is broken and a zero would
        // read as a pass.
        let instrumented = iterations == 0 || turns > 0
        let highlightOK = highlighted && outputObserved && highlightObserved
            && instrumented && postOutput <= 2
        log(
            (highlightOK ? "PASS" : "FAIL")
                + " mc highlight 1mb turns=\(turns)"
                + " publishTurn=\(publishedTurn.map(String.init) ?? "nil")"
                + " postOutput=\(highlightObserved ? String(postOutput) : "nil")"
                + " observed=\(outputObserved)"
                + " highlighted=\(highlightObserved)"
                + " instrumented=\(instrumented)"
                + " revision=\(revision)"
        )
    }

    /// Measures the main thread's busy span in each runloop iteration: from
    /// the end of the previous wait (or the start of an iteration that never
    /// slept) to the next beforeWaiting, where the loop sleeps. The sleep
    /// itself is excluded: a task resumed after `afterWaiting` runs in that
    /// phase, before `beforeSources`, so a span measured from beforeSources
    /// alone read zero while the real main-actor work happened just before
    /// it (measured: turnMax=0.00 with the work clearly done).
    private final class MainTurnTimer {
        private(set) var maxBusyMS = 0.0
        private(set) var turns = 0
        private var busyStart: CFAbsoluteTime?
        private var observer: CFRunLoopObserver?

        /// The maximum including a span still open at the reading moment.
        var peakBusyMS: Double {
            guard let busyStart else { return maxBusyMS }
            return max(
                maxBusyMS,
                (CFAbsoluteTimeGetCurrent() - busyStart) * 1000
            )
        }

        init() {
            // The timer is installed mid-turn. Opening the span here charges
            // the current turn's remaining work — including the first
            // insertion — to it; waiting for the next phase would leave that
            // sample unmeasured.
            busyStart = CFAbsoluteTimeGetCurrent()
            var context = CFRunLoopObserverContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            observer = CFRunLoopObserverCreate(
                kCFAllocatorDefault,
                CFRunLoopActivity.afterWaiting.rawValue
                    | CFRunLoopActivity.beforeSources.rawValue
                    | CFRunLoopActivity.beforeWaiting.rawValue,
                true,
                0,
                { _, activity, info in
                    guard let info else { return }
                    let timer = Unmanaged<MainTurnTimer>
                        .fromOpaque(info)
                        .takeUnretainedValue()
                    let now = CFAbsoluteTimeGetCurrent()
                    if activity.contains(.afterWaiting) {
                        // Work resumed from the wait starts here. A span
                        // still open is recorded before it is replaced.
                        if let start = timer.busyStart {
                            timer.maxBusyMS = max(
                                timer.maxBusyMS,
                                (now - start) * 1000
                            )
                        }
                        timer.turns += 1
                        timer.busyStart = now
                    } else if activity.contains(.beforeSources) {
                        // An iteration that processed ready sources without
                        // sleeping never reached afterWaiting.
                        if timer.busyStart == nil {
                            timer.turns += 1
                            timer.busyStart = now
                        }
                    } else if let start = timer.busyStart {
                        timer.maxBusyMS = max(
                            timer.maxBusyMS,
                            (now - start) * 1000
                        )
                        timer.busyStart = nil
                    }
                },
                &context
            )
            if let observer {
                CFRunLoopAddObserver(
                    CFRunLoopGetMain(),
                    observer,
                    .commonModes
                )
            }
        }

        deinit {
            if let observer {
                CFRunLoopRemoveObserver(
                    CFRunLoopGetMain(),
                    observer,
                    .commonModes
                )
            }
        }
    }

    /// Counts main-runloop turns: one per iteration, taken at beforeSources.
    /// An iteration that processes ready sources without sleeping never
    /// reaches afterWaiting, so counting wake-ups undercounted the very
    /// iterations a busy main thread runs.
    private final class RunloopTurnCounter {
        private(set) var turns = 0

        private var observer: CFRunLoopObserver?

        init() {
            var context = CFRunLoopObserverContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            observer = CFRunLoopObserverCreate(
                kCFAllocatorDefault,
                CFRunLoopActivity.beforeSources.rawValue,
                true,
                0,
                { _, _, info in
                    guard let info else { return }
                    Unmanaged<RunloopTurnCounter>
                        .fromOpaque(info)
                        .takeUnretainedValue()
                        .turns += 1
                },
                &context
            )
            if let observer {
                CFRunLoopAddObserver(
                    CFRunLoopGetMain(),
                    observer,
                    .commonModes
                )
            }
        }

        deinit {
            if let observer {
                CFRunLoopRemoveObserver(
                    CFRunLoopGetMain(),
                    observer,
                    .commonModes
                )
            }
        }
    }

    // MARK: - MC-09 AX contract

    /// With more than one caret AX must still report exactly the primary
    /// selection: the text view is the native text surface, the other carets
    /// are paint. This line pins that contract so a regression is visible.
    private static func runMultiCursorAXProbe() {
        let source = "alpha beta gamma"
        let (_, controller) = makeProbeEditor(source: source)
        guard let model = try? MultiCursorSelection(
            [
                MultiCursorSelection.Caret(anchor: 0, active: 5),
                MultiCursorSelection.Caret(anchor: 6, active: 10),
                MultiCursorSelection.Caret(anchor: 11, active: 16)
            ],
            primary: 1,
            source: source
        ) else {
            log("FAIL mc ax reason=model")
            return
        }
        controller.adoptMultiCursor(model)
        let axRange = controller.textView.accessibilitySelectedTextRange()
        let axText = controller.textView.accessibilitySelectedText() ?? ""
        let overlayIgnored =
            controller.caretOverlay?.isAccessibilityElement() == false
        let axOK = axRange == NSRange(location: 6, length: 4)
            && axText == "beta"
            && overlayIgnored
        log(
            (axOK ? "PASS" : "FAIL")
                + " mc ax primary-only carets=\(model.count)"
                + " range=\(axRange.location)+\(axRange.length)"
                + " text=\"\(axText)\""
                + " overlayIgnored=\(overlayIgnored)"
        )
    }

    // MARK: - MC-08 interaction guards

    private static func guardLog(
        _ operation: MultiCursorPolicy.Operation,
        _ passed: Bool,
        _ detail: String = ""
    ) {
        log(
            (passed ? "PASS" : "FAIL")
                + " mc guard \(operation.rawValue)"
                + (detail.isEmpty ? "" : " " + detail)
        )
    }

    private static func adoptProbeCarets(
        _ controller: MarkdownEditorController,
        offsets: [Int],
        source: String,
        primary: Int = 0
    ) -> Bool {
        guard let model = probeModel(
            offsets,
            primary: primary,
            source: source
        ) else { return false }
        controller.adoptMultiCursor(model)
        return true
    }

    private static func guardSelection(
        _ ranges: [Range<Int>],
        source: String
    ) -> MultiCursorSelection? {
        try? MultiCursorSelection(
            ranges.map {
                MultiCursorSelection.Caret(
                    anchor: $0.lowerBound,
                    active: $0.upperBound
                )
            },
            primary: 0,
            source: source
        )
    }

    private static func runMultiCursorGuardProbe() async {
        let source = "alpha beta gamma"

        // Batch rows.
        do {
            let (document, controller) = makeProbeEditor(source: source)
            let revision = document.revision
            guard adoptProbeCarets(controller, offsets: [0, 6, 11], source: source)
            else {
                guardLog(.typing, false, "reason=model")
                return
            }
            controller.textView.insertText(
                "X",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            guardLog(
                .typing,
                controller.textView.string == "Xalpha Xbeta Xgamma"
                    && document.revision == revision + 1,
                "source=\(controller.textView.string)"
            )
        }
        do {
            let (document, controller) = makeProbeEditor(source: source)
            guard adoptProbeCarets(controller, offsets: [0, 6, 11], source: source)
            else {
                guardLog(.backspace, false, "reason=model")
                return
            }
            _ = controller.textView(
                controller.textView,
                doCommandBy: #selector(NSResponder.deleteBackward(_:))
            )
            guardLog(
                .backspace,
                controller.textView.string == "alphabetagamma"
                    && controller.multiCursorSelection?.ranges
                        == [0..<0, 5..<5, 9..<9]
                    && document.revision == 2,
                "source=\(controller.textView.string)"
            )
        }
        do {
            let (document, controller) = makeProbeEditor(source: source)
            guard adoptProbeCarets(controller, offsets: [0, 6, 11], source: source)
            else {
                guardLog(.delete, false, "reason=model")
                return
            }
            _ = controller.textView(
                controller.textView,
                doCommandBy: #selector(NSResponder.deleteForward(_:))
            )
            guardLog(
                .delete,
                controller.textView.string == "lpha eta amma"
                    && document.revision == 2,
                "source=\(controller.textView.string)"
            )
        }

        // Clipboard rows use a scratch pasteboard: the probe must never
        // write the user's clipboard, and the old flattening save/restore
        // lost every representation it could not express as (type, data).
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("SonovoProbe.guards")
        )
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        do {
            let (document, controller) = makeProbeEditor(source: source)
            guard let model = guardSelection([0..<5, 6..<10], source: source)
            else {
                guardLog(.copy, false, "reason=model")
                return
            }
            controller.adoptMultiCursor(model)
            controller.clipboard = pasteboard
            pasteboard.clearContents()
            // Consume the action even if the handler regresses: a false
            // return falls through to AppKit's own copy, which writes the
            // general pasteboard the probe promises never to touch.
            let copyHandler = controller.textView.onMultiCursorCopy
            var copyHandled = false
            controller.textView.onMultiCursorCopy = {
                copyHandled = copyHandler?() ?? false
                return true
            }
            controller.textView.copy(nil)
            guardLog(
                .copy,
                copyHandled
                    && copyHandler != nil
                    && pasteboard.string(forType: .string) == "alphabeta"
                    && controller.textView.string == source
                    && document.revision == 1
            )
        }
        do {
            let (document, controller) = makeProbeEditor(source: source)
            guard let model = guardSelection([0..<5, 6..<10], source: source)
            else {
                guardLog(.cut, false, "reason=model")
                return
            }
            controller.adoptMultiCursor(model)
            controller.clipboard = pasteboard
            // The copy row left "alphabeta" on this pasteboard, so a cut
            // that only deleted text would still read back the expected
            // string. A distinct sentinel makes the write observable.
            pasteboard.clearContents()
            pasteboard.setString("sentinel", forType: .string)
            // Same consumption rule as copy: a regression must not reach
            // AppKit and overwrite the general pasteboard.
            let cutHandler = controller.textView.onMultiCursorCut
            var cutHandled = false
            controller.textView.onMultiCursorCut = {
                cutHandled = cutHandler?() ?? false
                return true
            }
            controller.textView.cut(nil)
            guardLog(
                .cut,
                cutHandled
                    && cutHandler != nil
                    && pasteboard.string(forType: .string) == "alphabeta"
                    && controller.textView.string == "  gamma"
                    && document.revision == 2,
                "source=\(controller.textView.string)"
                    + " cutCopied=\(pasteboard.string(forType: .string) ?? "nil")"
            )
        }
        do {
            let (document, controller) = makeProbeEditor(source: source)
            guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
            else {
                guardLog(.plainPaste, false, "reason=model")
                return
            }
            controller.clipboard = pasteboard
            pasteboard.clearContents()
            pasteboard.setString("12", forType: .string)
            controller.textView.paste(nil)
            guardLog(
                .plainPaste,
                controller.textView.string == "12alpha 12beta gamma"
                    && document.revision == 2,
                "source=\(controller.textView.string)"
            )
        }
        do {
            let (document, controller) = makeProbeEditor(source: source)
            guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
            else {
                guardLog(.imagePaste, false, "reason=model")
                return
            }
            controller.clipboard = pasteboard
            pasteboard.clearContents()
            pasteboard.setData(Data([0x89]), forType: .png)
            pasteboard.setString("ignored", forType: .string)
            controller.textView.paste(nil)
            guardLog(
                .imagePaste,
                controller.textView.string == source
                    && controller.multiCursorSelection?.ranges
                        == [0..<0, 6..<6]
                    && document.revision == 1
            )
        }
        do {
            let (document, controller) = makeProbeEditor(source: source)
            guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
            else {
                guardLog(.smartPaste, false, "reason=model")
                return
            }
            controller.clipboard = pasteboard
            pasteboard.clearContents()
            pasteboard.setString("<b>x</b>", forType: .html)
            pasteboard.setString("x", forType: .string)
            controller.textView.paste(nil)
            guardLog(
                .smartPaste,
                controller.textView.string == source
                    && controller.multiCursorSelection?.ranges
                        == [0..<0, 6..<6]
                    && document.revision == 1
            )
        }
        do {
            let (document, controller) = makeProbeEditor(source: source)
            guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
            else {
                guardLog(.autoPair, false, "reason=model")
                return
            }
            controller.textView.insertText(
                "(",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            guardLog(
                .autoPair,
                controller.textView.string == "(alpha (beta gamma"
                    && !controller.textView.string.contains("()")
                    && document.revision == 2,
                "source=\(controller.textView.string)"
            )
        }

        // Refuse rows.
        do {
            let (document, controller) = makeProbeEditor(source: source)
            guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
            else {
                guardLog(.formattingCommand, false, "reason=model")
                return
            }
            let applied = controller.perform(.toggleStrong)
            guardLog(
                .formattingCommand,
                !applied
                    && controller.textView.string == source
                    && controller.multiCursorSelection?.ranges
                        == [0..<0, 6..<6]
                    && document.revision == 1
            )
        }
        do {
            let table = "| a | b |\n|---|---|\n| 1 | 2 |"
            let (_, controller) = makeProbeEditor(source: table)
            guard adoptProbeCarets(controller, offsets: [2, 5], source: table)
            else {
                guardLog(.tableCommand, false, "reason=model")
                return
            }
            let applied = controller.perform(.insertTableRowBelow)
            guardLog(
                .tableCommand,
                !applied
                    && controller.textView.string == table
                    && controller.multiCursorSelection?.ranges
                        == [2..<2, 5..<5]
            )
        }
        do {
            let (_, controller) = makeProbeEditor(source: source)
            guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
            else {
                guardLog(.tabIndent, false, "reason=model")
                return
            }
            let handled = controller.textView(
                controller.textView,
                doCommandBy: #selector(NSResponder.insertTab(_:))
            )
            guardLog(
                .tabIndent,
                handled
                    && controller.textView.string == source
                    && controller.multiCursorSelection?.ranges
                        == [0..<0, 6..<6]
            )
        }
        do {
            let list = "- alpha\n- beta"
            let (_, controller) = makeProbeEditor(source: list)
            guard adoptProbeCarets(controller, offsets: [2, 11], source: list)
            else {
                guardLog(.listReturn, false, "reason=model")
                return
            }
            let handled = controller.textView(
                controller.textView,
                doCommandBy: #selector(NSResponder.insertNewline(_:))
            )
            guardLog(
                .listReturn,
                handled
                    && controller.textView.string == list
                    && controller.multiCursorSelection?.ranges
                        == [2..<2, 11..<11]
            )
        }
        do {
            // Real table cells, and the real Tab command: the table-cell
            // navigation is the operation the policy refuses. Opening the
            // grid popover on plain text tested neither.
            let table = "| a | b |\n|---|---|\n| 1 | 2 |"
            let (_, controller) = makeProbeEditor(source: table)
            guard adoptProbeCarets(
                controller,
                offsets: [2, 22],
                source: table
            ) else {
                guardLog(.tableCellTab, false, "reason=model")
                return
            }
            let handled = controller.textView(
                controller.textView,
                doCommandBy: #selector(NSResponder.insertTab(_:))
            )
            guardLog(
                .tableCellTab,
                handled
                    && controller.textView.string == table
                    && controller.multiCursorSelection?.ranges
                        == [2..<2, 22..<22]
            )
        }

        // Collapse rows that need only the editor.
        do {
            let (_, controller) = makeProbeEditor(source: source)
            guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
            else {
                guardLog(.linkPopover, false, "reason=model")
                return
            }
            controller.presentLinkPopover()
            guardLog(
                .linkPopover,
                controller.multiCursorSelection == nil
                    && controller.caretOverlay?.isEmpty != false
            )
        }
        do {
            let bold = "**alpha** beta"
            let (_, controller) = makeProbeEditor(source: bold)
            guard adoptProbeCarets(controller, offsets: [2, 11], source: bold)
            else {
                guardLog(.smartSelectAll, false, "reason=model")
                return
            }
            _ = controller.smartSelectAll()
            guardLog(
                .smartSelectAll,
                controller.multiCursorSelection == nil
            )
        }

        // Primary-only rows.
        do {
            let (_, controller) = makeProbeEditor(source: source)
            guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
            else {
                guardLog(.find, false, "reason=model")
                return
            }
            // The find bar owns focus while it navigates, so the native
            // selection moving is not a user takeover. Navigation is
            // primary-only: the set survives and its primary follows.
            controller.textView.setSelectedRange(
                NSRange(location: 11, length: 5)
            )
            guardLog(
                .find,
                controller.multiCursorSelection?.ranges == [6..<6, 11..<16]
                    && controller.multiCursorSelection?.primaryRange
                        == 11..<16,
                "native=\(controller.textView.selectedRange().location)+\(controller.textView.selectedRange().length)"
            )
        }
        do {
            let (_, controller) = makeProbeEditor(source: source)
            guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
            else {
                guardLog(.reviewMarker, false, "reason=model")
                return
            }
            controller.select(range: 11..<16)
            guardLog(
                .reviewMarker,
                controller.multiCursorSelection?.ranges == [6..<6, 11..<16]
                    && controller.multiCursorSelection?.primaryRange
                        == 11..<16
                    && controller.textView.selectedRange()
                        == NSRange(location: 11, length: 5)
            )
        }
        do {
            let (_, controller) = makeProbeEditor(source: source)
            guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
            else {
                guardLog(.focusMode, false, "reason=model")
                return
            }
            controller.isFocusModeEnabled = true
            controller.refreshReviewMarkers()
            guardLog(
                .focusMode,
                controller.multiCursorSelection?.ranges == [0..<0, 6..<6]
            )
        }
        do {
            let (_, controller) = makeProbeEditor(source: source)
            guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
            else {
                guardLog(.typewriter, false, "reason=model")
                return
            }
            controller.isTypewriterEnabled = true
            controller.keepCaretNearTypewriterLine()
            guardLog(
                .typewriter,
                controller.multiCursorSelection?.ranges == [0..<0, 6..<6]
            )
        }

        // Workspace rows.
        let workspace = MarkdownWorkspace(readsDemoEnvironment: false)
        let document = workspace.newDocument()
        try? document.replaceSource(source)
        let controller = workspace.controller(for: document)
        guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
        else {
            guardLog(.paletteEdit, false, "reason=model")
            return
        }
        workspace.executePaletteCommand(.uppercase)
        guardLog(
            .paletteEdit,
            controller.textView.string == source
                && controller.multiCursorSelection?.ranges == [0..<0, 6..<6]
        )
        // Projection rows drive the viewer's real entry points, with the
        // exact callback the workspace view installs. Calling
        // `collapseMultiCursor` directly here passed even when the viewer
        // stopped firing `onProjectionStart`.
        var projectionFires = 0
        let projectionViewer = MarkdownViewer(
            ast: SonovoAST(),
            headings: HeadingIndex(ast: SonovoAST()),
            theme: MarkdownThemeStore.shared.defaultTheme(),
            source: source,
            onCommitBlockEdit: { _, _, _ in true },
            onProjectionStart: {
                projectionFires += 1
                workspace.collapseMultiCursor(for: document)
            }
        )
        guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
        else { return }
        let blockLength = (source as NSString).length
        let blockRange = SourceRange(
            start: SourcePosition(line: 1, column: 0, offset: 0),
            end: SourcePosition(
                line: 1,
                column: blockLength,
                offset: blockLength
            )
        )
        var firesBefore = projectionFires
        projectionViewer.startBlockEditing(blockRange)
        guardLog(
            .blockProjection,
            projectionFires == firesBefore + 1
                && controller.multiCursorSelection == nil
        )
        guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
        else { return }
        firesBefore = projectionFires
        projectionViewer.startSourcePeek(blockRange)
        guardLog(
            .sourcePeek,
            projectionFires == firesBefore + 1
                && controller.multiCursorSelection == nil
        )
        guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
        else { return }
        workspace.setMode(.rendered, for: document)
        guardLog(
            .modeSwitch,
            controller.multiCursorSelection == nil
                && controller.caretOverlay?.isEmpty != false
        )
        workspace.setMode(.source, for: document)
        guard adoptProbeCarets(controller, offsets: [0, 6], source: source)
        else { return }
        try? document.replaceSource("reloaded alpha beta")
        // Synchronisation runs in a separate MainActor task; a fixed sleep
        // both flakes under load and never checks that the new source
        // reached the view.
        let reloaded = await waitUntil(2) {
            controller.multiCursorSelection == nil
                && controller.textView.string == "reloaded alpha beta"
        }
        guardLog(
            .reload,
            reloaded,
            "source=\(controller.textView.string)"
        )

        let saveDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-mc08-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: saveDirectory,
            withIntermediateDirectories: true
        )
        let saveURL = saveDirectory.appendingPathComponent("saved.md")
        guard adoptProbeCarets(
            controller,
            offsets: [0, 6],
            source: controller.textView.string
        ) else { return }
        _ = await workspace.saveAs(document, to: saveURL)
        guardLog(
            .saveAs,
            controller.multiCursorSelection == nil,
            "saved=\(FileManager.default.fileExists(atPath: saveURL.path))"
        )
        guard adoptProbeCarets(
            controller,
            offsets: [0, 6],
            source: controller.textView.string
        ) else { return }
        _ = await workspace.close(document)
        guardLog(
            .close,
            controller.multiCursorSelection == nil
        )
        try? FileManager.default.removeItem(at: saveDirectory)

        // Split focus: the pane being left is collapsed.
        let splitWorkspace = MarkdownWorkspace(readsDemoEnvironment: false)
        let first = splitWorkspace.newDocument()
        try? first.replaceSource("alpha beta")
        let second = splitWorkspace.newDocument()
        try? second.replaceSource("gamma delta")
        splitWorkspace.show(first, inPane: .secondary)
        splitWorkspace.focus(second)
        let firstController = splitWorkspace.controller(for: first)
        let secondController = splitWorkspace.controller(for: second)
        let firstReady = adoptProbeCarets(
            firstController,
            offsets: [0, 6],
            source: "alpha beta"
        )
        let secondReady = adoptProbeCarets(
            secondController,
            offsets: [0, 6],
            source: "gamma delta"
        )
        splitWorkspace.focus(first)
        guardLog(
            .splitFocus,
            firstReady
                && secondReady
                && secondController.multiCursorSelection == nil
                && firstController.multiCursorSelection != nil
        )
    }
}

private struct MCCompositionEvent {
    let kind: String
    let marked: String
    let selectedRange: NSRange
    let replacementRange: NSRange
    let selectionBefore: NSRange
}

private final class MultiCursorProbeTextView: NSTextView {
    var compositionEvents: [MCCompositionEvent] = []

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        compositionEvents.append(
            MCCompositionEvent(
                kind: "setMarkedText",
                marked: (string as? String)
                    ?? (string as? NSAttributedString)?.string
                    ?? "",
                selectedRange: selectedRange,
                replacementRange: replacementRange,
                selectionBefore: self.selectedRange()
            )
        )
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
    }

    override func insertText(
        _ string: Any,
        replacementRange: NSRange
    ) {
        compositionEvents.append(
            MCCompositionEvent(
                kind: "insertText",
                marked: (string as? String)
                    ?? (string as? NSAttributedString)?.string
                    ?? "",
                selectedRange: NSRange(location: NSNotFound, length: 0),
                replacementRange: replacementRange,
                selectionBefore: self.selectedRange()
            )
        )
        super.insertText(string, replacementRange: replacementRange)
    }

    override func unmarkText() {
        compositionEvents.append(
            MCCompositionEvent(
                kind: "unmarkText",
                marked: "",
                selectedRange: NSRange(location: NSNotFound, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0),
                selectionBefore: self.selectedRange()
            )
        )
        super.unmarkText()
    }
}

@MainActor
private final class ProbeEchoModel: NSObject {
    var offsets: [Int]
    var primary: Int
    var collapses = 0
    /// Covers only the synchronous batch window. Asynchronous selection
    /// restores still go through the comparison rule; this flag cannot mask
    /// them because it is cleared before the apply call returns.
    var suppressing = false

    init(offsets: [Int], primary: Int) {
        self.offsets = offsets
        self.primary = max(0, min(primary, offsets.count - 1))
        super.init()
    }

    var primaryRange: NSRange {
        NSRange(location: offsets[primary], length: 0)
    }

    @objc func selectionChanged(_ note: Notification) {
        guard !suppressing else { return }
        guard let view = note.object as? NSTextView else { return }
        let native = view.selectedRange()
        guard native != primaryRange else { return }
        offsets = [native.location]
        primary = 0
        collapses += 1
    }
}
#endif
