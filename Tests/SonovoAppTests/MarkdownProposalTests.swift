import AppKit
import SwiftUI
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MarkdownProposalTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-proposal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func hash(_ source: String) -> String {
        ReviewAnchorResolver.documentIdentity(of: source)
    }

    private func proposalText(
        for source: String,
        document: String = "doc.md",
        hunks: String
    ) -> String {
        """
        # sonovo-proposal 1
        # document: \(document)
        # base-sha256: \(hash(source))
        --- a/\(document)
        +++ b/\(document)
        \(hunks)
        """
    }

    private func write(
        _ source: String,
        proposal: String? = nil,
        in directory: URL
    ) throws -> (document: URL, sidecar: URL?) {
        let documentURL = directory.appendingPathComponent("doc.md")
        try Data(source.utf8).write(to: documentURL)
        guard let proposal else { return (documentURL, nil) }
        let proposalURL = MarkdownProposal.proposalURL(for: documentURL)
        try Data(proposal.utf8).write(to: proposalURL)
        return (documentURL, proposalURL)
    }

    func testConventionalProposalLoadsAndApplies() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "one\ntwo\nthree\nfour\nfive\nsix\n"
        let (url, proposalURL) = try write(
            source,
            proposal: proposalText(
                for: source,
                hunks: """
                @@ -1,2 +1,2 @@
                 one
                -two
                +TWO
                @@ -5,2 +5,2 @@
                 five
                -six
                +SIX
                """
            ),
            in: directory
        )
        let workspace = MarkdownWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        XCTAssertTrue(
            workspace.loadProposal(
                from: try XCTUnwrap(proposalURL),
                for: document
            )
        )
        XCTAssertTrue(workspace.isProposalVisible)
        XCTAssertEqual(workspace.proposalPreview?.proposal.hunks.count, 2)

        let applied = await workspace.applyProposal(
            accepting: [1, 2],
            in: document
        )
        XCTAssertTrue(applied)
        XCTAssertEqual(document.source, "one\nTWO\nthree\nfour\nfive\nSIX\n")
        XCTAssertEqual(
            try Data(contentsOf: url),
            Data("one\nTWO\nthree\nfour\nfive\nSIX\n".utf8)
        )
        XCTAssertFalse(workspace.isProposalVisible)
        // The proposal file is untouched; applying has no hidden state.
        XCTAssertEqual(
            try String(
                contentsOf: try XCTUnwrap(proposalURL),
                encoding: .utf8
            ),
            proposalText(
                for: source,
                hunks: """
                @@ -1,2 +1,2 @@
                 one
                -two
                +TWO
                @@ -5,2 +5,2 @@
                 five
                -six
                +SIX
                """
            )
        )
    }

    func testApplyingOneHunkLeavesTheOtherRegionExactly() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "one\ntwo\nthree\nfour\nfive\nsix\n"
        let (url, _) = try write(
            source,
            proposal: proposalText(
                for: source,
                hunks: """
                @@ -1,2 +1,2 @@
                 one
                -two
                +TWO
                @@ -5,2 +5,2 @@
                 five
                -six
                +SIX
                """
            ),
            in: directory
        )
        let workspace = MarkdownWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        _ = workspace.loadProposal(
            from: MarkdownProposal.proposalURL(for: url),
            for: document
        )
        let applied = await workspace.applyProposal(
            accepting: [2],
            in: document
        )
        XCTAssertTrue(applied)
        XCTAssertEqual(
            document.source,
            "one\ntwo\nthree\nfour\nfive\nSIX\n"
        )
        XCTAssertEqual(
            try Data(contentsOf: url),
            Data("one\ntwo\nthree\nfour\nfive\nSIX\n".utf8)
        )
    }

    func testApplyIsUndoable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "alpha\nnote\n"
        let (url, _) = try write(
            source,
            proposal: proposalText(
                for: source,
                hunks: """
                @@ -1,2 +1,2 @@
                 alpha
                -note
                +NOTE
                """
            ),
            in: directory
        )
        let workspace = MarkdownWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        _ = workspace.loadProposal(
            from: MarkdownProposal.proposalURL(for: url),
            for: document
        )
        let applied = await workspace.applyProposal(
            accepting: [1],
            in: document
        )
        XCTAssertTrue(applied)
        XCTAssertEqual(document.source, "alpha\nNOTE\n")
        XCTAssertFalse(document.isDirty)

        document.undoManager.undo()
        XCTAssertEqual(document.source, source)
        XCTAssertTrue(document.isDirty)
    }

    func testStaleBaseRefusesToLoad() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "alpha\nnote\n"
        let (url, _) = try write(
            source,
            proposal: proposalText(
                for: source,
                hunks: """
                @@ -1,2 +1,2 @@
                 alpha
                -note
                +NOTE
                """
            ),
            in: directory
        )
        let workspace = MarkdownWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        try document.replaceSource("alpha\nchanged\n")
        XCTAssertFalse(
            workspace.loadProposal(
                from: MarkdownProposal.proposalURL(for: url),
                for: document
            )
        )
        XCTAssertFalse(workspace.isProposalVisible)
        XCTAssertNil(workspace.proposalPreview)
        XCTAssertNotNil(workspace.proposalError)
    }

    func testProposalForAnotherDocumentIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "alpha\n"
        let (url, _) = try write(
            source,
            proposal: proposalText(
                for: source,
                document: "other.md",
                hunks: """
                @@ -1 +1 @@
                -alpha
                +ALPHA
                """
            ),
            in: directory
        )
        let workspace = MarkdownWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        XCTAssertFalse(
            workspace.loadProposal(
                from: MarkdownProposal.proposalURL(for: url),
                for: document
            )
        )
        XCTAssertTrue(
            workspace.proposalError?
                .contains("other.md") == true
        )
    }

    func testDocumentChangeAfterPreviewRefusesApply() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "alpha\nnote\n"
        let (url, _) = try write(
            source,
            proposal: proposalText(
                for: source,
                hunks: """
                @@ -1,2 +1,2 @@
                 alpha
                -note
                +NOTE
                """
            ),
            in: directory
        )
        let workspace = MarkdownWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        _ = workspace.loadProposal(
            from: MarkdownProposal.proposalURL(for: url),
            for: document
        )
        try document.replaceSource("alpha\nchanged\n")
        let applied = await workspace.applyProposal(
            accepting: [1],
            in: document
        )
        XCTAssertFalse(applied)
        XCTAssertEqual(document.source, "alpha\nchanged\n")
        XCTAssertNotNil(workspace.proposalError)
    }

    func testProposalSheetLaysOut() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "alpha\nnote\n"
        let (url, _) = try write(
            source,
            proposal: proposalText(
                for: source,
                hunks: """
                @@ -1,2 +1,2 @@
                 alpha
                -note
                +NOTE
                """
            ),
            in: directory
        )
        let workspace = MarkdownWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        _ = workspace.loadProposal(
            from: MarkdownProposal.proposalURL(for: url),
            for: document
        )
        let preview = try XCTUnwrap(workspace.proposalPreview)
        let hosting = NSHostingView(
            rootView: MarkdownProposalView(
                preview: preview,
                document: document,
                workspace: workspace
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 680, height: 560)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
    }
}
