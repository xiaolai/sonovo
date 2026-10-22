import Foundation
import XCTest
@testable import Sonovo

final class LocalDocumentResolverTests: XCTestCase {
    private var root: URL!
    private var outside: URL!
    private var resolver: LocalDocumentResolver!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoDocumentTests-\(UUID().uuidString)",
                isDirectory: true
            )
        root = base.appendingPathComponent("document", isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try write("page.html", "<html></html>")
        try write("style.css", "body {}")
        try write("image.png", "png")
        try write("script.js", "alert(1)")
        try write(".hidden.html", "<html></html>")
        try write("sub/nested.png", "png")
        try write(".hidden.png", "png")
        try write("target.js", "alert(1)")
        try Data("outside".utf8).write(
            to: outside.appendingPathComponent("outside.png")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.png"),
            withDestinationURL: outside.appendingPathComponent("outside.png")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("hidden-link.png"),
            withDestinationURL: root.appendingPathComponent(".hidden.png")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("script-link.png"),
            withDestinationURL: root.appendingPathComponent("target.js")
        )
        resolver = LocalDocumentResolver(root: root)
    }

    override func tearDown() {
        if let root {
            try? FileManager.default.removeItem(
                at: root.deletingLastPathComponent()
            )
        }
        super.tearDown()
    }

    func testRevalidationRejectsAPathSwappedForAnOutsideSymlink() throws {
        try write("swap.png", "png")
        guard case .file(let resource) = resolver.resolve(url("/doc/swap.png")) else {
            return XCTFail("Expected the file to resolve")
        }
        XCTAssertTrue(
            resolver.revalidates(
                resource,
                device: resource.fileDevice,
                inode: resource.fileInode
            )
        )

        try FileManager.default.removeItem(
            at: root.appendingPathComponent("swap.png")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("swap.png"),
            withDestinationURL: outside.appendingPathComponent("outside.png")
        )
        XCTAssertFalse(
            resolver.revalidates(
                resource,
                device: resource.fileDevice,
                inode: resource.fileInode
            ),
            "A path that now resolves outside the root must not be served"
        )
    }

    func testServesTheDocumentAndSiblingResources() throws {
        let page = try file("/doc/page.html")
        XCTAssertEqual(page.mimeType, "text/html")

        let style = try file("/doc/style.css")
        XCTAssertEqual(style.mimeType, "text/css")

        let image = try file("/doc/image.png")
        XCTAssertEqual(image.mimeType, "image/png")

        let nested = try file("/doc/sub/nested.png")
        XCTAssertEqual(nested.mimeType, "image/png")
        XCTAssertTrue(
            nested.url.path.hasSuffix("/document/sub/nested.png")
        )
    }

    func testRejectsTraversalHiddenFilesAndScripts() {
        for path in [
            "/doc/../outside.png",
            "/doc/%2e%2e/outside.png",
            "/doc/.hidden.html",
            "/doc/%00.png",
            "/doc/a%2fb.png"
        ] {
            let outcome = resolver.resolve(url(path))
            XCTAssertTrue(
                outcome == .forbidden || outcome == .badRequest,
                "\(path) resolved to \(outcome)"
            )
        }
        // Double-encoded separators decode once and remain a literal
        // directory name; they cannot escape and do not exist.
        XCTAssertEqual(
            resolver.resolve(url("/doc/%252e%252e/outside.png")),
            .notFound
        )
        XCTAssertEqual(
            resolver.resolve(url("/doc/script.js")),
            .unsupportedType
        )
    }

    func testRejectsSymlinkEscape() {
        XCTAssertEqual(
            resolver.resolve(url("/doc/escape.png")),
            .forbidden
        )
    }

    func testRejectsSymlinksToHiddenOrDisallowedTargets() {
        XCTAssertEqual(
            resolver.resolve(url("/doc/hidden-link.png")),
            .forbidden
        )
        XCTAssertEqual(
            resolver.resolve(url("/doc/script-link.png")),
            .unsupportedType
        )
    }

    func testMissingAndMalformedRequests() {
        XCTAssertEqual(
            resolver.resolve(url("/doc/missing.png")),
            .notFound
        )
        XCTAssertEqual(
            resolver.resolve(url("/doc/")),
            .badRequest
        )
        // A cache-busting query still addresses the same contained file.
        guard case .file(let queried) = resolver.resolve(
            url("/doc/image.png?x=1")
        ) else {
            return XCTFail("A query string should not reject a file")
        }
        XCTAssertEqual(queried.mimeType, "image/png")
        XCTAssertEqual(
            resolver.resolve(URL(string: "https://local/doc/page.html")!),
            .badRequest
        )
    }

    func testNavigationPolicyAllowsOnlyTheDocumentRoute() {
        XCTAssertTrue(
            LocalDocumentResolver.isDocumentNavigation(
                url("/doc/page.html")
            )
        )
        for rejected in [
            "https://example.com/doc/page.html",
            "file:///tmp/page.html",
            "sonovo-doc://other/doc/page.html",
            "sonovo-doc://local/asset/page.html",
            "sonovo-doc://local/"
        ] {
            XCTAssertFalse(
                LocalDocumentResolver.isDocumentNavigation(
                    URL(string: rejected)!
                ),
                rejected
            )
        }
    }

    func testDocumentURLPreservesAFileName() {
        XCTAssertEqual(
            LocalDocumentResolver.documentURL(
                fileName: "my page.svg"
            )?.absoluteString,
            "sonovo-doc://local/doc/my%20page.svg"
        )
    }

    func testContentSecurityPolicyBlocksScriptsAndNetwork() {
        let csp = LocalDocumentResolver.contentSecurityPolicy
        XCTAssertTrue(csp.contains("script-src 'none'"))
        XCTAssertTrue(csp.contains("default-src 'none'"))
        XCTAssertTrue(csp.contains("connect-src 'none'"))
        XCTAssertTrue(csp.contains("object-src 'none'"))
    }

    // MARK: - Helpers

    private func url(_ path: String) -> URL {
        URL(string: "sonovo-doc://local\(path)")!
    }

    private func file(_ path: String) throws -> LocalDocumentResolver.Resource {
        let outcome = resolver.resolve(url(path))
        guard case .file(let resource) = outcome else {
            XCTFail("Expected a file for \(path), got \(outcome)")
            throw ResolverError.notAFile
        }
        return resource
    }

    private func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private enum ResolverError: Error {
        case notAFile
    }
}
