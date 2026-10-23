/// One namespace for every Markdown limit.
///
/// Limits live here so the parser, augmenter, and viewer cannot drift apart
/// with scattered literals. A limit is a safety floor, not a rendering
/// preference: exceeding it falls back to a safe representation rather than
/// crashing or hanging.
public enum MarkdownLimits {
    /// Maximum nested `<details>` depth. The remainder stays raw HTML.
    public static let maxDetailsDepth = 16

    /// Maximum rendered TOC rows. The heading index stays complete.
    public static let maxTOCEntries = 1000

    /// Maximum container nesting depth the parser will walk.
    public static let maxParseDepth = 128

    /// Hard read cap. The editable threshold decides read-only state; this is
    /// the memory bound for the whole read/decode/parse pipeline.
    public static let maxReadBytes = 16 * 1024 * 1024

    /// Maximum source lines. A flat AST of one block per line would otherwise
    /// allocate without bound even inside the byte cap.
    public static let maxSourceLines = 100_000

    /// Maximum inline delimiter characters across the whole source. This
    /// bounds the inline node count when a document repeats many small
    /// emphasis/link constructs instead of nesting them.
    public static let maxInlineDelimiters = 500_000

    /// Maximum inline delimiters on one line. Short runs can nest emphasis
    /// without ever looking like a long run; a single line with hundreds of
    /// markers is the pathological case.
    public static let maxInlineDelimitersPerLine = 4 * maxParseDepth

    /// Maximum unmatched inline delimiter characters. Every nested inline
    /// node consumes at least two delimiter characters, so this bounds the
    /// depth below the recursive converter before the AST mapper's own limit
    /// can apply. Weighted runs count about half their length, matching the
    /// nodes a run can form.
    public static let maxInlineNestingBudget = 2 * maxParseDepth

    /// Maximum opener runs in one paragraph. This is the sound backstop:
    /// every nested inline node needs an opener, so the count bounds the
    /// depth no matter how closers and literal regions interact. It is sized
    /// so the worst case stays well inside the parse thread's stack.
    public static let maxInlineOpenerBudget = 32 * maxParseDepth

    /// Documents larger than this are routed to source-only/read-only mode.
    ///
    /// Provisional until the M0 measurement; adjust only with a measurement.
    public static let maxEditableDocumentBytes = 4 * 1024 * 1024

    /// Maximum number of wiki-link resolution candidates considered.
    public static let maxWikiLinkCandidates = 64
}
