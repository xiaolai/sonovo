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

    /// cmark ignores a backtick run longer than this as a code-span
    /// delimiter (its parser caps the opener run), so a longer run is
    /// ordinary text and its content must stay visible to the scanner.
    public static let maxCodeSpanBacktickRun = 80

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

    /// Maximum TeX source characters in one formula. Larger spans stay
    /// literal; the renderer never typesets unbounded input.
    public static let maxMathSourceCharacters = 4_096

    /// Maximum brace nesting in one formula. Typesetting recurses through
    /// groups, so this bounds the renderer's stack.
    public static let maxMathBraceDepth = 64

    /// Maximum formulas one export will rasterize. Later formulas stay
    /// literal source so a pathological document cannot stall an export.
    public static let maxRenderedMathFormulas = 500

    /// Maximum typeset formulas kept in the renderer's cache.
    public static let maxMathRenderCacheEntries = 512

    /// Maximum PNG bytes an HTML export spends on formulas. Later formulas
    /// stay literal source rather than letting one huge document produce an
    /// unbounded file.
    public static let maxMathExportBytes = 16 * 1024 * 1024

    /// Maximum bytes of one fenced code block the rendered viewer will
    /// syntax-highlight. Lexing is linear but the result is an attributed
    /// string; a fence is authored content, and a larger one renders plain
    /// rather than spending the reader's frame budget on it. Sized like the
    /// diagram source limits (32 KiB) with headroom for multibyte text.
    public static let maxHighlightedFenceBytes = 64 * 1024

    /// Maximum characters of Mermaid source in one fence. Diagrams are
    /// authored by hand; a larger fence is a document, not a diagram, and
    /// stays a code block.
    public static let maxMermaidSourceCharacters = 32_768

    /// Maximum nodes Mermaid may lay out in one diagram.
    public static let maxMermaidEdges = 500

    /// Maximum sanitized SVG bytes for one diagram. The sanitizer fails
    /// closed above this, and the reader shows the code block instead.
    public static let maxMermaidSVGBytes = 4 * 1024 * 1024

    /// Maximum rendered diagrams kept in the renderer cache.
    public static let maxMermaidRenderCacheEntries = 128

    /// Seconds one diagram may take before the renderer abandons it and
    /// reloads the isolated page.
    public static let mermaidRenderTimeoutSeconds: Double = 10

    /// A PDF export that has not finished by now is stalled: the page never
    /// loaded, a script never returned, or the web process died silently.
    public static let pdfRenderTimeoutSeconds: Double = 60

    /// Maximum characters of Graphviz DOT source in one fence.
    public static let maxGraphvizSourceCharacters = 32_768

    /// Maximum characters of Markmap source in one fence.
    public static let maxMarkmapSourceCharacters = 32_768

    /// Maximum bytes of a raw SVG fence. The sanitizer still applies; this
    /// only bounds the document that reaches it.
    public static let maxSVGFenceBytes = 2 * 1024 * 1024

    /// Seconds the synchronous SVG sanitizer may spend on one fence before
    /// it stops and the fence falls back to a code block.
    public static let svgSanitizeTimeoutSeconds: Double = 2

    /// Maximum diagrams of any engine one HTML export will render.
    public static let maxRenderedDiagrams = 200

    /// Maximum SVG bytes an HTML export spends on all diagram engines.
    public static let maxDiagramExportBytes = 16 * 1024 * 1024

    /// Maximum cells an HTML-pasted table may produce after padding every
    /// row to the widest row. A table with many rows and one wide row is
    /// quadratic in the padded output; above this the rows convert as plain
    /// text instead of a table.
    public static let maxPastedTableCells = 10_000

    /// Maximum simultaneous carets. Each caret costs a decoration range, a
    /// geometry lookup, and a slot in every batch; past this the editor
    /// refuses placement instead of degrading under unbounded fan-out.
    public static let maxCarets = 100
}
