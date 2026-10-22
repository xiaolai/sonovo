/// One namespace for every code limit.
///
/// These are safety floors, not preferences. Exceeding one always produces a
/// named state; a file is never partially applied.
enum CodeLimits {
    /// Largest editable file.
    static let editableBytes = 2_097_152
    /// Largest readable file. Above this the viewer refuses to read at all.
    static let maximumReadBytes = 8_388_608
    /// Diff sides are capped independently of editability.
    static let diffBytesPerSide = 2_097_152
    static let diffLinesPerSide = 50_000
    /// Project search limits.
    static let searchPerFileBytes = 2_097_152
    static let searchTotalBytes = 209_715_200
    static let searchResultLimit = 200
    /// A longer line is shown as plain text with a named note.
    static let highlightLineBytes = 20_000
    /// The read chunk keeps allocation bounded without a second full copy.
    static let readChunkBytes = 262_144
    /// Discovery stays bounded on a pathological tree.
    static let discoveryVisitedEntries = 200_000
    static let discoveryFiles = 20_000
}
