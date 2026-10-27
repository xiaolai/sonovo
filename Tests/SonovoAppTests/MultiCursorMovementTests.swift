import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MultiCursorMovementTests: XCTestCase {
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

    private func command(
        _ controller: MarkdownEditorController,
        _ selector: Selector
    ) -> Bool {
        controller.textView(
            controller.textView,
            doCommandBy: selector
        )
    }

    func testVerticalMotionKeepsTheGoalColumnAcrossAShortLine() throws {
        let source = "0123456789\nabc\n0123456789"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try carets([7, 11], primary: 0, source: source)
        )
        let revision = document.revision
        let canUndo = document.undoManager.canUndo

        XCTAssertTrue(command(controller, #selector(NSResponder.moveDown(_:))))
        // 7 -> 14 (the short line clamps to its end); 11 -> 15 (column 0).
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [14..<14, 15..<15]
        )
        XCTAssertTrue(command(controller, #selector(NSResponder.moveDown(_:))))
        // The first caret returns to its goal column on the third line; the
        // second is already on the last line and keeps its place.
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [15..<15, 22..<22]
        )

        XCTAssertTrue(command(controller, #selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [11..<11, 14..<14]
        )
        XCTAssertTrue(command(controller, #selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<0, 7..<7]
        )
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.undoManager.canUndo, canUndo)
    }

    func testVerticalMotionUsesWrappedDisplayLines() throws {
        let long = String(repeating: "wrap-word ", count: 12)
        let source = "\(long)\nshort"
        let (_, controller) = makeController(source: source)
        let model = try carets([3, 30], primary: 0, source: source)
        controller.adoptMultiCursor(model)
        let lines = TextKitLineProvider(textView: controller.textView)
        let before = model.carets.map {
            lines.line(containing: $0.active).flatMap {
                lines.lines.firstIndex(of: $0)
            }
        }
        XCTAssertNotNil(before[0])
        XCTAssertNotNil(before[1])

        XCTAssertTrue(command(controller, #selector(NSResponder.moveDown(_:))))
        guard let moved = controller.multiCursorSelection else {
            return XCTFail("movement collapsed the set")
        }
        XCTAssertEqual(moved.count, 2)
        XCTAssertNotEqual(moved.ranges, model.ranges)
        // "Any later display line" passed even for a regression that skipped
        // a wrapped line. Each caret must land on the very next display line,
        // at its own column (clamped only by a shorter target line).
        for (index, caret) in moved.carets.enumerated() {
            guard let start = before[index],
                  let origin = lines.line(containing: model.carets[index].active),
                  let line = lines.line(containing: caret.active),
                  let position = lines.lines.firstIndex(of: line) else {
                return XCTFail("caret left the layout")
            }
            XCTAssertEqual(position, start + 1, "skipped a display line")
            XCTAssertEqual(
                line.column(of: caret.active),
                min(origin.column(of: model.carets[index].active), line.range.count)
            )
        }
    }

    func testShiftRightExtendsEveryCaretAndKeepsAnchors() throws {
        let source = "alpha beta gamma"
        let (document, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try carets([0, 6, 11], primary: 1, source: source)
        )
        let revision = document.revision

        XCTAssertTrue(
            command(
                controller,
                #selector(NSResponder.moveRightAndModifySelection(_:))
            )
        )
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<1, 6..<7, 11..<12]
        )
        XCTAssertEqual(
            controller.multiCursorSelection?.carets.map(\.anchor),
            [0, 6, 11]
        )
        XCTAssertEqual(document.revision, revision)

        XCTAssertTrue(
            command(
                controller,
                #selector(NSResponder.moveLeftAndModifySelection(_:))
            )
        )
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [0..<0, 6..<6, 11..<11]
        )
    }

    func testWordAndLineMotionMoveEveryCaret() throws {
        let source = "alpha beta\ngamma delta"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try carets([0, 13], primary: 0, source: source)
        )

        XCTAssertTrue(
            command(controller, #selector(NSResponder.moveWordRight(_:)))
        )
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [6..<6, 17..<17]
        )

        XCTAssertTrue(
            command(controller, #selector(NSResponder.moveToEndOfLine(_:)))
        )
        XCTAssertEqual(
            controller.multiCursorSelection?.ranges,
            [10..<10, 22..<22]
        )

        XCTAssertTrue(
            command(
                controller,
                #selector(NSResponder.moveToBeginningOfDocument(_:))
            )
        )
        // Two carets merged at one offset leave a single caret, so
        // multi-cursor mode ends with the native selection at the primary.
        XCTAssertNil(controller.multiCursorSelection)
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: 0, length: 0)
        )
    }

    func testEscapeCollapsesToThePrimary() throws {
        let source = "alpha beta gamma"
        let (_, controller) = makeController(source: source)
        controller.adoptMultiCursor(
            try carets([6, 11], primary: 0, source: source)
        )

        controller.textView.cancelOperation(nil)
        XCTAssertNil(controller.multiCursorSelection)
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: 6, length: 0)
        )
    }
}
