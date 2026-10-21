import Foundation
import XCTest
@testable import Sonovo

@MainActor
final class Model3DWorkspaceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    func testOpenDedupesCanonicalPaths() async throws {
        let model = try makeModel(name: "model.stl", contents: "solid cube\n")
        let link = model.deletingLastPathComponent()
            .appendingPathComponent("link.stl")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: model
        )

        let workspace = Model3DWorkspace(
            environment: [:],
            converter: FakeBlendConverter()
        )
        let first = try XCTUnwrap(workspace.open(url: model))
        let second = try XCTUnwrap(workspace.open(url: link))

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(workspace.documents.count, 1)
        XCTAssertEqual(workspace.selectedDocument?.id, first.id)
        XCTAssertEqual(first.state, .loading(nil))
        XCTAssertEqual(first.renderableURL, model.resolvingSymlinksInPath())
    }

    func testOpenRejectsMissingUnsupportedAndDirectories() throws {
        let directory = try makeDirectory()
        let workspace = Model3DWorkspace(
            environment: [:],
            converter: FakeBlendConverter()
        )

        XCTAssertNil(
            workspace.open(url: directory.appendingPathComponent("missing.glb"))
        )
        XCTAssertNotNil(workspace.lastError)

        let unsupported = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: unsupported)
        XCTAssertNil(workspace.open(url: unsupported))
        XCTAssertTrue(workspace.lastError?.contains("does not support") == true)

        XCTAssertNil(workspace.open(url: directory))
        XCTAssertTrue(workspace.lastError?.contains("does not exist") == true)
    }

    func testSceneSwitchingUpdatesStatsAndSelection() throws {
        let model = try makeModel(name: "scenes.glb", contents: "glTF")
        let document = Model3DDocument(url: model, format: .glb)
        document.apply(
            stats: .empty,
            animations: [],
            scenes: ["CubeScene", "SphereScene"],
            scene: 1
        )
        XCTAssertEqual(document.selectedScene, 1)
        XCTAssertEqual(document.sceneNames.count, 2)

        let stats = Model3DStats(
            meshes: 2,
            triangles: 24,
            vertices: 48,
            materials: 1,
            textures: 0,
            animations: 0,
            bounds: Model3DBounds(x: 1, y: 2, z: 3),
            rendererRevision: "186"
        )
        document.applyScene(index: 0, stats: stats, animations: [])
        XCTAssertEqual(document.selectedScene, 0)
        XCTAssertEqual(document.stats, stats)

        document.selectScene(99)
        XCTAssertEqual(document.selectedScene, 1)
        document.selectScene(-4)
        XCTAssertEqual(document.selectedScene, 0)
    }

    func testLoadedKeepsWarningsPostedWhileLoading() throws {
        let model = try makeModel(name: "warn.stl", contents: "solid cube\n")
        let document = Model3DDocument(url: model, format: .stl)
        document.setWarning("This 3MF references external object files.")
        document.apply(stats: .empty, animations: [], scenes: [], scene: 0)

        XCTAssertEqual(document.state, .ready)
        XCTAssertEqual(
            document.warning,
            "This 3MF references external object files."
        )
        document.dismissWarning()
        XCTAssertNil(document.warning)
    }

    func testBlendOpensInNeedsConversion() async throws {
        let blend = try makeModel(name: "scene.blend", contents: "BLENDER")
        let workspace = Model3DWorkspace(
            environment: [:],
            converter: FakeBlendConverter()
        )
        let document = try XCTUnwrap(workspace.open(url: blend))

        XCTAssertEqual(document.state, .needsConversion)
        XCTAssertNil(document.renderableURL)
        XCTAssertEqual(document.upAxis, .y)
        XCTAssertTrue(document.format.isConvertible)
    }

    func testConversionSuccessPublishesTemporaryOutput() async throws {
        let blend = try makeModel(name: "scene.blend", contents: "BLENDER")
        let converter = FakeBlendConverter()
        let workspace = Model3DWorkspace(
            environment: [:],
            converter: converter
        )
        let document = try XCTUnwrap(workspace.open(url: blend))
        let output = try makeConversionDirectory()
        let glb = output.appendingPathComponent("model.glb")
        try Data("glTF".utf8).write(to: glb)

        converter.handler = {
            BlendConversionResult(
                outputURL: glb,
                temporaryDirectory: output,
                installation: BlenderInstallation(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true")
                ),
                version: "5.2.2",
                log: "SONOVO_EXPORT_OK"
            )
        }

        workspace.convert(document)
        let converted = await waitUntil {
            document.renderableURL == glb
        }
        XCTAssertTrue(converted)
        XCTAssertEqual(document.convertedFrom, blend)
        XCTAssertEqual(document.blenderVersion, "5.2.2")
        XCTAssertEqual(document.state, .loading(nil))
        XCTAssertEqual(document.conversionLog, "SONOVO_EXPORT_OK")

        await workspace.close(document)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.path),
            "Close must remove converted output"
        )
        XCTAssertTrue(workspace.documents.isEmpty)
    }

    func testUSDConversionIsAvailableAfterDirectLoadFailure() async throws {
        let usd = try makeModel(name: "scene.usdc", contents: "PXR-USDC")
        let converter = FakeBlendConverter()
        let workspace = Model3DWorkspace(
            environment: [:],
            converter: converter
        )
        let document = try XCTUnwrap(workspace.open(url: usd))
        XCTAssertEqual(document.state, .loading(nil))
        XCTAssertTrue(document.format.canConvertWithBlender)

        document.fail("The built-in USD parser could not read this file.")
        XCTAssertEqual(
            document.state,
            .failed("The built-in USD parser could not read this file.")
        )

        let output = try makeConversionDirectory()
        let glb = output.appendingPathComponent("model.glb")
        try Data("glTF".utf8).write(to: glb)
        converter.handler = {
            BlendConversionResult(
                outputURL: glb,
                temporaryDirectory: output,
                installation: BlenderInstallation(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true")
                ),
                version: "5.2.2",
                log: "SONOVO_EXPORT_OK",
                warnings: ["This file contains 2 scenes; choose one in the header."]
            )
        }

        workspace.convert(document)
        let converted = await waitUntil {
            document.renderableURL == glb
        }
        XCTAssertTrue(converted)
        XCTAssertTrue(document.isConverted)
        XCTAssertEqual(document.convertedFrom, usd)
        XCTAssertEqual(document.state, .loading(nil))
        XCTAssertEqual(
            document.warning,
            "This file contains 2 scenes; choose one in the header."
        )
    }

    func testConversionFailureKeepsLog() async throws {
        let blend = try makeModel(name: "broken.blend", contents: "BLENDER")
        let converter = FakeBlendConverter()
        let workspace = Model3DWorkspace(
            environment: [:],
            converter: converter
        )
        let document = try XCTUnwrap(workspace.open(url: blend))

        converter.error = BlenderConversionError.failed(
            status: 2,
            log: "Traceback: boom"
        )
        workspace.convert(document)

        let failed = await waitUntil {
            document.state == .conversionFailed("Blender exited with status 2.")
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(document.conversionLog, "Traceback: boom")
        XCTAssertNil(document.renderableURL)
    }

    func testCancellationReturnsToNeedsConversion() async throws {
        let blend = try makeModel(name: "slow.blend", contents: "BLENDER")
        let converter = FakeBlendConverter()
        let workspace = Model3DWorkspace(
            environment: [:],
            converter: converter
        )
        let document = try XCTUnwrap(workspace.open(url: blend))

        converter.handler = {
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        workspace.convert(document)
        let started = await waitUntil { document.state == .converting }
        XCTAssertTrue(started)

        workspace.cancelConversion(document)
        let cancelled = await waitUntil {
            document.state == .needsConversion
        }
        XCTAssertTrue(cancelled)
    }

    func testDeclaredMaterialThatDoesNotExistYetIsRetained() throws {
        let directory = try makeDirectory()
        let obj = directory.appendingPathComponent("model.obj")
        try Data(
            """
            mtllib materials/future.mtl
            v 0 0 0
            """.utf8
        ).write(to: obj)

        // The path must be cached even before the file exists: otherwise
        // creating it later leaves the empty cache valid and the viewer
        // never loads the new library.
        XCTAssertEqual(
            Model3DDocument.scanMaterialPaths(sourceURL: obj),
            ["materials/future.mtl"]
        )
    }

    func testOBJMaterialLibraryUsesTheDeclaredPath() throws {
        let container = try makeDirectory()
        let directory = container.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let materials = directory.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(
            at: materials,
            withIntermediateDirectories: true
        )
        let custom = materials.appendingPathComponent("custom.mtl")
        try Data("newmtl Custom".utf8).write(to: custom)
        try Data("newmtl Sibling".utf8).write(
            to: directory.appendingPathComponent("model.mtl")
        )
        let obj = directory.appendingPathComponent("model.obj")
        try Data("mtllib materials/custom.mtl\nv 0 0 0\n".utf8).write(to: obj)

        XCTAssertEqual(
            Model3DDocument.scanMaterialPaths(sourceURL: obj),
            ["materials/custom.mtl"],
            "The viewer must request the declared subdirectory, not just the name"
        )

        // Declarations outside the model's directory are not followed.
        let outside = container.appendingPathComponent("outside.mtl")
        try Data("newmtl Outside".utf8).write(to: outside)
        try Data("mtllib ../outside.mtl\n".utf8).write(to: obj)
        XCTAssertEqual(
            Model3DDocument.scanMaterialPaths(sourceURL: obj),
            ["model.mtl"],
            "An escaped mtllib falls back to the sibling MTL"
        )
        try? FileManager.default.removeItem(at: outside)
    }

    func testOBJMaterialLibraryParsingHandlesWhitespaceSpacesAndDistance() throws {
        let container = try makeDirectory()
        let directory = container.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let materials = directory.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(
            at: materials,
            withIntermediateDirectories: true
        )
        let first = materials.appendingPathComponent("first.mtl")
        let spaced = materials.appendingPathComponent("my materials.mtl")
        let last = materials.appendingPathComponent("last.mtl")
        for file in [first, spaced, last] {
            try Data("newmtl Custom".utf8).write(to: file)
        }
        let obj = directory.appendingPathComponent("model.obj")

        // A tab separator, a quoted filename containing spaces, and several
        // declarations — all of which OBJ permits — are all honoured.
        try Data(
            """
            mtllib\tmaterials/first.mtl
            mtllib "materials/my materials.mtl"
            mtllib materials/last.mtl
            v 0 0 0
            """.utf8
        ).write(to: obj)
        XCTAssertEqual(
            Model3DDocument.scanMaterialPaths(sourceURL: obj),
            [
                "materials/first.mtl",
                "materials/my materials.mtl",
                "materials/last.mtl"
            ]
        )

        // A declaration beyond the old fixed read windows is still found.
        // The padding is over 1 MiB, so a prefix read cannot reach it.
        let padding = String(repeating: "# padding line\n", count: 80_000)
        try Data((padding + "mtllib materials/my materials.mtl\n").utf8)
            .write(to: obj)
        XCTAssertEqual(
            Model3DDocument.scanMaterialPaths(sourceURL: obj),
            ["materials/my materials.mtl"]
        )

        // CRLF line endings leave a carriage return on the name.
        try Data("mtllib materials/first.mtl\r\nv 0 0 0\r\n".utf8)
            .write(to: obj)
        XCTAssertEqual(
            Model3DDocument.scanMaterialPaths(sourceURL: obj),
            ["materials/first.mtl"]
        )
    }

    func testExternalChangeIsReportedByWatcher() async throws {
        let model = try makeModel(name: "watched.stl", contents: "solid one\n")
        let workspace = Model3DWorkspace(
            environment: [:],
            converter: FakeBlendConverter()
        )
        let document = try XCTUnwrap(workspace.open(url: model))
        XCTAssertFalse(document.hasExternalChange)

        try Data("solid two\n".utf8).write(to: model)
        let changed = await waitUntil { document.hasExternalChange }
        XCTAssertTrue(changed)

        document.reload()
        XCTAssertFalse(document.hasExternalChange)
        XCTAssertEqual(document.state, .loading(nil))
    }

    func testDemoEnvironmentOpensAndSelects() async throws {
        let model = try makeModel(name: "demo.glb", contents: "glTF")
        let workspace = Model3DWorkspace(
            environment: ["SONOVO_DEMO_MODEL": model.path],
            converter: FakeBlendConverter()
        )

        XCTAssertEqual(workspace.selectedDocument?.sourceURL, model)
        XCTAssertEqual(workspace.documents.count, 1)
    }

    func testTerminationCancelsConversionsAndConverter() async throws {
        let blend = try makeModel(name: "quit.blend", contents: "BLENDER")
        let converter = FakeBlendConverter()
        let workspace = Model3DWorkspace(
            environment: [:],
            converter: converter
        )
        let document = try XCTUnwrap(workspace.open(url: blend))

        converter.handler = {
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        workspace.convert(document)
        _ = await waitUntil { document.state == .converting }

        workspace.prepareForTermination()
        XCTAssertTrue(converter.terminated)
    }

    func testStaleTemporaryDirectoriesAreRemoved() throws {
        let root = Model3DTemporaryFiles.root
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let stale = root.appendingPathComponent(
            "stale-\(UUID().uuidString)",
            isDirectory: true
        )
        let fresh = root.appendingPathComponent(
            "fresh-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-48 * 60 * 60)],
            ofItemAtPath: stale.path
        )
        temporaryDirectories.append(contentsOf: [stale, fresh])

        _ = Model3DWorkspace(
            environment: [:],
            converter: FakeBlendConverter()
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoModelWorkspaceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeModel(name: String, contents: String) throws -> URL {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeConversionDirectory() throws -> URL {
        let directory = Model3DTemporaryFiles.root
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return directory
    }
}

@MainActor
final class FakeBlendConverter: BlendConverting {
    var installation: BlenderInstallation? = BlenderInstallation(
        executableURL: URL(fileURLWithPath: "/usr/bin/true")
    )
    var handler: (() async throws -> BlendConversionResult)?
    var error: Error?
    private(set) var terminated = false

    func locateBlender() -> BlenderInstallation? {
        installation
    }

    func convert(source: URL) async throws -> BlendConversionResult {
        if let error { throw error }
        guard let handler else {
            throw BlenderConversionError.notInstalled
        }
        return try await handler()
    }

    func terminateAll() {
        terminated = true
    }
}
