import Foundation

package struct Model3DBounds: Equatable, Sendable {
    package let x: Double
    package let y: Double
    package let z: Double

    package var displayString: String {
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

package struct Model3DAnimation: Identifiable, Equatable, Sendable {
    package let index: Int
    package let name: String
    package let duration: Double

    package var id: Int { index }

    package var durationLabel: String {
        String(format: "%.1f s", duration)
    }
}

package struct Model3DStats: Equatable, Sendable {
    package let meshes: Int
    package let triangles: Int
    package let vertices: Int
    package let materials: Int
    package let textures: Int
    package let animations: Int
    package let bounds: Model3DBounds?
    package let rendererRevision: String

    package static let empty = Model3DStats(
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
