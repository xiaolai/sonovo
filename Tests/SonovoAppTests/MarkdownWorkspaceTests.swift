import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MarkdownWorkspaceTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func testNewDocumentAndCommandRouting() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("abc".utf8).write(to: url)

        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        let document = try XCTUnwrap(workspace.selectedDocument)
        document.mode = .source
        let controller = workspace.controller(for: document)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 3))

        workspace.perform(.toggleStrong, on: document)
        XCTAssertEqual(document.source, "**abc**")
        XCTAssertEqual(controller.textView.string, "**abc**")
        XCTAssertTrue(document.isDirty)
    }

    func testSaveAndClose() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("one\n".utf8).write(to: url)

        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        let document = try XCTUnwrap(workspace.selectedDocument)
        try document.replaceSource("two\n")

        await workspace.saveSelected()
        XCTAssertEqual(try Data(contentsOf: url), Data("two\n".utf8))
        XCTAssertFalse(document.isDirty)

        await workspace.close(document)
        XCTAssertTrue(workspace.documents.isEmpty)
        XCTAssertNil(workspace.selectedDocument)
    }

    func testFlushAllForTermination() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("one\n".utf8).write(to: url)

        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        try workspace.selectedDocument?.replaceSource("two\n")

        let canTerminate = await workspace.flushAllForTermination()
        XCTAssertTrue(canTerminate)
        XCTAssertEqual(try Data(contentsOf: url), Data("two\n".utf8))
    }

    func testUntitledDocumentBlocksTermination() async {
        let workspace = MarkdownWorkspace()
        let document = workspace.newDocument()
        try? document.replaceSource("draft")

        let canTerminate = await workspace.flushAllForTermination()
        XCTAssertFalse(canTerminate)
        XCTAssertEqual(workspace.pendingClose?.id, document.id)

        workspace.discardAndClose(document)
        XCTAssertTrue(workspace.documents.isEmpty)
    }

    func testWikiResolutionStatesAndNavigation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let a = directory.appendingPathComponent("A.md")
        let b = directory.appendingPathComponent("B.md")
        let nested = directory.appendingPathComponent("nested")
        let other = directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let duplicateA = nested.appendingPathComponent("Duplicate.md")
        let duplicateB = other.appendingPathComponent("Duplicate.md")

        for file in [a, b, duplicateA, duplicateB] {
            try Data("# Heading\n".utf8).write(to: file)
        }

        let workspace = MarkdownWorkspace()
        await workspace.openFolder(directory)
        let document = try XCTUnwrap(workspace.selectedDocument)

        XCTAssertEqual(
            workspace.wikiState(
                for: WikiLink(target: "B", fragment: nil, alias: nil),
                in: document
            ),
            .normal
        )
        XCTAssertEqual(
            workspace.wikiState(
                for: WikiLink(target: "Missing", fragment: nil, alias: nil),
                in: document
            ),
            .missing
        )
        XCTAssertEqual(
            workspace.wikiState(
                for: WikiLink(target: "Duplicate", fragment: nil, alias: nil),
                in: document
            ),
            .ambiguous
        )

        await workspace.openWikiLink(
            WikiLink(target: "B", fragment: "Heading", alias: nil),
            in: document
        )
        XCTAssertEqual(workspace.selectedDocument?.fileURL, b.standardizedFileURL)
        XCTAssertEqual(workspace.selectedDocument?.mode, .rendered)
        XCTAssertNotNil(workspace.selectedDocument.flatMap {
            workspace.scrollTargets[$0.id]
        })
    }

    func testExternalChangeSurfacesThroughWatcher() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("one\n".utf8).write(to: url)

        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        let document = try XCTUnwrap(workspace.selectedDocument)
        try document.replaceSource("local\n")

        try Data("external\n".utf8).write(to: url)
        let conflicted = await waitUntil { document.conflict != nil }
        XCTAssertTrue(conflicted)

        workspace.reload(document)
        XCTAssertEqual(document.source, "external\n")
        XCTAssertNil(document.conflict)
    }
}
