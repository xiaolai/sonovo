import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MultiCursorEditingTests: XCTestCase {
    private func makeController(
        source: String
    ) -> (MarkdownDocument, MarkdownEditorController) {
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

    private func model(
        _ carets: [(Int, Int)],
        primary: Int,
        source: String
    ) throws -> MultiCursorSelection {
        try MultiCursorSelection(
            carets.map {
                MultiCursorSelection.Caret(anchor: $0.0, active: $0.1)
            },
            primary: primary,
            source: source
        )
    }

    private func carets(
        _ offsets: [Int],
        primary: Int = 0,
        source: String
    ) throws -> MultiCursorSelection {
        try model(offsets.map { ($0, $0) }, primary: primary, source: source)
    }

    func testTypingAtThreeCaretsIsOneUndo() throws {
        let source = "alpha beta gamma"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try carets([0, 6, 11], primary: 1, source: source)
        )
        let revision = document.revision

        controller.textView.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(controller.textView.string, "Xalpha Xbeta Xgamma")
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [1..<1, 8..<8, 14..<14]
        )
        XCTAssertEqual(document.revision, revision + 1)
        XCTAssertTrue(document.undoManager.canUndo)
        XCTAssertEqual(document.undoManager.undoActionName, "Typing")

        document.undoManager.undo()
        XCTAssertEqual(document.source, source)
        document.undoManager.redo()
        XCTAssertEqual(document.source, "Xalpha Xbeta Xgamma")
    }

    func testDeleteBackwardAtThreeCarets() throws {
        let source = "abc def ghi"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([3, 7, 11], source: source))

        let handled = controller.textView(
            controller.textView,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(controller.textView.string, "ab de gh")
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [2..<2, 5..<5, 8..<8]
        )
        XCTAssertEqual(document.source, "ab de gh")
    }

    func testDeleteForwardAtThreeCarets() throws {
        let source = "abc def ghi"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 4, 8], source: source))

        let handled = controller.textView(
            controller.textView,
            doCommandBy: #selector(NSResponder.deleteForward(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(controller.textView.string, "bc ef hi")
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<0, 3..<3, 6..<6]
        )
    }

    func testPasteAtThreeCarets() throws {
        let source = "alpha beta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 6], source: source))

        XCTAssertTrue(controller.applyMultiCursor(.paste("1\n2")))
        XCTAssertEqual(controller.textView.string, "1\n2alpha 1\n2beta")
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [3..<3, 12..<12]
        )
    }

    func testCopyAndCutUseEverySelection() throws {
        let source = "alpha beta gamma"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try model([(0, 5), (6, 10), (11, 11)], primary: 0, source: source)
        )

        XCTAssertEqual(controller.multiCursorCopyText(), "alphabeta")
        XCTAssertTrue(controller.applyMultiCursor(.replace("")))
        XCTAssertEqual(controller.textView.string, "  gamma")
        // Each deleted selection collapses to its own edit point; the
        // untouched caret keeps its place.
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<0, 1..<1, 2..<2]
        )
    }

    func testCopyWithoutSelectionsFallsThrough() throws {
        let source = "alpha beta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 6], source: source))

        XCTAssertNil(controller.multiCursorCopyText())
    }

    func testChokePointRefusesANativeEdit() throws {
        let source = "alpha beta gamma"
        let (document, controller) = makeController(source: source)
        let revision = document.revision
        controller.adoptMultiCursor(try carets([0, 6, 11], source: source))

        XCTAssertFalse(
            controller.textView(
                controller.textView,
                shouldChangeTextIn: NSRange(location: 0, length: 0),
                replacementString: "Z"
            )
        )
        XCTAssertFalse(
            controller.textView(
                controller.textView,
                shouldChangeTextInRanges: [
                    NSValue(range: NSRange(location: 0, length: 0))
                ],
                replacementStrings: ["Z"]
            )
        )
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(controller.multiCursorSelection?.count, 3)
        XCTAssertEqual(controller.textView.string, source)
    }

    func testNoOpBatchLeavesRevisionAndUndoAlone() throws {
        let source = "alpha beta"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 5], source: source))
        let revision = document.revision
        let canUndo = document.undoManager.canUndo

        controller.textView.insertText(
            "",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.undoManager.canUndo, canUndo)
        XCTAssertEqual(controller.multiCursorSelection?.count, 2)
    }

    /// Replacing each selection with the text already there is a no-op for the
    /// document, but it still collapses the carets. The native selection must
    /// follow the model primary, and no revision or undo entry may appear.
    func testIdenticalReplacementCollapsesCaretsWithoutEditing() throws {
        let source = "foo foo"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try model([(0, 3), (4, 7)], primary: 0, source: source)
        )
        let revision = document.revision
        let canUndo = document.undoManager.canUndo

        controller.textView.insertText(
            "foo",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(document.source, source)
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.undoManager.canUndo, canUndo)
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [3..<3, 7..<7]
        )
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: 3, length: 0)
        )
    }

    func testPrimaryReplacementRangeIsExpandedToTheBatch() throws {
        let source = "alpha beta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 5], source: source))

        controller.textView.insertText(
            "Z",
            replacementRange: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(controller.textView.string, "ZalphaZ beta")
    }

    func testStalePreimageResetsFromTheDocument() throws {
        let source = "alpha beta"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 5], source: source))
        // An external reload lands in the document while the view still
        // holds the text the caret set was computed against.
        try document.replaceSource("external change")

        XCTAssertTrue(controller.applyMultiCursor(.insert("X")))
        XCTAssertEqual(controller.textView.string, "external change")
        XCTAssertNil(controller.multiCursorSelection)
        XCTAssertEqual(
            controller.lastCommandError as? DocumentError,
            .staleCompletion
        )
    }

    /// An external update of the same length passes every length check, so
    /// only the revision last synchronised into the view can catch it. Without
    /// that record the batch would write its edit over the newer text.
    func testEqualLengthStalePreimageIsRefused() throws {
        let source = "alpha beta"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 5], source: source))
        XCTAssertEqual(source.utf16.count, "omega zeta".utf16.count)
        try document.replaceSource("omega zeta")

        XCTAssertTrue(controller.applyMultiCursor(.insert("X")))
        XCTAssertEqual(controller.textView.string, "omega zeta")
        XCTAssertNil(controller.multiCursorSelection)
        XCTAssertEqual(
            controller.lastCommandError as? DocumentError,
            .staleCompletion
        )
    }

    /// A batch that normalises to one caret ends multi-cursor mode. Keeping a
    /// non-nil one-caret set left Return, Tab and formatting refused against
    /// a stale two-caret model.
    func testBatchThatNormalisesToOneCaretLeavesMultiCursorMode() throws {
        let source = "ab"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 1], source: source))

        _ = controller.textView(
            controller.textView,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        )
        XCTAssertEqual(controller.textView.string, "b")
        XCTAssertNil(controller.multiCursorSelection)

        // Tab is refused only while a caret set is live; with the set gone
        // the normal plan indents instead.
        let handled = controller.textView(
            controller.textView,
            doCommandBy: #selector(NSResponder.insertTab(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(controller.textView.string, "    b")
    }

    /// The policy table is the authority, not a comment: a handler that reads
    /// it must change behaviour when the table says something else.
    func testPolicyTableDrivesTheTabRefusal() throws {
        let source = "alpha beta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 6], source: source))
        controller.multiCursorPolicy = { operation in
            operation == .tabIndent ? .collapse : operation.outcome
        }

        let handled = controller.textView(
            controller.textView,
            doCommandBy: #selector(NSResponder.insertTab(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertNil(controller.multiCursorSelection)
        XCTAssertEqual(controller.textView.string, "    alpha beta")
    }

    /// A click on the primary's own position produces no selection change,
    /// so the change observer never runs. The view's plain-click hook runs
    /// before AppKit's handling and must collapse anyway: a click is the user
    /// taking over, and leaving the secondaries meant the next keystroke
    /// edited several places.
    func testAPlainClickCollapsesEvenAtThePrimaryPosition() throws {
        let source = "alpha beta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 6], source: source))

        controller.textView.onPlainClick?()
        XCTAssertNil(controller.multiCursorSelection)
        controller.textView.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(controller.textView.string, "Xalpha beta")
    }

    /// The vertical-motion cache is keyed by source text, and `String ==`
    /// treats a decomposed and a precomposed spelling as equal even though
    /// their UTF-16 offsets differ. A reload to the precomposed spelling
    /// reused line ranges that named positions in the old buffer.
    func testDisplayLineCacheIsNotReusedAcrossCanonicallyEqualSources()
        throws {
        let decomposed = "e\u{301}\nxx\nyy"
        let precomposed = "é\nxx\nyy"
        XCTAssertEqual(decomposed, precomposed)
        XCTAssertNotEqual(decomposed.utf16.count, precomposed.utf16.count)
        let (document, controller) = makeController(source: decomposed)
        controller.adoptMultiCursor(
            try carets([0, 3], primary: 0, source: decomposed)
        )
        let moveDown = #selector(NSResponder.moveDown(_:))
        XCTAssertTrue(controller.textView(controller.textView, doCommandBy: moveDown))
        // The old buffer's line starts: 3 and 6.
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [3..<3, 6..<6]
        )

        try document.replaceSource(precomposed)
        controller.syncFromDocument()
        controller.adoptMultiCursor(
            try carets([0, 2], primary: 0, source: precomposed)
        )
        XCTAssertTrue(controller.textView(controller.textView, doCommandBy: moveDown))
        // The new buffer's line starts: 2 and 5, one unit shorter.
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [2..<2, 5..<5]
        )
    }

    /// A focus change inside one key window moves no selection, frame, or
    /// scroll position, so the overlay's own observers never fire. The text
    /// view reports responder changes; the overlay must follow them.
    func testTheOverlayHidesWhenTheEditorLosesFocus() throws {
        let source = "alpha beta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 6], source: source))
        let overlay = try XCTUnwrap(controller.caretOverlay)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.textView

        XCTAssertTrue(window.makeFirstResponder(controller.textView))
        XCTAssertFalse(overlay.isHidden)

        XCTAssertTrue(window.makeFirstResponder(NSView()))
        XCTAssertTrue(overlay.isHidden)
    }

    /// An image file URL pastes an image even when the pasteboard also
    /// carries a string fallback. Classifying only PNG/TIFF data batched the
    /// fallback as text and edited every caret.
    func testAnImageFileURLIsNotBatchedAsText() throws {
        let source = "alpha beta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 6], source: source))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-paste-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("SonovoTests.imageURL")
        )
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString("12", forType: .string)
        controller.clipboard = pasteboard

        XCTAssertTrue(controller.textView.onMultiCursorPaste?() ?? false)
        XCTAssertEqual(controller.textView.string, source)
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<0, 6..<6]
        )
    }

    /// The batch path refuses a stale buffer; a native single-caret edit is
    /// the same overwrite. Without the guard, typing before the async sync
    /// wrote the old text back over an external update.
    func testNativeEditOnAStaleBufferIsRefused() throws {
        let source = "alpha beta"
        let (document, controller) = makeController(source: source)
        try document.replaceSource("omega zeta")

        controller.textView.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertEqual(document.source, "omega zeta")
        XCTAssertEqual(controller.textView.string, "omega zeta")
        XCTAssertEqual(
            controller.lastCommandError as? DocumentError,
            .staleCompletion
        )
    }

    /// MC-03: the secondary selection background hides while the editor is
    /// not first responder. It is a text attribute, so losing focus must
    /// repaint the decorations, not only hide the caret overlay.
    func testSecondarySelectionBackgroundHidesOnFocusLoss() throws {
        let source = "alpha beta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try model([(0, 5), (6, 10)], primary: 0, source: source)
        )
        let storage = try XCTUnwrap(controller.textView.textStorage)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.textView
        XCTAssertTrue(window.makeFirstResponder(controller.textView))
        XCTAssertNotNil(
            storage.attribute(.backgroundColor, at: 7, effectiveRange: nil)
        )

        XCTAssertTrue(window.makeFirstResponder(NSView()))
        XCTAssertNil(
            storage.attribute(.backgroundColor, at: 7, effectiveRange: nil)
        )
    }

    func testNativeSelectionChangeCollapsesTheSet() throws {
        let source = "alpha beta gamma"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 6, 11], source: source))
        // Only a change the user made in the text view collapses the set;
        // find-bar navigation is primary-only. Without a window the default
        // cannot tell, so the test supplies the cause.
        controller.isSelectionChangeUserDriven = { true }

        controller.textView.setSelectedRange(
            NSRange(location: 5, length: 0)
        )
        XCTAssertNil(controller.multiCursorSelection)
    }

    func testPrimarySelectionEchoKeepsTheSet() throws {
        let source = "alpha beta gamma"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try carets([0, 6, 11], primary: 1, source: source)
        )

        controller.textView.setSelectedRange(
            NSRange(location: 6, length: 0)
        )
        XCTAssertEqual(controller.multiCursorSelection?.count, 3)
    }
}
