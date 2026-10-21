import CryptoKit
import Foundation
import XCTest
@testable import Sonovo

final class ModelViewerResourceTests: XCTestCase {
    func testViewerBundleIsPresent() throws {
        let root = try XCTUnwrap(
            ModelViewerResources.root,
            "The ModelViewer resource directory is missing from the app bundle"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("index.html").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("viewer.css").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("app.js").path
        ))
        XCTAssertNotNil(ModelViewerResources.conversionScript)
    }

    func testIndexUsesAnImportMapAndNoncePlaceholder() throws {
        let html = try String(
            contentsOf: XCTUnwrap(ModelViewerResources.indexHTML),
            encoding: .utf8
        )
        XCTAssertTrue(html.contains("type=\"importmap\""))
        XCTAssertTrue(html.contains("__CSP_NONCE__"))
        XCTAssertTrue(html.contains("\"three\":"))
        XCTAssertTrue(html.contains("\"three/addons/\":"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertTrue(html.contains("app.js"))
    }

    func testViewerScriptsContainNoRuntimeExternalURLs() throws {
        let root = try XCTUnwrap(ModelViewerResources.root)
        for name in ["app.js", "viewer.css"] {
            let text = try String(
                contentsOf: root.appendingPathComponent(name),
                encoding: .utf8
            )
            XCTAssertFalse(
                text.contains("http://"),
                "\(name) must not fetch an external resource"
            )
            XCTAssertFalse(
                text.contains("https://"),
                "\(name) must not fetch an external resource"
            )
        }
    }

    func testDecoderAndColladaAssetsAreBundled() throws {
        let root = try XCTUnwrap(ModelViewerResources.root)
            .appendingPathComponent("vendor/three")
        for path in [
            "examples/jsm/loaders/DRACOLoader.js",
            "examples/jsm/loaders/KTX2Loader.js",
            "examples/jsm/loaders/ColladaLoader.js",
            "examples/jsm/libs/meshopt_decoder.module.js",
            "examples/jsm/libs/draco/gltf/draco_decoder.wasm",
            "examples/jsm/libs/draco/gltf/draco_wasm_wrapper.js",
            "examples/jsm/libs/basis/basis_transcoder.wasm",
            "examples/jsm/libs/basis/basis_transcoder.js",
            "examples/jsm/utils/WorkerPool.js",
            "examples/jsm/libs/ktx-parse.module.js",
            "examples/jsm/libs/zstddec.module.js"
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(path).path
                ),
                "Missing bundled decoder asset: \(path)"
            )
        }
    }

    func testChecksumManifestMatchesVendoredFiles() throws {
        let root = try XCTUnwrap(ModelViewerResources.root)
            .appendingPathComponent("vendor/three")
        let manifest = try String(
            contentsOf: root.appendingPathComponent("SHA256SUMS"),
            encoding: .utf8
        )
        let lines = manifest.split(separator: "\n")
        XCTAssertGreaterThanOrEqual(lines.count, 20)

        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else {
                return XCTFail("Malformed checksum line: \(line)")
            }
            let expected = String(parts[0])
            var path = String(parts[1])
            if path.hasPrefix("./") {
                path.removeFirst(2)
            }
            let fileURL = root.appendingPathComponent(path)
            let data = try Data(contentsOf: fileURL)
            let actual = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(actual, expected, "Checksum mismatch for \(path)")
        }
    }

    func testVendoredImportClosureResolves() throws {
        let vendorRoot = try XCTUnwrap(ModelViewerResources.root)
            .appendingPathComponent("vendor/three")
        let addonsRoot = vendorRoot.appendingPathComponent("examples/jsm")
        let pattern = try NSRegularExpression(
            pattern: #"(?:from\s+|import\s+)['"]([^'"]+)['"]"#
        )

        let enumerator = FileManager.default.enumerator(
            at: addonsRoot,
            includingPropertiesForKeys: nil
        )
        var checked = 0
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "js" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let specifierRange = Range(match.range(at: 1), in: text)
                else { continue }
                let specifier = String(text[specifierRange])
                if specifier.hasPrefix(".") {
                    let target = file.deletingLastPathComponent()
                        .appendingPathComponent(specifier)
                        .standardizedFileURL
                    XCTAssertTrue(
                        FileManager.default.fileExists(atPath: target.path),
                        "\(file.lastPathComponent) imports missing \(specifier)"
                    )
                    checked += 1
                } else if specifier.hasPrefix("three/addons/") {
                    let relative = specifier.replacingOccurrences(
                        of: "three/addons/",
                        with: ""
                    )
                    let target = addonsRoot.appendingPathComponent(relative)
                    XCTAssertTrue(
                        FileManager.default.fileExists(atPath: target.path),
                        "\(file.lastPathComponent) imports missing \(specifier)"
                    )
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 10)
    }

    func testConversionScriptIsBundledAndUsesEnvironmentPaths() throws {
        let script = try String(
            contentsOf: XCTUnwrap(ModelViewerResources.conversionScript),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains("SONOVO_BLEND_INPUT"))
        XCTAssertTrue(script.contains("SONOVO_BLEND_OUTPUT"))
        XCTAssertTrue(script.contains("open_mainfile"))
        XCTAssertTrue(script.contains("export_scene.gltf"))
        XCTAssertTrue(script.contains("SONOVO_EXPORT_OK"))
        XCTAssertFalse(script.contains("os.system"))
        XCTAssertFalse(script.contains("subprocess"))
    }

    func testVendorManifestNamesThePinnedVersion() throws {
        let root = try XCTUnwrap(ModelViewerResources.root)
            .appendingPathComponent("vendor/three")
        let manifest = try String(
            contentsOf: root.appendingPathComponent("VENDOR.md"),
            encoding: .utf8
        )
        XCTAssertTrue(manifest.contains("0.186.1"))
        XCTAssertTrue(manifest.contains("MIT"))
    }
}
