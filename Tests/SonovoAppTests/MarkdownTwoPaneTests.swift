import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MarkdownTwoPaneTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-two-pane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func makePair() throws -> (
        workspace: MarkdownWorkspace,
        first: MarkdownDocument,
        second: MarkdownDocument,
        directory: URL
    ) {
        let directory = try temporaryDirectory()
        let firstURL = directory.appendingPathComponent("first.md")
        let secondURL = directory.appendingPathComponent("second.md")
        try Data("alpha\n".utf8).write(to: firstURL)
        try Data("beta\n".utf8).write(to: secondURL)
        let workspace = MarkdownWorkspace()
        let first = try XCTUnwrap(workspace.open(url: firstURL))
        let second = try XCTUnwrap(workspace.open(url: secondURL))
        first.mode = .source
        second.mode = .source
        workspace.show(first, inPane: .primary)
        workspace.show(second, inPane: .secondary)
        return (workspace, first, second, directory)
    }

    func testSecondPaneShowsADifferentDocument() throws {
        let (workspace, first, second, directory) = try makePair()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(workspace.primaryDocument?.id, first.id)
        XCTAssertEqual(workspace.secondaryDocument?.id, second.id)
        XCTAssertEqual(workspace.focusedDocument?.id, second.id)
        XCTAssertEqual(workspace.focusedPane, .secondary)
        XCTAssertEqual(workspace.documents.count, 2)
    }

    func testFocusRoutesTheSelectedDocument() throws {
        let (workspace, first, second, directory) = try makePair()
        defer { try? FileManager.default.removeItem(at: directory) }

        workspace.focus(first)
        XCTAssertEqual(workspace.selectedDocument?.id, first.id)
        XCTAssertEqual(workspace.focusedPane, .primary)

        workspace.focus(second)
        XCTAssertEqual(workspace.selectedDocument?.id, second.id)
        XCTAssertEqual(workspace.focusedPane, .secondary)
    }

    func testFindTargetsTheFocusedPane() throws {
        let (workspace, first, second, directory) = try makePair()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstController = workspace.controller(for: first)
        let secondController = workspace.controller(for: second)

        workspace.focus(first)
        XCTAssertTrue(workspace.sourceFindTarget() === firstController)

        workspace.focus(second)
        XCTAssertTrue(workspace.sourceFindTarget() === secondController)

        // Rendered mode is served by the reader's own find bar, not a
        // retained source editor.
        second.mode = .rendered
        XCTAssertNil(workspace.sourceFindTarget())
    }

    func testDuplicateDocumentIsFocusedNotCloned() throws {
        let (workspace, first, second, directory) = try makePair()
        defer { try? FileManager.default.removeItem(at: directory) }

        workspace.show(first, inPane: .secondary)
        XCTAssertEqual(workspace.secondaryDocument?.id, second.id)
        XCTAssertEqual(workspace.focusedDocument?.id, first.id)

        workspace.show(second, inPane: .primary)
        XCTAssertEqual(workspace.primaryDocument?.id, first.id)
        XCTAssertEqual(workspace.focusedDocument?.id, second.id)
        XCTAssertEqual(workspace.documents.count, 2)
    }

    func testClosingAPaneKeepsBothDocumentsOpen() throws {
        let (workspace, first, second, directory) = try makePair()
        defer { try? FileManager.default.removeItem(at: directory) }

        workspace.closeSplitPane()
        XCTAssertNil(workspace.secondaryDocument)
        XCTAssertEqual(workspace.documents.count, 2)
        XCTAssertEqual(workspace.primaryDocument?.id, first.id)
        XCTAssertEqual(workspace.focusedDocument?.id, first.id)
        XCTAssertTrue(workspace.documents.contains { $0.id == second.id })
    }

    func testClosingTheSecondaryDocumentCollapsesToThePrimary() async throws {
        let (workspace, first, second, directory) = try makePair()
        defer { try? FileManager.default.removeItem(at: directory) }

        let closed = await workspace.close(second)
        XCTAssertTrue(closed)
        XCTAssertNil(workspace.secondaryDocument)
        XCTAssertEqual(workspace.documents.count, 1)
        XCTAssertEqual(workspace.primaryDocument?.id, first.id)
        XCTAssertEqual(workspace.focusedDocument?.id, first.id)
    }

    func testClosingThePrimaryPromotesTheSecondary() async throws {
        let (workspace, first, second, directory) = try makePair()
        defer { try? FileManager.default.removeItem(at: directory) }

        let closed = await workspace.close(first)
        XCTAssertTrue(closed)
        XCTAssertNil(workspace.secondaryDocument)
        XCTAssertEqual(workspace.documents.count, 1)
        XCTAssertEqual(workspace.primaryDocument?.id, second.id)
        XCTAssertEqual(workspace.focusedDocument?.id, second.id)
    }

    func testPanesKeepTheirOwnModes() throws {
        let (workspace, first, second, directory) = try makePair()
        defer { try? FileManager.default.removeItem(at: directory) }
        first.mode = .rendered
        second.mode = .source

        workspace.focus(first)
        XCTAssertEqual(
            workspace.primaryDocument?.mode,
            .rendered
        )
        workspace.focus(second)
        XCTAssertEqual(
            workspace.secondaryDocument?.mode,
            .source
        )
    }

    func testUndoHistoryIsIsolatedPerPane() throws {
        let (workspace, first, second, directory) = try makePair()
        defer { try? FileManager.default.removeItem(at: directory) }

        workspace.controller(for: first).textView.setSelectedRange(
            NSRange(location: 0, length: 5)
        )
        workspace.controller(for: second).textView.setSelectedRange(
            NSRange(location: 0, length: 4)
        )
        workspace.perform(.toggleStrong, on: first)
        workspace.perform(.toggleStrong, on: second)
        XCTAssertEqual(first.source, "**alpha**\n")
        XCTAssertEqual(second.source, "**beta**\n")

        second.undoManager.undo()
        XCTAssertEqual(first.source, "**alpha**\n")
        XCTAssertEqual(second.source, "beta\n")

        first.undoManager.undo()
        XCTAssertEqual(first.source, "alpha\n")
    }

    func testTwoDocumentPanesAndTheSurfaceSplitAreExclusive() throws {
        let (workspace, first, second, directory) = try makePair()
        defer { try? FileManager.default.removeItem(at: directory) }
        workspace.closeSplitPane()

        workspace.setSplitView(true, for: first)
        XCTAssertTrue(workspace.isSplitView(first))

        workspace.show(second, inPane: .secondary)
        XCTAssertFalse(workspace.isSplitView(first))
        XCTAssertEqual(workspace.secondaryDocument?.id, second.id)

        workspace.setSplitView(true, for: second)
        XCTAssertFalse(workspace.isSplitView(second))
    }
}
