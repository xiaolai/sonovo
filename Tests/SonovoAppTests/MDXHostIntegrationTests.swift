import SonovoWorkspaceHost
@testable import SonovoMDXFeature
import AppKit
import SwiftUI
import XCTest
@testable import Sonovo
import SonovoMarkdownEngine
import SonovoSubtitleEngine
import SonovoMDXKit

@MainActor
final class MDXHostIntegrationTests: XCTestCase {
    private var roots: [URL] = []
    private var projects: [Project] = []

    override func tearDown() async throws {
        for project in projects {
            project.invalidate()
        }
        projects = []
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots = []
    }

    // MARK: - Helpers

    /// Waits for the preview to leave `.compiling`.
    ///
    /// `setPreviewEnabled(true)` schedules its own debounced compile, which
    /// starts later, bumps the generation, and cancels the compile an
    /// immediately awaited `compileNow` started. That method therefore
    /// promises its own task finished, not that it was the last one; the
    /// state settles when the newer compile finishes.
    private func settlePreview(
        _ workspace: MDXWorkspace,
        _ document: MDXDocument,
        timeout: TimeInterval = 5
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .compiling = workspace.previewState(for: document) {
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            return
        }
    }

    private func makeProjectDirectory(
        _ files: [String: String]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-mdx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        for (path, source) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try source.write(to: url, atomically: true, encoding: .utf8)
        }
        roots.append(root)
        return root
    }

    private func liveService() throws -> MDXCompileService {
        let compiler = try XCTUnwrap(
            MDXHelperCompiler.appDefault(),
            "the helper and bundled compiler must exist in the build tree"
        )
        return MDXCompileService(compiler: compiler)
    }

    private func makeWorkspace(root: URL) throws -> MDXWorkspace {
        let workspace = MDXWorkspace(service: try liveService())
        workspace.setWorkspaceRoot(root)
        return workspace
    }

    private func page(
        entry: String,
        modules: [MDXCompiledModule]
    ) throws -> String {
        let runtime = try XCTUnwrap(MDXPreviewAssets.runtimeScript)
        return MDXPreviewPage.html(
            title: "Test",
            entry: entry,
            modules: modules,
            runtimeScript: runtime,
            theme: .light
        )
    }

    private func waitForRootText(
        _ controller: MDXPreviewController,
        containing needle: String,
        timeout: Duration = .seconds(3)
    ) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        var text = ""
        while ContinuousClock.now < deadline {
            text = try await controller.rootTextForTesting()
            if text.contains(needle) {
                return text
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("root text did not contain \(needle.debugDescription): \(text)")
        return text
    }

    // MARK: - Classification

    func testScannerClassifiesComponentDocuments() {
        XCTAssertEqual(
            ProjectScanner.kind(forFilename: "post.mdx"),
            .mdx
        )
        XCTAssertEqual(
            ProjectScanner.kind(forFilename: "Button.jsx"),
            .mdx
        )
        XCTAssertEqual(
            ProjectScanner.kind(forFilename: "notes.md"),
            .script
        )
        XCTAssertEqual(
            ProjectScanner.kind(forFilename: "script.js"),
            .code
        )
    }
    func testProjectOpensAnMDXFileInItsOwnTab() async throws {
        let root = try makeProjectDirectory([
            "post.mdx": "# Hello\n",
            "notes.md": "# Notes\n"
        ])
        let project = Project(folderURL: root)
        projects.append(project)
        await project.load()

        let mdxAsset = try XCTUnwrap(
            project.assets.first { $0.kind == .mdx }
        )
        project.openAsset(mdxAsset)

        XCTAssertEqual(project.selectedTab?.kind, .mdx)
        XCTAssertEqual(project.mdx.documents.count, 1)
        XCTAssertEqual(project.mdx.selectedDocument?.source, "# Hello\n")
        XCTAssertTrue(project.markdown.documents.isEmpty)

        let markdownAsset = try XCTUnwrap(
            project.assets.first { $0.kind == .script }
        )
        project.openAsset(markdownAsset)
        XCTAssertEqual(project.markdown.documents.count, 1)
        XCTAssertEqual(project.mdx.documents.count, 1)
    }
    func testMarkdownDocumentsStillUseTheMarkdownWorkspace() async throws {
        let root = try makeProjectDirectory([
            "notes.md": "# Notes\n\nA paragraph.\n",
            "post.mdx": "# Post\n"
        ])
        let workspace = try makeWorkspace(root: root)
        XCTAssertNil(workspace.open(url: root.appendingPathComponent("notes.md")))
        XCTAssertNotNil(workspace.lastError)
        XCTAssertTrue(workspace.documents.isEmpty)

        let project = Project(folderURL: root)
        projects.append(project)
        await project.load()
        let notes = try XCTUnwrap(
            project.assets.first {
                $0.relativePath == "notes.md"
            }
        )
        project.openAsset(notes)
        XCTAssertEqual(project.selectedTab?.kind, .script)
        XCTAssertEqual(project.markdown.documents.count, 1)
        XCTAssertTrue(project.mdx.documents.isEmpty)
    }
}
