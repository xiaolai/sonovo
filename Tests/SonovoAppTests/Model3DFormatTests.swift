import Foundation
import XCTest
@testable import Sonovo

final class Model3DFormatTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    func testEveryOpenPanelExtensionHasAFormat() {
        XCTAssertEqual(
            Set(Model3DFormat.openPanelExtensions),
            Set(Model3DFormat.allCases.map(\.rawValue))
        )
        for format in Model3DFormat.allCases {
            XCTAssertEqual(
                Model3DFormat.detect(fileExtension: format.rawValue),
                format
            )
            XCTAssertEqual(
                Model3DFormat.detect(fileExtension: format.rawValue.uppercased()),
                format
            )
        }
    }

    func testUnknownExtensionAndEmptyExtensionAreNil() {
        XCTAssertNil(Model3DFormat.detect(fileExtension: "txt"))
        XCTAssertNil(Model3DFormat.detect(fileExtension: ""))
        XCTAssertNil(Model3DFormat.detect(fileExtension: "glb2"))
    }

    func testConversionIsOnlyForBlend() {
        for format in Model3DFormat.allCases {
            XCTAssertEqual(format.isConvertible, format == .blend)
            XCTAssertEqual(
                format.canConvertWithBlender,
                format == .blend || format.isUSD
            )
        }
    }

    func testUSDAndDAEAreRecognized() {
        XCTAssertEqual(Model3DFormat.detect(fileExtension: "dae"), .dae)
        XCTAssertEqual(Model3DFormat.dae.displayName, "DAE")
        XCTAssertEqual(Model3DFormat.dae.defaultUpAxis, .y)
        XCTAssertEqual(Model3DFormat.usdz.displayName, "USDZ")
        XCTAssertTrue(Model3DFormat.usdz.canConvertWithBlender)
        XCTAssertFalse(Model3DFormat.glb.canConvertWithBlender)
        XCTAssertFalse(Model3DFormat.fbx.canConvertWithBlender)
    }

    func testUpAxisDefaultsFollowFormatConventions() {
        XCTAssertEqual(Model3DFormat.glb.defaultUpAxis, .y)
        XCTAssertEqual(Model3DFormat.gltf.defaultUpAxis, .y)
        XCTAssertEqual(Model3DFormat.fbx.defaultUpAxis, .y)
        XCTAssertEqual(Model3DFormat.usdz.defaultUpAxis, .y)
        XCTAssertEqual(Model3DFormat.dae.defaultUpAxis, .y)
        XCTAssertEqual(Model3DFormat.blend.defaultUpAxis, .y)
        XCTAssertEqual(Model3DFormat.stl.defaultUpAxis, .z)
        XCTAssertEqual(Model3DFormat.obj.defaultUpAxis, .z)
        XCTAssertEqual(Model3DFormat.ply.defaultUpAxis, .z)
        XCTAssertEqual(Model3DFormat.threeMF.defaultUpAxis, .z)
    }

    func testExtensionWinsOverContents() throws {
        let url = try write(
            name: "actually-stl.stl",
            bytes: Data("glTF\u{02}\u{00}\u{00}\u{00}".utf8)
        )
        XCTAssertEqual(Model3DFormat.detect(url: url), .stl)
    }

    func testSniffGLB() throws {
        let url = try write(
            name: "model.bin",
            bytes: Data([0x67, 0x6C, 0x54, 0x46, 0x02, 0, 0, 0])
        )
        XCTAssertEqual(Model3DFormat.detect(url: url), .glb)
    }

    func testSniffPLY() throws {
        let url = try write(name: "point-cloud", bytes: Data("ply\nformat ascii 1.0\n".utf8))
        XCTAssertEqual(Model3DFormat.detect(url: url), .ply)
    }

    func testSniffBinaryFBX() throws {
        let url = try write(
            name: "model-binary",
            bytes: Data("Kaydara FBX Binary  \0".utf8)
        )
        XCTAssertEqual(Model3DFormat.detect(url: url), .fbx)
    }

    func testSniffASCIIFBX() throws {
        let url = try write(
            name: "model-ascii",
            bytes: Data("; FBX 7.4.0 project file\n".utf8)
        )
        XCTAssertEqual(Model3DFormat.detect(url: url), .fbx)
    }

    func testSniffUSDAAndUSDC() throws {
        let usda = try write(name: "scene-text", bytes: Data("#usda 1.0\n".utf8))
        XCTAssertEqual(Model3DFormat.detect(url: usda), .usda)

        let usdc = try write(name: "scene-binary", bytes: Data("PXR-USDC".utf8))
        XCTAssertEqual(Model3DFormat.detect(url: usdc), .usdc)
    }

    func testSniffGLTFJSONWithoutTheGeneratorString() throws {
        // Valid glTF JSON need not contain the literal "glTF"; the asset
        // version is the reliable marker.
        let json = """
        {"scenes":[],"asset":{"generator":"Blender","version":"2.0"}}
        """
        let url = try write(name: "scene-json", bytes: Data(json.utf8))
        XCTAssertEqual(Model3DFormat.detect(url: url), .gltf)
    }

    func testSniffASCIISTL() throws {
        let url = try write(
            name: "part-ascii",
            bytes: Data("solid cube\nfacet normal 0 0 1\n".utf8)
        )
        XCTAssertEqual(Model3DFormat.detect(url: url), .stl)
    }

    func testSniffUnknownBytesIsNil() throws {
        let url = try write(name: "mystery", bytes: Data("not a model at all".utf8))
        XCTAssertNil(Model3DFormat.detect(url: url))
    }

    func testMissingFileDoesNotSniff() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        XCTAssertNil(Model3DFormat.detect(url: url))
    }

    // MARK: - Helpers

    private func write(name: String, bytes: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoModelFormatTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
}
