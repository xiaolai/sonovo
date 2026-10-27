import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MultiCursorPlacementTests: XCTestCase {
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
        controller.textView.frame = NSRect(
            x: 0,
            y: 0,
            width: 400,
            height: 400
        )
        controller.textView.textContainer?.widthTracksTextView = false
        controller.textView.textContainer?.containerSize = NSSize(
            width: 400,
            height: CGFloat.greatestFiniteMagnitude
        )
        return (document, controller)
    }

    /// The view point of the caret before `offset` on the laid-out source.
    private func point(
        for offset: Int,
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
                let local = offset - lower
                result = NSPoint(
                    x: fragment.layoutFragmentFrame.minX + inset.width
                        + line.locationForCharacter(at: local).x,
                    y: fragment.layoutFragmentFrame.minY + inset.height
                        + line.typographicBounds.midY
                )
                return false
            }
            return true
        }
        return result
    }

    private func commandClick(
        _ controller: MarkdownEditorController,
        at point: NSPoint
    ) {
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: controller.textView.convert(point, to: nil),
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            return XCTFail("could not build a mouse event")
        }
        controller.textView.mouseDown(with: event)
    }

    func testCommandClickTogglesCaretsAndMovesThePrimary() throws {
        let source = "alpha beta gamma"
        let (document, controller) = makeController(source: source)
        let revision = document.revision
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))

        // Command-click adds to the caret set the user already has.
        for offset in [2, 7, 13] {
            let point = try XCTUnwrap(point(for: offset, in: controller.textView))
            commandClick(controller, at: point)
        }
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<0, 2..<2, 7..<7, 13..<13]
        )
        XCTAssertEqual(
            controller.multiCursorSelection?.primaryRange,
            13..<13
        )
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: 13, length: 0)
        )

        // A second Command-click on an existing caret toggles it off.
        let point = try XCTUnwrap(point(for: 7, in: controller.textView))
        commandClick(controller, at: point)
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<0, 2..<2, 13..<13]
        )
        XCTAssertEqual(
            controller.multiCursorSelection?.primaryRange,
            13..<13
        )
        XCTAssertEqual(document.revision, revision)
    }

    func testAddNextOccurrenceSelectsTheWordAndWraps() throws {
        let source = "alpha beta alpha gamma alpha"
        let (document, controller) = makeController(source: source)
        controller.textView.setSelectedRange(NSRange(location: 2, length: 0))
        let revision = document.revision

        XCTAssertTrue(controller.perform(.addNextOccurrence))
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<5, 11..<16]
        )
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: 11, length: 5)
        )

        XCTAssertTrue(controller.perform(.addNextOccurrence))
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<5, 11..<16, 23..<28]
        )
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: 23, length: 5)
        )

        // Every occurrence is placed: the next command changes nothing.
        XCTAssertFalse(controller.perform(.addNextOccurrence))
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<5, 11..<16, 23..<28]
        )
        XCTAssertEqual(document.revision, revision)
    }

    func testSelectAllOccurrencesKeepsTheCaretOccurrencePrimary() throws {
        let source = "alpha beta alpha gamma alpha"
        let (_, controller) = makeController(source: source)
        controller.textView.setSelectedRange(NSRange(location: 13, length: 0))

        XCTAssertTrue(controller.perform(.selectAllOccurrences))
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<5, 11..<16, 23..<28]
        )
        XCTAssertEqual(
            controller.multiCursorSelection?.primaryRange,
            11..<16
        )
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: 11, length: 5)
        )
    }

    func testSelectAllOccurrencesRefusesBeyondTheCap() throws {
        let source = String(repeating: "ab ", count: 101)
        let (document, controller) = makeController(source: source)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let revision = document.revision
        let canUndo = document.undoManager.canUndo

        XCTAssertFalse(controller.perform(.selectAllOccurrences))
        XCTAssertNil(controller.multiCursorSelection)
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: 0, length: 0)
        )
        XCTAssertNotNil(controller.lastCommandError)
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.undoManager.canUndo, canUndo)
    }

    func testPlacementCommandsAreInTheCatalogAndAvailable() throws {
        let source = "alpha  beta alpha"
        let (_, controller) = makeController(source: source)
        controller.textView.setSelectedRange(NSRange(location: 2, length: 0))
        let catalog = MarkdownCommandCatalog.entries.map(\.command)
        XCTAssertTrue(catalog.contains(.addNextOccurrence))
        XCTAssertTrue(catalog.contains(.selectAllOccurrences))

        let available = controller.availableCommands()
        XCTAssertTrue(available.contains(.addNextOccurrence))
        XCTAssertTrue(available.contains(.selectAllOccurrences))

        // A caret between two spaces names nothing: both commands and the
        // palette entry are unavailable.
        controller.textView.setSelectedRange(NSRange(location: 6, length: 0))
        let unavailable = controller.availableCommands()
        XCTAssertFalse(unavailable.contains(.addNextOccurrence))
        XCTAssertFalse(unavailable.contains(.selectAllOccurrences))
    }
}
