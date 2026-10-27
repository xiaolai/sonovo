import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MultiCursorIMETests: XCTestCase {
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

    private func carets(
        _ offsets: [Int],
        primary: Int = 0,
        source: String
    ) throws -> MultiCursorSelection {
        try MultiCursorSelection(
            offsets.map {
                MultiCursorSelection.Caret(anchor: $0, active: $0)
            },
            primary: primary,
            source: source
        )
    }

    /// Emulates one marked-text update. The selection before the update is
    /// the primary's native range, exactly as the input method sees it.
    private func mark(
        _ text: String,
        in controller: MarkdownEditorController,
        replacing replacement: NSRange = NSRange(
            location: NSNotFound,
            length: 0
        )
    ) {
        controller.textView.setMarkedText(
            text,
            selectedRange: NSRange(
                location: (text as NSString).length,
                length: 0
            ),
            replacementRange: replacement
        )
    }

    private func commit(
        _ text: String,
        in controller: MarkdownEditorController
    ) {
        controller.textView.insertText(
            text,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
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

    /// Composing a precomposed "é" over a decomposed "e" + U+0301 makes
    /// Swift's canonical equality true while the UTF-16 length shrinks by
    /// one. The cancellation branch must not fire, or the secondary keeps an
    /// offset past the new end of its character.
    func testANormalizationOnlyCompositionStillTranslatesSecondaries() throws {
        let source = "e\u{301} beta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try model([(0, 2), (7, 7)], primary: 0, source: source)
        )

        mark("é", in: controller)
        commit("é", in: controller)

        XCTAssertEqual(controller.textView.string, "é beta")
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [1..<1, 6..<6]
        )
    }

    /// A commit that reproduces the selected text exactly still moves the
    /// native selection to its end. The model primary must follow, or the
    /// next keystroke edits the text that was just committed.
    func testAnUnchangedCommitMovesThePrimaryToTheNativeSelection() throws {
        let source = "foo beta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try model([(0, 3), (4, 4)], primary: 0, source: source)
        )

        mark("foo", in: controller)
        commit("foo", in: controller)

        XCTAssertEqual(controller.textView.string, "foo beta")
        XCTAssertEqual(
            controller.multiCursorSelection?.primaryRange,
            3..<3
        )
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: 3, length: 0)
        )
    }

    /// A composition that started before an external update must not commit
    /// over it. The baseline has to name the revision the buffer represents:
    /// capturing the document's current revision made a stale buffer look
    /// current, and the commit wrote its text over the external update.
    func testAStaleCompositionCannotOverwriteAnExternalUpdate() throws {
        let source = "alpha beta"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try carets([0, 6], primary: 0, source: source)
        )
        try document.replaceSource("omega zeta")
        XCTAssertEqual(
            document.source.utf16.count,
            source.utf16.count,
            "the update must not be distinguishable by length"
        )

        mark("に", in: controller)
        commit("に", in: controller)

        XCTAssertEqual(document.source, "omega zeta")
        XCTAssertEqual(controller.textView.string, "omega zeta")
        XCTAssertEqual(
            controller.lastCommandError as? DocumentError,
            .staleCompletion
        )
    }

    /// Marked text has already rewritten storage, so a batch would fail its
    /// length guard and reset the editor, discarding the composition. The
    /// paste must be left to the native path.
    func testPasteDuringACompositionIsLeftToTheNativePath() throws {
        let source = "alpha beta"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try carets([0, 6], primary: 1, source: source)
        )
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("SonovoTests.compositionPaste")
        )
        pasteboard.clearContents()
        pasteboard.setString("ZZ", forType: .string)
        controller.clipboard = pasteboard

        mark("に", in: controller)
        XCTAssertEqual(controller.textView.string, "alpha にbeta")

        XCTAssertFalse(controller.textView.onMultiCursorPaste?() ?? true)
        XCTAssertEqual(controller.textView.string, "alpha にbeta")
        XCTAssertTrue(controller.textView.hasMarkedText())
        XCTAssertEqual(document.source, source)
    }

    func testConfirmTranslatesSecondariesAndCommitsOnce() throws {
        let source = "alpha beta"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try carets([0, 6, 9], primary: 1, source: source)
        )
        let revision = document.revision

        mark("に", in: controller)
        // The marked text is visible in the storage but not in the document.
        XCTAssertEqual(controller.textView.string, "alpha にbeta")
        XCTAssertEqual(document.source, source)

        commit("日本", in: controller)
        XCTAssertEqual(controller.textView.string, "alpha 日本beta")
        XCTAssertEqual(document.source, "alpha 日本beta")
        XCTAssertEqual(document.revision, revision + 1)
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<0, 8..<8, 11..<11]
        )
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(
            location: 8,
            length: 0
        ))
    }

    func testCancelRestoresOffsetsExactly() throws {
        let source = "alpha beta"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try carets([0, 6, 9], primary: 1, source: source)
        )

        mark("に", in: controller)
        commit("", in: controller)
        XCTAssertEqual(controller.textView.string, source)
        XCTAssertEqual(document.source, source)
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<0, 6..<6, 9..<9]
        )
    }

    func testRepeatedCandidateUpdatesKeepTheFirstSpan() throws {
        let source = "alpha beta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try carets([0, 6, 9], primary: 1, source: source)
        )

        mark("n", in: controller)
        mark("に", in: controller)
        mark("にほ", in: controller)
        commit("日本", in: controller)
        XCTAssertEqual(controller.textView.string, "alpha 日本beta")
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<0, 8..<8, 11..<11]
        )
    }

    func testExplicitReplacementDropsAnIntersectingSecondary() throws {
        let source = "alpha beta gamma"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try carets([0, 5, 6], primary: 2, source: source)
        )

        // The input method names a span that covers the secondary at 5.
        mark(
            "に",
            in: controller,
            replacing: NSRange(location: 4, length: 3)
        )
        commit("日本", in: controller)
        XCTAssertEqual(controller.textView.string, "alph日本eta gamma")
        XCTAssertEqual(document.source, "alph日本eta gamma")
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<0, 6..<6]
        )
    }

    func testCompositionElsewhereDropsTheCoveredSecondary() throws {
        let source = "alpha beta"
        let (_, controller) = makeController(source: source)
        // The native selection is at 8, but the composition replaces 2..<6.
        controller.adoptMultiCursor(
            try carets([0, 3, 8], primary: 2, source: source)
        )

        mark(
            "に",
            in: controller,
            replacing: NSRange(location: 2, length: 4)
        )
        commit("日本", in: controller)
        // The input method's range did not fit the text AppKit produced, so
        // the diff names the real span: 2..<6 ("pha ").
        XCTAssertEqual(controller.textView.string, "al日本beta")
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<0, 4..<4]
        )
    }

    func testCompositionAtDocumentStartAndEnd() throws {
        let source = "alpha beta"
        let (_, start) = makeController(source: source)
        start.adoptMultiCursor(
            try carets([0, 6, 10], primary: 0, source: source)
        )
        mark("に", in: start)
        commit("日本", in: start)
        XCTAssertEqual(start.textView.string, "日本alpha beta")
        XCTAssertEqual(
            start.multiCursorSelection?.ranges,
            [2..<2, 8..<8, 12..<12]
        )

        let (_, end) = makeController(source: source)
        end.adoptMultiCursor(
            try carets([0, 6, 10], primary: 2, source: source)
        )
        mark("に", in: end)
        commit("日本", in: end)
        XCTAssertEqual(end.textView.string, "alpha beta日本")
        XCTAssertEqual(
            end.multiCursorSelection?.ranges,
            [0..<0, 6..<6, 12..<12]
        )
    }

    func testACompositionCommitIsNeverBatched() throws {
        let source = "alpha beta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try carets([0, 6, 9], primary: 1, source: source)
        )

        mark("に", in: controller)
        commit("日本", in: controller)
        // A batch would have inserted the committed text at every caret.
        XCTAssertEqual(controller.textView.string, "alpha 日本beta")
    }
}
