public enum SubtitleLimits {
    /// Larger files open read-only, matching the Markdown editor's limit.
    public static let maxEditableBytes = 4 * 1024 * 1024
    /// Hard read cap. A file above this is refused before it is allocated,
    /// separately from the editable threshold.
    public static let maxReadBytes = 16 * 1024 * 1024
    public static let maxCueCount = 50_000
    public static let maxDiagnostics = 500
    public static let maxUnparsedBlocks = 200
}
