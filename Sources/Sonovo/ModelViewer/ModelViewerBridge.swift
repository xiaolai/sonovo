import Foundation

/// The complete vocabulary between the viewer page and the app. Everything
/// arriving from JavaScript is boundary input: version and token are checked,
/// numbers are clamped, and strings are capped before they reach the UI.
enum ModelViewerBridge {
    static let version = 1
    static let maxStringLength = 2000
    static let maxClipCount = 200
    static let maxSceneCount = 100
    static let maxCount = 10_000_000
    static let maxProgress = 1_000_000_000_000.0

    enum Event: Equatable, Sendable {
        case ready
        case progress(loaded: Double, total: Double)
        case loaded(
            stats: Model3DStats,
            animations: [Model3DAnimation],
            scenes: [String],
            scene: Int
        )
        case scene(
            index: Int,
            stats: Model3DStats,
            animations: [Model3DAnimation]
        )
        case animation(playing: Bool, clip: Int)
        case warning(String)
        case error(message: String, code: String?)
    }

    static func decode(_ body: Any, expectedToken: String) -> Event? {
        guard let dictionary = body as? [String: Any],
              dictionary["v"] as? Int == version,
              let token = dictionary["token"] as? String,
              token == expectedToken,
              let type = dictionary["type"] as? String else {
            return nil
        }

        switch type {
        case "ready":
            return .ready
        case "progress":
            guard let loaded = finiteNumber(dictionary["loaded"]),
                  let total = finiteNumber(dictionary["total"]) else {
                return nil
            }
            let clampedTotal = min(max(total, 0), maxProgress)
            let clampedLoaded = min(max(loaded, 0), clampedTotal)
            return .progress(loaded: clampedLoaded, total: clampedTotal)
        case "loaded":
            return loadedEvent(dictionary)
        case "scene":
            return sceneEvent(dictionary)
        case "animation":
            guard let playing = dictionary["playing"] as? Bool,
                  let clip = dictionary["clip"] as? Int else {
                return nil
            }
            return .animation(
                playing: playing,
                clip: min(max(clip, 0), maxClipCount)
            )
        case "warning":
            guard let message = boundedString(dictionary["message"]) else {
                return nil
            }
            return .warning(message)
        case "error":
            guard let message = boundedString(dictionary["message"]) else {
                return nil
            }
            return .error(
                message: message,
                code: boundedString(dictionary["code"])
            )
        default:
            return nil
        }
    }

    private static func loadedEvent(_ dictionary: [String: Any]) -> Event? {
        guard let rawStats = dictionary["stats"] as? [String: Any] else {
            return nil
        }
        let stats = decodedStats(rawStats, dictionary: dictionary)
        let animations = decodedAnimations(dictionary)
        let scenes = (dictionary["scenes"] as? [String] ?? [])
            .prefix(maxSceneCount)
            .enumerated()
            .map { offset, name in
                let trimmed = String(name.prefix(200))
                return trimmed.isEmpty ? "Scene \(offset + 1)" : trimmed
            }
        let scene = min(
            max((dictionary["scene"] as? Int) ?? 0, 0),
            maxSceneCount - 1
        )
        return .loaded(
            stats: stats,
            animations: animations,
            scenes: scenes,
            scene: scene
        )
    }

    private static func decodedStats(
        _ rawStats: [String: Any],
        dictionary: [String: Any]
    ) -> Model3DStats {
        let bounds: Model3DBounds? = (rawStats["bounds"] as? [String: Any])
            .flatMap { value -> Model3DBounds? in
                guard let x = finiteNumber(value["x"]),
                      let y = finiteNumber(value["y"]),
                      let z = finiteNumber(value["z"]) else {
                    return nil
                }
                return Model3DBounds(x: x, y: y, z: z)
            }
        return Model3DStats(
            meshes: count(rawStats["meshes"]),
            triangles: count(rawStats["triangles"]),
            vertices: count(rawStats["vertices"]),
            materials: count(rawStats["materials"]),
            textures: count(rawStats["textures"]),
            animations: count(rawStats["animations"]),
            bounds: bounds,
            rendererRevision: boundedString(
                dictionary["rendererRevision"]
            ) ?? ""
        )
    }

    private static func decodedAnimations(
        _ dictionary: [String: Any]
    ) -> [Model3DAnimation] {
        let rawAnimations = dictionary["animations"] as? [[String: Any]] ?? []
        // Keep every position. Dropping a malformed entry would shift the
        // remaining indices relative to the JavaScript clip array, so a menu
        // selection could play a different clip.
        return rawAnimations.prefix(maxClipCount).enumerated().map {
            offset, value in
            let name = boundedString(value["name"])
                ?? "Animation \(offset + 1)"
            let duration = finiteNumber(value["duration"]) ?? 0
            return Model3DAnimation(
                index: offset,
                name: name,
                duration: max(duration, 0)
            )
        }
    }

    private static func sceneEvent(_ dictionary: [String: Any]) -> Event? {
        guard let rawStats = dictionary["stats"] as? [String: Any] else {
            return nil
        }
        let stats = decodedStats(rawStats, dictionary: dictionary)
        let animations = decodedAnimations(dictionary)
        let index = min(
            max((dictionary["scene"] as? Int) ?? 0, 0),
            maxSceneCount - 1
        )
        return .scene(index: index, stats: stats, animations: animations)
    }

    private static func count(_ value: Any?) -> Int {
        guard let number = value as? Int else { return 0 }
        return min(max(number, 0), maxCount)
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func boundedString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else {
            return nil
        }
        return String(string.prefix(maxStringLength))
    }

    struct Configuration: Encodable {
        let token: String
        let modelURL: String
        let format: String
        let mtlURLs: [String]
        let name: String
        let theme: String
        let grid: Bool
        let wireframe: Bool
        let upAxis: String
        let playing: Bool
        let clip: Int
        let scene: Int
    }

    static func configurationJSON(_ configuration: Configuration) -> String? {
        guard let data = try? JSONEncoder().encode(configuration),
              var json = String(data: data, encoding: .utf8) else {
            return nil
        }
        json = escapeLineSeparators(json)
        return json
    }

    static func encodedString(_ value: String) -> String? {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return escapeLineSeparators(json)
    }

    static func commandJSON(_ command: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(command),
              let data = try? JSONSerialization.data(
                withJSONObject: command,
                options: [.sortedKeys]
              ),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return escapeLineSeparators(json)
    }

    /// JavaScript parsers accept these, but escaping them keeps the injected
    /// source valid under every parser and costs nothing.
    private static func escapeLineSeparators(_ json: String) -> String {
        json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
