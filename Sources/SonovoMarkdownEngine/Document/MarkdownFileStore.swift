import SonovoTextEngine
import SonovoFileIO
import Darwin
import Foundation

/// A file read from disk.
public struct LoadedMarkdown: Sendable {
    public let url: URL
    public let contents: MarkdownFileContents
    public let snapshot: DiskSnapshot
    /// Whether the document is above the editable-size threshold.
    public let isLarge: Bool

    public init(url: URL, contents: MarkdownFileContents, snapshot: DiskSnapshot) {
        self.url = url
        self.contents = contents
        self.snapshot = snapshot
        self.isLarge = snapshot.byteCount > MarkdownLimits.maxEditableDocumentBytes
    }
}

public enum MarkdownFileStoreError: Error, Equatable, CustomStringConvertible {
    case fileTooLarge(byteCount: Int)
    case tooManyLines(Int)

    public var description: String {
        switch self {
        case let .fileTooLarge(byteCount):
            "The Markdown file is \(byteCount) bytes; the reading limit is "
                + "\(MarkdownLimits.maxReadBytes) bytes."
        case let .tooManyLines(lineCount):
            "The Markdown file has more than \(lineCount) lines; the reading "
                + "limit is \(MarkdownLimits.maxSourceLines) lines."
        }
    }
}

extension MarkdownFileStoreError: LocalizedError {
    public var errorDescription: String? { description }
}

/// Compatibility policy for Markdown reads and exact-byte atomic saves.
public struct MarkdownFileStore: Sendable {
    public var options: FileStoreOptions
    public init(options: FileStoreOptions = FileStoreOptions()) {
        self.options = options
    }

    public func read(_ url: URL) throws -> LoadedMarkdown {
        let data = try Self.readBoundedData(at: url)
        let contents = try MarkdownEncoding.decode(data)
        return LoadedMarkdown(
            url: url,
            contents: contents,
            snapshot: DiskSnapshot(bytes: data)
        )
    }

    /// Returns `nil` when the file does not exist.
    public func diskSnapshot(at url: URL) throws -> DiskSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return DiskSnapshot(bytes: try Self.readBoundedData(at: url))
    }

    public func compareDisk(at url: URL, to snapshot: DiskSnapshot) throws -> DiskComparison {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        // A destination that grew past the read cap is changed by definition;
        // never allocate it just to discover that.
        let current: Data
        do {
            current = try Self.readBoundedData(at: url)
        } catch {
            return .changed
        }
        return current == snapshot.bytes ? .unchanged : .changed
    }

    /// A bounded read for callers that only need the bytes: the same size
    /// and line caps as `read`, without decoding.
    public static func readBoundedData(
        at url: URL,
        maximumBytes: Int = MarkdownLimits.maxReadBytes
    ) throws -> Data {
        do {
            return try BoundedFileReader.read(
                url, maximumBytes: maximumBytes,
                maximumLines: MarkdownLimits.maxSourceLines
            )
        } catch let error as FileReadError {
            switch error {
            case .fileTooLarge(let count):
                throw MarkdownFileStoreError.fileTooLarge(byteCount: count)
            case .tooManyLines(let count):
                throw MarkdownFileStoreError.tooManyLines(count)
            case .invalidLimits:
                throw error
            }
        }
    }

    public func save(_ request: SaveRequest) throws -> SaveOutcome {
        try AtomicFileStore(options: options).save(request)
    }
}
