import Foundation

/// Serializes subtitle parsing and drops results that a newer edit has
/// superseded.
///
/// Parsing is pure and cheap relative to disk I/O, but a source editor can
/// enqueue several revisions per second. The actor keeps one parse running at
/// a time across all documents and lets a queued older request return `nil`
/// after a newer revision has been announced.
public actor SubtitleParseService {
    private var latestGeneration: [UUID: UInt64] = [:]

    public init() {}

    /// Announces a newer source revision for a document. A parse request for
    /// an older revision will not start once this has run.
    public func markLatest(documentID: UUID, generation: UInt64) {
        let current = latestGeneration[documentID] ?? 0
        if generation > current {
            latestGeneration[documentID] = generation
        }
    }

    /// Parses `source` unless a newer revision has been announced.
    public func parse(
        documentID: UUID,
        generation: UInt64,
        source: String,
        format: SubtitleFormat
    ) -> SubtitleParseResult? {
        if let latest = latestGeneration[documentID], latest > generation {
            return nil
        }
        latestGeneration[documentID] = max(
            latestGeneration[documentID] ?? 0,
            generation
        )
        return SubtitleParser.parse(source, format: format)
    }

    public func forget(documentID: UUID) {
        latestGeneration.removeValue(forKey: documentID)
    }
}
