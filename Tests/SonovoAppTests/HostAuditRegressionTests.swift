import Foundation
import XCTest
import SonovoDomainTypes
import SonovoFileIO
import SonovoFeatureAPI
import SonovoWorkspaceHost
import SonovoMarkdownEngine
import SonovoSubtitleEngine
import SonovoCodeFeature
import SonovoMDXFeature
import SonovoTimelineFeature
@testable import Sonovo

@MainActor final class HostAuditRegressionTests: XCTestCase {
    private let subtitle = "1\n00:00:00,000 --> 00:00:02,000\nBefore\n"
    private func ready(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("document did not settle")
    }

    func testNewTimelineCommandWaitsForANewDocumentWhenOneIsAlreadyOpen() async throws {
        let support = ProjectUXTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(files: [:])
        let workspace = support.makeWorkspace()
        let state = AppState(workspace: workspace)
        defer { state.prepareForTermination() }
        let project = try XCTUnwrap(workspace.openProject(at: root))
        let existing = root.appendingPathComponent("Existing.timeline.json")
        try project.timelines.create(url: existing, timeline: ProjectTimeline(name: "Existing"))
        state.newTimeline()
        await ready { project.timelines.document?.url.lastPathComponent == "Untitled.timeline.json"
            && project.selectedTab?.url == project.timelines.document?.url }
        XCTAssertEqual(project.timelines.document?.timeline?.name, "Untitled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
    }

    func testAllFiveRealFamiliesFlushInOrderAndRevealTheirFailingOwner() async throws {
        // Make each family the first failure in turn. Earlier files must have
        // saved; later files must remain dirty. This tests real models/stores,
        // rather than merely reasserting the synthetic coordinator's priorities.
        let kinds: [AssetKind] = [.subtitle, .script, .code, .mdx, .timeline]
        let names = ["a.srt", "a.md", "a.swift", "a.mdx", "a.timeline.json"]
        for failure in kinds.indices {
            let support = ProjectUXTestSupport()
            defer { support.tearDown() }
            let root = try support.makeRoot(files: ["a.srt": subtitle, "a.md": "before\n", "a.swift": "let a = 1\n", "a.mdx": "# Before\n"])
            let workspace = support.makeWorkspace()
            let state = AppState(workspace: workspace)
            defer { state.prepareForTermination() }
            let project = try XCTUnwrap(workspace.openProject(at: root))
            await project.load()
            let sub = try XCTUnwrap(project.subtitles.open(url: root.appendingPathComponent(names[0])))
            let md = try XCTUnwrap(project.markdown.open(url: root.appendingPathComponent(names[1])))
            let code = try XCTUnwrap(project.code.open(url: root.appendingPathComponent(names[2])))
            await ready { code.isReady }
            let mdx = try XCTUnwrap(project.mdx.open(url: root.appendingPathComponent(names[3])))
            try project.timelines.create(url: root.appendingPathComponent(names[4]), timeline: ProjectTimeline(name: "Before"))
            let timeline = try XCTUnwrap(project.timelines.document)
            try sub.replaceSource(subtitle.replacingOccurrences(of: "Before", with: "After"), actionName: "Edit")
            try md.replaceSource("after\n")
            try code.replaceSource("let a = 2\n")
            mdx.source = "# After\n"
            try timeline.mutate { $0.name = "After" }
            // Exact-byte conflict is deterministic and never opens a modal.
            try Data("external writer\n".utf8).write(to: root.appendingPathComponent(names[failure]), options: .atomic)
            state.activateProject(workspace.demoProject)
            state.terminalPresentation = .full
            let allowed = await state.flushAllBeforeClose()
            XCTAssertFalse(allowed, "failure family \(kinds[failure])")
            XCTAssertTrue(state.liveProject === project)
            XCTAssertEqual(state.selectedTab?.kind, kinds[failure])
            XCTAssertNotEqual(state.terminalPresentation, .full)
            let dirty = [sub.isDirty, md.isDirty, code.isDirty, mdx.isDirty, timeline.hasUnsavedChanges]
            for i in kinds.indices {
                XCTAssertEqual(dirty[i], i >= failure, "first failure \(kinds[failure]), family \(kinds[i])")
            }
        }
    }

    func testSaveDiscardAndCancelResolveTheFirstOwnerInEachDecisionFamily() async throws {
        for action in ["save", "discard", "cancel"] {
            let support = ProjectUXTestSupport()
            defer { support.tearDown() }
            let workspace = support.makeWorkspace()
            let state = AppState(workspace: workspace)
            defer { state.prepareForTermination() }
            var projects: [Project] = []
            for index in 0..<2 {
                let root = try support.makeRoot(name: "owner-\(index)", files: ["a.md": "before", "a.swift": "let a = 1", "a.mdx": "# Before"])
                let project = try XCTUnwrap(workspace.openProject(at: root))
                projects.append(project)
                let md = try XCTUnwrap(project.markdown.open(url: root.appendingPathComponent("a.md")))
                let code = try XCTUnwrap(project.code.open(url: root.appendingPathComponent("a.swift")))
                await ready { code.isReady }
                let mdx = try XCTUnwrap(project.mdx.open(url: root.appendingPathComponent("a.mdx")))
                try md.replaceSource("after")
                try code.replaceSource("let a = 2")
                mdx.source = "# After"
                project.markdown.pendingClose = md
                project.code.pendingClose = code
                let mdxClosed = await project.mdx.close(mdx)
                XCTAssertFalse(mdxClosed)
            }
            let first = projects[0], second = projects[1]
            XCTAssertTrue(state.pendingCloseOwner === first)
            if action == "cancel" {
                state.cancelPendingClose()
                XCTAssertNil(first.markdown.pendingClose)
                XCTAssertNil(first.code.pendingClose)
                XCTAssertNil(first.mdx.pendingClose)
            } else {
                for kind: AssetKind in [.script, .script, .code, .code, .mdx, .mdx] {
                    // Both owners of one family resolve before the next family.
                    XCTAssertTrue(state.hasPendingCloseDecision, "\(action) \(kind)")
                    let countBefore = workspace.allProjects.reduce(0) { $0 + $1.documentWorkspaces.adapters.filter { $0.pendingDecision != nil }.count }
                    if action == "save" {
                        state.savePendingClose()
                        XCTAssertEqual(state.selectedTab?.kind, kind)
                    } else { state.discardPendingClose() }
                    await ready {
                        workspace.allProjects.reduce(0) { $0 + $1.documentWorkspaces.adapters.filter { $0.pendingDecision != nil }.count } < countBefore
                    }
                }
                XCTAssertFalse(state.hasPendingCloseDecision)
            }
            if action == "cancel" {
                XCTAssertNotNil(second.markdown.pendingClose)
                XCTAssertNotNil(second.code.pendingClose)
                XCTAssertNotNil(second.mdx.pendingClose)
                XCTAssertTrue(first.markdown.hasDirtyDocuments)
                XCTAssertTrue(first.code.hasDirtyDocuments)
                XCTAssertTrue(first.mdx.hasDirtyDocuments)
            }
        }
    }

    func testRawAndCanonicalPathsShareOwnershipAndAStalledWriteKeepsItsReservation() async throws {
        let support = ProjectUXTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(files: ["a.swift": "let a = 1", "notes.md": "# Notes"])
        let project = Project(folderURL: root, watchFactory: { _, _ in UXTestWatcher() }, terminalEnvironment: .disabled)
        defer { project.prepareForTermination() }
        let notes = root.appendingPathComponent("notes.md")
        let alias = root.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: notes)
        let markdown = try XCTUnwrap(project.markdown.open(url: notes))
        XCTAssertTrue(project.markdown.open(url: alias) === markdown)
        // The existing owner-query contract takes a canonical path;
        // workspace open canonicalizes raw aliases before querying it.
        XCTAssertFalse(project.isDocumentPathOpen(alias.path, excluding: nil))
        XCTAssertTrue(project.isDocumentPathOpen(FilePathPolicy.canonical(alias).path, excluding: nil))
        let code = try XCTUnwrap(project.code.open(url: root.appendingPathComponent("a.swift")))
        await ready { code.isReady }
        let target = root.appendingPathComponent("new.md")
        let entered = expectation(description: "real atomic Save As is about to commit")
        let gate = DispatchSemaphore(value: 0)
        project.code.saveAsHooks = SaveHooks(beforeRename: { _ in entered.fulfill(); gate.wait() })
        defer { gate.signal(); project.code.saveAsHooks = nil }
        let save = Task { await project.code.saveAs(code, to: target) }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(project.code.isDestinationReserved?(target.path) == true)
        save.cancel()
        XCTAssertNil(project.markdown.open(url: target))
        XCTAssertTrue(project.code.isDestinationReserved?(target.path) == true, "cancellation must not free a possibly committing write")
        gate.signal()
        _ = await save.value
        XCTAssertFalse(project.code.isDestinationReserved?(target.path) == true)
    }
}
