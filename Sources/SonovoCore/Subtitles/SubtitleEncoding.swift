import Foundation

/// Encodings a subtitle file may use. Real-world SRT files are not always
/// UTF-8; UTF-16 and Windows-1252 still appear in legacy libraries and
/// broadcast pipelines.
public enum SubtitleTextEncoding: Sendable, Equatable {
    case utf8(hasBOM: Bool)
    case utf16LittleEndian
    case utf16BigEndian
    case windows1252

    public var displayName: String {
        switch self {
        case let .utf8(hasBOM): hasBOM ? "UTF-8 BOM" : "UTF-8"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .windows1252: "Windows-1252"
        }
    }

    public var hasBOM: Bool {
        if case let .utf8(hasBOM) = self { return hasBOM }
        return self == .utf16LittleEndian || self == .utf16BigEndian
    }
}

public struct SubtitleFileContents: Sendable, Equatable {
    /// BOM-free, LF-only text.
    public let text: String
    public let encoding: SubtitleTextEncoding
    public let lineEnding: LineEnding
    public let hadMixedLineEndings: Bool
    public let rawBytes: Data

    public init(
        text: String,
        encoding: SubtitleTextEncoding,
        lineEnding: LineEnding,
        hadMixedLineEndings: Bool,
        rawBytes: Data
    ) {
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.hadMixedLineEndings = hadMixedLineEndings
        self.rawBytes = rawBytes
    }
}

public enum SubtitleEncodingError: Error, Equatable, CustomStringConvertible {
    case invalidEncoding
    case cannotRepresent(String)
    case unsupportedUTF32

    public var description: String {
        switch self {
        case .invalidEncoding:
            "The file is not valid UTF-8, UTF-16, or Windows-1252 text."
        case let .cannotRepresent(encoding):
            "The text contains characters that \(encoding) cannot encode."
        case .unsupportedUTF32:
            "UTF-32 subtitle files are not supported."
        }
    }
}

public enum SubtitleEncoding {
    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let utf16LEBOM: [UInt8] = [0xFF, 0xFE]
    private static let utf16BEBOM: [UInt8] = [0xFE, 0xFF]

    public static func decode(
        _ data: Data
    ) throws -> SubtitleFileContents {
        let bytes = [UInt8](data)

        if bytes.starts(with: utf8BOM) {
            guard let text = String(
                data: data.dropFirst(3),
                encoding: .utf8
            ) else {
                throw SubtitleEncodingError.invalidEncoding
            }
            return try canonicalize(
                text,
                encoding: .utf8(hasBOM: true),
                original: data
            )
        }

        if bytes.starts(with: utf16LEBOM) {
            if bytes.count >= 4, bytes[2] == 0, bytes[3] == 0 {
                throw SubtitleEncodingError.unsupportedUTF32
            }
            guard let text = String(
                data: data.dropFirst(2),
                encoding: .utf16LittleEndian
            ) else {
                throw SubtitleEncodingError.invalidEncoding
            }
            return try canonicalize(
                text,
                encoding: .utf16LittleEndian,
                original: data
            )
        }

        if bytes.starts(with: utf16BEBOM) {
            guard let text = String(
                data: data.dropFirst(2),
                encoding: .utf16BigEndian
            ) else {
                throw SubtitleEncodingError.invalidEncoding
            }
            return try canonicalize(
                text,
                encoding: .utf16BigEndian,
                original: data
            )
        }

        if bytes.count >= 4,
           bytes[0] == 0, bytes[1] == 0,
           bytes[2] == 0xFE, bytes[3] == 0xFF {
            throw SubtitleEncodingError.unsupportedUTF32
        }

        // Text subtitles never contain NUL; a NUL means the bytes are not
        // text, even when they happen to be valid UTF-8.
        guard !bytes.contains(0x00) else {
            throw SubtitleEncodingError.invalidEncoding
        }

        if let text = String(data: data, encoding: .utf8) {
            return try canonicalize(
                text,
                encoding: .utf8(hasBOM: false),
                original: data
            )
        }

        // A subtitle file must not silently decode binary data as text.
        guard let text = String(
            data: data,
            encoding: .windowsCP1252
        ) else {
            throw SubtitleEncodingError.invalidEncoding
        }
        return try canonicalize(
            text,
            encoding: .windows1252,
            original: data
        )
    }

    private static func canonicalize(
        _ text: String,
        encoding: SubtitleTextEncoding,
        original: Data
    ) throws -> SubtitleFileContents {
        // A decoded NUL is binary data even when the bytes formed valid text
        // in some encoding (UTF-16 NULs decode to U+0000).
        guard !text.contains("\0") else {
            throw SubtitleEncodingError.invalidEncoding
        }
        let canonical = SourceMap.canonicalize(raw: text, stripBOM: false)
        return SubtitleFileContents(
            text: canonical.text,
            encoding: encoding,
            lineEnding: canonical.lineEnding,
            hadMixedLineEndings: canonical.hadMixedLineEndings,
            rawBytes: original
        )
    }

    public static func encode(
        _ canonicalText: String,
        encoding: SubtitleTextEncoding,
        lineEnding: LineEnding
    ) throws -> Data {
        let text = lineEnding == .crlf
            ? canonicalText.replacingOccurrences(of: "\n", with: "\r\n")
            : canonicalText

        switch encoding {
        case let .utf8(hasBOM):
            guard var data = text.data(using: .utf8) else {
                throw SubtitleEncodingError.invalidEncoding
            }
            if hasBOM {
                data.insert(contentsOf: utf8BOM, at: 0)
            }
            return data
        case .utf16LittleEndian:
            guard let body = text.data(using: .utf16LittleEndian) else {
                throw SubtitleEncodingError.invalidEncoding
            }
            return Data(utf16LEBOM) + body
        case .utf16BigEndian:
            guard let body = text.data(using: .utf16BigEndian) else {
                throw SubtitleEncodingError.invalidEncoding
            }
            return Data(utf16BEBOM) + body
        case .windows1252:
            guard let data = text.data(using: .windowsCP1252) else {
                throw SubtitleEncodingError.cannotRepresent(
                    encoding.displayName
                )
            }
            return data
        }
    }
}
