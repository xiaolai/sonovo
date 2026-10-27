import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MarkdownEditorTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }

    private func makeController(
        source: String = ""
    ) -> (MarkdownDocument, MarkdownEditorCache, MarkdownEditorController) {
        let document = MarkdownDocument(untitledWith: MarkdownFileStore())
        if !source.isEmpty {
            try? document.replaceSource(source)
        }
        let cache = MarkdownEditorCache()
        let entry = cache.entry(
            for: document,
            parseCoordinator: MarkdownParseCoordinator(
                service: MarkdownParseService()
            ),
            parseDebounce: 0
        )
        return (document, cache, entry.controller)
    }

    func testTypingUpdatesDocumentAndUndoRestoresBoth() async throws {
        let (document, _, controller) = makeController()
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("hello", replacementRange: NSRange(location: 0, length: 0))

        XCTAssertEqual(document.source, "hello")
        XCTAssertTrue(document.isDirty)
        XCTAssertTrue(document.undoManager.canUndo)

        document.undoManager.undo()
        XCTAssertEqual(document.source, "")

        let synced = await waitUntil { textView.string == "" }
        XCTAssertTrue(synced)
    }

    func testOneTextViewPerDocumentSurvivesRemoval() async throws {
        let (document, cache, controller) = makeController()
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("a", replacementRange: NSRange(location: 0, length: 0))

        // A tab or mode switch hides the view; the cache still owns it and the
        // document's undo stack still targets it.
        textView.removeFromSuperview()
        XCTAssertTrue(cache.cachedEntry(for: document.id) != nil)

        document.undoManager.undo()
        XCTAssertEqual(document.source, "")
        let synced = await waitUntil { textView.string == "" }
        XCTAssertTrue(synced)

        let again = cache.entry(
            for: document,
            parseCoordinator: MarkdownParseCoordinator(
                service: MarkdownParseService()
            )
        )
        XCTAssertTrue(again.textView === textView)
    }

    func testHighlightingDoesNotDirtyOrRegisterUndo() async throws {
        let (document, _, controller) = makeController(source: "# Title\n\nBody\n")
        XCTAssertTrue(document.undoManager.canUndo)

        controller.scheduleParse(immediate: true)
        let highlighted = await waitUntil {
            controller.lastHighlightedRevision == document.revision
        }
        XCTAssertTrue(highlighted)
        XCTAssertEqual(document.revision, 1)
        XCTAssertEqual(document.source, "# Title\n\nBody\n")
        XCTAssertTrue(document.undoManager.canUndo)

        let font = controller.textView.textStorage?.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertGreaterThan(font?.pointSize ?? 0, AppTheme.TypeScale.md)
    }

    func testMarkedTextDefersCommandsUntilCommit() async throws {
        let (document, _, controller) = makeController()
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        var ran = false
        controller.performCommand { ran = true }
        XCTAssertTrue(ran)

        textView.setMarkedText(
            "に",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        var queuedRan = false
        controller.performCommand { queuedRan = true }
        XCTAssertGreaterThan(controller.queuedCommandCount, 0)
        XCTAssertFalse(queuedRan)

        textView.insertText(
            "に",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertFalse(queuedRan)
        XCTAssertEqual(document.source, "に")
        XCTAssertEqual(controller.queuedCommandCount, 0)
    }

    func testQueuedCommandDropsWhenRevisionChanges() async throws {
        let (document, _, controller) = makeController()
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.setMarkedText(
            "あ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        var ran = false
        controller.performCommand { ran = true }

        textView.insertText(
            "あ",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        // The command was queued at the revision before the commit; the commit
        // itself bumps the revision, so the stale command must not run.
        XCTAssertFalse(ran)
        XCTAssertEqual(controller.queuedCommandCount, 0)
        XCTAssertEqual(document.source, "あ")
    }

    func testListContinuationAndExit() throws {
        let (_, _, controller) = makeController(source: "- item")
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 6, length: 0))

        let handled = controller.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(textView.string, "- item\n- ")

        // An empty item exits the list.
        let (_, _, empty) = makeController(source: "- ")
        let emptyView = empty.textView
        emptyView.setSelectedRange(NSRange(location: 2, length: 0))
        _ = empty.textView(
            emptyView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertEqual(emptyView.string, "")
    }

    func testCommandUpdatesSourceAndUndo() async throws {
        let (document, _, controller) = makeController(source: "abc")
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 0, length: 3))

        controller.perform(.toggleStrong)
        XCTAssertEqual(textView.string, "**abc**")
        XCTAssertEqual(document.source, "**abc**")

        document.undoManager.undo()
        XCTAssertEqual(document.source, "abc")
        let synced = await waitUntil { textView.string == "abc" }
        XCTAssertTrue(synced)
    }

    func testImageAssetInsertionAndUndo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-editor-asset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("doc.md")
        try Data("".utf8).write(to: url)
        let document = try MarkdownDocument(loading: url)
        let cache = MarkdownEditorCache()
        let controller = cache.entry(
            for: document,
            parseCoordinator: MarkdownParseCoordinator(
                service: MarkdownParseService()
            ),
            parseDebounce: 0
        ).controller

        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let inserted = controller.insertImageAsset(
            Data([0x89, 0x50, 0x4E, 0x47]),
            fileExtension: "png"
        )
        XCTAssertTrue(inserted)
        XCTAssertTrue(document.source.contains("![image](assets/image-"))
        XCTAssertTrue(document.source.hasSuffix(".png)"))

        let link = document.source
        let path = link
            .replacingOccurrences(of: "![image](", with: "")
            .replacingOccurrences(of: ")", with: "")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(path).path
            )
        )

        document.undoManager.undo()
        XCTAssertEqual(document.source, "")
    }

    func testUntitledDocumentRejectsImages() {
        let (document, _, controller) = makeController()
        XCTAssertFalse(
            controller.insertImageAsset(Data([1, 2, 3]), fileExtension: "png")
        )
        XCTAssertEqual(
            controller.lastCommandError as? MarkdownAssetError,
            .untitledDocument
        )
        XCTAssertEqual(document.source, "")
    }

    func testSpellCheckingToggle() {
        let (_, _, controller) = makeController()
        controller.setSpellChecking(false)
        XCTAssertFalse(controller.textView.isContinuousSpellCheckingEnabled)
        controller.setSpellChecking(true)
        XCTAssertTrue(controller.textView.isContinuousSpellCheckingEnabled)
    }

    func testVisibleRangeHighlighting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-highlight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var source = ""
        var index = 0
        while source.utf8.count < 200_000 {
            index += 1
            source += "# Section \(index)\n\n"
            source += "Paragraph \(index) with **emphasis** and `code`.\n\n"
        }
        let url = directory.appendingPathComponent("large.md")
        try Data(source.utf8).write(to: url)

        let document = try MarkdownDocument(loading: url)
        let cache = MarkdownEditorCache()
        let controller = cache.entry(
            for: document,
            parseCoordinator: MarkdownParseCoordinator(
                service: MarkdownParseService()
            ),
            parseDebounce: 0
        ).controller

        controller.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        controller.textView.frame = NSRect(x: 0, y: 0, width: 800, height: 80_000)
        controller.attach()
        controller.scrollView.layoutSubtreeIfNeeded()

        let parsed = MarkdownParser.parseCanonical(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        let output = MarkdownParseOutput(
            documentID: document.id,
            revision: document.revision,
            parsed: parsed,
            ast: ast,
            headings: HeadingIndex(ast: ast)
        )

        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<10 {
            let start = clock.now
            controller.applyHighlight(output)
            let elapsed = clock.now - start
            let components = elapsed.components
            samples.append(
                Double(components.seconds)
                    + Double(components.attoseconds) / 1_000_000_000_000_000_000
            )
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print("visible highlight p50 \(median)s, p95 \(p95)s for a 200KB document")

        #if DEBUG
        XCTAssertLessThan(p95, 0.5)
        #else
        XCTAssertLessThan(p95, 0.02)
        #endif

        let lastHeading = try XCTUnwrap(output.headings.headings.last)
        let headingOffset = try XCTUnwrap(lastHeading.range?.lowerBound)
        let storage = try XCTUnwrap(controller.textView.textStorage)

        let before = storage.attribute(.font, at: headingOffset, effectiveRange: nil) as? NSFont
        XCTAssertEqual(before?.pointSize, AppTheme.Reading.sourceSize)

        controller.scrollView.contentView.scroll(
            to: NSPoint(
                x: 0,
                y: max(0, controller.textView.bounds.maxY - 600)
            )
        )
        controller.scrollView.reflectScrolledClipView(
            controller.scrollView.contentView
        )
        controller.applyHighlight(output)

        let after = storage.attribute(.font, at: headingOffset, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(after?.pointSize ?? 0, AppTheme.TypeScale.md)
    }

    func testAccessibilityLabel() {
        let (_, _, controller) = makeController()
        XCTAssertEqual(
            controller.textView.accessibilityLabel(),
            "Markdown source"
        )
        XCTAssertEqual(controller.textView.accessibilityRole(), .textArea)
    }

    func testTypingPolicyRunsThroughTheEditorInOneUndo() {
        let (document, _, controller) = makeController(source: "- item")
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 3, length: 0))

        let handled = controller.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertTab(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(document.source, "  - item")
        XCTAssertEqual(textView.string, "  - item")

        document.undoManager.undo()
        XCTAssertEqual(document.source, "- item")
    }

    func testBackspacePolicyDeletesAnEmptyPairInOneUndo() {
        let (document, _, controller) = makeController(source: "f()")
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        let handled = controller.textView(
            textView,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(document.source, "f")
        document.undoManager.undo()
        XCTAssertEqual(document.source, "f()")
    }

    // MARK: - Reading anchor

    func testReadingAnchorRoundTripsTheVisibleLine() {
        let lines = (0..<300)
            .map { "line \($0) of the reading anchor fixture" }
            .joined(separator: "\n")
        let (document, _, controller) = makeController(source: lines)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.scrollView
        controller.scrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: 480,
            height: 320
        )
        window.layoutIfNeeded()
        controller.textView.layoutSubtreeIfNeeded()

        let ns = document.source as NSString
        let target = ns.range(of: "line 150").location
        controller.select(range: target..<target)
        controller.textView.layoutSubtreeIfNeeded()

        guard let anchor = controller.readingAnchor() else {
            XCTFail("no reading anchor for a laid-out document")
            return
        }
        let origin = controller.scrollView.contentView.bounds.origin.y
        XCTAssertGreaterThan(origin, 0)

        controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        XCTAssertEqual(controller.scrollView.contentView.bounds.origin.y, 0)

        controller.restoreReadingAnchor(anchor)
        // TextKit may refine estimated fragment positions as it lays out the
        // restored viewport, so the absolute origin can shift by half a line.
        // The contract is that the same line is visible at the same offset.
        let restored = controller.readingAnchor()
        XCTAssertEqual(restored?.lineOffset, anchor.lineOffset)
        XCTAssertEqual(
            restored?.viewportOffset ?? .nan,
            anchor.viewportOffset,
            accuracy: 1
        )
    }

    func testReadingAnchorFallsBackWhenTheLineIsGone() {
        let lines = (0..<300)
            .map { "line \($0) of the fixture" }
            .joined(separator: "\n")
        let (_, _, controller) = makeController(source: lines)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.scrollView
        controller.scrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: 480,
            height: 320
        )
        window.layoutIfNeeded()
        controller.textView.layoutSubtreeIfNeeded()

        // A reload shrank the file: the offset clamps to the last line, which
        // is the furthest the viewport can scroll.
        controller.restoreReadingAnchor(
            SourceReadingAnchor(lineOffset: 10_000_000, viewportOffset: 0)
        )
        let maximum = max(
            0,
            controller.textView.bounds.height
                - controller.scrollView.contentView.bounds.height
        )
        XCTAssertGreaterThan(maximum, 0)
        XCTAssertEqual(
            controller.scrollView.contentView.bounds.origin.y,
            maximum,
            accuracy: 2
        )
    }

    func testSourceReplacementRestoresTheReadingPosition() throws {
        let lines = (0..<300)
            .map { "line \($0) of the reload fixture" }
            .joined(separator: "\n")
        let (document, _, controller) = makeController(source: lines)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.scrollView
        controller.scrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: 480,
            height: 320
        )
        window.layoutIfNeeded()
        controller.textView.layoutSubtreeIfNeeded()

        let ns = document.source as NSString
        let target = ns.range(of: "line 200").location
        controller.select(range: target..<target)
        controller.textView.layoutSubtreeIfNeeded()
        let anchor = try XCTUnwrap(controller.readingAnchor())
        XCTAssertGreaterThan(anchor.lineOffset, 0)

        let shorter = (0..<40)
            .map { "line \($0) of the shorter fixture" }
            .joined(separator: "\n")
        try document.replaceSource(shorter)
        // The workspace arms the anchor after the new source lands and
        // before the view syncs it.
        controller.restoreReadingAnchorAfterSourceReplacement(anchor)
        controller.syncFromDocument()
        controller.textView.layoutSubtreeIfNeeded()

        let maximum = max(
            0,
            controller.textView.bounds.height
                - controller.scrollView.contentView.bounds.height
        )
        XCTAssertGreaterThan(maximum, 0)
        XCTAssertEqual(
            controller.scrollView.contentView.bounds.origin.y,
            maximum,
            accuracy: 2
        )
    }

    // MARK: - Link routing

    func testSourceLinkOpenUsesTheWorkspaceRouting() {
        let (_, _, controller) = makeController(source: "# Heading\n")
        var openedLocal: String?
        var openedMedia: MediaReference?
        controller.onOpenLocalLink = { openedLocal = $0 }
        controller.onOpenMediaLink = { openedMedia = $0 }

        controller.openLinkDestination("notes/other.md")
        XCTAssertEqual(openedLocal, "notes/other.md")

        controller.openLinkDestination("sonovo:take?path=a.mov")
        XCTAssertEqual(openedMedia?.kind, .take)
        XCTAssertEqual(openedMedia?.path, "a.mov")
    }

    // MARK: - Find bar seeding

    func testFindBarSeedSelectsTheMatchWhenMounted() {
        let (document, _, controller) = makeController(source: "hello world\n")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.scrollView
        controller.scrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: 480,
            height: 320
        )
        window.layoutIfNeeded()

        let offset = (document.source as NSString)
            .range(of: "world").location
        controller.seedFindBar(with: "world", at: offset)
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: offset, length: 5)
        )
        window.layoutIfNeeded()
        let field = searchField(in: controller.scrollView)
        XCTAssertNotNil(field, "the source find bar did not appear")
        XCTAssertEqual(field?.stringValue, "world")
    }

    // MARK: - Auto-pair

    func testTypedOpenerPairsAndUndoesAsOneEdit() async throws {
        let (document, _, controller) = makeController()
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.insertText(
            "(",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(document.source, "()")
        XCTAssertEqual(textView.string, "()")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertTrue(document.undoManager.canUndo)

        document.undoManager.undo()
        XCTAssertEqual(document.source, "")
        let synced = await waitUntil { textView.string == "" }
        XCTAssertTrue(synced)
    }

    func testTypedCloserSkipsTheInsertedOne() {
        let (document, _, controller) = makeController()
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.insertText(
            "(",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        textView.insertText(
            ")",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(document.source, "()")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    func testMarkedTextCommitsWithoutPairing() {
        let (document, _, controller) = makeController()
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.setMarkedText(
            "（",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        textView.insertText(
            "（",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(document.source, "（")
        XCTAssertEqual(textView.string, "（")
    }

    func testCJKFormattingIsOneUndoStep() async throws {
        let source = "中文English,中文.中文\n"
        let (document, _, controller) = makeController(source: source)
        let revisionBefore = document.revision
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(controller.perform(.formatCJK))
        XCTAssertEqual(document.source, "中文 English,中文。中文\n")
        XCTAssertEqual(document.revision, revisionBefore + 1)
        XCTAssertTrue(document.undoManager.canUndo)

        document.undoManager.undo()
        XCTAssertEqual(document.source, source)
        let synced = await waitUntil {
            controller.textView.string == source
        }
        XCTAssertTrue(synced)
    }

    func testCJKFormattingNoOpDoesNotRegisterUndo() {
        let source = "中文 English\n"
        let (document, _, controller) = makeController(source: source)
        document.undoManager.removeAllActions()
        XCTAssertFalse(document.undoManager.canUndo)

        XCTAssertTrue(controller.perform(.formatCJK))
        XCTAssertEqual(document.source, source)
        XCTAssertFalse(document.undoManager.canUndo)
    }

    /// The batch path reuses the cached caret-independent decoration layers,
    /// so a keystroke does not rescan the document for the caret's table
    /// cell. The full pass that follows must repaint that layer at the edited
    /// offsets; a cache that is never refreshed would leave the highlight
    /// frozen where the cell used to be.
    func testTheCellHighlightTracksTheCaretAcrossABatch() async throws {
        let source = "| a | b |\n| --- | --- |\n| 11 | 22 |\n\nafter\n"
        let (document, _, controller) = makeController(source: source)
        let textView = controller.textView
        let cellColour = NSColor(AppTheme.MarkdownChrome.TableCell.highlight)
        let eleven = (source as NSString).range(of: "11").location

        func cellBackground(at offset: Int) -> NSColor? {
            textView.textStorage?.attribute(
                .backgroundColor,
                at: offset,
                effectiveRange: nil
            ) as? NSColor
        }

        controller.scheduleParse(immediate: true)
        let settled = await waitUntil {
            controller.lastHighlightedRevision == document.revision
        }
        XCTAssertTrue(settled)
        textView.setSelectedRange(NSRange(location: eleven, length: 0))
        let painted = await waitUntil {
            cellBackground(at: eleven)?.isEqual(cellColour) == true
        }
        XCTAssertTrue(painted)

        controller.adoptMultiCursor(
            try MultiCursorSelection(
                [
                    MultiCursorSelection.Caret(anchor: eleven, active: eleven),
                    MultiCursorSelection.Caret(
                        anchor: eleven + 1,
                        active: eleven + 1
                    )
                ],
                primary: 0,
                source: source
            )
        )
        XCTAssertTrue(controller.applyMultiCursor(.insert("x")))
        XCTAssertEqual(
            document.source,
            "| a | b |\n| --- | --- |\n| x1x1 | 22 |\n\nafter\n"
        )

        // The parse publication is a full pass and must refresh the cache.
        controller.scheduleParse(immediate: true)
        let refreshed = await waitUntil {
            controller.lastHighlightedRevision == document.revision
        }
        XCTAssertTrue(refreshed)
        let edited = document.source as NSString
        let cell = edited.range(of: "x1x1").location + 2
        XCTAssertTrue(
            cellBackground(at: cell)?.isEqual(cellColour) == true,
            "the cell highlight did not follow the edit"
        )
    }
}
