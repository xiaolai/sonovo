import SonovoWorkspaceHost
import Foundation
import Observation
import SonovoMarkdownEngine
import SonovoSubtitleEngine
import XCTest
@testable import Sonovo

@MainActor
final class WorkspaceAdapterTests: XCTestCase {
    func testUntitledMarkdownWorkspaceRetainsItsTabTitle() throws {
        let support = ProjectUXTestSupport()
        defer { support.tearDown() }
        let project = support.makeWorkspace().demoProject
        defer { project.prepareForTermination() }
        _ = project.markdown.newDocument()
        project.selectWorkspaceTab(.script)
        let tab = try XCTUnwrap(project.selectedTab)
        XCTAssertEqual(project.displayName(for: tab), tab.title)
    }

    func testTerminalContextCacheReusesRetainedConsumerWithoutRetainingAppState() {
        let support = ProjectUXTestSupport()
        defer { support.tearDown() }
        weak var released: AppState?
        do {
            let state = AppState(workspace: support.makeWorkspace())
            released = state
            let consumer = state.terminalPaneContext
            XCTAssertTrue((consumer as AnyObject) === (state.terminalPaneContext as AnyObject))
            state.prepareForTermination()
        }
        XCTAssertNil(released, "the runtime must not strongly cycle through its context adapter")
    }

    func testRealAdaptersKeepWorkspaceOrderAndOptionalSaveCapabilities() throws {
        let support = ProjectUXTestSupport()
        defer { support.tearDown() }
        let project = support.makeWorkspace().demoProject
        defer { project.prepareForTermination() }
        XCTAssertEqual(project.documentWorkspaces.adapters.map(\.kind), [
            .script, .subtitle, .model3d, .code, .mdx, .timeline
        ])
        let markdown = try XCTUnwrap(project.documentWorkspaces.adapter(for: .script))
        XCTAssertNotNil(markdown.saveCommands)
        XCTAssertNil(project.documentWorkspaces.adapter(for: .model3d)?.saveCommands)
        XCTAssertNil(project.documentWorkspaces.adapter(for: .timeline)?.saveCommands)
        let document = project.markdown.newDocument()
        XCTAssertEqual(markdown.selectedDocument?.id, document.id)
        XCTAssertTrue(markdown.saveCommands?.canSave == true)
        XCTAssertTrue(markdown.saveCommands?.canSaveAs == true)
    }

    func testAdapterObservationTracksUnderlyingDirtyState() throws {
        let support = ProjectUXTestSupport()
        defer { support.tearDown() }
        let project = support.makeWorkspace().demoProject
        defer { project.prepareForTermination() }
        let document = project.markdown.newDocument()
        let adapter = try XCTUnwrap(project.documentWorkspaces.adapter(for: .script))
        let witness = AdapterObservationWitness()
        withObservationTracking {
            XCTAssertFalse(adapter.hasDirtyDocuments)
        } onChange: {
            witness.mark()
        }
        try document.replaceSource("changed through the real model")
        XCTAssertTrue(witness.wasMarked)
        XCTAssertTrue(adapter.hasDirtyDocuments)
        XCTAssertEqual(adapter.documents.first?.id, document.id)
    }

    func testAdapterPathOwnershipUsesExistingDocumentIdentity() throws {
        let support = ProjectUXTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(files: ["a.md": "first", "b.md": "second"])
        let project = Project(folderURL: root, watchFactory: { _, _ in UXTestWatcher() })
        defer { project.prepareForTermination() }
        let adapter = try XCTUnwrap(project.documentWorkspaces.adapter(for: .script))
        adapter.open(root.appendingPathComponent("a.md"))
        adapter.open(root.appendingPathComponent("b.md"))
        let first = try XCTUnwrap(project.markdown.documents.first)
        XCTAssertEqual(project.documentWorkspaces.owner(of: root.appendingPathComponent("a.md").path)?.kind, .script)
        adapter.select(path: root.appendingPathComponent("a.md").path)
        XCTAssertTrue(project.markdown.selectedDocument === first)
        XCTAssertFalse(project.isDocumentPathOpen(first.fileURL!.path, excluding: first.id))
    }
}

private final class AdapterObservationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    func mark() { lock.lock(); marked = true; lock.unlock() }
    var wasMarked: Bool { lock.lock(); defer { lock.unlock() }; return marked }
}
