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
}
