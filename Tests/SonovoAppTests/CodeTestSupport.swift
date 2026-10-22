import Foundation
@testable import Sonovo

/// Shared temp-file fixture for the code tests.
final class CodeTestSupport {
    private(set) var roots: [URL] = []

    func makeRoot(files: [String: Data] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoCode-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        roots.append(root)
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        return root
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    func tearDown() {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots = []
    }
}

enum CodeTestData {
    static func utf8(_ text: String) -> Data { Data(text.utf8) }

    static func crlf(_ text: String) -> Data {
        Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    static func bom(_ text: String) -> Data {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: text.utf8)
        return data
    }

    static func utf16LE(_ text: String) -> Data {
        Data([0xFF, 0xFE]) + Data(text.utf16.flatMap {
            [UInt8($0 & 0xFF), UInt8($0 >> 8)]
        })
    }

    static func utf16BE(_ text: String) -> Data {
        Data([0xFE, 0xFF]) + Data(text.utf16.flatMap {
            [UInt8($0 >> 8), UInt8($0 & 0xFF)]
        })
    }

    static func latin1(_ text: String) -> Data {
        Data(text.unicodeScalars.map { UInt8($0.value & 0xFF) })
    }
}
