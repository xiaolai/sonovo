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
    case fileTooLarge(byteCount: Int)

    public var description: String {
        switch self {
        case .unsupportedFormat:
            "The file is not SRT, WebVTT, ASS, or SSA subtitles."
        case let .fileTooLarge(byteCount):
            "The subtitle file is \(byteCount) bytes; the reading limit is "
                + "\(SubtitleLimits.maxReadBytes) bytes."
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
        // Check the size before allocating the file. The editable threshold
        // only decides read-only state; it is not a memory bound.
        let reported = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            ?? 0
        guard reported <= SubtitleLimits.maxReadBytes else {
            throw SubtitleFileStoreError.fileTooLarge(byteCount: reported)
        }
        // The metadata check above does not bound a file that grows between
        // the check and the read. Read at most cap + 1 bytes.
        let data = try Self.readBoundedData(url)
        guard data.count <= SubtitleLimits.maxReadBytes else {
            throw SubtitleFileStoreError.fileTooLarge(byteCount: data.count)
        }
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

    /// Reads at most `maxReadBytes + 1` bytes. Every reread path, including
    /// external-change and conflict recovery, must use this instead of
    /// `Data(contentsOf:)`.
    static func readBoundedData(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let cap = SubtitleLimits.maxReadBytes + 1
        var data = Data()
        while data.count < cap {
            let chunk = try handle.read(
                upToCount: min(1 << 18, cap - data.count)
            )
            guard let chunk, !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
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
