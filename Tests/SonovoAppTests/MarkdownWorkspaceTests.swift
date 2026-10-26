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

    private func sourceRange(_ offsets: Range<Int>) -> SourceRange {
        SourceRange(
            start: SourcePosition(
                line: 1,
                column: offsets.lowerBound,
                offset: offsets.lowerBound
            ),
            end: SourcePosition(
                line: 1,
                column: offsets.upperBound,
                offset: offsets.upperBound
            )
        )
    }

    private func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
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

    func testDetailsDefaultRoutesThroughTheCommandRegistry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("details.md")
        let source = "<details><summary>S</summary>\n\nbody\n</details>\n"
        try Data(source.utf8).write(to: url)

        let workspace = MarkdownWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        document.mode = .rendered
        let range = sourceRange(0..<((source as NSString).length - 1))

        workspace.setDetailsOpenDefault(
            at: range,
            expectedSource: source,
            open: true,
            in: document
        )
        XCTAssertTrue(document.source.hasPrefix("<details open>"))
        XCTAssertEqual(
            workspace.controller(for: document).textView.string,
            document.source
        )

        let opened = document.source
        workspace.setDetailsOpenDefault(
            at: range,
            expectedSource: opened,
            open: false,
            in: document
        )
        XCTAssertTrue(document.source.hasPrefix("<details>"))
        XCTAssertNil(workspace.lastError)
    }

    func testDetailsDefaultRefusesAChangedBlock() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("details.md")
        let source = "<details><summary>S</summary>\n\nbody\n</details>\n"
        try Data(source.utf8).write(to: url)

        let workspace = MarkdownWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        let range = sourceRange(0..<((source as NSString).length - 1))
        try document.replaceSource(
            "<details><summary>S</summary>\n\nchanged\n</details>\n"
        )
        let changed = document.source

        workspace.setDetailsOpenDefault(
            at: range,
            expectedSource: source,
            open: true,
            in: document
        )
        XCTAssertEqual(document.source, changed)
        XCTAssertNotNil(workspace.lastError)
    }

    func testRenderedAnchorsAreHandedBackOnRestore() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("read.md")
        try Data("# A\n\nbody\n".utf8).write(to: url)

        let workspace = MarkdownWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        document.mode = .rendered
        let anchor = RenderedReadingAnchor(
            blockOffset: 0,
            blockKind: .heading,
            fraction: 0.4
        )
        workspace.recordRenderedAnchor(anchor, for: document)
        workspace.restoreReadingPosition(for: document)
        XCTAssertEqual(workspace.pendingRenderedAnchors[document.id], anchor)

        // The viewer clears the anchor after it restores.
        workspace.pendingRenderedAnchors[document.id] = nil
        XCTAssertNil(workspace.pendingRenderedAnchors[document.id])
    }

    func testModeSwitchCapturesTheSourceSelection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("selection.md")
        try Data("hello world\n".utf8).write(to: url)

        let workspace = MarkdownWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        document.mode = .source
        let controller = workspace.controller(for: document)
        controller.textView.setSelectedRange(NSRange(location: 2, length: 4))
        // The source view's delegate owns this in production; a view without
        // a window has no delegate callbacks.
        document.selection = 2..<6
        workspace.setMode(.rendered, for: document)
        XCTAssertEqual(document.mode, .rendered)

        document.selection = 0..<0
        workspace.setMode(.source, for: document)
        XCTAssertEqual(document.selection, 2..<6)
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

    func testReloadRestoresTheSourceReadingPosition() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        let lines = (0..<300)
            .map { "line \($0) of the reload fixture" }
            .joined(separator: "\n")
        try Data((lines + "\n").utf8).write(to: url)

        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        let document = try XCTUnwrap(workspace.selectedDocument)
        try document.replaceSource(lines + "\nlocal edit\n")
        document.mode = .source

        let controller = workspace.controller(for: document)
        controller.syncFromDocument()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.scrollView
        controller.scrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: 480,
            height: 320
        )
        window.layoutIfNeeded()
        controller.textView.layoutSubtreeIfNeeded()

        let ns = document.source as NSString
        let target = ns.range(of: "line 200").location
        controller.select(range: target..<target)
        controller.textView.layoutSubtreeIfNeeded()
        let anchor = try XCTUnwrap(controller.readingAnchor())
        XCTAssertGreaterThan(anchor.lineOffset, 0)

        let shorter = (0..<40)
            .map { "line \($0) of the shorter fixture" }
            .joined(separator: "\n") + "\n"
        try Data(shorter.utf8).write(to: url)
        let conflicted = await waitUntil { document.conflict != nil }
        XCTAssertTrue(conflicted)

        workspace.reload(document)
        XCTAssertEqual(document.source, shorter)
        controller.syncFromDocument()
        controller.textView.layoutSubtreeIfNeeded()

        let maximum = max(
            0,
            controller.textView.bounds.height
                - controller.scrollView.contentView.bounds.height
        )
        XCTAssertGreaterThan(maximum, 0)
        XCTAssertEqual(
            controller.scrollView.contentView.bounds.origin.y,
            maximum,
            accuracy: 2
        )
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

    func testOpenResultSelectsTheReportedUTF16Column() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        let source = "hello world\n"
        try Data(source.utf8).write(to: url)

        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        let document = try XCTUnwrap(workspace.selectedDocument)
        let controller = workspace.controller(for: document)

        workspace.openResult(url: url, line: 1, column: 7)
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: 6, length: 0)
        )
    }

    func testOpenResultMapsAstralCharactersBeforeTheColumn() throws {
        // U+1F600 is one Character but two UTF-16 units, and project search
        // reports UTF-16 columns. Counting the column in Characters lands
        // inside the match instead of on its first character.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        let source = "😀😀 value-60\n"
        try Data(source.utf8).write(to: url)

        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        let document = try XCTUnwrap(workspace.selectedDocument)
        let controller = workspace.controller(for: document)

        workspace.openResult(url: url, line: 1, column: 6)
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: 5, length: 0)
        )
    }

    func testSearchScopeSeparatesCodeFromMarkdown() {
        XCTAssertTrue(CodeSearchScope.markdown.includes("doc.md"))
        XCTAssertTrue(CodeSearchScope.markdown.includes("DOC.MARKDOWN"))
        XCTAssertFalse(CodeSearchScope.markdown.includes("main.swift"))
        XCTAssertTrue(CodeSearchScope.code.includes("main.swift"))
        XCTAssertFalse(CodeSearchScope.code.includes("doc.md"))
    }

    func testFindInFilesReturnsTheOpenDocument() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("value-60\n".utf8).write(to: url)

        let workspace = MarkdownWorkspace()
        workspace.setWorkspaceRoot(directory)
        workspace.open(url: url)
        _ = try XCTUnwrap(workspace.selectedDocument)

        let result = await workspace.findInFiles("value-60")
        let search = try XCTUnwrap(result)
        let match = try XCTUnwrap(search.matches.first)
        XCTAssertEqual(
            match.url.standardizedFileURL.path,
            url.standardizedFileURL.path
        )
        XCTAssertEqual(match.line, 1)
        XCTAssertEqual(match.column, 1)
    }

    func testOpenResultSeedsTheSourceFindBarOnTheMatch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        let source = "hello world\n"
        try Data(source.utf8).write(to: url)

        let workspace = MarkdownWorkspace()
        workspace.open(url: url)
        let document = try XCTUnwrap(workspace.selectedDocument)
        let controller = workspace.controller(for: document)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.scrollView
        controller.scrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: 480,
            height: 320
        )
        window.layoutIfNeeded()

        workspace.openResult(url: url, line: 1, column: 7, query: "world")
        XCTAssertEqual(
            controller.textView.selectedRange(),
            NSRange(location: 6, length: 5)
        )
        window.layoutIfNeeded()
        let field = searchField(in: controller.scrollView)
        XCTAssertNotNil(field, "the source find bar did not appear")
        XCTAssertEqual(field?.stringValue, "world")
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
