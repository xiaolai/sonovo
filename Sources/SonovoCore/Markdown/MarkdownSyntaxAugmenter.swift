import Foundation

/// Applies Sonovo's custom syntax to the base tree.
///
/// The passes run in a fixed order: details pairing, `[TOC]`, then wiki links.
/// The augmenter never writes source; it only replaces matched spans with typed
/// nodes that carry exact UTF-16 ranges.
public struct MarkdownSyntaxAugmenter: Sendable {
    public init() {}

    /// Returns the augmented tree for a parsed document.
    public func augment(_ parsed: ParsedMarkdown) -> SonovoAST {
        var ast = parsed.ast

        ast.blocks = DetailsParser.augment(blocks: ast.blocks, parsed: parsed, depth: 0)
        ast.blocks = ast.blocks.map { block in
            if Self.isTableOfContentsMarker(block, source: parsed.source) {
                return .tableOfContents(range: block.range)
            }
            return block
        }
        ast.blocks = ast.blocks.map {
            augmentWikiLinks($0, parsed: parsed)
        }

        return ast
    }

    // MARK: - TOC

    static func isTableOfContentsMarker(
        _ block: Block,
        source: String
    ) -> Bool {
        guard
            case let .paragraph(inlines, range) = block,
            let range,
            inlines.count == 1,
            case .text = inlines[0]
        else {
            return false
        }
        // The authored text must be the marker. A resolved link,
        // backslash escape, or entity-decoded `[TOC]` is not.
        return source.utf16Range(range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "[toc]"
    }

    // MARK: - Wiki links

    private func augmentWikiLinks(_ block: Block, parsed: ParsedMarkdown) -> Block {
        switch block {
        case let .paragraph(inlines, range):
            guard let range else { return block }
            return .paragraph(
                inlines: augmentInlines(inlines, span: range, parsed: parsed),
                range: range
            )
        case let .heading(level, inlines, range):
            guard let range else { return block }
            return .heading(
                level: level,
                inlines: augmentInlines(inlines, span: range, parsed: parsed),
                range: range
            )
        case let .blockQuote(blocks, range):
            return .blockQuote(
                blocks: blocks.map { augmentWikiLinks($0, parsed: parsed) },
                range: range
            )
        case let .list(list, range):
            let items = list.items.map { item in
                ListItem(
                    blocks: item.blocks.map { augmentWikiLinks($0, parsed: parsed) },
                    checked: item.checked,
                    range: item.range
                )
            }
            return .list(
                ListBlock(kind: list.kind, items: items, tight: list.tight),
                range: range
            )
        case let .table(table, range):
            let header = table.header.map { cell in
                augmentCell(cell, parsed: parsed)
            }
            let rows = table.rows.map { row in
                row.map { cell in augmentCell(cell, parsed: parsed) }
            }
            return .table(
                TableBlock(header: header, rows: rows, alignments: table.alignments),
                range: range
            )
        case let .details(details, range):
            let summary = details.summaryRange.map { summaryRange in
                augmentInlines(details.summary, span: summaryRange, parsed: parsed)
            } ?? details.summary
            let blocks = details.blocks.map { augmentWikiLinks($0, parsed: parsed) }
            return .details(
                DetailsBlock(
                    summary: summary,
                    blocks: blocks,
                    isOpen: details.isOpen,
                    range: details.range,
                    summaryRange: details.summaryRange
                ),
                range: range
            )
        default:
            return block
        }
    }

    private func augmentCell(_ cell: TableCell, parsed: ParsedMarkdown) -> TableCell {
        guard let range = cell.range else { return cell }
        return TableCell(
            inlines: augmentInlines(cell.inlines, span: range, parsed: parsed),
            colspan: cell.colspan,
            rowspan: cell.rowspan,
            range: range
        )
    }

    private func augmentInlines(
        _ inlines: [Inline],
        span: SourceRange,
        parsed: ParsedMarkdown
    ) -> [Inline] {
        let leaves = InlineLeaves.flatten(inlines)
        let excluded = leaves.compactMap { leaf -> SourceRange? in
            switch leaf.inline {
            case let .inlineCode(_, range),
                 let .inlineHTML(_, range),
                 let .link(_, _, _, range),
                 let .image(_, _, _, range):
                return range
            default:
                return nil
            }
        }

        var matches = WikiLinkScanner.scan(
            source: parsed.source,
            span: span,
            excluding: excluded
        )
        guard !matches.isEmpty else { return inlines }

        matches.sort { $0.range.lowerBound < $1.range.lowerBound }
        matches = applicableMatches(matches, leaves: leaves)
        guard !matches.isEmpty else { return inlines }

        // Keeping one cursor across the ordered leaves avoids rescanning the
        // whole match list per leaf.
        var emitted = Set<Int>()
        var segments: [InlineLeaf] = []
        var windowStart = 0

        for (leafIndex, leaf) in leaves.enumerated() {
            guard let leafRange = leaf.range else {
                segments.append(
                    InlineLeaf(
                        path: leaf.path,
                        styleRanges: leaf.styleRanges,
                        inline: leaf.inline
                    )
                )
                continue
            }

            while windowStart < matches.count,
                  matches[windowStart].range.upperBound <= leafRange.lowerBound {
                windowStart += 1
            }

            var intersecting: [Int] = []
            var probe = windowStart
            while probe < matches.count,
                  matches[probe].range.lowerBound < leafRange.upperBound {
                if matches[probe].range.upperBound > leafRange.lowerBound {
                    intersecting.append(probe)
                }
                probe += 1
            }

            if intersecting.isEmpty {
                segments.append(
                    InlineLeaf(
                        path: leaf.path,
                        styleRanges: leaf.styleRanges,
                        inline: leaf.inline
                    )
                )
                continue
            }

            var cursor = leafRange.lowerBound
            for index in intersecting {
                let match = matches[index]
                let lower = max(match.range.lowerBound, leafRange.lowerBound)
                let upper = min(match.range.upperBound, leafRange.upperBound)

                if lower > cursor {
                    appendTextSlice(
                        leaf: leaf,
                        from: cursor,
                        to: lower,
                        parsed: parsed,
                        into: &segments
                    )
                }

                if !emitted.contains(index) {
                    emitted.insert(index)
                    // Keep the style ancestry shared by every leaf the link
                    // spans, so `**[[Page]]**` stays bold while formatting
                    // authored inside the wiki syntax is still discarded.
                    let style = commonStyle(
                        for: match,
                        startingAt: leafIndex,
                        leaves: leaves
                    )
                    segments.append(
                        InlineLeaf(
                            path: style.path,
                            styleRanges: style.ranges,
                            inline: makeWikiInline(match, parsed: parsed)
                        )
                    )
                }

                cursor = max(cursor, upper)
            }

            if cursor < leafRange.upperBound {
                appendTextSlice(
                    leaf: leaf,
                    from: cursor,
                    to: leafRange.upperBound,
                    parsed: parsed,
                    into: &segments
                )
            }
        }

        return InlineLeaves.rebuild(segments)
    }

    /// Filters matches with one ordered pass over the leaves.
    ///
    /// A match may span several leaves. A partial overlap is only allowed on
    /// a text leaf; partial overlap with emphasis, code, or another structured
    /// leaf would split that structure.
    private func applicableMatches(
        _ matches: [WikiLinkMatch],
        leaves: [InlineLeaf]
    ) -> [WikiLinkMatch] {
        guard !matches.isEmpty else { return [] }
        var applicable = Array(repeating: true, count: matches.count)
        var windowStart = 0

        for leaf in leaves {
            guard let leafRange = leaf.range else { continue }
            while windowStart < matches.count,
                  matches[windowStart].range.upperBound <= leafRange.lowerBound {
                windowStart += 1
            }

            var isTextLeaf = false
            if case .text = leaf.inline { isTextLeaf = true }

            var index = windowStart
            while index < matches.count,
                  matches[index].range.lowerBound < leafRange.upperBound {
                let match = matches[index]
                if match.range.upperBound > leafRange.lowerBound {
                    let coversWholeLeaf = match.range.lowerBound <= leafRange.lowerBound
                        && match.range.upperBound >= leafRange.upperBound
                    if !coversWholeLeaf, !isTextLeaf {
                        applicable[index] = false
                    }
                }
                index += 1
            }
        }

        return zip(matches, applicable)
            .filter { $0.1 }
            .map { $0.0 }
    }

    /// The longest style prefix shared by every leaf the match touches.
    ///
    /// Style kinds alone are not enough: two adjacent strong nodes are
    /// distinct authored nodes even though both are `.strong`.
    private func commonStyle(
        for match: WikiLinkMatch,
        startingAt start: Int,
        leaves: [InlineLeaf]
    ) -> (path: [InlineStyle], ranges: [SourceRange?]) {
        guard start < leaves.count else { return ([], []) }
        let first = leaves[start]
        var path: [InlineStyle] = []
        var ranges: [SourceRange?] = []

        for depth in 0..<first.path.count {
            let style = first.path[depth]
            let styleRange = first.styleRanges.count > depth
                ? first.styleRanges[depth]
                : nil

            var shared = true
            var index = start
            while index < leaves.count {
                guard let leafRange = leaves[index].range,
                      leafRange.lowerBound < match.range.upperBound else {
                    break
                }
                if leafRange.upperBound > match.range.lowerBound {
                    let leaf = leaves[index]
                    let leafRangeValue = leaf.styleRanges.count > depth
                        ? leaf.styleRanges[depth]
                        : nil
                    if leaf.path.count <= depth
                        || leaf.path[depth] != style
                        || leafRangeValue != styleRange {
                        shared = false
                        break
                    }
                }
                index += 1
            }

            guard shared else { break }
            path.append(style)
            ranges.append(styleRange)
        }
        return (path, ranges)
    }

    private func makeWikiInline(
        _ match: WikiLinkMatch,
        parsed: ParsedMarkdown
    ) -> Inline {
        let link = WikiLink(
            target: match.target,
            fragment: match.fragment,
            alias: match.alias
        )
        let range = parsed.fullSourceMap.position(atUTF16Offset: match.range.lowerBound)
            .flatMap { start in
                parsed.fullSourceMap.position(atUTF16Offset: match.range.upperBound)
                    .map { end in SourceRange(start: start, end: end) }
            }
        return .wikiLink(link, range: range)
    }

    private func appendTextSlice(
        leaf: InlineLeaf,
        from lower: Int,
        to upper: Int,
        parsed: ParsedMarkdown,
        into segments: inout [InlineLeaf]
    ) {
        guard upper > lower, case let .text(literal, range) = leaf.inline, let range else {
            return
        }
        guard
            let start = parsed.fullSourceMap.position(atUTF16Offset: lower),
            let end = parsed.fullSourceMap.position(atUTF16Offset: upper)
        else {
            return
        }

        let leafRawLength = parsed.source.utf16Range(range).utf16.count
        if leafRawLength == literal.utf16.count {
            let localLower = lower - range.lowerBound
            let localUpper = upper - range.lowerBound
            let text = literal.utf16Slice(localLower..<localUpper)
            guard !text.isEmpty else { return }
            segments.append(
                InlineLeaf(
                    path: leaf.path,
                    styleRanges: leaf.styleRanges,
                    inline: .text(
                        text,
                        range: SourceRange(start: start, end: end)
                    )
                )
            )
            return
        }

        // Escapes or entities: re-parse the raw slice so its semantics are
        // preserved exactly.
        let raw = parsed.source.utf16Range(SourceRange(start: start, end: end))
        for inline in decodedTextSlice(
            raw,
            lower: lower,
            end: end,
            start: start,
            parsed: parsed
        ) {
            segments.append(
                InlineLeaf(
                    path: leaf.path,
                    styleRanges: leaf.styleRanges,
                    inline: inline
                )
            )
        }
    }

    /// Re-parses a raw text slice and restores boundary whitespace that block
    /// parsing trims.
    private func decodedTextSlice(
        _ raw: String,
        lower: Int,
        end: SourcePosition,
        start: SourcePosition,
        parsed: ParsedMarkdown
    ) -> [Inline] {
        var parsedInlines = InlineFragmentParser.parse(
            raw,
            baseLine: start.line,
            baseOffset: lower,
            baseColumn: start.column,
            referenceDefinitions: parsed.ast.referenceDefinitions
        )

        // Block parsing trims boundary whitespace. At a mid-paragraph slice
        // that whitespace is content. Count decoded whitespace, not raw
        // characters, so `&#32;` cannot masquerade as retained whitespace.
        let leadingRawCount = decodedBoundaryCount(raw, fromEnd: false)
        let firstText: String? = parsedInlines.first.flatMap { inline in
            if case let .text(value, _) = inline { return value }
            return nil
        }
        let leadingPresent = firstText?.prefix {
            $0 == " " || $0 == "\t"
        } ?? ""
        if leadingRawCount > leadingPresent.count {
            let missingCount = leadingRawCount - leadingPresent.count
            let spaces = String(repeating: " ", count: missingCount)
            if let first = parsedInlines.first,
               case let .text(value, range) = first {
                // Keep the source range; the entity prefix already covers
                // the authored whitespace this replaces.
                parsedInlines[0] = .text(spaces + value, range: range)
            } else {
                let startPosition = parsed.fullSourceMap.position(
                    atUTF16Offset: lower
                )
                let endPosition = parsed.fullSourceMap.position(
                    atUTF16Offset: lower + missingCount
                )
                if let startPosition, let endPosition {
                    parsedInlines.insert(
                        .text(
                            spaces,
                            range: SourceRange(
                                start: startPosition,
                                end: endPosition
                            )
                        ),
                        at: 0
                    )
                }
            }
        }

        let trailingRawCount = decodedBoundaryCount(raw, fromEnd: true)
        let lastText: String? = parsedInlines.last.flatMap { inline in
            if case let .text(value, _) = inline { return value }
            return nil
        }
        let trailingPresentCount = (lastText ?? "").reversed().prefix {
            $0 == " " || $0 == "\t"
        }.count
        if trailingRawCount > trailingPresentCount {
            let missingCount = trailingRawCount - trailingPresentCount
            let missingStart = end.offset - missingCount
            if let startPosition = parsed.fullSourceMap.position(
                atUTF16Offset: missingStart
            ), let endPosition = parsed.fullSourceMap.position(
                atUTF16Offset: end.offset
            ) {
                parsedInlines.append(
                    .text(
                        String(repeating: " ", count: missingCount),
                        range: SourceRange(
                            start: startPosition,
                            end: endPosition
                        )
                    )
                )
            }
        }

        return parsedInlines
    }

    /// Counts boundary spaces/tabs as they decode, including whitespace
    /// character references.
    private func decodedBoundaryCount(_ raw: String, fromEnd: Bool) -> Int {
        if fromEnd {
            var count = 0
            var index = raw.endIndex
            while index > raw.startIndex {
                let previous = raw.index(before: index)
                if raw[previous] == " " || raw[previous] == "\t" {
                    count += 1
                    index = previous
                    continue
                }
                if raw[previous] == ";" {
                    var start = previous
                    var steps = 0
                    while start > raw.startIndex, steps < 10 {
                        start = raw.index(before: start)
                        steps += 1
                        if raw[start] == "&" { break }
                    }
                    if start < previous, raw[start] == "&" {
                        let entity = raw[raw.index(after: start)..<previous]
                        if decodesToWhitespace(entity) {
                            count += 1
                            index = start
                            continue
                        }
                    }
                }
                break
            }
            return count
        }

        var count = 0
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == " " || raw[index] == "\t" {
                count += 1
                index = raw.index(after: index)
                continue
            }
            if raw[index] == "&",
               let semicolon = raw[index...].firstIndex(of: ";"),
               raw.distance(from: index, to: semicolon) <= 10 {
                let entity = raw[raw.index(after: index)..<semicolon]
                if decodesToWhitespace(entity) {
                    count += 1
                    index = raw.index(after: semicolon)
                    continue
                }
            }
            break
        }
        return count
    }

    private func decodesToWhitespace(_ entity: Substring) -> Bool {
        let lowered = entity.lowercased()
        if lowered == "tab" { return true }

        let value: UInt32?
        if lowered.hasPrefix("#x") {
            value = UInt32(lowered.dropFirst(2), radix: 16)
        } else if lowered.hasPrefix("#") {
            value = UInt32(lowered.dropFirst(1), radix: 10)
        } else {
            value = nil
        }
        // Numeric references may pad with leading zeros (`&#032;`).
        guard let value else { return false }
        return value == 0x20 || value == 0x09
    }
}

// MARK: - Inline flattening

enum InlineStyle: Hashable {
    case emphasis
    case strong
    case strikethrough
}

struct InlineLeaf {
    let path: [InlineStyle]
    /// The authored range of each style node on `path`, outermost first.
    let styleRanges: [SourceRange?]
    let inline: Inline

    var range: SourceRange? { inline.range }
}

enum InlineLeaves {
    static func flatten(
        _ inlines: [Inline],
        path: [InlineStyle] = [],
        ranges: [SourceRange?] = []
    ) -> [InlineLeaf] {
        var result: [InlineLeaf] = []
        for inline in inlines {
            switch inline {
            case let .emphasis(children, range):
                result.append(contentsOf: flatten(
                    children,
                    path: path + [.emphasis],
                    ranges: ranges + [range]
                ))
            case let .strong(children, range):
                result.append(contentsOf: flatten(
                    children,
                    path: path + [.strong],
                    ranges: ranges + [range]
                ))
            case let .strikethrough(children, range):
                result.append(contentsOf: flatten(
                    children,
                    path: path + [.strikethrough],
                    ranges: ranges + [range]
                ))
            default:
                result.append(
                    InlineLeaf(
                        path: path,
                        styleRanges: ranges,
                        inline: inline
                    )
                )
            }
        }
        return result
    }

    static func rebuild(_ segments: [InlineLeaf], depth: Int = 0) -> [Inline] {
        var result: [Inline] = []
        var index = 0

        while index < segments.count {
            let segment = segments[index]
            if segment.path.count == depth {
                result.append(segment.inline)
                index += 1
                continue
            }
            guard segment.path.count > depth else {
                index += 1
                continue
            }

            let style = segment.path[depth]
            // Do not merge two adjacent authored nodes that happen to use
            // the same style: their delimiters and ranges are distinct.
            let groupRange = segment.styleRanges.count > depth
                ? segment.styleRanges[depth]
                : nil
            func rangeOf(_ candidate: InlineLeaf) -> SourceRange? {
                candidate.styleRanges.count > depth
                    ? candidate.styleRanges[depth]
                    : nil
            }
            var end = index
            while end < segments.count,
                  segments[end].path.count > depth,
                  segments[end].path[depth] == style,
                  rangeOf(segments[end]) == groupRange {
                end += 1
            }

            let children = rebuild(Array(segments[index..<end]), depth: depth + 1)
            if !children.isEmpty {
                // Preserve the authored style node's range, including its
                // delimiters. Deriving it only from the children shrank
                // `**bold**` to `bold` after a rebuild.
                let originalRanges = segments[index..<end].compactMap { segment in
                    segment.styleRanges.count > depth
                        ? segment.styleRanges[depth]
                        : nil
                }
                let range: SourceRange?
                if let first = originalRanges.first {
                    range = originalRanges.dropFirst().reduce(first) {
                        $0.union($1)
                    }
                } else {
                    range = children.compactMap(\.range).reduce(nil as SourceRange?) {
                        accumulated, child in
                        accumulated.map { $0.union(child) } ?? child
                    }
                }
                switch style {
                case .emphasis:
                    result.append(.emphasis(inlines: children, range: range))
                case .strong:
                    result.append(.strong(inlines: children, range: range))
                case .strikethrough:
                    result.append(.strikethrough(inlines: children, range: range))
                }
            }
            index = end
        }

        return result
    }
}

// MARK: - UTF-16 helpers

extension String {
    /// Returns the substring covered by global UTF-16 offsets.
    func utf16Range(_ range: SourceRange) -> String {
        utf16Slice(range.lowerBound..<range.upperBound)
    }

    /// Returns the slice covered by local UTF-16 offsets.
    ///
    /// Both helpers share one failure result (an empty string) so callers do
    /// not have to handle two different failure conventions.
    func utf16Slice(_ range: Range<Int>) -> String {
        guard
            range.lowerBound >= 0,
            range.upperBound <= utf16.count,
            let lower = utf16.index(
                utf16.startIndex,
                offsetBy: range.lowerBound,
                limitedBy: utf16.endIndex
            ),
            let upper = utf16.index(
                utf16.startIndex,
                offsetBy: range.upperBound,
                limitedBy: utf16.endIndex
            ),
            let lowerScalar = lower.samePosition(in: unicodeScalars),
            let upperScalar = upper.samePosition(in: unicodeScalars)
        else {
            return ""
        }
        return String(unicodeScalars[lowerScalar..<upperScalar])
    }
}
