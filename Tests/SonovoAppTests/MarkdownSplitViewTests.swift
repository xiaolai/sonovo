import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MarkdownSplitViewTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func openDocument(
        _ source: String
    ) throws -> (MarkdownWorkspace, MarkdownDocument, URL) {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("split.md")
        try Data(source.utf8).write(to: url)
        let workspace = MarkdownWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        // The mounted editor starts the first parse; a workspace alone does
        // not, because a document can open without an editor surface.
        workspace.controller(for: document).attach()
        return (workspace, document, directory)
    }

    private func waitForReady(
        _ workspace: MarkdownWorkspace,
        _ document: MarkdownDocument
    ) async -> MarkdownParseOutput? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case let .ready(output) = workspace.parseCoordinator.state(
                for: document.id
            ), output.revision == document.revision {
                return output
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func testSplitRemembersTheModeItCameFrom() throws {
        let (workspace, document, directory) = try openDocument("alpha\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        document.mode = .rendered

        workspace.setSplitView(true, for: document)
        XCTAssertTrue(workspace.isSplitView(document))
        XCTAssertEqual(document.mode, .source)

        workspace.setSplitView(false, for: document)
        XCTAssertFalse(workspace.isSplitView(document))
        XCTAssertEqual(document.mode, .rendered)
    }

    func testSourceOnlyDocumentRefusesSplit() throws {
        let (workspace, document, directory) = try openDocument("alpha\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        document.setNestingLimit(true)

        let modeBefore = document.mode
        workspace.setSplitView(true, for: document)
        XCTAssertFalse(workspace.isSplitView(document))
        XCTAssertEqual(document.mode, modeBefore)
    }

    func testSplitKeepsBothReadingPositions() throws {
        let (workspace, document, directory) = try openDocument(
            "one two three\n\nfour five six\n"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        document.mode = .source
        document.selection = 4..<7
        workspace.captureReadingPosition(for: document)
        let rendered = RenderedReadingAnchor(
            blockOffset: 14,
            blockKind: .paragraph,
            fraction: 0.4
        )
        workspace.recordRenderedAnchor(rendered, for: document)

        workspace.setSplitView(true, for: document)
        XCTAssertEqual(document.selection, 4..<7)
        XCTAssertEqual(
            workspace.pendingRenderedAnchors[document.id],
            rendered
        )

        workspace.setSplitView(false, for: document)
        let stored = workspace.storedReadingAnchors(for: document)
        XCTAssertEqual(document.selection, 4..<7)
        XCTAssertEqual(stored.rendered, rendered)
    }

    func testUndoStaysSharedWhileSplit() throws {
        let (workspace, document, directory) = try openDocument("abc\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        workspace.setSplitView(true, for: document)
        let controller = workspace.controller(for: document)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 3))

        workspace.perform(.toggleStrong, on: document)
        XCTAssertEqual(document.source, "**abc**\n")
        XCTAssertEqual(controller.textView.string, "**abc**\n")

        document.undoManager.undo()
        XCTAssertEqual(document.source, "abc\n")
        document.undoManager.redo()
        XCTAssertEqual(document.source, "**abc**\n")
    }

    func testScrollSyncRefusesWithoutASplitOrARender() async throws {
        let (workspace, document, directory) = try openDocument("alpha\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(
            workspace.splitSyncRefusalReason(for: document),
            "Split view is off."
        )

        workspace.setSplitView(true, for: document)
        let ready = await waitForReady(workspace, document)
        XCTAssertNotNil(ready)
        XCTAssertNil(workspace.splitSyncRefusalReason(for: document))

        workspace.parseCoordinator.release(documentID: document.id)
        XCTAssertEqual(
            workspace.splitSyncRefusalReason(for: document),
            "Scroll sync needs a current render."
        )
    }

    func testSourceScrollMapsToTheRenderedBlock() async throws {
        let (workspace, document, directory) = try openDocument("alpha\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        workspace.setSplitView(true, for: document)
        let maybeOutput = await waitForReady(workspace, document)
        let output = try XCTUnwrap(
            maybeOutput,
            "the document did not finish parsing"
        )
        let range = try XCTUnwrap(output.ast.blocks.first?.range)

        workspace.sourceDidScroll(
            SourceReadingAnchor(
                lineOffset: range.lowerBound,
                viewportOffset: 0
            ),
            in: document
        )
        XCTAssertEqual(workspace.scrollTargets[document.id], "block-0")
    }

    func testSourceScrollRefusesWhitespaceBetweenBlocks() async throws {
        let source = "alpha\n\nbeta\n"
        let (workspace, document, directory) = try openDocument(source)
        defer { try? FileManager.default.removeItem(at: directory) }
        workspace.setSplitView(true, for: document)
        let maybeOutput = await waitForReady(workspace, document)
        _ = try XCTUnwrap(maybeOutput)
        let gap = (source as NSString).range(of: "\n\n")
        XCTAssertNotEqual(gap.location, NSNotFound)

        workspace.sourceDidScroll(
            SourceReadingAnchor(
                lineOffset: gap.location + 1,
                viewportOffset: 0
            ),
            in: document
        )
        XCTAssertNil(workspace.scrollTargets[document.id])
    }

    func testRenderedScrollMapsToTheSourceBlock() async throws {
        let (workspace, document, directory) = try openDocument(
            "alpha\n\nbeta\n"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        workspace.setSplitView(true, for: document)
        let maybeOutput = await waitForReady(workspace, document)
        let output = try XCTUnwrap(
            maybeOutput,
            "the document did not finish parsing"
        )
        let paragraph = try XCTUnwrap(
            output.ast.blocks.last
        )
        let range = try XCTUnwrap(paragraph.range)

        workspace.renderedDidScroll(
            RenderedReadingAnchor(
                blockOffset: range.lowerBound,
                blockKind: .paragraph,
                fraction: 0.5
            ),
            in: document
        )
        XCTAssertEqual(
            workspace.sourceScrollTargets[document.id],
            range.lowerBound
        )
        XCTAssertEqual(
            workspace.storedReadingAnchors(for: document).rendered?
                .blockOffset,
            range.lowerBound
        )
    }

    func testSplitScrollSyncEchoIsSuppressed() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let (workspace, document, directory) = try openDocument(
            "alpha\n\nbeta\n"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        workspace.splitSyncNow = { now }
        workspace.setSplitView(true, for: document)
        let maybeOutput = await waitForReady(workspace, document)
        let output = try XCTUnwrap(
            maybeOutput,
            "the document did not finish parsing"
        )
        let first = try XCTUnwrap(output.ast.blocks.first?.range)
        let second = try XCTUnwrap(output.ast.blocks.last?.range)

        workspace.renderedDidScroll(
            RenderedReadingAnchor(
                blockOffset: second.lowerBound,
                blockKind: .paragraph,
                fraction: 0
            ),
            in: document
        )
        XCTAssertEqual(
            workspace.sourceScrollTargets[document.id],
            second.lowerBound
        )

        // The source pane reports the programmatic scroll it just received;
        // that report must not bounce back into a new rendered target.
        workspace.sourceDidScroll(
            SourceReadingAnchor(
                lineOffset: first.lowerBound,
                viewportOffset: 0
            ),
            in: document
        )
        XCTAssertNil(workspace.scrollTargets[document.id])

        now = now.addingTimeInterval(1)
        workspace.sourceDidScroll(
            SourceReadingAnchor(
                lineOffset: first.lowerBound,
                viewportOffset: 0
            ),
            in: document
        )
        XCTAssertEqual(workspace.scrollTargets[document.id], "block-0")
    }

    func testScrollSyncCanBeTurnedOff() async throws {
        let (workspace, document, directory) = try openDocument("alpha\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        workspace.setSplitView(true, for: document)
        let maybeOutput = await waitForReady(workspace, document)
        let output = try XCTUnwrap(
            maybeOutput,
            "the document did not finish parsing"
        )
        let range = try XCTUnwrap(output.ast.blocks.first?.range)
        workspace.isSplitScrollSynced = false

        workspace.sourceDidScroll(
            SourceReadingAnchor(
                lineOffset: range.lowerBound,
                viewportOffset: 0
            ),
            in: document
        )
        XCTAssertNil(workspace.scrollTargets[document.id])
    }
}
