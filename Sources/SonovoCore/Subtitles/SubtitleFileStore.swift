import Foundation

/// A subtitle file read from disk, with its detected format and encoding.
public struct LoadedSubtitle: Sendable {
    public let url: URL
    public let contents: SubtitleFileContents
    public let snapshot: DiskSnapshot
    public let format: SubtitleFormat
    /// Whether the document is above the editable-size threshold.
    public let isLarge: Bool

    public init(
        url: URL,
        contents: SubtitleFileContents,
        snapshot: DiskSnapshot,
        format: SubtitleFormat,
        isLarge: Bool
    ) {
        self.url = url
        self.contents = contents
        self.snapshot = snapshot
        self.format = format
        self.isLarge = isLarge
    }
}

public enum SubtitleFileStoreError: Error, Equatable, CustomStringConvertible {
    case unsupportedFormat

    public var description: String {
        switch self {
        case .unsupportedFormat:
            "The file is not SRT, WebVTT, ASS, or SSA subtitles."
        }
    }
}

/// Reads subtitle files with their own encoding rules and delegates the
/// compare-and-swap write path to the proven `MarkdownFileStore`.
public struct SubtitleFileStore: Sendable {
    private var fileStore: MarkdownFileStore

    public init(fileStore: MarkdownFileStore = MarkdownFileStore()) {
        self.fileStore = fileStore
    }

    public func read(_ url: URL) throws -> LoadedSubtitle {
        let data = try Data(contentsOf: url)
        let contents = try SubtitleEncoding.decode(data)
        guard let format = SubtitleFormat.detect(
            url: url,
            source: contents.text
        ) else {
            throw SubtitleFileStoreError.unsupportedFormat
        }
        return LoadedSubtitle(
            url: url,
            contents: contents,
            snapshot: DiskSnapshot(bytes: data),
            format: format,
            isLarge: data.count > SubtitleLimits.maxEditableBytes
        )
    }

    /// Returns `nil` when the file does not exist.
    public func diskSnapshot(at url: URL) throws -> DiskSnapshot? {
        try fileStore.diskSnapshot(at: url)
    }

    public func compareDisk(
        at url: URL,
        to snapshot: DiskSnapshot
    ) throws -> DiskComparison {
        try fileStore.compareDisk(at: url, to: snapshot)
    }

    public func save(_ request: SaveRequest) throws -> SaveOutcome {
        try fileStore.save(request)
    }
}
