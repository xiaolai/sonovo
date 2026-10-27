import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MultiCursorWorkspaceTests: XCTestCase {
    private func carets(
        _ offsets: [Int],
        source: String
    ) throws -> MultiCursorSelection {
        try MultiCursorSelection(
            offsets.map {
                MultiCursorSelection.Caret(anchor: $0, active: $0)
            },
            primary: 0,
            source: source
        )
    }

    private func makeWorkspaceAndDocument(
        _ source: String
    ) -> (MarkdownWorkspace, MarkdownDocument, MarkdownEditorController) {
        let workspace = MarkdownWorkspace(readsDemoEnvironment: false)
        let document = workspace.newDocument()
        try? document.replaceSource(source)
        let controller = workspace.controller(for: document)
        return (workspace, document, controller)
    }

    func testModeSwitchCollapsesAndClearsTheOverlay() throws {
        let (workspace, document, controller) = makeWorkspaceAndDocument(
            "alpha beta"
        )
        controller.adoptMultiCursor(try carets([0, 6], source: "alpha beta"))
        XCTAssertNotNil(controller.multiCursorSelection)
        // Unwrap and require it populated first: `?? true` passed when the
        // overlay was missing or never fed, which is the failure this test
        // exists to catch.
        let overlay = try XCTUnwrap(controller.caretOverlay)
        XCTAssertFalse(overlay.isEmpty)

        workspace.setMode(.rendered, for: document)
        XCTAssertNil(controller.multiCursorSelection)
        XCTAssertTrue(overlay.isEmpty)
    }

    /// Reload is a collapse surface in the policy table. The path used to
    /// rely on the changed text resetting the caret set, which missed a
    /// reload whose source is canonically unchanged.
    func testReloadCollapsesThroughThePolicyTable() throws {
        let (workspace, document, controller) = makeWorkspaceAndDocument(
            "alpha beta"
        )
        controller.adoptMultiCursor(try carets([0, 6], source: "alpha beta"))
        XCTAssertNotNil(controller.multiCursorSelection)
        workspace.multiCursorPolicy = { operation in
            operation == .reload ? .collapse : operation.outcome
        }

        workspace.reload(document)

        XCTAssertNil(controller.multiCursorSelection)
    }

    func testDisablingSplitCollapsesTheCaretSet() throws {
        let (workspace, document, controller) = makeWorkspaceAndDocument(
            "alpha beta"
        )
        // Start from Rendered so closing the split restores Rendered without
        // a mode change that would otherwise do the collapsing.
        workspace.setMode(.rendered, for: document)
        workspace.setSplitView(true, for: document)
        controller.adoptMultiCursor(try carets([0, 6], source: "alpha beta"))
        XCTAssertNotNil(controller.multiCursorSelection)

        workspace.setSplitView(false, for: document)
        XCTAssertNil(controller.multiCursorSelection)
        XCTAssertTrue(controller.caretOverlay?.isEmpty ?? true)
    }

    func testSelectingAnotherDocumentCollapsesTheDepartedOne() throws {
        let workspace = MarkdownWorkspace(readsDemoEnvironment: false)
        let first = workspace.newDocument()
        try? first.replaceSource("alpha beta")
        let second = workspace.newDocument()
        try? second.replaceSource("gamma delta")
        workspace.select(first)
        let firstController = workspace.controller(for: first)
        firstController.adoptMultiCursor(
            try carets([0, 6], source: "alpha beta")
        )
        XCTAssertNotNil(firstController.multiCursorSelection)

        workspace.select(second)
        XCTAssertNil(firstController.multiCursorSelection)
    }

    func testSplitViewCollapses() throws {
        let (workspace, document, controller) = makeWorkspaceAndDocument(
            "alpha beta"
        )
        controller.adoptMultiCursor(try carets([0, 6], source: "alpha beta"))

        workspace.setSplitView(true, for: document)
        XCTAssertNil(controller.multiCursorSelection)
    }

    func testCollapseSurfacesConsultThePolicyTable() throws {
        let (workspace, document, controller) = makeWorkspaceAndDocument(
            "alpha beta"
        )
        controller.adoptMultiCursor(try carets([0, 6], source: "alpha beta"))
        // Deliberately wrong for production, right for the wiring: the table
        // is the authority, so a `primaryOnly` mode switch must not collapse.
        workspace.multiCursorPolicy = { operation in
            operation == .modeSwitch ? .primaryOnly : operation.outcome
        }
        workspace.setMode(.rendered, for: document)
        XCTAssertNotNil(controller.multiCursorSelection)
    }

    func testSplitFocusChangeCollapsesThePaneLeft() throws {
        let workspace = MarkdownWorkspace(readsDemoEnvironment: false)
        let first = workspace.newDocument()
        try? first.replaceSource("alpha beta")
        let second = workspace.newDocument()
        try? second.replaceSource("gamma delta")
        XCTAssertNotEqual(first.id, second.id)
        // The newest document is selected; put the older one in the second
        // pane and make the selected one the focused pane.
        workspace.show(first, inPane: .secondary)
        workspace.focus(second)

        let firstController = workspace.controller(for: first)
        let secondController = workspace.controller(for: second)
        firstController.adoptMultiCursor(
            try carets([0, 6], source: "alpha beta")
        )
        secondController.adoptMultiCursor(
            try carets([0, 6], source: "gamma delta")
        )
        workspace.focus(first)
        XCTAssertNil(secondController.multiCursorSelection)
        XCTAssertNotNil(firstController.multiCursorSelection)
    }
}
