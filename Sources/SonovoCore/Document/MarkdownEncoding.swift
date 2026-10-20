import CryptoKit
import Foundation

/// A failure while decoding a Markdown file.
public enum MarkdownEncodingError: Error, Equatable, CustomStringConvertible {
    case invalidUTF8

    public var description: String {
        switch self {
        case .invalidUTF8:
            return "file is not valid UTF-8"
        }
    }
}

/// A Markdown file's bytes and the canonical text they represent.
public struct MarkdownFileContents: Sendable, Equatable {
    /// The exact bytes on disk.
    public let rawBytes: Data
    /// BOM-free, LF-only text.
    public let canonicalText: String
    public let hasBOM: Bool
    public let lineEnding: LineEnding
    public let hadMixedLineEndings: Bool

    public init(
        rawBytes: Data,
        canonicalText: String,
        hasBOM: Bool,
        lineEnding: LineEnding,
        hadMixedLineEndings: Bool
    ) {
        self.rawBytes = rawBytes
        self.canonicalText = canonicalText
        self.hasBOM = hasBOM
        self.lineEnding = lineEnding
        self.hadMixedLineEndings = hadMixedLineEndings
    }
}

/// A byte-for-byte snapshot of the file an edit was based on.
public struct DiskSnapshot: Sendable, Equatable {
    public let bytes: Data
    public let sha256: String

    public init(bytes: Data) {
        self.bytes = bytes
        self.sha256 = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public var byteCount: Int { bytes.count }
}

/// Encoding rules for Markdown files.
public enum MarkdownEncoding {
    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Decodes raw bytes, rejecting invalid UTF-8 loudly.
    public static func decode(_ data: Data) throws -> MarkdownFileContents {
        let hasBOM = data.count >= 3 && Array(data.prefix(3)) == bom
        let body = hasBOM ? data.dropFirst(3) : data[...]
        // `String(data:encoding:)` strips a leading U+FEFF of its own, which
        // would delete a real content character after the byte BOM.
        // `validating:` preserves it and still rejects invalid UTF-8.
        guard let text = String(validating: body, as: UTF8.self) else {
            throw MarkdownEncodingError.invalidUTF8
        }

        // The UTF-8 BOM was already removed above. Stripping a second U+FEFF
        // here would delete a real leading text character from a file whose
        // content itself starts with one.
        let canonical = SourceMap.canonicalize(raw: text, stripBOM: false)
        return MarkdownFileContents(
            rawBytes: data,
            canonicalText: canonical.text,
            hasBOM: hasBOM || canonical.hasBOM,
            lineEnding: canonical.lineEnding,
            hadMixedLineEndings: canonical.hadMixedLineEndings
        )
    }

    /// Encodes canonical text back to bytes, re-emitting BOM and line endings.
    public static func encode(
        _ canonicalText: String,
        hasBOM: Bool,
        lineEnding: LineEnding
    ) -> Data {
        let text: String
        switch lineEnding {
        case .lf:
            text = canonicalText
        case .crlf:
            text = canonicalText.replacingOccurrences(of: "\n", with: "\r\n")
        }

        var data = Data()
        if hasBOM {
            data.append(contentsOf: bom)
        }
        data.append(contentsOf: text.utf8)
        return data
    }

    /// Soft comparison ignores BOM, line endings, and trailing newlines.
    ///
    /// It is used for external-change decisions, never for compare-and-swap;
    /// the save path compares exact bytes.
    public static func softText(_ canonicalText: String) -> String {
        var text = canonicalText
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    public static func softEqual(_ lhs: String, _ rhs: String) -> Bool {
        softText(lhs) == softText(rhs)
    }
}
