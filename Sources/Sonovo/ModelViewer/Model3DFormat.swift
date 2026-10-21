import Foundation

enum Model3DUpAxis: String, CaseIterable, Sendable {
    case y
    case z

    var label: String {
        switch self {
        case .y: "Y-up"
        case .z: "Z-up"
        }
    }

    var shortLabel: String { rawValue.uppercased() }
}

/// The file formats the model viewer can open. Raw values are the lowercase
/// filename extensions, so detection and the open panel share one list.
enum Model3DFormat: String, CaseIterable, Sendable {
    case glb
    case gltf
    case stl
    case obj
    case ply
    case fbx
    case threeMF = "3mf"
    case usdz
    case usda
    case usdc
    case usd
    case dae
    case blend

    static let openPanelExtensions: [String] = allCases.map(\.rawValue)

    var displayName: String {
        switch self {
        case .glb: "GLB"
        case .gltf: "glTF"
        case .stl: "STL"
        case .obj: "OBJ"
        case .ply: "PLY"
        case .fbx: "FBX"
        case .threeMF: "3MF"
        case .usdz: "USDZ"
        case .usda: "USDA"
        case .usdc: "USDC"
        case .usd: "USD"
        case .dae: "DAE"
        case .blend: "Blender"
        }
    }

    /// `.blend` cannot be loaded at all and always starts in the conversion
    /// state. USD loads directly first; conversion is the fallback when the
    /// bundled USD parser cannot read the file.
    var isConvertible: Bool { self == .blend }

    var isUSD: Bool {
        switch self {
        case .usdz, .usda, .usdc, .usd: true
        default: false
        }
    }

    var canConvertWithBlender: Bool { isConvertible || isUSD }

    /// glTF and USD declare Y-up, and Blender exports Y-up glTF. STL, OBJ,
    /// PLY, and 3MF come from 3D-printing workflows that author Z-up, and 3MF
    /// is defined that way.
    var defaultUpAxis: Model3DUpAxis {
        switch self {
        case .glb, .gltf, .fbx, .usdz, .usda, .usdc, .usd, .dae, .blend:
            .y
        case .stl, .obj, .ply, .threeMF:
            .z
        }
    }

    static func detect(fileExtension: String) -> Model3DFormat? {
        Model3DFormat(rawValue: fileExtension.lowercased())
    }

    /// Extension first; the byte sniff only covers a missing or unknown
    /// extension, so a mislabeled file still has a chance to open.
    static func detect(url: URL) -> Model3DFormat? {
        if let format = detect(fileExtension: url.pathExtension) {
            return format
        }
        return sniff(url: url)
    }

    static func sniff(url: URL) -> Model3DFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else {
            return nil
        }

        if data.starts(with: Array("glTF".utf8)) {
            return .glb
        }
        if data.starts(with: Array("ply".utf8)) {
            return .ply
        }
        if data.starts(with: Array("PXR-USDC".utf8)) {
            return .usdc
        }

        let head = String(decoding: data, as: UTF8.self)
        if head.contains("Kaydara FBX Binary") || head.hasPrefix("; FBX") {
            return .fbx
        }
        if head.contains("#usda") {
            return .usda
        }
        if head.contains("\"asset\"") && head.contains("\"version\"") {
            return .gltf
        }
        if head.lowercased().hasPrefix("solid ") {
            return .stl
        }
        return nil
    }
}
