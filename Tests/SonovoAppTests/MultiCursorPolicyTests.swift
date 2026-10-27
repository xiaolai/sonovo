import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MultiCursorPolicyTests: XCTestCase {
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

    /// A scratch pasteboard for one test. The production default is the
    /// general pasteboard; a test must never clear the user's clipboard.
    private func scratchPasteboard(
        _ name: String
    ) -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("SonovoTests.\(name)")
        )
        pasteboard.clearContents()
        return pasteboard
    }

    func testTableMatchesThePlan() {
        let expected: [MultiCursorPolicy.Operation: MultiCursorPolicy.Outcome] = [
            .typing: .batch,
            .backspace: .batch,
            .delete: .batch,
            .plainPaste: .batch,
            .copy: .batch,
            .cut: .batch,
            .imagePaste: .refuse,
            .smartPaste: .refuse,
            .blockProjection: .collapse,
            .sourcePeek: .collapse,
            .tableCellTab: .refuse,
            .tableCommand: .refuse,
            .formattingCommand: .refuse,
            .paletteEdit: .refuse,
            .tabIndent: .refuse,
            .listReturn: .refuse,
            .autoPair: .refuse,
            .linkPopover: .collapse,
            .smartSelectAll: .collapse,
            .modeSwitch: .collapse,
            .reload: .collapse,
            .saveAs: .collapse,
            .close: .collapse,
            .splitFocus: .collapse,
            .find: .primaryOnly,
            .focusMode: .primaryOnly,
            .typewriter: .primaryOnly,
            .reviewMarker: .primaryOnly
        ]
        XCTAssertEqual(MultiCursorPolicy.outcomes.count, expected.count)
        for (operation, outcome) in expected {
            XCTAssertEqual(
                MultiCursorPolicy.outcomes[operation],
                outcome,
                "policy row \(operation.rawValue)"
            )
        }
    }

    func testBackspaceDeleteAndCutBatch() throws {
        let source = "alpha beta gamma"

        let (backspaceDocument, backspaceController) = makeController(source: source)
        backspaceController.adoptMultiCursor(
            try carets([0, 6, 11], source: source)
        )
        _ = backspaceController.textView(
            backspaceController.textView,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        )
        XCTAssertEqual(
            backspaceController.textView.string,
            "alphabetagamma"
        )
        XCTAssertEqual(
            backspaceController.multiCursorSelection?.ranges,
            [0..<0, 5..<5, 9..<9]
        )
        XCTAssertEqual(backspaceDocument.revision, 2)

        let (deleteDocument, deleteController) = makeController(source: source)
        deleteController.adoptMultiCursor(try carets([0, 6, 11], source: source))
        _ = deleteController.textView(
            deleteController.textView,
            doCommandBy: #selector(NSResponder.deleteForward(_:))
        )
        XCTAssertEqual(deleteController.textView.string, "lpha eta amma")
        XCTAssertEqual(deleteDocument.revision, 2)

        let (cutDocument, cutController) = makeController(source: source)
        cutController.clipboard = scratchPasteboard("cut")
        cutController.adoptMultiCursor(
            try MultiCursorSelection(
                [
                    MultiCursorSelection.Caret(anchor: 0, active: 5),
                    MultiCursorSelection.Caret(anchor: 6, active: 10)
                ],
                primary: 0,
                source: source
            )
        )
        cutController.textView.cut(nil)
        XCTAssertEqual(cutController.textView.string, "  gamma")
        XCTAssertEqual(cutDocument.revision, 2)
        XCTAssertEqual(
            cutController.clipboard.string(forType: .string),
            "alphabeta"
        )
    }

    /// Paste as Plain Text is its own AppKit action; intercepting only
    /// `paste` sent it to the choke point, which refused it instead of
    /// batching the plain string.
    func testPlainTextPasteBatchesThroughItsOwnCommand() throws {
        let source = "alpha beta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 6], source: source))
        let pasteboard = scratchPasteboard("plainCommand")
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString("<b>12</b>", forType: .html)
        pasteboard.setString("12", forType: .string)
        controller.clipboard = pasteboard

        controller.textView.pasteAsPlainText(nil)

        XCTAssertEqual(controller.textView.string, "12alpha 12beta")
        // The second caret shifts by the first insertion and then lands
        // after its own: 6 + 2 + 2.
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [2..<2, 10..<10]
        )
    }

    func testEditingCommandsAreRefusedWithMultipleCarets() throws {
        let source = "alpha beta gamma"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try carets([0, 6, 11], source: source)
        )
        let revision = document.revision

        XCTAssertFalse(controller.perform(.toggleStrong))
        XCTAssertFalse(controller.perform(.uppercase))
        XCTAssertFalse(controller.perform(.insertTableRowBelow))
        XCTAssertEqual(controller.textView.string, source)
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<0, 6..<6, 11..<11]
        )
        XCTAssertEqual(document.revision, revision)
    }

    /// The policy table has a row for table commands, and `perform` must
    /// consult it rather than the formatting row. The production outcomes are
    /// the same today, so only a split injection can show the wiring: this
    /// table entry collapses while the formatting one refuses.
    func testTableCommandsConsultTheirOwnPolicyRow() throws {
        let source =
            "before\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nafter"
        let (_, controller) = makeController(source: source)
        let offset = (source as NSString).range(of: "1").location
        controller.adoptMultiCursor(
            try carets([offset, offset + 1], source: source)
        )
        controller.multiCursorPolicy = { operation in
            switch operation {
            case .tableCommand: .collapse
            case .formattingCommand: .refuse
            default: operation.outcome
            }
        }

        XCTAssertTrue(controller.perform(.insertTableRowBelow))
        XCTAssertNil(controller.multiCursorSelection)
        XCTAssertTrue(
            controller.textView.string.contains("| 1 | 2 |\n|     |     |"),
            controller.textView.string
        )
    }

    func testReturnAndTabAreRefused() throws {
        let source = "- alpha\n- beta"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([2, 11], source: source))

        XCTAssertTrue(
            controller.textView(
                controller.textView,
                doCommandBy: #selector(NSResponder.insertNewline(_:))
            )
        )
        XCTAssertTrue(
            controller.textView(
                controller.textView,
                doCommandBy: #selector(NSResponder.insertTab(_:))
            )
        )
        XCTAssertTrue(
            controller.textView(
                controller.textView,
                doCommandBy: #selector(NSResponder.insertBacktab(_:))
            )
        )
        XCTAssertEqual(controller.textView.string, source)
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [2..<2, 11..<11]
        )
        XCTAssertEqual(document.revision, 1)
    }

    func testTypingBatchesWithoutAutoPair() throws {
        let source = "alpha beta"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 6], source: source))

        controller.textView.insertText(
            "(",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(controller.textView.string, "(alpha (beta")
        XCTAssertFalse(controller.textView.string.contains("()"))
        XCTAssertEqual(document.revision, 2)
    }

    func testRichPasteIsRefusedAndPlainPasteBatches() throws {
        let source = "alpha beta"
        let (document, controller) = makeController(source: source)
        controller.clipboard = scratchPasteboard("paste")
        controller.adoptMultiCursor(try carets([0, 6], source: source))

        // Each refused flavour carries a plain-text fallback that would
        // visibly paste if the refusal were routed as a plain paste. The old
        // fixture combined PNG and HTML with no `.string`, so either branch
        // could have been mis-routed and still produced a no-op.
        controller.clipboard.clearContents()
        controller.clipboard.setData(Data([0x89]), forType: .png)
        controller.clipboard.setString("12", forType: .string)
        controller.textView.paste(nil)
        XCTAssertEqual(controller.textView.string, source)
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<0, 6..<6]
        )

        controller.clipboard.clearContents()
        controller.clipboard.setString("<b>x</b>", forType: .html)
        controller.clipboard.setString("12", forType: .string)
        controller.textView.paste(nil)
        XCTAssertEqual(controller.textView.string, source)
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<0, 6..<6]
        )

        controller.clipboard.clearContents()
        controller.clipboard.setString("12", forType: .string)
        controller.textView.paste(nil)
        XCTAssertEqual(controller.textView.string, "12alpha 12beta")
        XCTAssertEqual(document.revision, 2)
    }

    func testLinkPopoverCollapsesFirst() throws {
        let source = "alpha beta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 6], source: source))

        controller.presentLinkPopover()
        XCTAssertNil(controller.multiCursorSelection)
    }

    func testSmartSelectAllCollapsesFirst() throws {
        let source = "**alpha** beta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([2, 6], source: source))

        _ = controller.smartSelectAll()
        XCTAssertNil(controller.multiCursorSelection)
    }

    func testNavigationPreservesTheCaretSet() throws {
        let source = "alpha beta gamma"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 6], source: source))

        // Edit in Source, review markers, and find all move the native
        // selection through this path; it is primary-only. The primary caret
        // moves to the selection, and the other carets stay.
        controller.select(range: 11..<16)
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [6..<6, 11..<16]
        )
        XCTAssertEqual(
            controller.multiCursorSelection?.primaryRange,
            11..<16
        )
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: 11, length: 5)
        )

        // The model primary follows the navigation, so typing lands on what
        // the user sees selected. With the primary stuck at 0 and 6 this
        // produced "Xalpha Xbeta gamma" while "gamma" was visibly selected.
        controller.textView.insertText(
            "X",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(controller.textView.string, "alpha Xbeta X")
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [7..<7, 13..<13]
        )
        XCTAssertEqual(
            controller.multiCursorSelection?.primaryRange,
            13..<13
        )
    }

    /// The bracket the Find overrides install. AppKit's finder cannot run in
    /// a windowless test process, but both overrides must read the sender's
    /// tag inside `performNavigation`; a menu item that records the view's
    /// navigation depth when the superclass reads its tag proves the bracket
    /// exists, and fails if an override stops installing it.
    func testBothFindOverridesBracketTheNativeAction() {
        let (_, controller) = makeController(source: "alpha beta gamma")
        let textView = controller.textView
        for entryPoint in ["textFinder", "findPanel"] {
            let item = TagSpyMenuItem()
            item.tag = entryPoint == "textFinder"
                ? NSTextFinder.Action.setSearchString.rawValue
                : Int(NSFindPanelAction.next.rawValue)
            var depths: [Int] = []
            item.onTagRead = { depths.append(textView.navigationDepth) }
            if entryPoint == "textFinder" {
                textView.performTextFinderAction(item)
            } else {
                textView.performFindPanelAction(item)
            }
            // The panel action can forward to the finder, nesting the
            // bracket; every read must still happen inside one.
            XCTAssertFalse(depths.isEmpty, entryPoint)
            XCTAssertGreaterThanOrEqual(depths.min() ?? 0, 1, entryPoint)
            XCTAssertEqual(textView.navigationDepth, 0, entryPoint)
        }
    }

    /// The behaviour the bracket protects: a selection change made inside a
    /// navigation is primary-only, even while the text view is first
    /// responder and the pointer heuristic would otherwise collapse.
    func testFindNavigationDoesNotCollapseTheSet() throws {
        let source = "alpha beta gamma"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(try carets([0, 6], source: source))
        controller.isSelectionChangeUserDriven = { true }

        controller.textView.performNavigation {
            controller.textView.setSelectedRange(
                NSRange(location: 11, length: 5)
            )
        }

        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [6..<6, 11..<16]
        )
        XCTAssertEqual(
            controller.multiCursorSelection?.primaryRange,
            11..<16
        )
    }
}

/// A menu item that reports when AppKit reads its tag, which both find
/// entry points do synchronously inside the override's navigation bracket.
private final class TagSpyMenuItem: NSMenuItem {
    var onTagRead: (() -> Void)?

    override var tag: Int {
        get {
            onTagRead?()
            return super.tag
        }
        set { super.tag = newValue }
    }
}
