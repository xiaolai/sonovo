import AppKit
import SwiftUI
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class ReviewCommentsTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func makeDocument(
        _ source: String,
        in directory: URL
    ) throws -> (URL, MarkdownDocument) {
        let url = directory.appendingPathComponent("doc.md")
        try Data(source.utf8).write(to: url)
        return (url, try MarkdownDocument(loading: url))
    }

    private func range(
        of text: String,
        in source: String
    ) -> Range<Int> {
        let ns = source as NSString
        let found = ns.range(of: text)
        return found.location..<(found.location + found.length)
    }

    // MARK: - Adding

    func testAddCommentWritesSidecarAndNeverTheSource() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "alpha note beta\n"
        let (url, document) = try makeDocument(source, in: directory)
        document.selection = range(of: "note", in: source)
        let workspace = MarkdownWorkspace()
        workspace.open(url: url)

        let added = await workspace.addReviewComment(
            to: document,
            body: "Check the note."
        )
        XCTAssertTrue(added)
        XCTAssertEqual(document.source, source)
        XCTAssertEqual(try Data(contentsOf: url), Data(source.utf8))

        let sidecar = ReviewAnchorResolver.sidecarURL(for: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        let loaded = try ReviewSidecar.load(
            for: url,
            documentIdentity: ReviewAnchorResolver.documentIdentity(
                of: source
            )
        )
        XCTAssertEqual(loaded.document.threads.count, 1)
        let thread = try XCTUnwrap(loaded.document.threads.first)
        XCTAssertEqual(thread.anchor.quote, "note")
        XCTAssertEqual(thread.comments.first?.body, "Check the note.")
        XCTAssertEqual(workspace.reviewComments.openCount(for: document), 1)
    }

    func testAddWithoutSelectionIsRefusedWithAMessage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (url, document) = try makeDocument("alpha\n", in: directory)
        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        document.selection = nil

        let added = await workspace.addReviewComment(
            to: document,
            body: "No target."
        )
        XCTAssertFalse(added)
        XCTAssertEqual(
            workspace.reviewComments.state(for: document).error,
            "Select text to comment on."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ReviewAnchorResolver.sidecarURL(for: url).path
            )
        )
    }

    func testUntitledDocumentRefusesComments() async throws {
        let workspace = MarkdownWorkspace()
        let document = workspace.newDocument()
        document.selection = 0..<0
        let added = await workspace.addReviewComment(
            to: document,
            body: "Nowhere to anchor."
        )
        XCTAssertFalse(added)
        XCTAssertEqual(
            workspace.reviewComments.state(for: document).error,
            "Comments need a saved document."
        )
    }

    // MARK: - Drift and reveal

    func testAnchorDriftFollowsTheQuoteAndRevealSelectsIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "alpha note beta\n"
        let (url, document) = try makeDocument(source, in: directory)
        document.selection = range(of: "note", in: source)
        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        let added = await workspace.addReviewComment(
            to: document,
            body: "Anchored."
        )
        let threadID = try XCTUnwrap(
            workspace.reviewComments.placements(for: document).first?.id
        )
        XCTAssertTrue(added)

        // The text moves and the stored offset is stale.
        let edited = "new first line\n\nalpha note beta\n"
        try document.replaceSource(edited)
        let placement = try XCTUnwrap(
            workspace.reviewComments.placements(for: document).first
        )
        let expected = range(of: "note", in: edited)
        XCTAssertEqual(placement.resolution, .drifted(expected))

        document.mode = .rendered
        workspace.revealReviewComment(threadID, in: document)
        XCTAssertEqual(document.mode, .source)
        XCTAssertEqual(document.selection, expected)
        XCTAssertEqual(
            workspace.reviewComments.selectedThreadID,
            threadID
        )
    }

    func testUnanchoredThreadIsKeptButNotRevealed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "alpha note beta\n"
        let (url, document) = try makeDocument(source, in: directory)
        document.selection = range(of: "note", in: source)
        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        _ = await workspace.addReviewComment(to: document, body: "Gone soon.")
        let threadID = try XCTUnwrap(
            workspace.reviewComments.placements(for: document).first?.id
        )
        try document.replaceSource("the quote was deleted\n")
        let placement = try XCTUnwrap(
            workspace.reviewComments.placements(for: document).first
        )
        XCTAssertEqual(placement.resolution, .unresolved(.missing))
        XCTAssertEqual(workspace.reviewComments.openCount(for: document), 1)

        let selectionBefore = document.selection
        workspace.revealReviewComment(threadID, in: document)
        XCTAssertEqual(
            workspace.reviewComments.selectedThreadID,
            threadID
        )
        // The document selection was not moved to a guessed range.
        XCTAssertEqual(document.selection, selectionBefore)
    }

    // MARK: - Mutations

    func testReplyResolveReopenAndDeletePersist() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "alpha note beta\n"
        let (url, document) = try makeDocument(source, in: directory)
        document.selection = range(of: "note", in: source)
        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        _ = await workspace.addReviewComment(to: document, body: "First.")
        let threadID = try XCTUnwrap(
            workspace.reviewComments.placements(for: document).first?.id
        )

        let replied = await workspace.replyToReviewComment(
            threadID,
            in: document,
            body: "Reply."
        )
        XCTAssertTrue(replied)
        let resolved = await workspace.setReviewCommentResolved(
            true,
            threadID: threadID,
            in: document
        )
        XCTAssertTrue(resolved)
        XCTAssertEqual(workspace.reviewComments.openCount(for: document), 0)

        let diskAfterResolve = try ReviewSidecar.load(
            for: url,
            documentIdentity: "id"
        ).document
        XCTAssertEqual(diskAfterResolve.threads[0].comments.count, 2)
        XCTAssertTrue(diskAfterResolve.threads[0].resolved)

        let deleted = await workspace.deleteReviewComment(
            threadID,
            from: document
        )
        XCTAssertTrue(deleted)
        let diskAfterDelete = try ReviewSidecar.load(
            for: url,
            documentIdentity: "id"
        ).document
        XCTAssertTrue(diskAfterDelete.threads.isEmpty)
        XCTAssertEqual(document.source, source)
        XCTAssertEqual(try Data(contentsOf: url), Data(source.utf8))
    }

    // MARK: - External changes

    func testConcurrentWritersRefuseAndOverwriteIsDeliberate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "alpha note beta\n"
        let (url, document) = try makeDocument(source, in: directory)
        document.selection = range(of: "note", in: source)

        let first = ReviewCommentsController(author: "First")
        let second = ReviewCommentsController(author: "Second")
        _ = await first.load(document)
        _ = await second.load(document)

        let firstAdded = await first.addComment(
            to: document,
            selection: document.selection,
            body: "One."
        )
        XCTAssertTrue(firstAdded)
        let secondAdded = await second.addComment(
            to: document,
            selection: document.selection,
            body: "Two."
        )
        XCTAssertFalse(secondAdded)
        let secondState = second.state(for: document)
        XCTAssertTrue(secondState.externalChange)
        XCTAssertNotNil(secondState.pending)

        // The first writer's bytes survive; the second writer did not clobber.
        let onDisk = try ReviewSidecar.load(
            for: url,
            documentIdentity: "id"
        ).document
        XCTAssertEqual(onDisk.threads.map { $0.comments[0].body }, ["One."])
        // The pending local edit is preserved for a deliberate overwrite.
        XCTAssertEqual(
            secondState.pending?.threads.map { $0.comments[0].body },
            ["Two."]
        )

        let overwritten = await second.overwrite(document)
        XCTAssertTrue(overwritten)
        let afterOverwrite = try ReviewSidecar.load(
            for: url,
            documentIdentity: "id"
        ).document
        XCTAssertEqual(
            afterOverwrite.threads.map { $0.comments[0].body },
            ["Two."]
        )
        XCTAssertFalse(second.state(for: document).externalChange)
    }

    func testReloadDiscardsThePendingLocalEdit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "alpha note beta\n"
        let (url, document) = try makeDocument(source, in: directory)
        document.selection = range(of: "note", in: source)
        let first = ReviewCommentsController(author: "First")
        let second = ReviewCommentsController(author: "Second")
        _ = await first.load(document)
        _ = await second.load(document)
        _ = await first.addComment(
            to: document,
            selection: document.selection,
            body: "One."
        )
        let refused = await second.addComment(
            to: document,
            selection: document.selection,
            body: "Two."
        )
        XCTAssertFalse(refused)
        XCTAssertTrue(second.state(for: document).externalChange)

        let reloaded = await second.reload(document)
        XCTAssertTrue(reloaded)
        let state = second.state(for: document)
        XCTAssertFalse(state.externalChange)
        XCTAssertNil(state.pending)
        XCTAssertEqual(
            state.review.threads.map { $0.comments[0].body },
            ["One."]
        )
    }

    func testCorruptSidecarIsRefusedAndLeftUntouched() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "alpha note beta\n"
        let (url, document) = try makeDocument(source, in: directory)
        document.selection = range(of: "note", in: source)
        let sidecar = ReviewAnchorResolver.sidecarURL(for: url)
        let corrupt = Data("{\"threads\": [".utf8)
        try corrupt.write(to: sidecar)

        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        let added = await workspace.addReviewComment(
            to: document,
            body: "Cannot write."
        )
        XCTAssertFalse(added)
        let state = workspace.reviewComments.state(for: document)
        XCTAssertTrue(state.isCorrupt)
        XCTAssertNotNil(state.error)
        XCTAssertEqual(try Data(contentsOf: sidecar), corrupt)
    }

    // MARK: - Identity and margin

    func testSaveAsReloadsTheDestinationSidecar() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "alpha note beta\n"
        let (url, document) = try makeDocument(source, in: directory)
        document.selection = range(of: "note", in: source)
        let controller = ReviewCommentsController(author: "Tester")
        _ = await controller.load(document)
        _ = await controller.addComment(
            to: document,
            selection: document.selection,
            body: "On the first file."
        )
        XCTAssertEqual(
            controller.placements(for: document).count,
            1
        )

        let destination = directory.appendingPathComponent("second.md")
        try await document.saveAs(to: destination)
        let reloaded = await controller.load(document)
        XCTAssertTrue(reloaded)
        XCTAssertTrue(
            controller.placements(for: document).isEmpty,
            "Save As must adopt the destination's sidecar, not carry the old one"
        )
    }

    func testMarginMarkersFollowCommentState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "alpha note beta\n"
        let (url, document) = try makeDocument(source, in: directory)
        document.mode = .source
        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        let controller = workspace.controller(for: document)
        // Creating the text view installs its default empty selection, so the
        // source selection is set after the controller exists.
        document.selection = range(of: "note", in: source)
        XCTAssertTrue(controller.reviewRulerView.commentMarkers.isEmpty)
        XCTAssertFalse(controller.scrollView.rulersVisible)

        let added = await workspace.addReviewComment(
            to: document,
            body: "Marker."
        )
        XCTAssertTrue(
            added,
            "state error: \(workspace.reviewComments.state(for: document).error ?? "none")"
        )
        XCTAssertEqual(
            workspace.reviewComments.placements(for: document).count,
            1
        )
        XCTAssertEqual(controller.reviewRulerView.commentMarkers.count, 1)
        XCTAssertTrue(controller.scrollView.rulersVisible)
        XCTAssertEqual(
            controller.reviewRulerView.commentMarkers[0].offset,
            range(of: "note", in: source).lowerBound
        )
        XCTAssertFalse(controller.reviewRulerView.commentMarkers[0].resolved)
    }

    func testCommentsPanelLaysOut() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "alpha note beta\n"
        let (url, document) = try makeDocument(source, in: directory)
        document.selection = range(of: "note", in: source)
        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        _ = await workspace.addReviewComment(to: document, body: "Body.")
        let view = NSHostingView(
            rootView: MarkdownCommentsView(
                document: document,
                workspace: workspace
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.height, 0)
        XCTAssertGreaterThan(view.fittingSize.width, 0)
    }
}
