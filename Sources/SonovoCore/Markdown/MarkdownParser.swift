import Foundation
import Markdown

/// A parsed Markdown document.
public struct ParsedMarkdown: Sendable {
    /// The canonical full source (BOM-free, LF-only).
    public let source: String

    /// The owned tree, before custom-syntax augmentation.
    public let ast: SonovoAST

    /// Maps positions in the body to global UTF-16 offsets.
    public let bodySourceMap: SourceMap

    /// Maps positions in the full canonical source.
    public let fullSourceMap: SourceMap

    /// The UTF-16 offset where the body starts (after frontmatter).
    public let bodyStartOffset: Int

    /// Whether the source exceeded the container-nesting limit and was kept
    /// as a single raw block instead of being parsed. The UI routes this to
    /// source-only mode.
    public let exceededNestingLimit: Bool

    public init(
        source: String,
        ast: SonovoAST,
        bodySourceMap: SourceMap,
        fullSourceMap: SourceMap,
        bodyStartOffset: Int,
        exceededNestingLimit: Bool = false
    ) {
        self.source = source
        self.ast = ast
        self.bodySourceMap = bodySourceMap
        self.fullSourceMap = fullSourceMap
        self.bodyStartOffset = bodyStartOffset
        self.exceededNestingLimit = exceededNestingLimit
    }
}

/// The base CommonMark + GFM parser.
///
/// Parsing is a pure function over the canonical source. It never touches the
/// main actor, never writes source text, and never runs an unstructured task.
/// Custom syntax (wiki links, details, TOC) is applied by
/// `MarkdownSyntaxAugmenter`, not here.
public struct MarkdownParser: Sendable {
    /// Parse options: smart punctuation is off; source positions stay on.
    public static let parseOptions: ParseOptions = [.disableSmartOpts]

    public init() {}

    /// Parses raw Markdown text.
    ///
    /// The input is canonicalized first: a leading BOM is removed and CRLF and
    /// lone CR line endings become LF. The returned map describes the
    /// canonical text.
    public static func parse(
        _ raw: String,
        enableAutolinks: Bool = true
    ) -> ParsedMarkdown {
        let canonical = SourceMap.canonicalize(raw: raw).text
        return parseCanonical(canonical, enableAutolinks: enableAutolinks)
    }

    /// The safe representation for a source that exceeds a parser guard:
    /// one raw block, so the UI can fall back to source-only presentation.
    private static func rawParsed(
        source: String,
        map: SourceMap
    ) -> ParsedMarkdown {
        let end = endPosition(of: source)
        let wholeRange = SourceRange(
            start: SourcePosition(line: 1, column: 0, offset: 0),
            end: end
        )
        // A paragraph of literal text, not an HTML block: the viewer drops
        // unknown HTML, which would blank a guarded document. The raw text
        // stays visible if the UI does not route it to source-only mode.
        let ast = SonovoAST(
            blocks: [
                .paragraph(
                    inlines: [.text(source, range: wholeRange)],
                    range: wholeRange
                )
            ]
        )
        return ParsedMarkdown(
            source: source,
            ast: ast,
            bodySourceMap: map,
            fullSourceMap: map,
            bodyStartOffset: 0,
            exceededNestingLimit: true
        )
    }

    /// The position after the source's last UTF-16 code unit. Computed
    /// without the line table so an over-budget source can be wrapped
    /// without indexing it.
    private static func endPosition(of source: String) -> SourcePosition {
        let utf16Count = source.utf16.count
        let newlineCount = source.utf8.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        guard let last = source.lastIndex(of: "\n") else {
            return SourcePosition(
                line: 1,
                column: utf16Count,
                offset: utf16Count
            )
        }
        let tail = source[source.index(after: last)...]
        return SourcePosition(
            line: newlineCount + 1,
            column: tail.utf16.count,
            offset: utf16Count
        )
    }

    /// Parses text that is already canonical (BOM-free, LF-only).
    public static func parseCanonical(
        _ source: String,
        enableAutolinks: Bool = true
    ) -> ParsedMarkdown {
        let byteCount = source.utf8.count
        let lineCount = source.utf8.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }

        // The byte and line budgets come first: building the source map
        // allocates one entry per line, so it must not run on a source that
        // is itself over budget. An unindexed map keeps the text for
        // source-only presentation without that allocation.
        if byteCount > MarkdownLimits.maxReadBytes
            || lineCount > MarkdownLimits.maxSourceLines {
            return Self.rawParsed(
                source: source,
                map: SourceMap(unindexed: source)
            )
        }

        // Only the body reaches the converter. Scanning the whole source
        // would let a YAML frontmatter value such as `~~~: true` open a
        // fence that hides the body from the inline guard.
        let split = FrontmatterSplitter.split(source)

        // Guard before swift-markdown's recursive converter can overflow the
        // stack, and before a flat document can exhaust memory. Content is
        // preserved as one raw block.
        if NestingGuard.exceedsLimit(
            split.body,
            limit: MarkdownLimits.maxParseDepth
        )
            || NestingGuard.exceedsInlineLimit(
                split.body,
                limit: MarkdownLimits.maxParseDepth
            ) {
            return Self.rawParsed(
                source: source,
                map: SourceMap(source: source)
            )
        }

        let fullMap = SourceMap(source: source)
        let bodyMap: SourceMap
        if split.bodyStartOffset == 0, split.bodyStartLine == 1 {
            bodyMap = fullMap
        } else {
            bodyMap = SourceMap(
                source: split.body,
                baseLine: split.bodyStartLine,
                baseOffset: split.bodyStartOffset
            )
        }

        let document = Document(parsing: split.body, options: parseOptions)
        let mapper = ASTMapper(
            sourceMap: bodyMap,
            lineOffset: split.bodyStartLine - 1,
            enableAutolinks: enableAutolinks
        )
        let blocks = mapper.mapBlocks(document.children)

        var excludedRanges: [SourceRange] = []
        if let frontmatter = split.frontmatter {
            excludedRanges.append(frontmatter.range)
        }
        Self.collectExcludedRanges(blocks, into: &excludedRanges)
        let definitions = ReferenceDefinitionScanner.scan(
            source,
            sourceMap: fullMap,
            excluding: excludedRanges
        )

        let ast = SonovoAST(
            blocks: blocks,
            frontmatter: split.frontmatter,
            referenceDefinitions: definitions
        )

        return ParsedMarkdown(
            source: source,
            ast: ast,
            bodySourceMap: bodyMap,
            fullSourceMap: fullMap,
            bodyStartOffset: split.bodyStartOffset
        )
    }

    /// Collects code and raw-HTML ranges at every depth. Reference-shaped
    /// text inside a nested fence or HTML block must not become a definition,
    /// just as it must not inside a top-level one.
    private static func collectExcludedRanges(
        _ blocks: [Block],
        into ranges: inout [SourceRange]
    ) {
        for block in blocks {
            switch block {
            case let .codeBlock(_, range), let .htmlBlock(_, range):
                if let range { ranges.append(range) }
            case let .paragraph(_, range):
                // A link reference definition cannot interrupt a paragraph.
                // A definition-shaped line inside one is ordinary text.
                if let range { ranges.append(range) }
            case let .blockQuote(children, _):
                collectExcludedRanges(children, into: &ranges)
            case let .list(list, _):
                for item in list.items {
                    collectExcludedRanges(item.blocks, into: &ranges)
                }
            case let .details(details, _):
                collectExcludedRanges(details.blocks, into: &ranges)
            default:
                continue
            }
        }
    }

    /// Convenience instance method.
    public func parse(_ raw: String) -> ParsedMarkdown {
        Self.parse(raw)
    }
}

// MARK: - Nesting guard

enum NestingGuard {
    /// A cheap bound shared by the full parser and the two reparse paths
    /// (`InlineFragmentParser` and `DetailsParser`), neither of which may
    /// build an unbounded source map.
    static func exceedsSourceBudget(_ source: String) -> Bool {
        if source.utf8.count > MarkdownLimits.maxReadBytes { return true }
        var lineCount = 0
        for byte in source.utf8 where byte == 0x0A {
            lineCount += 1
            if lineCount > MarkdownLimits.maxSourceLines { return true }
        }
        return false
    }

    /// Detects inline nesting that the block-container guard cannot see.
    ///
    /// swift-markdown converts the cmark tree recursively before the AST
    /// mapper can apply its own depth limit, so a deeply nested inline
    /// document overflows the stack in the dependency. The bound here is
    /// conservative by construction: every nested inline node consumes
    /// delimiter characters, so the number of *unclosed* delimiter
    /// characters is an upper bound on the nesting depth.
    ///
    /// A run that can open adds its full length to the depth; a run that can
    /// only close removes one entry per character, and only from matching
    /// openers; a run that can do both counts as an opener, because
    /// CommonMark's "rule of three" may refuse to pair it. The count can
    /// therefore exceed the real depth, never fall short.
    ///
    /// Delimiters are compared by their first Unicode scalar. Swift groups a
    /// combining mark with the character before it, so a grapheme that
    /// begins the delimiter still has to count as one; cmark sees the scalar.
    static func exceedsInlineLimit(_ source: String, limit: Int) -> Bool {
        // The budget checks run before splitting so a newline-only file does
        // not allocate one substring per line.
        guard source.utf8.count <= MarkdownLimits.maxReadBytes else {
            return true
        }
        var lineCount = 0
        for byte in source.utf8 where byte == 0x0A {
            lineCount += 1
            if lineCount > MarkdownLimits.maxSourceLines { return true }
        }

        let nestingBudget = MarkdownLimits.maxInlineNestingBudget
        var bracketDepth = 0
        var delimiterCount = 0
        // Unmatched delimiter characters, in the order they were opened.
        var openDelimiters: [Unicode.Scalar] = []
        // Every opener in the paragraph, never decremented. The stack above
        // is a tighter heuristic, but it can be talked into removing an
        // opener cmark keeps; this count cannot fall, so it is the bound
        // that holds when the heuristic is wrong.
        var openerCount = 0
        // False once the paragraph contains something whose content cmark
        // may treat as literal (an inline code span or an inline HTML tag
        // that does not close on the line). While uncertain, a closer is not
        // allowed to remove an opener: a literal closer cannot pair, and
        // popping there is how an earlier proxy undercounted.
        var paragraphCertain = true
        var fence: (Unicode.Scalar, Int)?
        // Raw HTML is literal to cmark; a fence marker inside it must not
        // turn on fence skipping. Openers in the block still count, because
        // a misidentified block may really be markup.
        var htmlEnd: String?

        // Delimiters inside a skipped HTML block count as openers: a
        // misidentified block is markup to cmark. Types 6/7 are the
        // heuristic ones and also enter the stack, so the tight bound
        // still applies.
        func countHTMLOpeners(
            _ line: Substring,
            heuristic: Bool
        ) -> Bool {
            var scan = line.unicodeScalars
            var cursor = scan.startIndex
            while cursor < scan.endIndex {
                let inner = scan[cursor]
                if inner == "*" || inner == "_" || inner == "~" {
                    openerCount += 1
                    if heuristic { openDelimiters.append(inner) }
                } else if inner == "[" {
                    openerCount += 1
                    if heuristic { bracketDepth += 1 }
                }
                if openerCount > MarkdownLimits.maxInlineOpenerBudget
                    || bracketDepth > limit
                    || openDelimiters.count > nestingBudget {
                    return true
                }
                cursor = scan.index(after: cursor)
            }
            return false
        }

        for line in source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            if let end = htmlEnd {
                if countHTMLOpeners(line, heuristic: end.isEmpty) {
                    return true
                }
                let terminated = end.isEmpty
                    ? stripContainers(line).allSatisfy({
                        $0 == " " || $0 == "\t"
                    })
                    : line.lowercased().contains(end.lowercased())
                if terminated {
                    htmlEnd = nil
                    openDelimiters.removeAll()
                    paragraphCertain = true
                }
                continue
            }
            if let end = htmlBlockEnd(line) {
                // The opening line can carry the whole markup; count it
                // before the block starts hiding lines.
                if countHTMLOpeners(line, heuristic: end.isEmpty) {
                    return true
                }
                htmlEnd = end
                openDelimiters.removeAll()
                paragraphCertain = true
                continue
            }
            if let active = fence {
                // A closing fence may be indented at most three spaces and
                // carries no info string. Anything else is literal content
                // of the block.
                var indent = 0
                var cursor = line.startIndex
                while cursor < line.endIndex, line[cursor] == " " {
                    indent += 1
                    cursor = line.index(after: cursor)
                }
                let trimmed = line[cursor...]
                // Count the run in scalars: a combining mark inside it ends
                // the run for cmark, and a grapheme-based count would close
                // a fence the parser keeps open (hiding real nesting).
                let scalars = trimmed.unicodeScalars
                var scalarIndex = scalars.startIndex
                var run = 0
                while scalarIndex < scalars.endIndex,
                      scalars[scalarIndex] == active.0 {
                    run += 1
                    scalarIndex = scalars.index(after: scalarIndex)
                }
                if indent <= 3, run >= active.1,
                   scalars[scalarIndex...].allSatisfy({
                       $0 == " " || $0 == "\t"
                   }) {
                    fence = nil
                    openDelimiters.removeAll()
                    openerCount = 0
                    paragraphCertain = true
                }
                continue
            }

            if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                // A blank line ends the paragraph whose delimiters pair.
                openDelimiters.removeAll()
                openerCount = 0
                bracketDepth = 0
                paragraphCertain = true
                continue
            }

            // A fence opens only at the start of a line. A fence indented
            // inside a container ends with that container, which this
            // scanner does not model; scanning container content instead
            // over-counts, while skipping it could hide real nesting.
            if let first = line.unicodeScalars.first,
               first == "`" || first == "~" {
                let scalars = line.unicodeScalars
                var scalarIndex = scalars.startIndex
                var run = 0
                while scalarIndex < scalars.endIndex,
                      scalars[scalarIndex] == first {
                    run += 1
                    scalarIndex = scalars.index(after: scalarIndex)
                }
                let info = scalars[scalarIndex...]
                let opensFence = first == "~" || !info.contains("`")
                if run >= 3, opensFence {
                    fence = (first, run)
                    openDelimiters.removeAll()
                    openerCount = 0
                    paragraphCertain = true
                    continue
                }
            }

            var lineDelimiters = 0
            var index = line.startIndex
            while index < line.endIndex {
                let character = line[index]
                guard let scalar = character.unicodeScalars.first else {
                    index = line.index(after: index)
                    continue
                }
                if scalar == "\\" {
                    // cmark escapes the next code point. When the
                    // backslash's grapheme already carries that scalar (a
                    // combining mark), advancing again would swallow the
                    // following delimiter.
                    let escapedInside = character.unicodeScalars.count > 1
                    index = line.index(after: index)
                    if !escapedInside, index < line.endIndex {
                        index = line.index(after: index)
                    }
                    continue
                }
                if scalar == "`" {
                    // Inline code content is scanned rather than hidden.
                    // A code span may open on one line and close on
                    // another, and the greedy same-line pairing this
                    // scanner can do is not cmark's; hiding content it
                    // parses as markup is the direction that undercounts.
                    let (run, after) = scalarRun(
                        line,
                        from: index,
                        scalar: scalar
                    )
                    lineDelimiters += run
                    delimiterCount += run
                    if paragraphCertain,
                       run <= MarkdownLimits.maxCodeSpanBacktickRun,
                       let close = sameLineRun(
                           line,
                           from: after,
                           length: run
                       ) {
                        // Closed on this line: cmark pairs the same two
                        // runs, so the content is certainly literal and
                        // contributes no delimiters.
                        index = close
                    } else {
                        // The span may close on a later line, where cmark
                        // treats everything up to the closer as literal.
                        // Scan the content, and stop letting closers remove
                        // openers for the rest of the paragraph.
                        paragraphCertain = false
                        index = after
                    }
                    if delimiterCount
                        > MarkdownLimits.maxInlineDelimiters {
                        return true
                    }
                    continue
                }

                if scalar == "<" {
                    let after = line.index(after: index)
                    if after < line.endIndex,
                       startsHTMLTag(line[after]) {
                        if let close = line[after...].firstIndex(of: ">"),
                           !line[after..<close].contains("`") {
                            // A valid tag is literal to cmark; an invalid
                            // one is not. Counting the tag's delimiters as
                            // openers is conservative either way, and it
                            // cannot remove a real opener.
                            var cursor = after
                            while cursor < close {
                                let inner = line[cursor]
                                    .unicodeScalars.first
                                if inner == "*" || inner == "_"
                                    || inner == "~" {
                                    openDelimiters.append(inner!)
                                    openerCount += 1
                                } else if inner == "[" {
                                    // Compare by scalar: a combining mark
                                    // can join the bracket's grapheme.
                                    openerCount += 1
                                }
                                cursor = line.index(after: cursor)
                            }
                            if openDelimiters.count > nestingBudget
                                || openerCount
                                    > MarkdownLimits.maxInlineOpenerBudget {
                                return true
                            }
                            index = line.index(after: close)
                            continue
                        }
                        paragraphCertain = false
                    }
                }

                var nextIndex = line.index(after: index)
                switch scalar {
                case "[":
                    bracketDepth += 1
                    openerCount += 1
                    lineDelimiters += 1
                    delimiterCount += 1
                case "]":
                    if bracketDepth > 0 { bracketDepth -= 1 }
                    lineDelimiters += 1
                    delimiterCount += 1
                case "*", "_", "~":
                    let delimiter = scalar
                    let run = line[index...]
                        .prefix(while: {
                            $0.unicodeScalars.first == delimiter
                        }).count
                    let after = line.index(index, offsetBy: run)
                    lineDelimiters += run
                    delimiterCount += run
                    let before = index > line.startIndex
                        ? line[line.index(before: index)]
                        : nil
                    let next = after < line.endIndex ? line[after] : nil
                    let beforeIsWord = before?.isLetter == true
                        || before?.isNumber == true
                    let nextIsWord = next?.isLetter == true
                        || next?.isNumber == true
                    // Underscores inside a word are literal.
                    let wordInterior = delimiter == "_"
                        && beforeIsWord && nextIsWord
                    // Mirrors cmark's flanking rules for a depth bound: a
                    // run can close if text precedes it, and can open if
                    // text follows it.
                    let canClose = before?.isWhitespace == false
                        && !wordInterior
                    // A combining mark in the run's last grapheme follows
                    // the delimiter scalar, so cmark sees non-whitespace
                    // text after it even when the next grapheme is a space
                    // or a line ending.
                    let lastOfRun = line[line.index(before: after)]
                    let hasCombiningTail =
                        lastOfRun.unicodeScalars.count > 1
                    let canOpen = (hasCombiningTail
                        || next?.isWhitespace == false)
                        && !wordInterior
                    if canOpen {
                        // Both-flanking runs count as openers: the rule of
                        // three may keep them unpaired, so popping there
                        // could undercount.
                        openerCount += run
                        openDelimiters.append(
                            contentsOf: repeatElement(delimiter, count: run)
                        )
                    } else if canClose, paragraphCertain {
                        var remaining = run
                        while remaining > 0,
                              openDelimiters.last == delimiter {
                            openDelimiters.removeLast()
                            remaining -= 1
                        }
                    }
                    nextIndex = after
                case "!":
                    lineDelimiters += 1
                    delimiterCount += 1
                default:
                    // A leading format character (U+0600 and friends)
                    // joins the following delimiter into one grapheme.
                    // cmark still sees the delimiter, so count it.
                    if character.unicodeScalars.count > 1 {
                        for inner in character.unicodeScalars
                            where inner == "*" || inner == "_"
                            || inner == "~" || inner == "[" {
                            openerCount += 1
                        }
                    }
                }

                if bracketDepth > limit
                    || openerCount > MarkdownLimits.maxInlineOpenerBudget
                    || bracketDepth + openDelimiters.count > nestingBudget
                    || lineDelimiters
                        > MarkdownLimits.maxInlineDelimitersPerLine
                    || delimiterCount
                        > MarkdownLimits.maxInlineDelimiters {
                    return true
                }
                index = nextIndex
            }
        }
        return false
    }

    /// The index just past the next run of exactly `length` backticks, or
    /// nil when the line has none. Used only to decide whether a code span
    /// certainly closes here; the content is still scanned either way.
    private static func sameLineRun(
        _ line: Substring,
        from start: Substring.Index,
        length: Int
    ) -> Substring.Index? {
        var index = start
        while index < line.endIndex {
            if line[index].unicodeScalars.first == "`" {
                let (run, after) = scalarRun(
                    line,
                    from: index,
                    scalar: "`"
                )
                if run == length { return after }
                index = after
            } else {
                index = line.index(after: index)
            }
        }
        return nil
    }

    /// A run of `scalar` at `start`, counted in Unicode scalars.
    ///
    /// A grapheme whose first scalar is the delimiter but which continues
    /// with a combining mark contributes one scalar to the run and then
    /// ends it: cmark counts code points, so a backtick-backtick-combining
    /// sequence is a run of two, not three.
    private static func scalarRun(
        _ line: Substring,
        from start: Substring.Index,
        scalar: Unicode.Scalar
    ) -> (length: Int, end: Substring.Index) {
        var length = 0
        var index = start
        while index < line.endIndex {
            let scalars = line[index].unicodeScalars
            guard scalars.first == scalar else { break }
            length += 1
            index = line.index(after: index)
            if scalars.count > 1 { break }
        }
        return (length, index)
    }

    /// Whether `character` can begin an inline HTML tag. A bare `<` in
    /// prose is not a tag.
    private static func startsHTMLTag(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else {
            return false
        }
        return CharacterSet.letters.contains(scalar)
            || scalar == "/" || scalar == "!" || scalar == "?"
    }

    /// Detects blockquote nesting above `limit` before parsing.
    ///
    /// `swift-markdown` converts the cmark tree recursively; a pathological
    /// document would overflow the stack before the mapper's own depth guard
    /// could run. The guard is deliberately cheap and conservative.
    static func exceedsLimit(_ source: String, limit: Int) -> Bool {
        // Container nesting accumulates across lines. The stack records the
        // indentation of each open list/quote level so a document that opens
        // one level per line still trips the limit.
        var indentStack: [Int] = []
        var fence: (character: Character, length: Int, prefix: String)?
        // An open raw-HTML block: empty means "until a blank line", otherwise
        // the closing marker to look for. A block that opened inside a
        // container ends with that container, which can disappear at a
        // blank line or at an unindented successor line.
        var htmlEnd: String?
        var htmlContainer: String?

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            // Raw HTML is literal text to cmark, so its markers cannot nest.
            if let end = htmlEnd {
                // Types 6 and 7 end at a blank line and their recognizer is
                // a heuristic; container markers on such a line stay
                // structural, so a misidentified block cannot hide their
                // nesting. A raw-text block (types 1-5) is genuinely literal
                // until its terminator.
                if end.isEmpty,
                   Self.lineExceedsContainerLimit(
                       line,
                       limit: limit,
                       indentStack: &indentStack
                   ) {
                    return true
                }
                let (prefix, rest) = splitContainers(line)
                let blank = rest.allSatisfy({
                    $0 == " " || $0 == "\t"
                })
                let containerEnded = htmlContainer.map { container in
                    if !normalizedContainerPrefix(prefix)
                        .hasPrefix(container) {
                        return true
                    }
                    let blockInList = container.contains {
                        $0 == "-" || $0 == "*" || $0 == "+" || $0.isNumber
                    }
                    return blockInList && beginsListItem(line)
                        && leadingColumns(line)
                            <= leadingColumns(container)
                } ?? false
                let reachedTerminator = end.isEmpty
                    ? blank
                    : line.lowercased().contains(end.lowercased())
                if containerEnded {
                    // The block's container ended. The block ends with it;
                    // this line is ordinary Markdown again.
                    htmlEnd = nil
                    htmlContainer = nil
                } else if reachedTerminator {
                    // A blank line ends a type-6/7 block; HTML terminators
                    // are case-insensitive, so `</SCRIPT>` closes a
                    // `<script>` block.
                    htmlEnd = nil
                    htmlContainer = nil
                    continue
                } else {
                    continue
                }
            }

            // Fenced literal content is not structural Markdown.
            if let active = fence {
                // A fence opened inside a blockquote or list ends when that
                // container ends. A top-level fence has no container prefix
                // and absorbs every subsequent line. The container only has
                // to still be open, not identical: `> >` is a valid content
                // line inside a quoted fence.
                // Every container level of the opening line must still be
                // present. Checking quotes alone let a fence outlive the
                // list it opened inside, hiding the lines after it.
                let currentPrefix = splitContainers(line).prefix
                let fenceInList = active.prefix.contains {
                    $0 == "-" || $0 == "*" || $0 == "+" || $0.isNumber
                }
                let siblingItem = fenceInList
                    && beginsListItem(line)
                    && leadingColumns(line)
                        <= leadingColumns(active.prefix)
                let scopeOpen = active.prefix.isEmpty
                    || (normalizedContainerPrefix(currentPrefix)
                        .hasPrefix(active.prefix) && !siblingItem)
                if scopeOpen {
                    let rest: Substring
                    if active.prefix.isEmpty {
                        // A top-level closing fence may be indented up to
                        // three spaces. A tab reaches column four and is
                        // indented code, not a delimiter.
                        let spaces = line.prefix(while: { $0 == " " }).count
                        rest = spaces <= 3
                            ? line.dropFirst(spaces)
                            : line
                    } else {
                        rest = splitContainers(line).rest
                    }
                    if closesFence(rest, active) {
                        fence = nil
                    }
                    continue
                }
                // The container ended. Clear the fence and process this line
                // as ordinary Markdown; it may open a new one.
                fence = nil
            }
            // Every line that is not literal content still contributes its
            // container markers, including a line that opens a fence.
            if Self.lineExceedsContainerLimit(
                line,
                limit: limit,
                indentStack: &indentStack
            ) {
                return true
            }
            if let opened = openingFence(line) {
                fence = opened
                continue
            }
            if let end = htmlBlockEnd(line) {
                // The opening line's own container markers are structural.
                if Self.lineExceedsContainerLimit(
                    line,
                    limit: limit,
                    indentStack: &indentStack
                ) {
                    return true
                }
                htmlEnd = end
                let prefix = splitContainers(line).prefix
                htmlContainer = prefix.isEmpty
                    ? nil
                    : normalizedContainerPrefix(prefix)
                continue
            }

        }
        return false
    }

    /// The column reached by leading spaces and tabs, with a tab advancing
    /// to the next multiple of four.
    private static func leadingColumns(_ line: Substring) -> Int {
        var columns = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns = (columns / 4 + 1) * 4
            } else {
                break
            }
        }
        return columns
    }

    private static func leadingColumns(_ text: String) -> Int {
        leadingColumns(Substring(text))
    }

    /// Whether the line's first non-space token is a list marker.
    private static func beginsListItem(_ line: Substring) -> Bool {
        var index = line.startIndex
        while index < line.endIndex,
              line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        return listMarkerLength(at: index, in: line) != nil
    }

    /// Counts the container markers on a line, updates the accumulated
    /// indentation stack, and reports whether the total depth is over the
    /// limit. Shared by the ordinary path and the skipped type 6/7 HTML
    /// path, so a misidentified block cannot hide list or quote nesting.
    private static func lineExceedsContainerLimit(
        _ line: Substring,
        limit: Int,
        indentStack: inout [Int]
    ) -> Bool {
        // A thematic break is made of the same characters as bullet
        // markers but is not a container.
        if isThematicBreak(line) { return false }


        // A tab advances to column four, so it must grow the accumulated
        // indent; counting only spaces let tab-indented lists nest freely.
        var leadingSpaces = 0
        for character in line.prefix(while: {
            $0 == " " || $0 == "\t"
        }) {
            if character == "\t" {
                // A tab advances to the next multiple of four, not four
                // columns from where it starts.
                leadingSpaces = (leadingSpaces / 4 + 1) * 4
            } else {
                leadingSpaces += 1
            }
        }
        var index = line.startIndex
        var depth = 0
        var afterMarker = false

        while index < line.endIndex {
            // Three columns can indent the first marker; a list marker
            // can be followed by up to four columns of padding. Inside
            // an open container, the line may also carry that container's
            // indentation. Tabs count as one column, conservatively.
            let indentLimit = afterMarker
                ? 4
                : (indentStack.isEmpty
                    ? 3
                    : max(3, (indentStack.last ?? 0) + 4))
            var indent = 0
            while index < line.endIndex,
                  line[index] == " " || line[index] == "\t",
                  indent < indentLimit {
                indent += 1
                index = line.index(after: index)
            }
            if index < line.endIndex,
               line[index] == " " || line[index] == "\t" {
                break
            }
            guard index < line.endIndex else { break }

            if line[index] == ">" {
                afterMarker = true
                depth += 1
                if depth > limit { return true }
                index = line.index(after: index)
                // One optional space or tab belongs to the marker.
                if index < line.endIndex,
                   line[index] == " " || line[index] == "\t" {
                    index = line.index(after: index)
                }
                continue
            }

            if let markerLength = listMarkerLength(at: index, in: line) {
                depth += 1
                if depth > limit { return true }
                afterMarker = true
                index = line.index(index, offsetBy: markerLength)
                continue
            }

            break
        }

        guard depth > 0 else { return false }

        if indentStack.isEmpty {
            // Four leading spaces at top level make indented code, not a
            // container.
            if leadingSpaces < 4 {
                indentStack.append(leadingSpaces)
            }
        } else if leadingSpaces > indentStack[indentStack.count - 1] {
            indentStack.append(leadingSpaces)
        } else {
            while let top = indentStack.last, top > leadingSpaces {
                indentStack.removeLast()
            }
            if indentStack.isEmpty {
                indentStack.append(leadingSpaces)
            }
        }

        let totalDepth = indentStack.count + max(0, depth - 1)
        if totalDepth > limit { return true }
        return false
    }

    /// Splits a line into its leading container prefix and its content, so a
    /// fence inside a container is recognized and its scope can be tracked.
    private static func splitContainers(
        _ line: Substring
    ) -> (prefix: Substring, rest: Substring) {
        var rest = line
        while true {
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            if rest.first == ">" {
                rest = rest.dropFirst()
                continue
            }
            if let index = rest.indices.first,
               let length = listMarkerLength(at: index, in: rest) {
                rest = rest.dropFirst(length)
                continue
            }
            return (line[line.startIndex..<rest.startIndex], rest)
        }
    }

    /// Removes blockquote markers and list markers, so a fence inside a
    /// container is still recognized as a fence.
    private static func stripContainers(_ line: Substring) -> Substring {
        splitContainers(line).rest
    }

    /// Container identity for fence scope. Trailing whitespace after a quote
    /// marker is not significant (`>` and `> ` are the same container);
    /// indentation for list containers is significant.
    private static func normalizedContainerPrefix(_ prefix: Substring) -> String {
        var text = String(prefix)
        if text.contains(">") {
            while text.last == " " || text.last == "\t" { text.removeLast() }
        }
        return text
    }

    private static func openingFence(
        _ line: Substring
    ) -> (character: Character, length: Int, prefix: String)? {
        let (prefix, trimmed) = splitContainers(line)
        guard let first = trimmed.first, first == "`" || first == "~" else {
            return nil
        }
        var length = 0
        for character in trimmed {
            guard character == first else { break }
            length += 1
        }
        guard length >= 3 else { return nil }
        if first == "`", trimmed.dropFirst(length).contains("`") {
            return nil
        }
        // Ordinary leading indentation is not a container. A blockquote or
        // list marker makes the fence's prefix a scope requirement.
        let hasContainer = prefix.contains {
            $0 == ">" || $0 == "-" || $0 == "*" || $0 == "+" || $0.isNumber
        }
        // A fence may be indented at most three columns past its
        // container. That applies inside a container too: `>     ``` ` is
        // indented code, not a fence.
        let trailingSpaces = prefix.reversed()
            .prefix(while: { $0 == " " }).count
        if trailingSpaces > 3 || prefix.contains("\t") { return nil }
        return (
            first,
            length,
            hasContainer ? normalizedContainerPrefix(prefix) : ""
        )
    }

    private static func closesFence(
        _ rest: Substring,
        _ fence: (character: Character, length: Int, prefix: String)
    ) -> Bool {
        var length = 0
        for character in rest {
            guard character == fence.character else { break }
            length += 1
        }
        guard length >= fence.length else { return false }
        return rest.dropFirst(length).allSatisfy {
            $0 == " " || $0 == "\t"
        }
    }

    private static let htmlBlockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote",
        "body", "caption", "center", "col", "colgroup", "dd", "details",
        "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption",
        "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3",
        "h4", "h5", "h6", "head", "header", "hr", "html", "iframe",
        "legend", "li", "link", "main", "menu", "menuitem", "nav",
        "noframes", "ol", "optgroup", "option", "p", "param", "search",
        "section", "summary", "table", "tbody", "td", "tfoot", "th",
        "thead", "title", "tr", "track", "ul",
    ]

    /// The terminator for a raw-HTML block starting on this line, or nil when
    /// the line does not open one.
    private static func htmlBlockEnd(_ line: Substring) -> String? {
        // A raw HTML block can sit inside a blockquote or list item, but
        // like a fence it may be indented at most three columns past its
        // container. More is indented code, and treating it as HTML would
        // hide the lines after it.
        let (prefix, trimmed) = splitContainers(line)
        let trailing = prefix.reversed()
            .prefix(while: { $0 == " " || $0 == "\t" }).count
        guard trailing <= 3 else { return nil }
        guard trimmed.first == "<" else { return nil }
        let lower = trimmed.lowercased()

        if lower.hasPrefix("<!--") {
            return lower.contains("-->") ? nil : "-->"
        }
        if lower.hasPrefix("<![cdata[") {
            return lower.contains("]]>") ? nil : "]]>"
        }
        if lower.hasPrefix("<?") {
            return lower.contains("?>") ? nil : "?>"
        }
        // Type 4: a declaration, ended by `>`. The uppercase test must use
        // the original text and must accept only ASCII: the HTML grammar
        // allows no other letter, and `Ä`.isUppercase would otherwise start
        // a block cmark does not recognize.
        if trimmed.hasPrefix("<!"),
           let first = trimmed.dropFirst(2).first,
           first.isASCII, first.isUppercase {
            return lower.contains(">") ? nil : ">"
        }

        // Types 1-5 end at their own closing tag. The tag name must end at a
        // real boundary: `<scripture>` is not `<script>`.
        for tag in ["script", "pre", "style", "textarea"] {
            let opening = "<" + tag
            guard lower.hasPrefix(opening) else { continue }
            let boundary = lower.index(
                lower.startIndex,
                offsetBy: opening.count
            )
            if boundary < lower.endIndex {
                let next = lower[boundary]
                guard next == " " || next == "\t"
                    || next == ">" else { continue }
            }
            if !lower.contains("</" + tag + ">") {
                return "</" + tag + ">"
            }
        }

        // Type 6: a block-level tag, terminated by a blank line.
        for tag in htmlBlockTags {
            guard lower.hasPrefix("<" + tag) else { continue }
            let boundary = lower.index(
                lower.startIndex,
                offsetBy: tag.count + 1
            )
            if boundary == lower.endIndex {
                return ""
            }
            let next = lower[boundary]
            if next == " " || next == "\t" || next == ">" || next == "/" {
                return ""
            }
        }

        // Type 7: any complete open or closing tag alone on its line. The
        // tag name must end at a real boundary, so `<https://…>` is an
        // autolink, not a tag.
        let afterBracket = lower.dropFirst()
        if let first = afterBracket.first,
           first.isLetter || first == "/" {
            var probe = lower.index(
                lower.startIndex,
                offsetBy: first == "/" ? 2 : 1
            )
            while probe < lower.endIndex,
                  lower[probe].isLetter || lower[probe].isNumber
                    || lower[probe] == "-" {
                probe = lower.index(after: probe)
            }
            let boundaryOK = probe == lower.endIndex
                || lower[probe] == " " || lower[probe] == "\t"
                || lower[probe] == ">" || lower[probe] == "/"
            if boundaryOK, let close = lower.firstIndex(of: ">") {
                let remainder = lower[lower.index(after: close)...]
                if remainder.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    return ""
                }
            }
        }
        return nil
    }

    private static func isThematicBreak(_ line: Substring) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first,
              first == "-" || first == "*" || first == "_" else {
            return false
        }
        var count = 0
        for character in trimmed {
            if character == first {
                count += 1
            } else if character != " " && character != "\t" {
                return false
            }
        }
        return count >= 3
    }

    /// The length of a list marker at `index`, or `nil` when the character
    /// does not begin one. The marker must be followed by whitespace or the
    /// end of the line.
    private static func listMarkerLength(
        at index: String.Index,
        in line: Substring
    ) -> Int? {
        let character = line[index]
        if character == "-" || character == "+" || character == "*" {
            let next = line.index(after: index)
            if next == line.endIndex { return 1 }
            if line[next] == " " || line[next] == "\t" { return 1 }
            return nil
        }

        var probe = index
        var digits = 0
        while probe < line.endIndex, line[probe].isNumber, digits < 10 {
            digits += 1
            probe = line.index(after: probe)
        }
        guard digits >= 1, digits <= 9, probe < line.endIndex else {
            return nil
        }
        let delimiter = line[probe]
        guard delimiter == "." || delimiter == ")" else { return nil }
        let after = line.index(after: probe)
        if after == line.endIndex {
            return line.distance(from: index, to: after)
        }
        guard line[after] == " " || line[after] == "\t" else { return nil }
        return line.distance(from: index, to: after)
    }
}

// MARK: - Frontmatter

struct FrontmatterSplit {
    let frontmatter: Frontmatter?
    let body: String
    let bodyStartLine: Int
    let bodyStartOffset: Int
}

enum FrontmatterSplitter {
    static func split(_ source: String) -> FrontmatterSplit {
        // Avoid splitting the whole document unless the first line can
        // actually open a frontmatter block.
        let firstLine = source.prefix(while: { $0 != "\n" })
        guard firstLine.trimmingCharacters(in: .whitespaces) == "---" else {
            return FrontmatterSplit(
                frontmatter: nil,
                body: source,
                bodyStartLine: 1,
                bodyStartOffset: 0
            )
        }

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        var closingIndex: Int?
        for index in 1..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                closingIndex = index
                break
            }
        }

        guard let closingIndex else {
            return FrontmatterSplit(
                frontmatter: nil,
                body: source,
                bodyStartLine: 1,
                bodyStartOffset: 0
            )
        }

        // Offsets: every line in `lines[0...closingIndex]` is followed by a
        // newline except possibly the last line of the file.
        var rawEnd = 0
        for index in 0...closingIndex {
            rawEnd += lines[index].utf16.count
            if index < closingIndex {
                rawEnd += 1
            }
        }
        let hasNewlineAfterClose = closingIndex < lines.count - 1
        let bodyStart = hasNewlineAfterClose ? rawEnd + 1 : rawEnd

        let utf16 = source.utf16
        let rawEndIndex = utf16.index(utf16.startIndex, offsetBy: rawEnd)
        let bodyStartIndex = utf16.index(utf16.startIndex, offsetBy: bodyStart)
        let rawString = String(source[..<rawEndIndex])
        let bodyString = String(source[bodyStartIndex...])

        let range = SourceRange(
            start: SourcePosition(line: 1, column: 0, offset: 0),
            end: SourcePosition(
                line: closingIndex + 1,
                column: lines[closingIndex].utf16.count,
                offset: rawEnd
            )
        )

        return FrontmatterSplit(
            frontmatter: Frontmatter(
                raw: rawString,
                body: lines.dropFirst().dropLast(lines.count - closingIndex)
                    .joined(separator: "\n"),
                range: range
            ),
            body: bodyString,
            bodyStartLine: closingIndex + 2,
            bodyStartOffset: bodyStart
        )
    }
}

// MARK: - AST mapping

struct ASTMapper {
    let sourceMap: SourceMap
    /// Upstream line numbers are relative to the parsed body; this offset
    /// converts them to global canonical-source line numbers.
    let lineOffset: Int
    let enableAutolinks: Bool

    func mapBlocks(_ children: MarkupChildren) -> [Block] {
        mapBlocks(children, depth: 0)
    }

    private func mapBlocks(_ children: MarkupChildren, depth: Int) -> [Block] {
        var blocks: [Block] = []
        for child in children {
            if let block = mapBlock(child, depth: depth) {
                blocks.append(block)
            }
        }
        return blocks
    }

    private func mapBlock(_ markup: Markup, depth: Int) -> Block? {
        let range = resolve(markup)

        if depth > MarkdownLimits.maxParseDepth {
            let raw = range.flatMap { sourceMap.text(in: $0) } ?? ""
            return .htmlBlock(raw: raw, range: range)
        }

        switch markup {
        case let heading as Heading:
            return .heading(
                level: heading.level,
                inlines: fillMissingTextRanges(
                    in: mapInlines(heading.children),
                    within: range
                ),
                range: range
            )
        case let paragraph as Paragraph:
            return .paragraph(
                inlines: fillMissingTextRanges(
                    in: mapInlines(paragraph.children),
                    within: range
                ),
                range: range
            )
        case let quote as BlockQuote:
            return .blockQuote(blocks: mapBlocks(quote.children, depth: depth + 1), range: range)
        case let list as UnorderedList:
            return .list(mapList(list, ordered: false, depth: depth), range: range)
        case let list as OrderedList:
            return .list(mapList(list, ordered: true, depth: depth), range: range)
        case let table as Table:
            return .table(mapTable(table), range: range)
        case let code as Markdown.CodeBlock:
            return .codeBlock(mapCodeBlock(code), range: range)
        case let html as HTMLBlock:
            return .htmlBlock(raw: html.rawHTML, range: range)
        case is ThematicBreak:
            return .thematicBreak(range: range)
        default:
            // Unknown block: keep its source rather than dropping content.
            let raw = range.flatMap { sourceMap.text(in: $0) } ?? ""
            return .htmlBlock(raw: raw, range: range)
        }
    }

    private func mapList(_ list: Markup, ordered: Bool, depth: Int) -> ListBlock {
        var items: [ListItem] = []
        for child in list.children {
            guard let item = child as? Markdown.ListItem else { continue }
            let checked: Bool?
            switch item.checkbox {
            case .checked: checked = true
            case .unchecked: checked = false
            case nil: checked = nil
            }
            items.append(
                ListItem(
                    blocks: mapBlocks(item.children, depth: depth + 1),
                    checked: checked,
                    range: resolve(item)
                )
            )
        }

        let kind: ListBlock.Kind
        if ordered, let list = list as? OrderedList {
            kind = .ordered(start: Int(list.startIndex))
        } else {
            kind = .bullet
        }

        return ListBlock(
            kind: kind,
            items: items,
            tight: listTightness(items: items)
        )
    }

    private func mapTable(_ table: Table) -> TableBlock {
        let alignments = table.columnAlignments.map { alignment -> TableBlock.Alignment in
            switch alignment {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            case nil: return .none
            }
        }

        return TableBlock(
            header: table.head.cells.map(mapCell),
            rows: table.body.rows.map { row in
                row.cells.map(mapCell)
            },
            alignments: alignments
        )
    }

    private func mapCell(_ cell: Table.Cell) -> TableCell {
        TableCell(
            inlines: fillMissingTextRanges(
                in: mapInlines(cell.children),
                within: resolve(cell)
            ),
            colspan: Int(cell.colspan),
            rowspan: Int(cell.rowspan),
            range: resolve(cell)
        )
    }

    private func mapCodeBlock(_ code: Markdown.CodeBlock) -> CodeBlock {
        let range = resolve(code)
        var fenced = false
        var info: String?
        if let range, let text = sourceMap.text(in: range) {
            let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? ""
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fenced = true
                let fenceCharacter = trimmed.first!
                var fenceLength = 0
                for character in trimmed {
                    guard character == fenceCharacter else { break }
                    fenceLength += 1
                }
                info = String(trimmed.dropFirst(fenceLength))
                    .trimmingCharacters(in: .whitespaces)
                if info?.isEmpty == true { info = nil }
            }
        }

        return CodeBlock(
            code: code.code,
            language: code.language,
            fenced: fenced,
            info: info
        )
    }

    func mapInlines(_ children: MarkupChildren) -> [Inline] {
        mapInlines(children, allowAutolinks: enableAutolinks, depth: 0)
    }

    private func mapInlines(
        _ children: MarkupChildren,
        allowAutolinks: Bool,
        depth: Int
    ) -> [Inline] {
        var inlines: [Inline] = []
        for child in children {
            appendInlines(
                for: child,
                allowAutolinks: allowAutolinks,
                depth: depth,
                into: &inlines
            )
        }
        return inlines
    }

    private func appendInlines(
        for markup: Markup,
        allowAutolinks: Bool,
        depth: Int,
        into inlines: inout [Inline]
    ) {
        let range = resolve(markup)

        if depth > MarkdownLimits.maxParseDepth {
            let raw = range.flatMap { sourceMap.text(in: $0) } ?? ""
            inlines.append(.text(raw, range: range))
            return
        }

        switch markup {
        case let text as Text:
            appendText(
                text.string,
                range: range,
                allowAutolinks: allowAutolinks,
                into: &inlines
            )
        case is SoftBreak:
            inlines.append(.softBreak(range: range))
        case is LineBreak:
            inlines.append(.lineBreak(range: range))
        case let code as InlineCode:
            inlines.append(
                .inlineCode(
                    code.code,
                    range: inlineCodeContentRange(around: range)
                )
            )
        case let emphasis as Emphasis:
            inlines.append(
                .emphasis(
                    inlines: mapInlines(
                        emphasis.children,
                        allowAutolinks: allowAutolinks,
                        depth: depth + 1
                    ),
                    range: range
                )
            )
        case let strong as Strong:
            inlines.append(
                .strong(
                    inlines: mapInlines(
                        strong.children,
                        allowAutolinks: allowAutolinks,
                        depth: depth + 1
                    ),
                    range: range
                )
            )
        case let strike as Strikethrough:
            inlines.append(
                .strikethrough(
                    inlines: mapInlines(
                        strike.children,
                        allowAutolinks: allowAutolinks,
                        depth: depth + 1
                    ),
                    range: range
                )
            )
        case let link as Link:
            inlines.append(
                .link(
                    destination: link.destination ?? "",
                    title: link.title,
                    inlines: mapInlines(
                        link.children,
                        allowAutolinks: false,
                        depth: depth + 1
                    ),
                    range: range
                )
            )
        case let image as Image:
            inlines.append(
                .image(
                    destination: image.source ?? "",
                    title: image.title,
                    description: mapInlines(
                        image.children,
                        allowAutolinks: false,
                        depth: depth + 1
                    ),
                    range: range
                )
            )
        case let html as InlineHTML:
            inlines.append(.inlineHTML(html.rawHTML, range: range))
        default:
            let raw = range.flatMap { sourceMap.text(in: $0) } ?? ""
            inlines.append(.text(raw, range: range))
        }
    }

    private func appendText(
        _ literal: String,
        range: SourceRange?,
        allowAutolinks: Bool,
        into inlines: inout [Inline]
    ) {
        guard
            allowAutolinks,
            let range,
            let raw = sourceMap.text(in: range),
            raw.utf16.count == literal.utf16.count
        else {
            inlines.append(.text(literal, range: range))
            return
        }

        // Every autolink form requires one of these markers. Skipping the
        // per-character scanner for ordinary prose removes the dominant cost.
        guard AutolinkScanner.mightContainLink(literal) else {
            inlines.append(.text(literal, range: range))
            return
        }

        let matches = AutolinkScanner.scan(literal)
        guard !matches.isEmpty else {
            inlines.append(.text(literal, range: range))
            return
        }

        let utf16 = literal.utf16
        var cursor = 0
        for match in matches {
            if match.range.lowerBound > cursor {
                let slice = Self.slice(literal, utf16Range: cursor..<match.range.lowerBound)
                let start = sourceMap.position(atUTF16Offset: range.lowerBound + cursor)
                let end = sourceMap.position(atUTF16Offset: range.lowerBound + match.range.lowerBound)
                let textRange = start.flatMap { s in
                    end.map { e in SourceRange(start: s, end: e) }
                }
                inlines.append(.text(slice, range: textRange))
            }

            let display = Self.slice(literal, utf16Range: match.range)
            let linkRange = sourceMap.position(atUTF16Offset: range.lowerBound + match.range.lowerBound)
                .flatMap { start in
                    sourceMap.position(atUTF16Offset: range.lowerBound + match.range.upperBound)
                        .map { end in SourceRange(start: start, end: end) }
                }
            inlines.append(
                .link(
                    destination: match.destination,
                    title: nil,
                    inlines: [.text(display, range: linkRange)],
                    range: linkRange
                )
            )
            cursor = match.range.upperBound
        }

        if cursor < utf16.count {
            let slice = Self.slice(literal, utf16Range: cursor..<utf16.count)
            let start = sourceMap.position(atUTF16Offset: range.lowerBound + cursor)
            let end = sourceMap.position(atUTF16Offset: range.upperBound)
            let textRange = start.flatMap { s in end.map { e in SourceRange(start: s, end: e) } }
            inlines.append(.text(slice, range: textRange))
        }
    }

    private static func slice(_ text: String, utf16Range: Range<Int>) -> String {
        text.utf16Slice(utf16Range)
    }

    /// cmark reports a code span's range over its content; swift-markdown
    /// reports the span including delimiters, and its upstream end position is
    /// truncated when the span contains escapes. Locate the authored
    /// delimiters in the full source instead of trusting the upstream range.
    private func inlineCodeContentRange(
        around range: SourceRange?
    ) -> SourceRange? {
        guard let range else { return nil }
        let source = sourceMap.source as NSString
        let relativeLower = range.lowerBound - sourceMap.baseOffset
        guard relativeLower >= 0, relativeLower <= source.length else {
            return range
        }

        var openingRun = 0
        var contentStart = relativeLower

        if relativeLower < source.length,
           source.character(at: relativeLower) == 0x60 {
            while contentStart < source.length,
                  source.character(at: contentStart) == 0x60 {
                openingRun += 1
                contentStart += 1
            }
        } else {
            var probe = relativeLower - 1
            while probe >= 0, source.character(at: probe) == 0x60 {
                openingRun += 1
                probe -= 1
            }
        }

        guard openingRun > 0 else { return range }

        var probe = contentStart
        while probe < source.length {
            if source.character(at: probe) == 0x60 {
                var run = 0
                while probe + run < source.length,
                      source.character(at: probe + run) == 0x60 {
                    run += 1
                }
                if run == openingRun {
                    guard
                        let start = sourceMap.position(
                            atUTF16Offset: sourceMap.baseOffset + contentStart
                        ),
                        let end = sourceMap.position(
                            atUTF16Offset: sourceMap.baseOffset + probe
                        )
                    else {
                        return range
                    }
                    return SourceRange(start: start, end: end)
                }
                probe += run
            } else {
                probe += 1
            }
        }

        return range
    }

    /// Fills a missing text range when the source slice at the inferred
    /// position is exactly the literal. This is a deterministic recovery for
    /// swift-markdown's occasional nil text ranges, not a guess.
    private func fillMissingTextRanges(
        in inlines: [Inline],
        within parent: SourceRange?
    ) -> [Inline] {
        guard let parent else { return inlines }

        var result: [Inline] = []
        result.reserveCapacity(inlines.count)
        var cursor = parent.lowerBound
        var index = 0

        while index < inlines.count {
            let inline = inlines[index]
            switch inline {
            case let .text(literal, nil):
                let nextStart = inlines[(index + 1)...].lazy.compactMap {
                    $0.range?.lowerBound
                }.first ?? parent.upperBound
                if nextStart >= cursor, nextStart - cursor == literal.utf16.count,
                   let start = sourceMap.position(atUTF16Offset: cursor),
                   let end = sourceMap.position(atUTF16Offset: nextStart) {
                    let candidate = SourceRange(start: start, end: end)
                    if sourceMap.text(in: candidate) == literal {
                        result.append(.text(literal, range: candidate))
                        cursor = nextStart
                        index += 1
                        continue
                    }
                }
                result.append(inline)
            case let .emphasis(children, range):
                result.append(
                    .emphasis(
                        inlines: fillMissingTextRanges(in: children, within: range),
                        range: range
                    )
                )
                if let range { cursor = max(cursor, range.upperBound) }
            case let .strong(children, range):
                result.append(
                    .strong(
                        inlines: fillMissingTextRanges(in: children, within: range),
                        range: range
                    )
                )
                if let range { cursor = max(cursor, range.upperBound) }
            case let .strikethrough(children, range):
                result.append(
                    .strikethrough(
                        inlines: fillMissingTextRanges(in: children, within: range),
                        range: range
                    )
                )
                if let range { cursor = max(cursor, range.upperBound) }
            default:
                result.append(inline)
                if let range = inline.range {
                    cursor = max(cursor, range.upperBound)
                }
            }
            index += 1
        }
        return result
    }

    private func resolve(_ markup: Markup) -> SourceRange? {
        guard let range = markup.range else { return nil }
        return sourceMap.sourceRange(
            startLine: range.lowerBound.line + lineOffset,
            startUTF8Column: range.lowerBound.column,
            endLine: range.upperBound.line + lineOffset,
            endUTF8Column: range.upperBound.column
        )
    }

    /// Resolves a node's source range for callers outside the mapper.
    func sourceRange(for markup: Markup) -> SourceRange? {
        resolve(markup)
    }

    /// A list is loose when a blank line separates two items or two block
    /// elements inside one item.
    ///
    /// Scanning the whole list source is wrong: blank lines inside a fenced
    /// code block or between a paragraph and its lazy continuation do not
    /// loosen the list. Only gaps between sibling blocks are inspected.
    private func listTightness(items: [ListItem]) -> Bool? {
        // Use the content extremes inside each item, not the item range:
        // cmark item ranges include trailing newlines, which would hide the
        // blank line between two items.
        var contentRanges: [SourceRange] = []
        contentRanges.reserveCapacity(items.count)
        for item in items {
            if let first = item.blocks.first?.range,
               let last = item.blocks.last?.range {
                contentRanges.append(
                    SourceRange(start: first.start, end: last.end)
                )
            } else if let range = item.range {
                contentRanges.append(range)
            } else {
                return nil
            }
        }

        if rangesHaveBlankLine(contentRanges) {
            return false
        }

        for item in items {
            let blockRanges = item.blocks.map(\.range)
            guard blockRanges.allSatisfy({ $0 != nil }) else { continue }
            if rangesHaveBlankLine(blockRanges.compactMap { $0 }) {
                return false
            }
        }

        return true
    }

    private func rangesHaveBlankLine(_ ranges: [SourceRange]) -> Bool {
        guard ranges.count > 1 else { return false }
        for index in 0..<(ranges.count - 1) {
            if gapHasBlankLine(
                from: ranges[index].upperBound,
                to: ranges[index + 1].lowerBound
            ) {
                return true
            }
        }
        return false
    }

    private func gapHasBlankLine(from lower: Int, to upper: Int) -> Bool {
        guard lower <= upper,
              let start = sourceMap.position(atUTF16Offset: lower),
              let end = sourceMap.position(atUTF16Offset: upper),
              let gap = sourceMap.text(in: SourceRange(start: start, end: end))
        else {
            return false
        }

        // A blank line means two newlines with only whitespace or blockquote
        // markers between them. A single newline followed by the next item's
        // marker is not a blank line.
        var sawNewline = false
        if lower > sourceMap.baseOffset {
            // A newline immediately before the gap belongs to the previous
            // line; treating it as seen lets one more newline count as blank.
            let relative = lower - 1 - sourceMap.baseOffset
            let utf16 = sourceMap.source.utf16
            if let index = utf16.index(
                utf16.startIndex,
                offsetBy: relative,
                limitedBy: utf16.endIndex
            ), index < utf16.endIndex, utf16[index] == 10 {
                sawNewline = true
            }
        }
        for character in gap {
            switch character {
            case "\n":
                if sawNewline { return true }
                sawNewline = true
            case " ", "\t", "\r", ">":
                continue
            default:
                sawNewline = false
            }
        }
        return false
    }
}
