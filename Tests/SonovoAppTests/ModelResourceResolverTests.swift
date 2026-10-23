import Foundation
import XCTest
@testable import Sonovo

final class ModelResourceResolverTests: XCTestCase {
    private var base: URL!
    private var viewerRoot: URL!
    private var assetRoot: URL!
    private var outsideRoot: URL!
    private var resolver: ModelResourceResolver!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoResolverTests-\(UUID().uuidString)",
                isDirectory: true
            )
        viewerRoot = base.appendingPathComponent("viewer", isDirectory: true)
        assetRoot = base.appendingPathComponent("models", isDirectory: true)
        outsideRoot = base.appendingPathComponent("outside", isDirectory: true)
        for directory in [viewerRoot!, assetRoot!, outsideRoot!] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        try write("index.html", in: viewerRoot, contents: "<html></html>")
        try write("app.js", in: viewerRoot, contents: "export {}")
        try FileManager.default.createDirectory(
            at: viewerRoot.appendingPathComponent("vendor/three/build"),
            withIntermediateDirectories: true
        )
        try write(
            "vendor/three/build/three.module.js",
            in: viewerRoot,
            contents: "export {}"
        )
        try write("model.glb", in: assetRoot, contents: "glTF")
        try write("model-no-extension", in: assetRoot, contents: "glTF")
        try write("model.mtl", in: assetRoot, contents: "newmtl a")
        try write("secret.txt", in: assetRoot, contents: "secret")
        try write(".hidden.glb", in: assetRoot, contents: "glTF")
        try FileManager.default.createDirectory(
            at: assetRoot.appendingPathComponent("textures"),
            withIntermediateDirectories: true
        )
        try write(
            "textures/albedo.png",
            in: assetRoot,
            contents: "png"
        )
        try write("outside.glb", in: outsideRoot, contents: "glTF")
        try write("模型 name.glb", in: assetRoot, contents: "glTF")

        try FileManager.default.createSymbolicLink(
            at: assetRoot.appendingPathComponent("escape.glb"),
            withDestinationURL: outsideRoot.appendingPathComponent("outside.glb")
        )
        try FileManager.default.createSymbolicLink(
            at: assetRoot.appendingPathComponent("inside.glb"),
            withDestinationURL: assetRoot.appendingPathComponent("model.glb")
        )
        try FileManager.default.createSymbolicLink(
            at: assetRoot.appendingPathComponent("escape-folder"),
            withDestinationURL: outsideRoot
        )

        resolver = ModelResourceResolver(
            viewerRoot: viewerRoot,
            assetRoot: assetRoot
        )
    }

    override func tearDown() {
        if let base {
            try? FileManager.default.removeItem(at: base)
        }
        super.tearDown()
    }

    func testServesViewerPageAndAssets() throws {
        let page = try file("/viewer/index.html")
        XCTAssertEqual(page.url.lastPathComponent, "index.html")
        XCTAssertEqual(page.mimeType, "text/html; charset=utf-8")
        XCTAssertEqual(page.route, .viewer)

        let model = try file("/asset/model.glb")
        XCTAssertEqual(model.url.lastPathComponent, "model.glb")
        XCTAssertEqual(model.mimeType, "model/gltf-binary")
        XCTAssertEqual(model.route, .asset)

        let texture = try file("/asset/textures/albedo.png")
        XCTAssertEqual(texture.mimeType, "image/png")
    }

    func testNestedViewerResourcesResolve() throws {
        let resource = try file("/viewer/vendor/three/build/three.module.js")
        XCTAssertEqual(resource.mimeType, "text/javascript; charset=utf-8")
    }

    func testPercentEncodedNamesRoundTrip() throws {
        let url = try XCTUnwrap(
            ModelResourceResolver.assetURL(relativePath: "模型 name.glb")
        )
        let resource = try file(url)
        XCTAssertEqual(resource.url.lastPathComponent, "模型 name.glb")
    }

    func testRelativeAssetURLPreservesSubdirectories() {
        XCTAssertEqual(
            ModelResourceResolver.assetURL(
                relativePath: "materials/custom.mtl"
            )?.path,
            "/asset/materials/custom.mtl"
        )
        XCTAssertEqual(
            ModelResourceResolver.assetURL(
                relativePath: "textures/贴图.png"
            )?.absoluteString,
            "sonovo-model://local/asset/textures/%E8%B4%B4%E5%9B%BE.png"
        )
    }

    func testTraversalAndEncodedSeparatorsAreRejected() {
        for path in [
            "/asset/../secret.txt",
            "/asset/%2e%2e/secret.txt",
            "/asset/textures/../../secret.txt",
            "/asset/%252e%252e/secret.txt",
            "/asset/a%2fb.glb",
            "/asset/a%5cb.glb",
            "/asset/%00.glb"
        ] {
            let outcome = resolver.resolve(url(path))
            if case .file = outcome {
                XCTFail("\(path) served a file")
            }
            XCTAssertTrue(
                outcome == .forbidden
                    || outcome == .badRequest
                    || outcome == .unsupportedType
                    || outcome == .notFound,
                "\(path) resolved to \(outcome)"
            )
        }
    }

    func testHiddenFilesAreRejected() {
        XCTAssertEqual(resolver.resolve(url("/asset/.hidden.glb")), .forbidden)
        XCTAssertEqual(
            resolver.resolve(url("/asset/textures/.DS_Store")),
            .forbidden
        )
    }

    func testDisallowedExtensionsAreNotServed() {
        XCTAssertEqual(resolver.resolve(url("/asset/secret.txt")), .unsupportedType)
        XCTAssertEqual(
            resolver.resolve(url("/viewer/app.py")),
            .unsupportedType
        )
    }

    func testMissingFileIsNotFound() {
        let missingAsset = resolver.resolve(url("/asset/missing.glb"))
        guard case .missingAsset(let target) = missingAsset else {
            return XCTFail("An absent asset must be reported as missing")
        }
        XCTAssertEqual(target.lastPathComponent, "missing.glb")
        XCTAssertEqual(resolver.resolve(url("/viewer/missing.js")), .notFound)
    }

    func testMalformedURLsAreBadRequests() {
        let bad = [
            "https://local/asset/model.glb",
            "sonovo-model://elsewhere/asset/model.glb",
            "sonovo-model://local/unknown/model.glb",
            "sonovo-model://local/",
            "sonovo-model://local/asset/",
            "sonovo-model://local/asset//model.glb",
            "sonovo-model://local/asset/model.glb?x=1",
            "sonovo-model://local/asset/model.glb#fragment"
        ]
        for string in bad {
            let candidate = URL(string: string)!
            let outcome = resolver.resolve(candidate)
            XCTAssertTrue(
                outcome == .badRequest || outcome == .notFound,
                "\(string) resolved to \(outcome)"
            )
        }

        var components = URLComponents()
        components.scheme = ModelResourceResolver.scheme
        components.host = ModelResourceResolver.host
        components.port = 8080
        components.path = "/asset/model.glb"
        XCTAssertEqual(resolver.resolve(components.url!), .badRequest)
    }

    func testPrimaryFileMayHaveNoExtension() {
        let primary = assetRoot.appendingPathComponent("model-no-extension")
        let resolver = ModelResourceResolver(
            viewerRoot: viewerRoot,
            assetRoot: assetRoot,
            primaryFile: primary
        )
        guard case .file(let resource) = resolver.resolve(
            url("/asset/model-no-extension")
        ) else {
            return XCTFail("The selected primary file must be served")
        }
        XCTAssertEqual(resource.mimeType, "application/octet-stream")
        XCTAssertEqual(
            self.resolver.resolve(url("/asset/model-no-extension")),
            .unsupportedType,
            "Only the selected primary file gets the exception"
        )
    }

    func testSymlinkEscapeIsForbidden() {
        XCTAssertEqual(resolver.resolve(url("/asset/escape.glb")), .forbidden)
        XCTAssertEqual(
            resolver.resolve(url("/asset/escape-folder/outside.glb")),
            .forbidden
        )
    }

    func testSymlinkInsideRootIsAllowed() throws {
        let resource = try file("/asset/inside.glb")
        XCTAssertEqual(resource.url.lastPathComponent, "model.glb")
    }

    func testFileWithoutExtensionIsNotServed() {
        XCTAssertEqual(resolver.resolve(url("/asset/model")), .unsupportedType)
    }

    func testMIMETableCoversEveryServedType() {
        XCTAssertEqual(
            ModelResourceResolver.mimeType(forExtension: "gltf"),
            "model/gltf+json; charset=utf-8"
        )
        XCTAssertEqual(
            ModelResourceResolver.mimeType(forExtension: "3mf"),
            "model/3mf"
        )
        XCTAssertEqual(
            ModelResourceResolver.mimeType(forExtension: "usdz"),
            "model/vnd.usdz+zip"
        )
        XCTAssertEqual(
            ModelResourceResolver.mimeType(forExtension: "obj"),
            "text/plain; charset=utf-8"
        )
        XCTAssertEqual(
            ModelResourceResolver.mimeType(forExtension: "wasm"),
            "application/wasm"
        )
        XCTAssertEqual(
            ModelResourceResolver.mimeType(forExtension: "unknown"),
            "application/octet-stream"
        )
    }

    func testBlendIsNeverAServedAssetType() {
        XCTAssertFalse(
            ModelResourceResolver.assetExtensions.contains("blend")
        )
        XCTAssertFalse(
            ModelResourceResolver.assetExtensions.contains("py")
        )
    }

    func testViewerURLCannotBeUsedAsTheModelPage() {
        XCTAssertEqual(
            ModelResourceResolver.viewerURL()?.absoluteString,
            "sonovo-model://local/viewer/index.html"
        )
    }

    func testNavigationPolicyAllowsOnlyTheViewerOrigin() {
        XCTAssertTrue(
            ModelNavigationPolicy.allows(
                URL(string: "sonovo-model://local/viewer/index.html")!
            )
        )
        XCTAssertTrue(
            ModelNavigationPolicy.allows(
                URL(string: "sonovo-model://local/viewer/vendor/three/build/three.module.js")!
            )
        )
        for blocked in [
            "sonovo-model://local/asset/model.glb",
            "https://example.com/",
            "http://localhost/",
            "file:///etc/passwd",
            "about:blank",
            "sonovo-model://other/viewer/index.html",
            "sonovo-model://local/viewerish/index.html"
        ] {
            XCTAssertFalse(
                ModelNavigationPolicy.allows(URL(string: blocked)!),
                "\(blocked) must not be a navigation target"
            )
        }
    }

    // MARK: - Helpers

    private func url(_ path: String) -> URL {
        URL(string: "sonovo-model://local\(path)")!
    }

    private func file(_ path: String) throws -> ModelResourceResolver.Resource {
        try file(url(path))
    }

    private func file(_ url: URL) throws -> ModelResourceResolver.Resource {
        let outcome = resolver.resolve(url)
        guard case .file(let resource) = outcome else {
            XCTFail("Expected a file for \(url.absoluteString), got \(outcome)")
            throw ResolverTestError.notAFile
        }
        return resource
    }

    private enum ResolverTestError: Error {
        case notAFile
    }

    private func write(
        _ relativePath: String,
        in root: URL,
        contents: String
    ) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    func testReadBudgetRefusesBeyondTheLimit() throws {
        let budget = ModelReadBudget(limit: 10)
        try budget.charge(6)
        XCTAssertThrowsError(try budget.charge(5)) { error in
            XCTAssertTrue(error is ModelResourceError)
        }
        budget.release(6)
        XCTAssertNoThrow(try budget.charge(10))
    }

    func testBoundedReadRefusesAFileOverTheCap() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("asset.bin")
        let data = Data([0, 1, 2, 3, 4])
        try data.write(to: url)

        let exact = try await ModelSchemeHandler.readBounded(
            url,
            cap: data.count
        )
        XCTAssertEqual(exact.data, data)

        do {
            _ = try await ModelSchemeHandler.readBounded(
                url,
                cap: data.count - 1
            )
            XCTFail("Expected the cap to reject the file")
        } catch {
            XCTAssertTrue(error is ModelResourceError)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SonovoModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
