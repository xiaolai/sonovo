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

    func testSaveRecordsAHistorySnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("a.md")
        try Data("one\n".utf8).write(to: url)

        let workspace = MarkdownWorkspace(
            snapshotBaseDirectory: directory.appendingPathComponent("snap")
        )
        workspace.setWorkspaceRoot(directory)
        let document = try XCTUnwrap(workspace.open(url: url))
        try document.replaceSource("two\n")
        await workspace.save(document)

        let records = await workspace.historyRecords(for: document)
        XCTAssertFalse(records.isEmpty)
        XCTAssertEqual(records.first?.byteCount, Data("two\n".utf8).count)
    }

    func testALocalAssetLinkRoutesToTheProjectViewer() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("pic.png")
        try Data([0x89]).write(to: image)
        let documentURL = directory.appendingPathComponent("doc.md")
        try Data("x".utf8).write(to: documentURL)

        let workspace = MarkdownWorkspace()
        workspace.setWorkspaceRoot(directory)
        let document = try XCTUnwrap(workspace.open(url: documentURL))
        var routed: URL?
        workspace.onOpenAsset = { url in
            routed = url
            return true
        }
        await workspace.openLocalLink("pic.png", from: document)
        XCTAssertEqual(routed?.lastPathComponent, "pic.png")
        XCTAssertNil(workspace.lastError)
    }

    func testAnOutsideRootAssetLinkIsRefused() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("doc.md")
        try Data("x".utf8).write(to: documentURL)

        let workspace = MarkdownWorkspace()
        workspace.setWorkspaceRoot(directory)
        let document = try XCTUnwrap(workspace.open(url: documentURL))
        var routed: URL?
        workspace.onOpenAsset = { url in
            routed = url
            return true
        }
        await workspace.openLocalLink("../escape.png", from: document)
        XCTAssertNil(routed)
        XCTAssertNotNil(workspace.lastError)
    }

    func testAMissingLocalAssetNamesTheState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("doc.md")
        try Data("x".utf8).write(to: documentURL)

        let workspace = MarkdownWorkspace()
        workspace.setWorkspaceRoot(directory)
        let document = try XCTUnwrap(workspace.open(url: documentURL))
        workspace.onOpenAsset = { _ in true }
        await workspace.openLocalLink("missing.png", from: document)
        XCTAssertEqual(workspace.lastError, "File not found: missing.png")
    }

    func testABackgroundRescanNeverOpensADocument() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("a".utf8).write(
            to: directory.appendingPathComponent("a.md")
        )

        let workspace = MarkdownWorkspace()
        workspace.setWorkspaceRoot(directory)
        let indexed = await waitUntil { !workspace.workspaceFiles.isEmpty }
        XCTAssertTrue(indexed)
        XCTAssertTrue(workspace.documents.isEmpty)
        let root = try XCTUnwrap(workspace.workspaceRoot)

        // The watcher path calls exactly this signature.
        await workspace.rescanWorkspaceIndex(root: root)
        XCTAssertTrue(workspace.documents.isEmpty)
        XCTAssertEqual(workspace.workspaceFiles.count, 1)

        // Opening the folder explicitly is the only path that opens one.
        await workspace.rescanWorkspaceIndex(root: root, openFirst: true)
        XCTAssertEqual(workspace.documents.count, 1)
    }

    func testAnExplicitOpenSurvivesABackgroundRescan() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("a".utf8).write(
            to: directory.appendingPathComponent("a.md")
        )

        let workspace = MarkdownWorkspace()
        workspace.setWorkspaceRoot(directory)
        _ = await waitUntil { !workspace.workspaceFiles.isEmpty }
        let root = try XCTUnwrap(workspace.workspaceRoot)

        // A watcher rescan that supersedes the explicit open must inherit
        // its intent; otherwise the folder opens with no document. Start
        // the explicit scan first and yield so it reaches its enumeration
        // before the background scan advances the generation.
        let explicit = Task {
            await workspace.rescanWorkspaceIndex(root: root, openFirst: true)
        }
        await Task.yield()
        let background = Task {
            await workspace.rescanWorkspaceIndex(root: root)
        }
        await explicit.value
        await background.value
        XCTAssertEqual(workspace.documents.count, 1)
    }

    func testOpeningAnAlreadyOpenDocumentActivatesItsTab() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.md")
        let second = directory.appendingPathComponent("second.md")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)

        let workspace = MarkdownWorkspace()
        workspace.open(url: first)
        workspace.open(url: second)
        var activated: [String] = []
        workspace.onDocumentActivated = { url in
            activated.append(url?.lastPathComponent ?? "untitled")
        }

        workspace.open(url: first)
        XCTAssertEqual(activated, ["first.md"])
        XCTAssertEqual(
            workspace.selectedDocument?.fileURL,
            first.resolvingSymlinksInPath()
        )
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

    func testEditInSourceSelectsTheExactRange() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("hello world\n".utf8).write(to: url)

        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        let document = try XCTUnwrap(workspace.selectedDocument)
        document.mode = .rendered
        let controller = workspace.controller(for: document)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))

        let source = "hello world\n"
        let start = source.range(of: "world")!.lowerBound
        let end = source.range(of: "world")!.upperBound
        let startOffset = source.distance(from: source.startIndex, to: start)
        let endOffset = source.distance(from: source.startIndex, to: end)
        let range = SourceRange(
            start: SourcePosition(
                line: 1,
                column: startOffset,
                offset: startOffset
            ),
            end: SourcePosition(
                line: 1,
                column: endOffset,
                offset: endOffset
            )
        )

        await workspace.editInSource(
            range: range,
            expectedSource: source,
            in: document
        )
        XCTAssertEqual(document.mode, .source)
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: startOffset, length: endOffset - startOffset)
        )
        XCTAssertNil(workspace.lastError)
    }

    func testEditInSourceRefusesAStaleSlice() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("hello world\n".utf8).write(to: url)

        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        let document = try XCTUnwrap(workspace.selectedDocument)
        let controller = workspace.controller(for: document)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))

        let range = SourceRange(
            start: SourcePosition(line: 1, column: 6, offset: 6),
            end: SourcePosition(line: 1, column: 11, offset: 11)
        )
        await workspace.editInSource(
            range: range,
            expectedSource: "hello WORLD\n",
            in: document
        )
        XCTAssertNotNil(workspace.lastError)
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: 0, length: 0)
        )
    }
}
