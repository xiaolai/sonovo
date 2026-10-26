import AppKit
import SwiftUI
import XCTest
@testable import Sonovo
import SonovoCore
import SonovoMDXKit

@MainActor
final class MDXWorkspaceTests: XCTestCase {
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

    // MARK: - Project integration

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

    // MARK: - Canonical source

    func testPreviewNeverRewritesTheSourceFile() async throws {
        let root = try makeProjectDirectory([
            "post.mdx": "# Original\n"
        ])
        let workspace = try makeWorkspace(root: root)
        let document = try XCTUnwrap(
            workspace.open(url: root.appendingPathComponent("post.mdx"))
        )
        let file = root.appendingPathComponent("post.mdx")
        let original = try Data(contentsOf: file)

        document.source = "# Edited\n"
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(try Data(contentsOf: file), original)

        workspace.setPreviewEnabled(true)
        await workspace.compileNow(document)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(document.source, "# Edited\n")

        await workspace.save(document)
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            "# Edited\n"
        )
    }

    // MARK: - Compile through the helper

    func testCompileThroughTheSandboxedHelper() async throws {
        let root = try makeProjectDirectory([
            "post.mdx": "# Hello\n\nThe answer is {2 + 2}.\n"
        ])
        let workspace = try makeWorkspace(root: root)
        let document = try XCTUnwrap(
            workspace.open(url: root.appendingPathComponent("post.mdx"))
        )
        XCTAssertFalse(workspace.previewEnabled)
        workspace.setPreviewEnabled(true)
        await workspace.compileNow(document)

        guard case .ready(let modules) = workspace.previewState(for: document)
        else {
            return XCTFail(
                "expected a compiled preview, got "
                    + "\(workspace.previewState(for: document))"
            )
        }
        let entry = try XCTUnwrap(
            modules.first { $0.id == "post.mdx" }
        )
        XCTAssertTrue(entry.code.contains("Hello"))
        XCTAssertTrue(entry.code.contains("2 + 2"))
    }

    func testCompileErrorFallsBackToTheSource() async throws {
        let root = try makeProjectDirectory([
            "post.mdx": "# Hi\n\n{unclosed\n"
        ])
        let workspace = try makeWorkspace(root: root)
        let document = try XCTUnwrap(
            workspace.open(url: root.appendingPathComponent("post.mdx"))
        )
        workspace.setPreviewEnabled(true)
        await workspace.compileNow(document)

        guard case .failed(let diagnostic) =
            workspace.previewState(for: document) else {
            return XCTFail(
                "expected a compile diagnostic, got "
                    + "\(workspace.previewState(for: document))"
            )
        }
        XCTAssertFalse(diagnostic.message.isEmpty)
        XCTAssertNotNil(diagnostic.line)
        XCTAssertEqual(document.source, "# Hi\n\n{unclosed\n")
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent("post.mdx"),
                encoding: .utf8
            ),
            "# Hi\n\n{unclosed\n"
        )
    }

    func testRemoteImportIsRefused() async throws {
        let root = try makeProjectDirectory([
            "post.mdx": """
            import x from "https://example.com/x.js"

            # Hi
            """
        ])
        let workspace = try makeWorkspace(root: root)
        let document = try XCTUnwrap(
            workspace.open(url: root.appendingPathComponent("post.mdx"))
        )
        workspace.setPreviewEnabled(true)
        await workspace.compileNow(document)

        guard case .unavailable(let message) =
            workspace.previewState(for: document) else {
            return XCTFail(
                "expected a refusal, got "
                    + "\(workspace.previewState(for: document))"
            )
        }
        XCTAssertTrue(message.contains("Remote imports are refused"))
    }

    func testMissingImportIsRefused() async throws {
        let root = try makeProjectDirectory([
            "post.mdx": """
            import x from "./missing.jsx"

            # Hi
            """
        ])
        let workspace = try makeWorkspace(root: root)
        let document = try XCTUnwrap(
            workspace.open(url: root.appendingPathComponent("post.mdx"))
        )
        workspace.setPreviewEnabled(true)
        await workspace.compileNow(document)

        guard case .unavailable(let message) =
            workspace.previewState(for: document) else {
            return XCTFail(
                "expected a refusal, got "
                    + "\(workspace.previewState(for: document))"
            )
        }
        XCTAssertTrue(message.contains("could not be found"))
    }

    // MARK: - Cache

    func testCompiledOutputIsCachedByContentHash() async throws {
        let source = """
        import A from "./A.jsx"

        # Hi
        """
        let root = try makeProjectDirectory([
            "post.mdx": source,
            "A.jsx": "export default function A() { return <b>A</b>; }\n"
        ])
        let service = try liveService()

        _ = try await service.compile(
            entryID: "post.mdx",
            source: source,
            projectRoot: root
        )
        let afterFirst = await service.compilerInvocations
        XCTAssertGreaterThan(afterFirst, 0)

        _ = try await service.compile(
            entryID: "post.mdx",
            source: source,
            projectRoot: root
        )
        let afterSecond = await service.compilerInvocations
        XCTAssertEqual(afterSecond, afterFirst, "cache hit must not compile")

        try "export default function A() { return <b>B</b>; }\n".write(
            to: root.appendingPathComponent("A.jsx"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await service.compile(
            entryID: "post.mdx",
            source: source,
            projectRoot: root
        )
        let afterChange = await service.compilerInvocations
        XCTAssertGreaterThan(
            afterChange,
            afterSecond,
            "a changed import must invalidate the cache"
        )
    }

    func testANewHigherPriorityImportInvalidatesTheCache() async throws {
        let source = """
        import A from "./A"

        # Hi
        """
        let root = try makeProjectDirectory([
            "post.mdx": source,
            "A.jsx": "export default function A() { return <b>JSX</b>; }\n"
        ])
        let service = try liveService()
        let first = try await service.compile(
            entryID: "post.mdx",
            source: source,
            projectRoot: root
        )
        XCTAssertTrue(first.ok)
        XCTAssertTrue(first.modules.contains { $0.id == "A.jsx" })
        let afterFirst = await service.compilerInvocations

        // Extensionless imports try `.mdx` first. Creating that file must
        // invalidate the cached graph even though A.jsx is unchanged.
        try "# MDX component\n".write(
            to: root.appendingPathComponent("A.mdx"),
            atomically: true,
            encoding: .utf8
        )
        let second = try await service.compile(
            entryID: "post.mdx",
            source: source,
            projectRoot: root
        )
        XCTAssertTrue(second.ok)
        XCTAssertTrue(second.modules.contains { $0.id == "A.mdx" })
        XCTAssertFalse(second.modules.contains { $0.id == "A.jsx" })
        let afterSecond = await service.compilerInvocations
        XCTAssertGreaterThan(afterSecond, afterFirst)
    }

    private final class CompileCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    func testTheCompileCacheHasAByteBudget() async throws {
        let counter = CompileCounter()
        let payload = String(repeating: "x", count: 4_096)
        let service = MDXCompileService(
            compile: { request in
                counter.increment()
                return MDXCompileResponse(
                    ok: true,
                    entry: request.entry,
                    modules: request.files.keys.sorted().map {
                        MDXCompiledModule(id: $0, code: payload)
                    },
                    diagnostic: nil
                )
            },
            cacheLimitBytes: 10_000
        )
        let root = try makeProjectDirectory([
            "a.mdx": "# A\n",
            "b.mdx": "# B\n",
            "c.mdx": "# C\n"
        ])
        func compile(_ name: String, _ source: String) async throws {
            _ = try await service.compile(
                entryID: name,
                source: source,
                projectRoot: root
            )
        }

        try await compile("a.mdx", "# A\n")
        try await compile("a.mdx", "# A\n")
        XCTAssertEqual(counter.value, 1, "the second compile must hit")

        try await compile("b.mdx", "# B\n")
        try await compile("c.mdx", "# C\n")
        XCTAssertEqual(counter.value, 3)
        // Three 4 KiB entries exceed the 10 KiB budget, so a.mdx is evicted.
        try await compile("a.mdx", "# A\n")
        XCTAssertEqual(counter.value, 4)
    }

    func testACompileFailureIsNotCached() async throws {
        let source = "# Hi\n\n{unclosed\n"
        let root = try makeProjectDirectory(["post.mdx": source])
        let service = try liveService()
        let first = try await service.compile(
            entryID: "post.mdx",
            source: source,
            projectRoot: root
        )
        XCTAssertFalse(first.ok)
        let afterFirst = await service.compilerInvocations

        let second = try await service.compile(
            entryID: "post.mdx",
            source: source,
            projectRoot: root
        )
        XCTAssertFalse(second.ok)
        let afterSecond = await service.compilerInvocations
        XCTAssertGreaterThan(
            afterSecond,
            afterFirst,
            "a failure must be recompiled, not served from the cache"
        )
    }

    // MARK: - Web view boundary

    func testPreviewPageBlocksNetworkAndHasNoHostBridge() async throws {
        let root = try makeProjectDirectory([
            "post.mdx": "# Hello\n"
        ])
        let service = try liveService()
        let response = try await service.compile(
            entryID: "post.mdx",
            source: "# Hello\n",
            projectRoot: root
        )
        let controller = MDXPreviewController()
        try await controller.loadForTesting(
            html: try page(entry: "post.mdx", modules: response.modules)
        )
        let results = try await controller.probeNetworkForTesting()
        XCTAssertEqual(results["fetch"], "blocked")
        XCTAssertEqual(results["xhr"], "blocked")
        XCTAssertEqual(results["websocket"], "blocked")
        XCTAssertEqual(results["image"], "blocked")
        XCTAssertEqual(results["dataImage"], "allowed")
        XCTAssertEqual(results["dataFetch"], "blocked")
        XCTAssertEqual(results["file"], "blocked")
        XCTAssertEqual(results["messageHandlers"], "0")
    }

    func testPreviewRendersMarkdownAndLocalComponents() async throws {
        let source = """
        import Button from "./Button.jsx"

        # Hello

        <Button label="Save" />
        """
        let root = try makeProjectDirectory([
            "post.mdx": source,
            "Button.jsx": """
            export default function Button(props) {
              return <button>{props.label}</button>;
            }
            """
        ])
        let service = try liveService()
        let response = try await service.compile(
            entryID: "post.mdx",
            source: source,
            projectRoot: root
        )
        let controller = MDXPreviewController()
        try await controller.loadForTesting(
            html: try page(entry: "post.mdx", modules: response.modules)
        )
        let text = try await waitForRootText(controller, containing: "Save")
        XCTAssertTrue(text.contains("Hello"))

        let hasButton = try await controller.webViewForTesting
            .evaluateJavaScript(
                "document.querySelector('button') !== null"
            ) as? Bool
        XCTAssertEqual(hasButton, true)
    }

    func testACommonJSModuleThatReplacesItsExportsRenders() async throws {
        // A .js dependency written as CommonJS assigns through `module`; the
        // loader must honour the replaced export object, not only
        // `exports.default`.
        let source = """
        import Legacy from "./Legacy.js"

        # CommonJS

        <Legacy label="Replaced exports" />
        """
        let root = try makeProjectDirectory([
            "post.mdx": source,
            "Legacy.js": """
            var React = require("react");
            module.exports = function Legacy(props) {
              return React.createElement("button", null, props.label);
            };
            """
        ])
        let service = try liveService()
        let response = try await service.compile(
            entryID: "post.mdx",
            source: source,
            projectRoot: root
        )
        let controller = MDXPreviewController()
        try await controller.loadForTesting(
            html: try page(entry: "post.mdx", modules: response.modules)
        )
        let text = try await waitForRootText(
            controller,
            containing: "Replaced exports"
        )
        XCTAssertTrue(text.contains("CommonJS"))
        let hasButton = try await controller.webViewForTesting
            .evaluateJavaScript(
                "document.querySelector('button') !== null"
            ) as? Bool
        XCTAssertEqual(hasButton, true)
    }

    func testPreviewNavigationIsCancelled() async throws {
        let root = try makeProjectDirectory([
            "post.mdx": "# Hello\n"
        ])
        let service = try liveService()
        let response = try await service.compile(
            entryID: "post.mdx",
            source: "# Hello\n",
            projectRoot: root
        )
        let controller = MDXPreviewController()
        try await controller.loadForTesting(
            html: try page(entry: "post.mdx", modules: response.modules)
        )
        let before = controller.webViewForTesting.url?.absoluteString
        try? await controller.webViewForTesting.evaluateJavaScript(
            "location.href = 'https://example.com/sonovo-escape'"
        )
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            controller.webViewForTesting.url?.absoluteString,
            before
        )
        XCTAssertEqual(
            controller.webViewForTesting.url?.absoluteString,
            "about:blank"
        )
    }

    // MARK: - Opt-in and close

    func testPreviewIsOptInAndClearsWhenDisabled() async throws {
        let root = try makeProjectDirectory([
            "post.mdx": "# Hello\n"
        ])
        let workspace = try makeWorkspace(root: root)
        let document = try XCTUnwrap(
            workspace.open(url: root.appendingPathComponent("post.mdx"))
        )
        XCTAssertFalse(workspace.previewEnabled)
        await workspace.compileNow(document)
        XCTAssertEqual(workspace.previewState(for: document), .idle)

        workspace.setPreviewEnabled(true)
        await workspace.compileNow(document)
        guard case .ready = workspace.previewState(for: document) else {
            return XCTFail("expected a ready preview")
        }

        workspace.setPreviewEnabled(false)
        XCTAssertEqual(workspace.previewState(for: document), .idle)
    }

    func testDirtyCloseAsksBeforeRemoving() async throws {
        let root = try makeProjectDirectory([
            "post.mdx": "# Hello\n"
        ])
        let workspace = try makeWorkspace(root: root)
        let document = try XCTUnwrap(
            workspace.open(url: root.appendingPathComponent("post.mdx"))
        )
        document.source = "# Changed\n"

        var closed: MDXDocument?
        workspace.onDocumentClosed = { closed = $0 }

        let removed = await workspace.close(document)
        XCTAssertFalse(removed)
        XCTAssertTrue(workspace.pendingClose === document)
        XCTAssertEqual(workspace.documents.count, 1)

        workspace.discardAndClose(document)
        XCTAssertTrue(workspace.documents.isEmpty)
        XCTAssertNil(workspace.pendingClose)
        XCTAssertTrue(closed === document)
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent("post.mdx"),
                encoding: .utf8
            ),
            "# Hello\n",
            "discarding must not write the file"
        )
    }

    // MARK: - Markdown regression

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
