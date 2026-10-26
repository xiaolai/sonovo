import AppKit
import SwiftUI
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MarkdownTableGridTests: XCTestCase {
    private func makeController(
        _ source: String
    ) -> (MarkdownDocument, MarkdownEditorController) {
        let document = MarkdownDocument(untitledWith: MarkdownFileStore())
        try? document.replaceSource(source)
        document.undoManager.removeAllActions()
        let cache = MarkdownEditorCache()
        let entry = cache.entry(
            for: document,
            parseCoordinator: MarkdownParseCoordinator(
                service: MarkdownParseService()
            ),
            parseDebounce: 0
        )
        return (document, entry.controller)
    }

    private func offset(of text: String, in source: String) -> Int {
        (source as NSString).range(of: text).location
    }

    func testCellCommitIsOneUndoableEditPerCell() throws {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        let (document, controller) = makeController(source)
        XCTAssertNotNil(
            controller.beginTableEditing(
                at: offset(of: "1", in: source)
            )
        )

        guard case let .updated(first) = controller.commitTableCell(
            row: 1,
            column: 0,
            text: "one"
        ) else {
            return XCTFail("first cell commit refused")
        }
        XCTAssertEqual(
            document.source,
            "| A | B |\n| --- | --- |\n| one | 2 |\n"
        )
        XCTAssertEqual(controller.textView.string, document.source)
        XCTAssertEqual(first.content(row: 1, column: 0), "one")
        let selection = try XCTUnwrap(document.selection)
        XCTAssertEqual(
            (document.source as NSString).substring(
                with: NSRange(
                    location: selection.lowerBound,
                    length: selection.count
                )
            ),
            "one"
        )

        guard case .updated = controller.commitTableCell(
            row: 1,
            column: 1,
            text: "two"
        ) else {
            return XCTFail("second cell commit refused")
        }
        XCTAssertEqual(
            document.source,
            "| A | B |\n| --- | --- |\n| one | two |\n"
        )

        document.undoManager.undo()
        XCTAssertEqual(
            document.source,
            "| A | B |\n| --- | --- |\n| one | 2 |\n"
        )
        document.undoManager.undo()
        XCTAssertEqual(document.source, source)
    }

    func testCommitRefusesAfterTheDocumentMoved() throws {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        let (document, controller) = makeController(source)
        XCTAssertNotNil(
            controller.beginTableEditing(
                at: offset(of: "1", in: source)
            )
        )
        try document.replaceSource("A new first line.\n\n" + source)
        let moved = document.source

        guard case let .refused(message) = controller.commitTableCell(
            row: 1,
            column: 0,
            text: "nope"
        ) else {
            return XCTFail("a moved document must refuse the commit")
        }
        XCTAssertTrue(message.contains("changed"))
        XCTAssertEqual(document.source, moved)
        XCTAssertFalse(controller.textView.string.contains("| nope |"))
    }

    func testAlignmentAndStructuralCommands() throws {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        let (document, controller) = makeController(source)
        XCTAssertNotNil(
            controller.beginTableEditing(
                at: offset(of: "A", in: source)
            )
        )

        guard case .updated = controller.performTableCommand(
            .setAlignment(.right),
            row: 0,
            column: 0
        ) else {
            return XCTFail("alignment refused")
        }
        XCTAssertTrue(document.source.contains("| ---: | --- |"))

        guard case let .updated(inserted) = controller.performTableCommand(
            .insertRowBelow,
            row: 0,
            column: 0
        ) else {
            return XCTFail("insert row refused")
        }
        XCTAssertEqual(inserted.rowCount, 3)
        // Header, delimiter, two body rows, and the trailing empty component.
        XCTAssertEqual(
            controller.textView.string.components(separatedBy: "\n").count,
            5
        )

        guard case let .updated(deleted) = controller.performTableCommand(
            .deleteRow,
            row: 1,
            column: 0
        ) else {
            return XCTFail("delete row refused")
        }
        XCTAssertEqual(deleted.rowCount, 2)
        XCTAssertEqual(deleted.content(row: 1, column: 0), "1")
        XCTAssertEqual(
            document.source,
            "| A | B |\n| ---: | --- |\n| 1 | 2 |\n"
        )
    }

    func testCJKAndWideCellCommits() throws {
        let source = """
        | 名 | メモ |
        | --- | --- |
        | 😀 中文 | 值 |
        | B | 二 |
        """
        let (document, controller) = makeController(source)
        XCTAssertNotNil(
            controller.beginTableEditing(
                at: offset(of: "😀", in: source)
            )
        )
        let wide = String(repeating: "很宽", count: 100) + " 😀"
        guard case let .updated(snapshot) = controller.commitTableCell(
            row: 1,
            column: 1,
            text: wide
        ) else {
            return XCTFail("wide CJK commit refused")
        }
        XCTAssertEqual(snapshot.content(row: 1, column: 0), "😀 中文")
        XCTAssertEqual(snapshot.content(row: 1, column: 1), wide)
        XCTAssertEqual(snapshot.content(row: 2, column: 1), "二")
        XCTAssertEqual(controller.textView.string, document.source)
    }

    func testTableGridPopoverLaysOut() throws {
        let source = "| A | B |\n| --- | ---: |\n| 1 | 2 |\n"
        let snapshot = try XCTUnwrap(
            MarkdownTableGrid.snapshot(
                at: 0,
                in: source
            )
        )
        let view = MarkdownTableGridPopoverView(
            snapshot: snapshot,
            onSetCell: { _, _, _ in
                .refused("not used")
            },
            onCommand: { _, _, _ in
                .refused("not used")
            },
            onReload: {
                .refused("not used")
            },
            onClose: {}
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 440)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        XCTAssertGreaterThan(hosting.fittingSize.width, 0)
    }
}
