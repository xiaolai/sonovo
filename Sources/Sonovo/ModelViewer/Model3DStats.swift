import Foundation

struct Model3DBounds: Equatable, Sendable {
    let x: Double
    let y: Double
    let z: Double

    var displayString: String {
        [x, y, z]
            .map(Self.format)
            .joined(separator: " × ")
    }

    private static func format(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude == 0 {
            return "0"
        }
        if magnitude < 1 {
            return String(format: "%.3f", value)
        }
        if magnitude < 1000 {
            return String(format: "%.2f", value)
        }
        return String(format: "%.0f", value)
    }
}

struct Model3DAnimation: Identifiable, Equatable, Sendable {
    let index: Int
    let name: String
    let duration: Double

    var id: Int { index }

    var durationLabel: String {
        String(format: "%.1f s", duration)
    }
}

struct Model3DStats: Equatable, Sendable {
    let meshes: Int
    let triangles: Int
    let vertices: Int
    let materials: Int
    let textures: Int
    let animations: Int
    let bounds: Model3DBounds?
    let rendererRevision: String

    static let empty = Model3DStats(
        meshes: 0,
        triangles: 0,
        vertices: 0,
        materials: 0,
        textures: 0,
        animations: 0,
        bounds: nil,
        rendererRevision: ""
    )
}
