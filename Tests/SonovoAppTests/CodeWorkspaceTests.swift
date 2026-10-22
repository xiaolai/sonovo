import Foundation
import SonovoCore
import XCTest
@testable import Sonovo

@MainActor
final class CodeWorkspaceTests: XCTestCase {
    private var support: CodeTestSupport!
    private var projectSupport: ProjectUXTestSupport!

    override func setUp() {
        super.setUp()
        support = CodeTestSupport()
        projectSupport = ProjectUXTestSupport()
    }

    override func tearDown() {
        support.tearDown()
        projectSupport.tearDown()
        support = nil
        projectSupport = nil
        super.tearDown()
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func openProject(
        _ files: [String: Data]
    ) async throws -> (Workspace, Project, URL) {
        let root = try support.makeRoot(files: files)
        let workspace = projectSupport.makeWorkspace()
        let project = try XCTUnwrap(workspace.openProject(at: root))
        let loaded = await waitUntil {
            project.assets.count == files.count
        }
        XCTAssertTrue(loaded)
        return (workspace, project, root)
    }

    // MARK: - Controller identity

    func testControllerIdentityAndReleaseAcrossFilesAndProjects() async throws {
        let (workspace, first, _) = try await openProject([
            "a.swift": CodeTestData.utf8("let a = 1\n"),
            "b.swift": CodeTestData.utf8("let b = 2\n")
        ])
        let a = try XCTUnwrap(first.assets.first { $0.name == "a.swift" })
        let b = try XCTUnwrap(first.assets.first { $0.name == "b.swift" })
        first.openAsset(a)
        let loadedA = await waitUntil {
            first.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(loadedA)
        let documentA = try XCTUnwrap(first.code.selectedDocument)
        let controllerA = first.code.controller(for: documentA)

        first.openAsset(b)
        let loadedB = await waitUntil {
            first.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(loadedB)
        let documentB = try XCTUnwrap(first.code.selectedDocument)
        let controllerB = first.code.controller(for: documentB)
        XCTAssertFalse(controllerA === controllerB)

        first.openAsset(a)
        XCTAssertTrue(first.code.controller(for: documentA) === controllerA)
        XCTAssertTrue(
            first.code.selectedDocument === documentA,
            "switching back selects the existing document"
        )

        let secondRoot = try support.makeRoot(
            files: ["a.swift": CodeTestData.utf8("let other = 1\n")]
        )
        let second = try XCTUnwrap(workspace.openProject(at: secondRoot))
        let secondLoaded = await waitUntil {
            second.assets.count == 1
        }
        XCTAssertTrue(secondLoaded)
        let secondAsset = try XCTUnwrap(second.assets.first)
        second.openAsset(secondAsset)
        let secondReady = await waitUntil {
            second.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(secondReady)
        let secondDocument = try XCTUnwrap(second.code.selectedDocument)
        let secondController = second.code.controller(for: secondDocument)
        XCTAssertFalse(
            controllerA === secondController,
            "one project's controller must not serve another project"
        )

        await first.closeAllTabs()
        XCTAssertEqual(first.code.editorCache.count, 0)
        XCTAssertTrue(first.code.documents.isEmpty)
        await second.closeAllTabs()
        XCTAssertEqual(second.code.editorCache.count, 0)
    }

    func testReadOnlyDocumentClosesWithoutADecision() async throws {
        let (_, project, _) = try await openProject([
            "mixed.swift": CodeTestData.utf8("a\r\nb\n")
        ])
        let asset = try XCTUnwrap(project.assets.first)
        project.openAsset(asset)
        let loaded = await waitUntil {
            project.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(loaded)
        let document = try XCTUnwrap(project.code.selectedDocument)
        XCTAssertFalse(document.isEditable)
        let tab = try XCTUnwrap(
            project.openTabs.first { $0.id == asset.id }
        )
        await project.closeTab(tab.id)
        XCTAssertNil(project.code.pendingClose)
        XCTAssertTrue(project.code.documents.isEmpty)
        XCTAssertFalse(project.openTabs.contains { $0.id == asset.id })
    }

    // MARK: - Save As

    func testSaveAsRefusesAFileOpenInAnotherTab() async throws {
        let (_, project, _) = try await openProject([
            "a.swift": CodeTestData.utf8("let a = 1\n"),
            "b.swift": CodeTestData.utf8("let b = 2\n")
        ])
        let a = try XCTUnwrap(project.assets.first { $0.name == "a.swift" })
        let b = try XCTUnwrap(project.assets.first { $0.name == "b.swift" })
        project.openAsset(a)
        let firstReady = await waitUntil {
            project.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(firstReady)
        let documentA = try XCTUnwrap(project.code.documents.first {
            $0.fileURL.lastPathComponent == "a.swift"
        })
        project.openAsset(b)
        let secondReady = await waitUntil {
            project.code.documents.contains {
                $0.fileURL.lastPathComponent == "b.swift" && $0.isReady
            }
        }
        XCTAssertTrue(secondReady)
        try documentA.replaceSource("let a = 9\n")

        let saved = await project.code.saveAs(documentA, to: b.url)
        XCTAssertFalse(saved)
        XCTAssertTrue(
            project.code.lastError?.contains("already open") == true
        )
        XCTAssertEqual(
            try Data(contentsOf: b.url),
            CodeTestData.utf8("let b = 2\n")
        )
    }

    func testReservedSaveAsDestinationCannotBeOpenedConcurrently() async throws {
        let (_, project, root) = try await openProject([
            "a.swift": CodeTestData.utf8("let a = 1\n"),
            "target.swift": CodeTestData.utf8("let t = 1\n"),
            "notes.md": CodeTestData.utf8("# Notes\n"),
            "captions.srt": CodeTestData.utf8("1\n00:00:00,000 --> 1\nHi\n")
        ])
        let target = root.appendingPathComponent("target.swift")
        let key = MarkdownSecurity.canonical(target).path
        let owner = UUID()

        // A reservation stands in for a Save As that is still writing. The
        // reservation is made before the write's await, and every workspace's
        // `open` must consult it, or a second document can appear for the
        // same path.
        XCTAssertTrue(project.code.reserveDestination?(key, owner) == true)
        XCTAssertNil(project.code.open(url: target))
        XCTAssertTrue(
            project.code.lastError?.contains("being saved") == true
        )

        let markdown = root.appendingPathComponent("notes.md")
        let markdownKey = MarkdownSecurity.canonical(markdown).path
        XCTAssertTrue(
            project.code.reserveDestination?(markdownKey, owner) == true
        )
        XCTAssertNil(project.markdown.open(url: markdown))
        XCTAssertTrue(
            project.markdown.lastError?.contains("being saved") == true
        )

        let subtitles = root.appendingPathComponent("captions.srt")
        let subtitlesKey = MarkdownSecurity.canonical(subtitles).path
        XCTAssertTrue(
            project.code.reserveDestination?(subtitlesKey, owner) == true
        )
        XCTAssertNil(project.subtitles.open(url: subtitles))

        for path in [key, markdownKey, subtitlesKey] {
            project.code.releaseDestination?(path, owner)
            XCTAssertFalse(project.code.isDestinationReserved?(path) == true)
        }
        XCTAssertNotNil(project.code.open(url: target))
    }

    func testKeepMineAppliesBeforeTheBannerClickReturns() async throws {
        let (_, project, root) = try await openProject([
            "a.swift": CodeTestData.utf8("let a = 1\n")
        ])
        project.openAsset(try XCTUnwrap(project.assets.first))
        let loaded = await waitUntil {
            project.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(loaded)
        let document = try XCTUnwrap(project.code.selectedDocument)
        XCTAssertFalse(document.isDirty)

        // A binary disk turns the clean buffer's re-check into a conflict.
        try support.write(
            Data([0x00, 0x01, 0x02]),
            to: root.appendingPathComponent("a.swift")
        )
        _ = await document.checkExternalChange(projectVisible: true)
        XCTAssertNotNil(document.conflict)

        // The banner's decision must take effect before the click returns;
        // a queued task could be lost to a close or termination.
        project.code.keepLocal(document)
        XCTAssertNil(document.conflict)
        XCTAssertTrue(document.isDirty)
    }

    func testAnOpenDocumentBlocksASharedReservation() async throws {
        let (_, project, root) = try await openProject([
            "notes.md": CodeTestData.utf8("# Notes\n")
        ])
        let markdown = root.appendingPathComponent("notes.md")
        let key = MarkdownSecurity.canonical(markdown).path
        let document = try XCTUnwrap(project.code.open(url: markdown))
        let loaded = await waitUntil { document.isReady }
        XCTAssertTrue(loaded)

        // Another document's Save As must not take a path this open document
        // owns, even though no Save As is currently in flight.
        XCTAssertFalse(
            project.code.reserveDestination?(key, UUID()) == true
        )
        XCTAssertTrue(
            project.code.reserveDestination?(key, document.id) == true,
            "the owning document may reserve its own path"
        )
        project.code.releaseDestination?(key, document.id)
    }

    func testReloadResolvesAConflictThatCoexistsWithAPendingReview() async throws {
        let (_, project, root) = try await openProject([
            "a.swift": CodeTestData.utf8("let a = 1\n")
        ])
        project.openAsset(try XCTUnwrap(project.assets.first))
        let loaded = await waitUntil {
            project.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(loaded)
        let document = try XCTUnwrap(project.code.selectedDocument)

        project.code.setProjectVisible(false)
        try support.write(
            CodeTestData.utf8("let a = 9\n"),
            to: root.appendingPathComponent("a.swift")
        )
        _ = await document.checkExternalChange(projectVisible: false)
        XCTAssertTrue(document.pendingReview)

        try document.replaceSource("let a = 2\n")
        do {
            try await document.save()
        } catch {
            // The hidden disk change turns this save into a conflict.
        }
        XCTAssertNotNil(document.conflict)
        XCTAssertTrue(
            document.pendingReview,
            "the awaiting review survives the failed save"
        )

        // Reload must resolve the conflict, not take the review path that
        // refuses to run while a conflict is open.
        project.code.reload(document)
        let reloaded = await waitUntil {
            document.source == "let a = 9\n"
        }
        XCTAssertTrue(reloaded)
        XCTAssertNil(document.conflict)
        XCTAssertFalse(document.pendingReview)
    }

    func testCodeOpenRefusesAPathOwnedByAnotherWorkspace() async throws {
        let (_, project, root) = try await openProject([
            "notes.md": CodeTestData.utf8("# Notes\n")
        ])
        let url = root.appendingPathComponent("notes.md")
        _ = try XCTUnwrap(project.markdown.open(url: url))

        XCTAssertNil(project.code.open(url: url))
        XCTAssertTrue(
            project.code.lastError?.contains("already open") == true
        )
        XCTAssertFalse(project.code.documents.contains {
            MarkdownSecurity.canonical($0.fileURL).path
                == MarkdownSecurity.canonical(url).path
        })
    }

    func testAnAssetClickCannotCreateATabForAPathOwnedElsewhere() async throws {
        let (_, project, root) = try await openProject([
            "a.swift": CodeTestData.utf8("let a = 1\n"),
            "b.swift": CodeTestData.utf8("let b = 1\n"),
            "notes.md": CodeTestData.utf8("# Notes\n")
        ])
        let aURL = root.appendingPathComponent("a.swift")
        let bURL = root.appendingPathComponent("b.swift")
        // Markdown owns both paths; b is selected when the code asset for a
        // is clicked.
        _ = try XCTUnwrap(project.markdown.open(url: aURL))
        _ = try XCTUnwrap(project.markdown.open(url: bURL))
        let asset = try XCTUnwrap(project.assets.first { $0.name == "a.swift" })
        project.openAsset(asset)

        XCTAssertTrue(project.code.documents.isEmpty)
        XCTAssertFalse(project.openTabs.contains {
            $0.kind == .code
                && $0.url.map {
                    MarkdownSecurity.canonical($0).path
                        == MarkdownSecurity.canonical(aURL).path
                } == true
        })
        XCTAssertEqual(
            project.markdown.selectedDocument?.fileURL,
            aURL,
            "the click selects the owning document, not just its workspace"
        )
    }

    func testSavingCodeOverAScannedMarkdownFileKeepsACodeTab() async throws {
        let (_, project, root) = try await openProject([
            "a.swift": CodeTestData.utf8("let a = 1\n"),
            "notes.md": CodeTestData.utf8("# Notes\n")
        ])
        let asset = try XCTUnwrap(project.assets.first { $0.name == "a.swift" })
        project.openAsset(asset)
        let loaded = await waitUntil {
            project.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(loaded)
        let document = try XCTUnwrap(project.code.selectedDocument)
        try document.replaceSource("let a = 2\n")

        let destination = root.appendingPathComponent("notes.md")
        let saved = await project.code.saveAs(document, to: destination)
        XCTAssertFalse(saved)
        let request = try XCTUnwrap(project.code.pendingOverwrite)
        await project.code.confirmOverwrite(request)

        XCTAssertEqual(document.fileURL, destination)
        let destinationPath = MarkdownSecurity.canonical(destination).path
        let tab = project.openTabs.first {
            guard let url = $0.url else { return false }
            return MarkdownSecurity.canonical(url).path == destinationPath
        }
        XCTAssertEqual(
            tab?.kind,
            .code,
            "the tab follows the code document, not the .md asset kind"
        )
        XCTAssertEqual(project.code.selectedDocument?.id, document.id)
    }

    func testAMovedCodeDocumentKeepsATabWhenAnotherTabIsSelected() async throws {
        let (_, project, root) = try await openProject([
            "a.swift": CodeTestData.utf8("let a = 1\n"),
            "b.swift": CodeTestData.utf8("let b = 1\n"),
            "notes.md": CodeTestData.utf8("# Notes\n")
        ])
        let aAsset = try XCTUnwrap(project.assets.first { $0.name == "a.swift" })
        project.openAsset(aAsset)
        _ = await waitUntil {
            project.code.documents.first { $0.fileURL.lastPathComponent == "a.swift" }?.isReady == true
        }
        let documentA = try XCTUnwrap(project.code.documents.first {
            $0.fileURL.lastPathComponent == "a.swift"
        })
        let bAsset = try XCTUnwrap(project.assets.first { $0.name == "b.swift" })
        project.openAsset(bAsset)
        _ = await waitUntil {
            project.code.documents.first { $0.fileURL.lastPathComponent == "b.swift" }?.isReady == true
        }
        try documentA.replaceSource("let a = 2\n")

        // The moved document is not the selected tab. Its tab must still
        // follow the move, and the selection must not be stolen.
        let destination = root.appendingPathComponent("notes.md")
        let saved = await project.code.saveAs(documentA, to: destination)
        XCTAssertFalse(saved)
        let request = try XCTUnwrap(project.code.pendingOverwrite)
        await project.code.confirmOverwrite(request)

        XCTAssertEqual(documentA.fileURL, destination)
        let destinationPath = MarkdownSecurity.canonical(destination).path
        let destinationTab = project.openTabs.first {
            guard let url = $0.url else { return false }
            return MarkdownSecurity.canonical(url).path == destinationPath
        }
        XCTAssertEqual(destinationTab?.kind, .code)
        XCTAssertEqual(
            project.code.selectedDocument?.fileURL.lastPathComponent,
            "b.swift",
            "a background move must not move the selection"
        )
    }

    func testSaveAsOverwriteConfirmationFlow() async throws {
        let (_, project, root) = try await openProject([
            "a.swift": CodeTestData.utf8("let a = 1\n")
        ])
        let asset = try XCTUnwrap(project.assets.first)
        project.openAsset(asset)
        let loaded = await waitUntil {
            project.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(loaded)
        let document = try XCTUnwrap(project.code.selectedDocument)
        try document.replaceSource("let a = 2\n")

        let destination = root.appendingPathComponent("copy.swift")
        try support.write(
            CodeTestData.utf8("existing\n"),
            to: destination
        )
        let saved = await project.code.saveAs(document, to: destination)
        XCTAssertFalse(saved)
        let request = try XCTUnwrap(project.code.pendingOverwrite)
        XCTAssertEqual(request.url, destination)
        XCTAssertEqual(
            request.expected.bytes,
            CodeTestData.utf8("existing\n")
        )

        await project.code.confirmOverwrite(request)
        XCTAssertNil(project.code.pendingOverwrite)
        XCTAssertEqual(document.fileURL, destination)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            CodeTestData.utf8("let a = 2\n")
        )
        XCTAssertTrue(
            project.openTabs.contains {
                $0.url?.standardizedFileURL
                    == destination.standardizedFileURL
            },
            "the tab follows the moved document"
        )
    }

    // MARK: - Close and bulk close

    func testDirtyCloseDefersThenResumesThroughTheDecision() async throws {
        let (_, project, root) = try await openProject([
            "a.swift": CodeTestData.utf8("let a = 1\n")
        ])
        let asset = try XCTUnwrap(project.assets.first)
        project.openAsset(asset)
        let loaded = await waitUntil {
            project.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(loaded)
        let document = try XCTUnwrap(project.code.selectedDocument)
        try document.replaceSource("let a = 2\n")

        // A read-only folder makes the save fail, which is what turns the
        // close into a decision instead of a silent autosave.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: root.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.path
            )
        }

        await project.closeTab(asset.id)
        XCTAssertNotNil(project.code.pendingClose)
        XCTAssertTrue(
            project.openTabs.contains { $0.id == asset.id },
            "the tab stays until the decision resolves"
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: root.path
        )
        await project.code.saveAndClose(document)
        XCTAssertNil(project.code.pendingClose)
        XCTAssertTrue(project.code.documents.isEmpty)
        XCTAssertFalse(project.openTabs.contains { $0.id == asset.id })
        XCTAssertEqual(
            try Data(contentsOf: asset.url),
            CodeTestData.utf8("let a = 2\n")
        )
    }

    func testMixedBulkCloseResumesAfterEachDecision() async throws {
        let (_, project, root) = try await openProject([
            "a.md": CodeTestData.utf8("# text\n"),
            "b.swift": CodeTestData.utf8("let a = 1\n")
        ])
        let markdownAsset = try XCTUnwrap(
            project.assets.first { $0.name == "a.md" }
        )
        let codeAsset = try XCTUnwrap(
            project.assets.first { $0.name == "b.swift" }
        )
        project.openAsset(markdownAsset)
        project.markdown.selectedDocument?.replaceSourceSafely("# changed\n")
        project.openAsset(codeAsset)
        let codeLoaded = await waitUntil {
            project.code.documents.contains { $0.isReady }
        }
        XCTAssertTrue(codeLoaded)
        let codeDocument = try XCTUnwrap(project.code.selectedDocument)
        try codeDocument.replaceSource("let a = 2\n")

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: root.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.path
            )
        }

        await project.closeAllTabs()
        XCTAssertFalse(project.openTabs.isEmpty)

        for _ in 0..<4 {
            if let markdown = project.markdown.pendingClose {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: root.path
                )
                await project.markdown.saveAndClose(markdown)
            } else if let code = project.code.pendingClose {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: root.path
                )
                await project.code.saveAndClose(code)
            } else {
                break
            }
            _ = await waitUntil(timeout: 1) {
                project.markdown.pendingClose == nil
                    && project.code.pendingClose == nil
            }
        }
        let closed = await waitUntil {
            project.openTabs.isEmpty
        }
        XCTAssertTrue(closed, "both decisions must resume the bulk close")
    }

    func testSaveAsRefusesAFileOpenInAnotherWorkspaceType() async throws {
        let (_, project, _) = try await openProject([
            "a.swift": CodeTestData.utf8("let a = 1\n"),
            "notes.md": CodeTestData.utf8("# notes\n")
        ])
        let codeAsset = try XCTUnwrap(
            project.assets.first { $0.name == "a.swift" }
        )
        let markdownAsset = try XCTUnwrap(
            project.assets.first { $0.name == "notes.md" }
        )
        project.openAsset(markdownAsset)
        XCTAssertNotNil(project.markdown.selectedDocument)

        project.openAsset(codeAsset)
        let loaded = await waitUntil {
            project.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(loaded)
        let document = try XCTUnwrap(project.code.selectedDocument)
        try document.replaceSource("let a = 2\n")

        let saved = await project.code.saveAs(
            document,
            to: markdownAsset.url
        )
        XCTAssertFalse(saved)
        XCTAssertTrue(
            project.code.lastError?.contains("already open") == true
        )
        XCTAssertEqual(
            try Data(contentsOf: markdownAsset.url),
            CodeTestData.utf8("# notes\n")
        )
    }

    func testClosedDocumentIsNotResurrectedByItsWatcher() async throws {
        let (_, project, _) = try await openProject([
            "a.swift": CodeTestData.utf8("let a = 1\n")
        ])
        let asset = try XCTUnwrap(project.assets.first)
        project.openAsset(asset)
        let loaded = await waitUntil {
            project.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(loaded)
        let tab = try XCTUnwrap(project.openTabs.first { $0.id == asset.id })
        await project.closeTab(tab.id)
        XCTAssertTrue(project.code.documents.isEmpty)

        try support.write(
            CodeTestData.utf8("let a = 2\n"),
            to: asset.url
        )
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(
            project.code.documents.isEmpty,
            "a stopped watcher must not reopen a closed document"
        )
    }

    func testSelectionSurvivesATabSwitch() async throws {
        let (_, project, _) = try await openProject([
            "a.swift": CodeTestData.utf8("let a = 1\nlet b = 2\n"),
            "b.swift": CodeTestData.utf8("let c = 3\n")
        ])
        let a = try XCTUnwrap(project.assets.first { $0.name == "a.swift" })
        let b = try XCTUnwrap(project.assets.first { $0.name == "b.swift" })
        project.openAsset(a)
        let aReady = await waitUntil {
            project.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(aReady)
        let documentA = try XCTUnwrap(project.code.selectedDocument)
        let controllerA = project.code.controller(for: documentA)
        controllerA.textView.setSelectedRange(
            NSRange(location: 12, length: 0)
        )
        documentA.selection = 12..<12

        project.openAsset(b)
        let bReady = await waitUntil {
            project.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(bReady)
        project.openAsset(a)
        XCTAssertTrue(project.code.selectedDocument === documentA)
        XCTAssertTrue(project.code.controller(for: documentA) === controllerA)
        XCTAssertEqual(
            controllerA.textView.selectedRange().location,
            12
        )
    }

    func testReopenDuringCloseKeepsTheTabAndReopensTheDocument() async throws {
        let (_, project, _) = try await openProject([
            "a.swift": CodeTestData.utf8("let a = 1\n")
        ])
        let asset = try XCTUnwrap(project.assets.first)
        project.openAsset(asset)
        let loaded = await waitUntil {
            project.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(loaded)
        let document = try XCTUnwrap(project.code.selectedDocument)
        try document.replaceSource("let a = 2\n")

        let entered = expectation(description: "before rename")
        let gate = DispatchSemaphore(value: 0)
        project.code.closeHooks = SaveHooks(beforeRename: { _ in
            entered.fulfill()
            gate.wait()
        })
        defer { project.code.closeHooks = nil }

        let closeTask = Task { await project.closeTab(asset.id) }
        await fulfillment(of: [entered], timeout: 5)
        // The user asks for the file while its close is awaiting the save.
        project.openAsset(asset)
        gate.signal()
        await closeTask.value

        XCTAssertTrue(
            project.openTabs.contains { $0.id == asset.id },
            "a closed tab must stay when the file was reopened during close"
        )
        XCTAssertEqual(project.code.documents.count, 1)
        XCTAssertEqual(
            project.code.documents.first?.fileURL,
            asset.url
        )
    }

    func testAutosaveWritesADirtyDocument() async throws {
        let (_, project, _) = try await openProject([
            "a.swift": CodeTestData.utf8("let a = 1\n")
        ])
        let asset = try XCTUnwrap(project.assets.first)
        project.openAsset(asset)
        let loaded = await waitUntil {
            project.code.selectedDocument?.isReady == true
        }
        XCTAssertTrue(loaded)
        let document = try XCTUnwrap(project.code.selectedDocument)
        try document.replaceSource("let a = 2\n")
        let autosaved = await waitUntil(timeout: 8) { !document.isDirty }
        XCTAssertTrue(autosaved)
        XCTAssertEqual(
            try Data(contentsOf: asset.url),
            CodeTestData.utf8("let a = 2\n")
        )
    }

    // MARK: - Discovery

    func testWorkspaceDiscoverySkipsIgnoredAndHiddenTargets() throws {
        let root = try support.makeRoot(files: [
            "Sources/main.swift": CodeTestData.utf8("let a = 1\n"),
            "node_modules/package/index.js": CodeTestData.utf8("x\n"),
            ".hidden/secret.swift": CodeTestData.utf8("x\n"),
            "README": CodeTestData.utf8("x\n")
        ])
        let files = CodeWorkspace.codeFiles(in: root)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.lastPathComponent, "main.swift")
    }
}

private extension MarkdownDocument {
    /// The test edits through the same public path the editor uses; this
    /// wrapper keeps the test readable and fails loudly.
    func replaceSourceSafely(_ source: String) {
        XCTAssertNoThrow(try replaceSource(source))
    }
}
