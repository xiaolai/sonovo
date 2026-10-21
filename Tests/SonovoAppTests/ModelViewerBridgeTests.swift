import Foundation
import XCTest
@testable import Sonovo

final class ModelViewerBridgeTests: XCTestCase {
    private let token = "token-123"

    func testDecodesReadyAndRejectsWrongTokenOrVersion() {
        XCTAssertEqual(decode(["type": "ready"]), .ready)
        XCTAssertNil(
            ModelViewerBridge.decode(
                ["v": 1, "token": "other", "type": "ready"],
                expectedToken: token
            )
        )
        XCTAssertNil(
            ModelViewerBridge.decode(
                ["v": 2, "token": token, "type": "ready"],
                expectedToken: token
            )
        )
        XCTAssertNil(
            ModelViewerBridge.decode(
                ["v": 1, "token": token, "type": "mystery"],
                expectedToken: token
            )
        )
    }

    func testProgressClampsAndRejectsNonFiniteNumbers() {
        XCTAssertEqual(
            decode(["type": "progress", "loaded": -10, "total": 50]),
            .progress(loaded: 0, total: 50)
        )
        XCTAssertEqual(
            decode(["type": "progress", "loaded": 10, "total": 50]),
            .progress(loaded: 10, total: 50)
        )
        XCTAssertNil(decode(["type": "progress", "loaded": Double.nan, "total": 1]))
        XCTAssertNil(decode(["type": "progress", "loaded": 1]))

        XCTAssertEqual(
            decode([
                "type": "progress",
                "loaded": 15_000_000,
                "total": 20_000_000
            ]),
            .progress(loaded: 15_000_000, total: 20_000_000)
        )
    }

    func testLoadedPayloadIsSanitized() throws {
        let stats: [String: Any] = [
            "meshes": -1,
            "triangles": Int.max,
            "vertices": 12,
            "materials": 2,
            "textures": 3,
            "animations": 1,
            "bounds": ["x": 1.5, "y": 2, "z": -3]
        ]
        let animations: [[String: Any]] = [
            ["index": 0, "name": "Idle", "duration": 2.5],
            ["index": 1, "duration": 1],
            ["name": "Walk", "duration": Double.infinity]
        ]
        let event = try XCTUnwrap(
            decode([
                "type": "loaded",
                "stats": stats,
                "animations": animations,
                "rendererRevision": "186"
            ])
        )
        guard case .loaded(let loadedStats, let clips, _, _) = event else {
            return XCTFail("Expected loaded event")
        }
        XCTAssertEqual(loadedStats.meshes, 0)
        XCTAssertEqual(loadedStats.triangles, ModelViewerBridge.maxCount)
        XCTAssertEqual(loadedStats.vertices, 12)
        XCTAssertEqual(loadedStats.bounds, Model3DBounds(x: 1.5, y: 2, z: -3))
        XCTAssertEqual(loadedStats.rendererRevision, "186")
        XCTAssertEqual(clips.count, 3)
        XCTAssertEqual(clips[0].name, "Idle")
        XCTAssertEqual(clips[0].duration, 2.5)
        XCTAssertEqual(clips[1].index, 1)
        XCTAssertEqual(clips[1].name, "Animation 2")
        XCTAssertEqual(clips[1].duration, 1)
        XCTAssertEqual(clips[2].index, 2)
        XCTAssertEqual(clips[2].name, "Walk")
    }

    func testLoadedWithoutStatsIsRejectedAndPartialBoundsAreNil() throws {
        XCTAssertNil(decode(["type": "loaded"]))
        let event = try XCTUnwrap(
            decode([
                "type": "loaded",
                "stats": ["meshes": 1, "bounds": ["x": 1, "y": 2]]
            ])
        )
        guard case .loaded(let stats, _, _, _) = event else {
            return XCTFail("Expected loaded event")
        }
        XCTAssertNil(stats.bounds)
        XCTAssertEqual(stats.meshes, 1)
    }

    func testAnimationMessageIsBounded() {
        XCTAssertEqual(
            decode(["type": "animation", "playing": true, "clip": 4]),
            .animation(playing: true, clip: 4)
        )
        XCTAssertEqual(
            decode(["type": "animation", "playing": false, "clip": 9999]),
            .animation(
                playing: false,
                clip: ModelViewerBridge.maxClipCount
            )
        )
        XCTAssertNil(decode(["type": "animation", "playing": true]))
    }

    func testStringsAreTruncated() throws {
        let long = String(repeating: "A", count: 5000)
        let event = try XCTUnwrap(
            decode(["type": "error", "message": long, "code": long])
        )
        guard case .error(let message, let code) = event else {
            return XCTFail("Expected error event")
        }
        XCTAssertEqual(message.count, ModelViewerBridge.maxStringLength)
        XCTAssertEqual(code?.count, ModelViewerBridge.maxStringLength)
    }

    func testEmptyAndMissingMessagesAreRejected() {
        XCTAssertNil(decode(["type": "warning", "message": ""]))
        XCTAssertNil(decode(["type": "error"]))
    }

    func testDecodesScenesAndSceneSwitches() throws {
        let loaded = try XCTUnwrap(
            decode([
                "type": "loaded",
                "stats": ["meshes": 2],
                "animations": [[String: Any]](),
                "scenes": ["CubeScene", "SphereScene"],
                "scene": 1
            ])
        )
        guard case .loaded(_, _, let scenes, let scene) = loaded else {
            return XCTFail("Expected loaded event")
        }
        XCTAssertEqual(scenes, ["CubeScene", "SphereScene"])
        XCTAssertEqual(scene, 1)

        let switched = try XCTUnwrap(
            decode([
                "type": "scene",
                "stats": ["meshes": 3, "triangles": 12],
                "animations": [[String: Any]](),
                "scene": 0,
                "rendererRevision": "186"
            ])
        )
        guard case .scene(let index, let stats, let clips) = switched else {
            return XCTFail("Expected scene event")
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(stats.meshes, 3)
        XCTAssertEqual(stats.triangles, 12)
        XCTAssertEqual(stats.rendererRevision, "186")
        XCTAssertTrue(clips.isEmpty)
        XCTAssertNil(decode(["type": "scene", "scene": 0]))
    }

    func testSceneListAndNamesAreBounded() throws {
        var names = (0..<99).map { "Scene \($0)" }
        let longName = String(repeating: "S", count: 500)
        names.append(longName)
        names.append("")
        names += (0..<60).map { "Extra \($0)" }
        let event = try XCTUnwrap(
            decode([
                "type": "loaded",
                "stats": ["meshes": 1],
                "scenes": names,
                "scene": 999
            ])
        )
        guard case .loaded(_, _, let scenes, let scene) = event else {
            return XCTFail("Expected loaded event")
        }
        XCTAssertEqual(scenes.count, ModelViewerBridge.maxSceneCount)
        XCTAssertEqual(scenes.last?.count, 200)
        XCTAssertFalse(scenes.contains(""))
        XCTAssertEqual(scene, ModelViewerBridge.maxSceneCount - 1)
    }

    func testClipListIsCapped() throws {
        let animations = (0..<300).map { index -> [String: Any] in
            ["index": index, "name": "Clip \(index)", "duration": 1]
        }
        let event = try XCTUnwrap(
            decode([
                "type": "loaded",
                "stats": [String: Any](),
                "animations": animations
            ])
        )
        guard case .loaded(_, let clips, _, _) = event else {
            return XCTFail("Expected loaded event")
        }
        XCTAssertEqual(clips.count, ModelViewerBridge.maxClipCount)
    }

    func testConfigurationJSONRoundTripsAndEscapesLineSeparators() throws {
        let configuration = ModelViewerBridge.Configuration(
            token: token,
            modelURL: "sonovo-model://local/asset/model.glb",
            format: "glb",
            mtlURLs: [
                "sonovo-model://local/asset/materials/one.mtl",
                "sonovo-model://local/asset/materials/two.mtl"
            ],
            name: "model\u{2028}name.glb",
            theme: "dark",
            grid: true,
            wireframe: false,
            upAxis: "y",
            playing: true,
            clip: 0,
            scene: 1
        )
        let json = try XCTUnwrap(
            ModelViewerBridge.configurationJSON(configuration)
        )
        XCTAssertTrue(json.contains("\\u2028"))
        XCTAssertFalse(json.contains("\u{2028}"))
        let object = try JSONSerialization.jsonObject(
            with: Data(json.utf8)
        ) as? [String: Any]
        XCTAssertEqual(object?["format"] as? String, "glb")
        XCTAssertEqual(object?["grid"] as? Bool, true)
        XCTAssertEqual(
            object?["mtlURLs"] as? [String],
            [
                "sonovo-model://local/asset/materials/one.mtl",
                "sonovo-model://local/asset/materials/two.mtl"
            ]
        )
        XCTAssertEqual(object?["clip"] as? Int, 0)
        XCTAssertEqual(object?["scene"] as? Int, 1)
    }

    func testCommandJSONEscapesLineSeparators() throws {
        let json = try XCTUnwrap(
            ModelViewerBridge.commandJSON([
                "theme": "dark",
                "name": "a\u{2029}b",
                "fit": 3
            ])
        )
        XCTAssertTrue(json.contains("\\u2029"))
        XCTAssertFalse(json.contains("\u{2029}"))
        XCTAssertNotNil(json.range(of: "\"fit\":3"))
    }

    func testEncodedStringIsQuotedJSON() throws {
        let encoded = try XCTUnwrap(
            ModelViewerBridge.encodedString("dark\"mode")
        )
        XCTAssertTrue(encoded.hasPrefix("\""))
        XCTAssertTrue(encoded.hasSuffix("\""))
        XCTAssertTrue(encoded.contains("\\\""))
    }

    // MARK: - Helpers

    private func decode(_ body: [String: Any]) -> ModelViewerBridge.Event? {
        var message = body
        message["v"] = message["v"] ?? 1
        message["token"] = message["token"] ?? token
        return ModelViewerBridge.decode(message, expectedToken: token)
    }
}
