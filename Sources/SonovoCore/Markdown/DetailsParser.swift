import Foundation
import Markdown

/// Pairs `<details>` blocks from the base tree.
///
/// Both the compact form (all tags in one HTML block) and the multi-block form
/// are recognized. The body is ordinary Markdown; document-wide reference
/// definitions are prepended when a compact body is re-parsed so references
/// resolve across the block. Malformed input stays raw.
enum DetailsParser {
    private struct Tag {
        let isOpening: Bool
        let isOpenAttribute: Bool
        let isSelfClosing: Bool
        let start: Int
        let end: Int
    }

    // MARK: - Entry point

    static func augment(
        blocks: [Block],
        parsed: ParsedMarkdown,
        depth: Int
    ) -> [Block] {
        guard depth < MarkdownLimits.maxDetailsDepth else { return blocks }

        var result: [Block] = []
        var index = 0

        while index < blocks.count {
            let block = blocks[index]
            guard let blockRange = block.range,
                  case .htmlBlock = block,
                  let opener = detailsOpeningTag(
                    in: parsed.source.utf16Range(blockRange),
                    absoluteStart: blockRange.lowerBound
                  )
            else {
                result.append(block)
                index += 1
                continue
            }

            guard !opener.isSelfClosing else {
                result.append(block)
                index += 1
                continue
            }

            // Compact form: the matching close is inside the same HTML block.
            if let close = matchingClose(
                source: parsed.source,
                from: opener.end,
                limit: blockRange.upperBound
            ) {
                if let parsedDetails = compactDetails(
                    opener: opener,
                    close: close,
                    blockRange: blockRange,
                    parsed: parsed,
                    depth: depth
                ) {
                    result.append(parsedDetails)
                } else {
                    result.append(block)
                }
                index += 1
                continue
            }

            // Multi-block form: pair the opener with a later HTML block close.
            // Nested openers that appear after the outer opener in the same
            // HTML block are already part of the depth.
            var initialDepth = 1
            let openingBlockText = parsed.source.utf16Range(blockRange)
            for tag in tagsIn(
                raw: openingBlockText,
                absoluteStart: blockRange.lowerBound
            ) where tag.start >= opener.end {
                if tag.isOpening {
                    if !tag.isSelfClosing { initialDepth += 1 }
                } else if initialDepth > 0 {
                    initialDepth -= 1
                }
            }

            if let pair = multiBlockClose(
                blocks: blocks,
                from: index + 1,
                parsed: parsed,
                initialDepth: initialDepth
            ) {
                var interior = Array(blocks[(index + 1)..<pair.closingIndex])

                // A closing block may contain the closes of nested details
                // before the outer close. Keep that prefix with the interior
                // so the nested pairing pass can see it.
                if pair.closeTagStart > pair.closingBlockRange.lowerBound {
                    let prefixRange = range(
                        parsed.fullSourceMap,
                        lower: pair.closingBlockRange.lowerBound,
                        upper: pair.closeTagStart
                    )
                    if let prefixRange {
                        let prefixRaw = parsed.source.utf16Range(prefixRange)
                        interior.append(.htmlBlock(raw: prefixRaw, range: prefixRange))
                    }
                }
                result.append(
                    multiBlockDetails(
                        opener: opener,
                        openRange: blockRange,
                        closeTagEnd: pair.closeTagEnd,
                        interior: interior,
                        parsed: parsed,
                        depth: depth
                    )
                )
                index = pair.closingIndex + 1
                continue
            }

            result.append(block)
            index += 1
        }

        return result.map { block in
            switch block {
            case let .blockQuote(children, range):
                return .blockQuote(
                    blocks: augment(blocks: children, parsed: parsed, depth: depth),
                    range: range
                )
            case let .list(list, range):
                let items = list.items.map { item in
                    ListItem(
                        blocks: augment(blocks: item.blocks, parsed: parsed, depth: depth),
                        checked: item.checked,
                        range: item.range
                    )
                }
                return .list(
                    ListBlock(kind: list.kind, items: items, tight: list.tight),
                    range: range
                )
            default:
                return block
            }
        }
    }

    // MARK: - Compact form

    private static func compactDetails(
        opener: Tag,
        close: Int,
        blockRange: SourceRange,
        parsed: ParsedMarkdown,
        depth: Int
    ) -> Block? {
        guard !opener.isSelfClosing else { return nil }

        let ns = parsed.source as NSString
        guard close >= opener.end else { return nil }

        let summaryValue = parsedSummary(
            ns: ns,
            from: opener.end,
            to: close,
            parsed: parsed
        )
        let summary = summaryValue?.span
        let bodyStart = summary?.afterClose ?? opener.end
        let bodyEnd = close

        guard let closingTag = parseTag(
            ns,
            at: close,
            limit: blockRange.upperBound
        ) else {
            return nil
        }

        // Content after the close tag inside the same HTML block would be
        // lost; keep the whole block raw instead of dropping it.
        let trailing = ns.substring(
            with: NSRange(
                location: closingTag.end,
                length: max(0, blockRange.upperBound - closingTag.end)
            )
        )
        if !trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        var leadingBody: [Block] = []
        if let summary, summary.openStart > opener.end {
            let prefixText = ns.substring(
                with: NSRange(
                    location: opener.end,
                    length: summary.openStart - opener.end
                )
            )
            if !prefixText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let prefixRange = range(
                   parsed.fullSourceMap,
                   lower: opener.end,
                   upper: summary.openStart
               ) {
                leadingBody = parseBody(
                    prefixText,
                    baseRange: prefixRange,
                    parsed: parsed,
                    depth: depth + 1
                )
            }
        }

        let bodyText = ns.substring(with: NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart)))
        let bodyRange = range(
            parsed.fullSourceMap,
            lower: bodyStart,
            upper: bodyEnd
        )

        let summaryInlines = summaryValue?.inlines ?? []
        let summarySourceRange = summaryValue?.range

        let bodyBlocks = leadingBody + parseBody(
            bodyText,
            baseRange: bodyRange,
            parsed: parsed,
            depth: depth + 1
        )

        return .details(
            DetailsBlock(
                summary: summaryInlines,
                blocks: bodyBlocks,
                isOpen: opener.isOpenAttribute,
                range: blockRange,
                summaryRange: summarySourceRange
            ),
            range: blockRange
        )
    }

    // MARK: - Multi-block form

    private struct ClosePair {
        let closingIndex: Int
        let closingBlockRange: SourceRange
        let closeTagStart: Int
        let closeTagEnd: Int
    }

    private static func multiBlockClose(
        blocks: [Block],
        from start: Int,
        parsed: ParsedMarkdown,
        initialDepth: Int
    ) -> ClosePair? {
        var depth = initialDepth
        let ns = parsed.source as NSString

        for index in start..<blocks.count {
            guard case let .htmlBlock(_, blockRange) = blocks[index],
                  let blockRange else {
                continue
            }
            let blockText = ns.substring(
                with: NSRange(
                    location: blockRange.lowerBound,
                    length: blockRange.upperBound - blockRange.lowerBound
                )
            )
            let tags = tagsIn(
                raw: blockText,
                absoluteStart: blockRange.lowerBound
            )
            for tag in tags {
                if tag.isOpening {
                    if !tag.isSelfClosing { depth += 1 }
                } else {
                    depth -= 1
                    if depth == 0 {
                        let trailing = ns.substring(
                            with: NSRange(
                                location: tag.end,
                                length: max(0, blockRange.upperBound - tag.end)
                            )
                        )
                        if !trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            return nil
                        }
                        return ClosePair(
                            closingIndex: index,
                            closingBlockRange: blockRange,
                            closeTagStart: tag.start,
                            closeTagEnd: tag.end
                        )
                    }
                }
            }
        }
        return nil
    }

    private static func multiBlockDetails(
        opener: Tag,
        openRange: SourceRange,
        closeTagEnd: Int,
        interior: [Block],
        parsed: ParsedMarkdown,
        depth: Int
    ) -> Block {
        let ns = parsed.source as NSString
        var summaryInlines: [Inline] = []
        var summarySourceRange: SourceRange?
        var bodyBlocks = interior
        var leadingBody: [Block] = []

        if let summaryValue = parsedSummary(
            ns: ns,
            from: opener.end,
            to: openRange.upperBound,
            parsed: parsed
        ) {
            let summary = summaryValue.span
            summaryInlines = summaryValue.inlines
            summarySourceRange = summaryValue.range

            // Content before and after the summary within the opening HTML
            // block is body content. Parse it instead of dropping everything
            // except the summary.
            if summary.openStart > opener.end {
                let prefix = ns.substring(
                    with: NSRange(
                        location: opener.end,
                        length: summary.openStart - opener.end
                    )
                )
                if !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let prefixRange = range(
                       parsed.fullSourceMap,
                       lower: opener.end,
                       upper: summary.openStart
                   ) {
                    leadingBody.append(
                        contentsOf: parseBody(
                            prefix,
                            baseRange: prefixRange,
                            parsed: parsed,
                            depth: depth + 1
                        )
                    )
                }
            }
            if summary.afterClose < openRange.upperBound {
                let remainder = ns.substring(
                    with: NSRange(
                        location: summary.afterClose,
                        length: openRange.upperBound - summary.afterClose
                    )
                )
                if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let remainderRange = range(
                       parsed.fullSourceMap,
                       lower: summary.afterClose,
                       upper: openRange.upperBound
                   ) {
                    leadingBody.append(
                        contentsOf: parseBody(
                            remainder,
                            baseRange: remainderRange,
                            parsed: parsed,
                            depth: depth + 1
                        )
                    )
                }
            }
        } else {
            // Without a summary, the opening block's own content is still
            // body content.
            if opener.end < openRange.upperBound {
                let remainder = ns.substring(
                    with: NSRange(
                        location: opener.end,
                        length: openRange.upperBound - opener.end
                    )
                )
                if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let remainderRange = range(
                       parsed.fullSourceMap,
                       lower: opener.end,
                       upper: openRange.upperBound
                   ) {
                    leadingBody.append(
                        contentsOf: parseBody(
                            remainder,
                            baseRange: remainderRange,
                            parsed: parsed,
                            depth: depth + 1
                        )
                    )
                }
            }

            // A summary may be its own HTML block between the tags. Track
            // nested details across blocks: a nested opener in one block and
            // its summary in a later one must not become the outer summary.
            var nestedDepth = 0
            func apply(_ tags: [Tag], to depth: inout Int) {
                for tag in tags {
                    if tag.isOpening {
                        if !tag.isSelfClosing { depth += 1 }
                    } else if depth > 0 {
                        depth -= 1
                    }
                }
            }

            // Nested openers in the opening HTML block are already inside
            // the outer block; seed the depth with them.
            let openingRaw = ns.substring(
                with: NSRange(
                    location: openRange.lowerBound,
                    length: openRange.upperBound - openRange.lowerBound
                )
            )
            let openingTags = tagsIn(
                raw: openingRaw,
                absoluteStart: openRange.lowerBound
            )
            for tag in openingTags where tag.start >= opener.end {
                if tag.isOpening {
                    if !tag.isSelfClosing { nestedDepth += 1 }
                } else if nestedDepth > 0 {
                    nestedDepth -= 1
                }
            }

            for (offset, block) in interior.enumerated() {
                guard case let .htmlBlock(_, blockRange) = block,
                      let blockRange else { continue }
                let raw = ns.substring(
                    with: NSRange(
                        location: blockRange.lowerBound,
                        length: blockRange.upperBound - blockRange.lowerBound
                    )
                )
                let tags = tagsIn(
                    raw: raw,
                    absoluteStart: blockRange.lowerBound
                )
                guard let summaryValue = parsedSummary(
                    ns: ns,
                    from: blockRange.lowerBound,
                    to: blockRange.upperBound,
                    parsed: parsed
                ) else {
                    apply(tags, to: &nestedDepth)
                    continue
                }
                let summary = summaryValue.span

                var depthAtSummary = nestedDepth
                for tag in tags where tag.start < summary.openStart {
                    if tag.isOpening {
                        if !tag.isSelfClosing { depthAtSummary += 1 }
                    } else if depthAtSummary > 0 {
                        depthAtSummary -= 1
                    }
                }
                if depthAtSummary > 0 {
                    apply(tags, to: &nestedDepth)
                    continue
                }
                summaryInlines = summaryValue.inlines
                summarySourceRange = summaryValue.range

                // Consume only the summary tag. Content sharing the block is
                // preserved as raw HTML instead of being deleted with it.
                var replacements: [Block] = []
                if summary.openStart > blockRange.lowerBound,
                   let prefixRange = range(
                       parsed.fullSourceMap,
                       lower: blockRange.lowerBound,
                       upper: summary.openStart
                   ) {
                    let raw = ns.substring(
                        with: NSRange(
                            location: blockRange.lowerBound,
                            length: summary.openStart - blockRange.lowerBound
                        )
                    )
                    if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        replacements.append(
                            contentsOf: parseBody(
                                raw,
                                baseRange: prefixRange,
                                parsed: parsed,
                                depth: depth + 1
                            )
                        )
                    }
                }
                if summary.afterClose < blockRange.upperBound,
                   let suffixRange = range(
                       parsed.fullSourceMap,
                       lower: summary.afterClose,
                       upper: blockRange.upperBound
                   ) {
                    let raw = ns.substring(
                        with: NSRange(
                            location: summary.afterClose,
                            length: blockRange.upperBound - summary.afterClose
                        )
                    )
                    if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        replacements.append(
                            contentsOf: parseBody(
                                raw,
                                baseRange: suffixRange,
                                parsed: parsed,
                                depth: depth + 1
                            )
                        )
                    }
                }
                bodyBlocks.replaceSubrange(offset...offset, with: replacements)
                break
            }
        }

        if !leadingBody.isEmpty {
            bodyBlocks = leadingBody + bodyBlocks
        }

        let augmentedBody = augment(blocks: bodyBlocks, parsed: parsed, depth: depth + 1)
        let combinedRange = range(
            parsed.fullSourceMap,
            lower: openRange.lowerBound,
            upper: closeTagEnd
        ) ?? openRange

        return .details(
            DetailsBlock(
                summary: summaryInlines,
                blocks: augmentedBody,
                isOpen: opener.isOpenAttribute,
                range: combinedRange,
                summaryRange: summarySourceRange
            ),
            range: combinedRange
        )
    }

    // MARK: - Body parsing

    private static func parseBody(
        _ text: String,
        baseRange: SourceRange?,
        parsed: ParsedMarkdown,
        depth: Int
    ) -> [Block] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let baseRange else {
            return []
        }

        // Prepend document-wide reference definitions so a compact body can
        // resolve references defined outside it.
        let prefix = parsed.ast.referenceDefinitions
            .map(ReferenceDefinitionSerializer.line)
            .joined(separator: "\n")
        // Prefer prepending the definitions: a definition before the body
        // cannot be swallowed by an unclosed construct at the body's end. It
        // is only unsafe when the synthetic prefix would map before offset
        // zero; in that case append instead and filter the appended lines
        // out by range.
        let basePosition = parsed.fullSourceMap.position(
            atUTF16Offset: baseRange.lowerBound
        )
        let baseLine = basePosition?.line ?? 1
        let startingColumn = basePosition?.column ?? 0
        let prefixLength = prefix.isEmpty ? 0 : prefix.utf16.count + 2
        let prefixLines = prefix.isEmpty
            ? 0
            : prefix.filter { $0 == "\n" }.count + 2
        // Prepending needs both offset and line space; clamping the synthetic
        // line to 1 would shift every body line number.
        let prepend = !prefix.isEmpty
            && baseRange.lowerBound >= prefixLength
            && baseLine > prefixLines
            && startingColumn == 0

        // A details block inside a blockquote carries `>` markers on every
        // continuation line. Parsing them would turn the container into a
        // second quote and split emphasis that spans lines, so strip the
        // container markers first and map positions back with the removal
        // counts. The fragment's first line is mid-line after `</summary>`
        // unless it starts at the container prefix; a `>` at its start is
        // authored content there, not a container marker.
        let container = containerPrefix(
            at: baseRange.lowerBound,
            in: parsed.source
        )
        let sourceNS = parsed.source as NSString
        let baseLocation = min(
            max(baseRange.lowerBound, 0),
            max(sourceNS.length - 1, 0)
        )
        let baseLineStart = sourceNS.lineRange(
            for: NSRange(location: baseLocation, length: 0)
        ).location
        let startsAtPrefix = baseRange.lowerBound
            <= baseLineStart + container.length
        let stripped = stripContainerQuotes(
            text,
            depth: container.depth,
            stripFirstLine: startsAtPrefix
        )
        let parseText = stripped.text
        let removals = stripped.removals

        let combined: String
        let mapBaseOffset: Int
        let mapBaseLine: Int
        let mapBaseColumn: Int
        let bodyStartInCombined: Int
        let mapRemovals: [Int]
        if prefix.isEmpty {
            combined = parseText
            mapBaseOffset = baseRange.lowerBound
            mapBaseLine = max(1, baseLine)
            mapBaseColumn = startingColumn
            bodyStartInCombined = 0
            mapRemovals = removals
        } else if prepend {
            combined = prefix + "\n\n" + parseText
            mapBaseOffset = baseRange.lowerBound - prefixLength
            mapBaseLine = max(1, baseLine - prefixLines)
            // The synthetic prefix ends with a newline, so the body starts at
            // column zero.
            mapBaseColumn = 0
            bodyStartInCombined = prefixLength
            mapRemovals = Array(repeating: 0, count: prefixLines) + removals
        } else {
            // An unclosed fence at the body's end would swallow the appended
            // definitions. Close it synthetically so the definitions are
            // structural and never become code-block content.
            let closer = unclosedConstructCloser(in: parseText)
            // Add a blank line before the synthetic closer: it keeps a
            // synthetic-only block separate from the last real block, and
            // the body-end clamp removes it from the body's ranges.
            let body = closer.map { parseText + "\n\n" + $0 } ?? parseText
            combined = body + "\n\n" + prefix
            mapBaseOffset = baseRange.lowerBound
            mapBaseLine = max(1, baseLine)
            mapBaseColumn = startingColumn
            bodyStartInCombined = 0
            mapRemovals = removals
        }

        let map = SourceMap(
            source: combined,
            baseLine: mapBaseLine,
            baseOffset: mapBaseOffset,
            baseColumn: mapBaseColumn,
            linePrefixRemovals: mapRemovals
        )
        // The details body is parsed with the same recursive converter as a
        // document. Guard it before the converter can overflow the stack;
        // preserve the body literally instead of dropping it.
        if NestingGuard.exceedsLimit(
            combined,
            limit: MarkdownLimits.maxParseDepth
        )
            || NestingGuard.exceedsInlineLimit(
                combined,
                limit: MarkdownLimits.maxParseDepth
            ) {
            return [
                .paragraph(
                    inlines: [.text(text, range: baseRange)],
                    range: baseRange
                )
            ]
        }
        let document = Document(parsing: combined, options: MarkdownParser.parseOptions)
        let mapper = ASTMapper(
            sourceMap: map,
            lineOffset: mapBaseLine - 1,
            enableAutolinks: true
        )
        let blocks = mapper.mapBlocks(document.children)
        let bodyStart = mapBaseOffset + bodyStartInCombined
        let bodyEnd = bodyStart + text.utf16.count
        // A synthetic closing fence sits just past the body. Blocks it ends
        // (an unclosed code block, a list containing one) must not report a
        // range that extends into the synthetic prefix.
        let bodyEndPosition = map.position(atUTF16Offset: bodyEnd)
        let filtered = blocks.filter { block in
                guard let range = block.range else { return true }
                return range.lowerBound < bodyEnd && range.upperBound > bodyStart
            }
            .map { clamp($0, upperBound: bodyEndPosition) }

        return augment(blocks: filtered, parsed: parsed, depth: depth)
    }

    /// Strips up to `depth` blockquote markers from the start of every
    /// line. Returns the stripped text and the UTF-16 count removed from
    /// each line, which the source map uses to report original positions.
    /// `stripFirstLine` is false when the fragment starts mid-line after a
    /// tag, where a leading `>` is authored content.
    private static func stripContainerQuotes(
        _ text: String,
        depth: Int,
        stripFirstLine: Bool
    ) -> (text: String, removals: [Int]) {
        guard depth > 0 else { return (text, []) }
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var removals: [Int] = []
        var output: [Substring] = []
        for (lineIndex, line) in lines.enumerated() {
            guard lineIndex > 0 || stripFirstLine else {
                removals.append(0)
                output.append(line)
                continue
            }
            var cursor = line.startIndex
            for _ in 0..<depth {
                var probe = cursor
                var spaces = 0
                while probe < line.endIndex, line[probe] == " ", spaces < 4 {
                    probe = line.index(after: probe)
                    spaces += 1
                }
                guard probe < line.endIndex, line[probe] == ">" else {
                    break
                }
                probe = line.index(after: probe)
                // CommonMark removes one space after the marker; further
                // spaces are content (`>     code` is an indented code
                // block inside the quote).
                if probe < line.endIndex, line[probe] == " " {
                    probe = line.index(after: probe)
                }
                cursor = probe
            }
            let removed = line.utf16.distance(
                from: line.startIndex,
                to: cursor
            )
            removals.append(removed)
            output.append(line[cursor...])
        }
        return (output.map(String.init).joined(separator: "\n"), removals)
    }

    /// The container prefix on the source line that contains `offset`: its
    /// blockquote depth and its UTF-16 length. List markers count as prefix
    /// but not as quote depth (`- > <details>` is one quote).
    private static func containerPrefix(
        at offset: Int,
        in source: String
    ) -> (depth: Int, length: Int) {
        let ns = source as NSString
        guard ns.length > 0 else { return (0, 0) }
        let location = min(max(offset, 0), ns.length - 1)
        let lineRange = ns.lineRange(
            for: NSRange(location: location, length: 0)
        )
        let line = ns.substring(with: lineRange)
        var index = line.startIndex
        var markers = 0
        while index < line.endIndex {
            var probe = index
            var spaces = 0
            while probe < line.endIndex, line[probe] == " ", spaces < 4 {
                probe = line.index(after: probe)
                spaces += 1
            }
            if probe < line.endIndex, line[probe] == ">" {
                markers += 1
                index = line.index(after: probe)
                continue
            }
            if let afterMarker = listMarkerEnd(from: probe, in: line) {
                index = afterMarker
                continue
            }
            break
        }
        return (
            markers,
            line.utf16.distance(from: line.startIndex, to: index)
        )
    }

    /// The index after a list marker (`- `, `* `, `1. `) at `index`, or nil.
    private static func listMarkerEnd(
        from index: String.Index,
        in line: String
    ) -> String.Index? {
        guard index < line.endIndex else { return nil }
        let character = line[index]
        if character == "-" || character == "+" || character == "*" {
            let after = line.index(after: index)
            guard after < line.endIndex,
                  line[after] == " " || line[after] == "\t" else {
                return nil
            }
            return line.dropFirst(0).index(after: after)
        }
        var probe = index
        var digits = 0
        while probe < line.endIndex, line[probe].isNumber, digits < 10 {
            probe = line.index(after: probe)
            digits += 1
        }
        guard digits >= 1, digits <= 9, probe < line.endIndex,
              line[probe] == "." || line[probe] == ")" else {
            return nil
        }
        let after = line.index(after: probe)
        guard after < line.endIndex,
              line[after] == " " || line[after] == "\t" else {
            return nil
        }
        return line.index(after: after)
    }

    /// Clamps block ranges to the real body, dropping synthetic-only extent.
    private static func clamp(
        _ block: Block,
        upperBound: SourcePosition?
    ) -> Block {
        guard let upperBound else { return block }

        func clampRange(_ range: SourceRange?) -> SourceRange? {
            guard let range, range.upperBound > upperBound.offset else {
                return range
            }
            return SourceRange(start: range.start, end: upperBound)
        }

        switch block {
        case let .paragraph(inlines, range):
            return .paragraph(inlines: inlines, range: clampRange(range))
        case let .heading(level, inlines, range):
            return .heading(
                level: level,
                inlines: inlines,
                range: clampRange(range)
            )
        case let .blockQuote(blocks, range):
            return .blockQuote(
                blocks: blocks.map { clamp($0, upperBound: upperBound) },
                range: clampRange(range)
            )
        case let .list(list, range):
            let items = list.items.map { item in
                ListItem(
                    blocks: item.blocks.map {
                        clamp($0, upperBound: upperBound)
                    },
                    checked: item.checked,
                    range: clampRange(item.range)
                )
            }
            return .list(
                ListBlock(kind: list.kind, items: items, tight: list.tight),
                range: clampRange(range)
            )
        case let .codeBlock(code, range):
            return .codeBlock(code, range: clampRange(range))
        case let .htmlBlock(raw, range):
            return .htmlBlock(raw: raw, range: clampRange(range))
        case let .thematicBreak(range):
            return .thematicBreak(range: clampRange(range))
        case let .table(table, range):
            return .table(table, range: clampRange(range))
        case let .details(details, range):
            return .details(
                DetailsBlock(
                    summary: details.summary,
                    blocks: details.blocks.map {
                        clamp($0, upperBound: upperBound)
                    },
                    isOpen: details.isOpen,
                    range: clampRange(details.range),
                    summaryRange: details.summaryRange
                ),
                range: clampRange(range)
            )
        case let .tableOfContents(range):
            return .tableOfContents(range: clampRange(range))
        }
    }

    /// A closer that ends the construct still open at the end of `text`,
    /// so reference definitions appended after it stay structural.
    ///
    /// Guessing from the text misses cases (a fence marker inside an HTML
    /// block, a tag name split across lines). Instead, probe with the real
    /// parser: append a definition and see whether it becomes structural.
    /// The common case needs one probe; a swallowed definition tries each
    /// closer until the parser agrees. Fragments are small and this only
    /// runs when the document actually has reference definitions to append.
    static func unclosedConstructCloser(in text: String) -> String? {
        // A random label cannot collide with a definition already in the
        // fragment, which would make a swallowed marker look structural.
        let probeLabel = "zz-probe-\(UUID().uuidString.lowercased())"
        let marker = "[\(probeLabel)]: /probe-target"

        func markerIsStructural(_ body: String) -> Bool {
            MarkdownParser.parseCanonical(body + "\n\n" + marker)
                .ast.referenceDefinitions
                .contains { $0.label.lowercased() == probeLabel }
        }

        if markerIsStructural(text) { return nil }
        // A fence closes only with at least as many markers as it opened
        // with, so try the run lengths the text actually contains first.
        var candidates: [String] = []
        for line in text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let trimmed = line.drop(while: { $0 == " " })
            guard let first = trimmed.first,
                  first == "`" || first == "~" else {
                continue
            }
            var run = 0
            for character in trimmed {
                guard character == first else { break }
                run += 1
            }
            if run >= 3 {
                let closer = String(repeating: first, count: run)
                if !candidates.contains(closer) {
                    candidates.append(closer)
                }
            }
        }
        for closer in [
            "```", "~~~", "-->", "]]>", "?>", ">",
            "</script>", "</style>", "</pre>", "</textarea>"
        ] where !candidates.contains(closer) {
            candidates.append(closer)
        }
        for candidate in candidates {
            if markerIsStructural(text + "\n\n" + candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Lexing

    private static func detailsOpeningTag(
        in raw: String,
        absoluteStart: Int
    ) -> Tag? {
        // Skip leading container markers so a `<details>` inside a
        // blockquote is still recognized as the block's opening tag.
        var index = raw.startIndex
        while index < raw.endIndex {
            while index < raw.endIndex,
                  raw[index] == " " || raw[index] == "\t" {
                index = raw.index(after: index)
            }
            if index < raw.endIndex, raw[index] == ">" {
                index = raw.index(after: index)
                if index < raw.endIndex,
                   raw[index] == " " || raw[index] == "\t" {
                    index = raw.index(after: index)
                }
                continue
            }
            break
        }
        guard index < raw.endIndex else { return nil }

        let offset = absoluteStart + raw[..<index].utf16.count
        let tags = tagsIn(raw: raw, absoluteStart: absoluteStart)
        return tags.first { $0.isOpening && $0.start == offset }
    }

    /// A structural token found while scanning raw HTML.
    private struct LexToken {
        enum Kind {
            case details(ParsedTag)
            case summary(ParsedTag)
            /// A comment, code span, or unrelated tag. It is consumed as a
            /// unit so its contents cannot be mistaken for structure.
            case other
        }

        let kind: Kind
        let start: Int
        let end: Int
    }

    /// Tokenizes raw HTML once for both details pairing and summary search.
    ///
    /// Fenced code, comments, inline code, escaped `<`, and unrelated tags
    /// are consumed without producing structural tokens. Both callers used
    /// to carry their own copy of this loop, so a lexical fix in one was
    /// invisible to the other.
    private struct Lexer {
        private let ns: NSString
        private var index = 0
        private var fence: (character: unichar, length: Int)?
        /// The current line's bounds, cached across tokens. Searching for
        /// the next newline and copying the rest of the line once per token
        /// made a long line full of tags quadratic.
        private var lineBounds: (start: Int, limit: Int, next: Int)?

        init(_ ns: NSString) {
            self.ns = ns
        }

        mutating func next() -> LexToken? {
            while index < ns.length {
                let bounds: (start: Int, limit: Int, next: Int)
                if let cached = lineBounds,
                   index >= cached.start, index <= cached.limit {
                    bounds = cached
                } else {
                    let lineEnd = ns.range(
                        of: "\n",
                        options: [],
                        range: NSRange(
                            location: index,
                            length: ns.length - index
                        )
                    )
                    let limit = lineEnd.location == NSNotFound
                        ? ns.length
                        : lineEnd.location
                    let next = lineEnd.location == NSNotFound
                        ? ns.length
                        : lineEnd.location + 1
                    bounds = (index, limit, next)
                    lineBounds = bounds
                }
                let lineLimit = bounds.limit
                let nextLine = bounds.next
                let atLineStart = index == 0
                    || ns.character(at: index - 1) == 0x0A
                // Only a line-start token needs the line text; mid-line
                // tokens never inspect it.
                let line = atLineStart
                    ? ns.substring(
                        with: NSRange(
                            location: index,
                            length: max(0, lineLimit - index)
                        )
                    )
                    : ""

                if let activeFence = fence {
                    if closesFence(
                        line,
                        character: activeFence.character,
                        minimumLength: activeFence.length
                    ) {
                        fence = nil
                    }
                    index = nextLine
                    continue
                }

                if atLineStart, let opened = openingFence(line) {
                    fence = opened
                    index = nextLine
                    continue
                }

                var position = index
                while position < lineLimit {
                    let character = ns.character(at: position)

                    if character == 0x3C { // <
                        var backslashes = 0
                        var probe = position - 1
                        while probe >= 0,
                              ns.character(at: probe) == 0x5C {
                            backslashes += 1
                            probe -= 1
                        }
                        if backslashes % 2 == 1 {
                            // An escaped `<` is text, not a tag.
                            position += 1
                            continue
                        }
                        if let commentEnd = skipComment(
                            ns,
                            at: position,
                            limit: lineLimit
                        ) {
                            index = commentEnd
                            return LexToken(
                                kind: .other,
                                start: position,
                                end: commentEnd
                            )
                        }
                        if let tag = parseTag(
                            ns,
                            at: position,
                            limit: ns.length
                        ) {
                            index = tag.end
                            return LexToken(
                                kind: .details(tag),
                                start: position,
                                end: tag.end
                            )
                        }
                        if let summary = parseTag(
                            ns,
                            at: position,
                            limit: ns.length,
                            expecting: "summary"
                        ) {
                            index = summary.end
                            return LexToken(
                                kind: .summary(summary),
                                start: position,
                                end: summary.end
                            )
                        }
                        // Skip any other tag as a unit so a `<details>`
                        // inside its quoted attribute value is not mistaken
                        // for one.
                        if let end = skipAnyTag(
                            ns,
                            at: position,
                            limit: ns.length
                        ) {
                            index = end
                            return LexToken(
                                kind: .other,
                                start: position,
                                end: end
                            )
                        }
                    }

                    if character == 0x60 { // `
                        var backslashes = 0
                        var probe = position - 1
                        while probe >= 0,
                              ns.character(at: probe) == 0x5C {
                            backslashes += 1
                            probe -= 1
                        }
                        if backslashes % 2 == 0,
                           let after = skipInlineCode(
                               ns,
                               at: position,
                               limit: lineLimit
                           ) {
                            index = after
                            return LexToken(
                                kind: .other,
                                start: position,
                                end: after
                            )
                        }
                    }

                    position += 1
                }

                // A multiline comment, code span, or tag can move the inner
                // cursor past this line. Resume where it stopped instead of
                // rescanning the skipped lines on the next iteration.
                index = position > lineLimit ? position : nextLine
            }
            return nil
        }
    }

    /// Finds `<details>` and `</details>` tags in an HTML block, skipping
    /// comments, quoted attribute values, inline code, and fenced code.
    private static func tagsIn(
        raw: String,
        absoluteStart: Int
    ) -> [Tag] {
        var lexer = Lexer(raw as NSString)
        var tags: [Tag] = []
        while let token = lexer.next() {
            guard case let .details(tag) = token.kind else { continue }
            if absoluteStart >= 0 {
                tags.append(
                    Tag(
                        isOpening: tag.isOpening,
                        isOpenAttribute: tag.isOpenAttribute,
                        isSelfClosing: tag.isSelfClosing,
                        start: absoluteStart + token.start,
                        end: absoluteStart + token.end
                    )
                )
            }
        }
        return tags
    }

    private struct ParsedTag {
        let isOpening: Bool
        let isOpenAttribute: Bool
        let isSelfClosing: Bool
        let end: Int
    }

    private static func parseTag(
        _ ns: NSString,
        at start: Int,
        limit: Int,
        expecting name: String = "details"
    ) -> ParsedTag? {
        var index = start + 1
        guard index < limit else { return nil }

        var isOpening = true
        if ns.character(at: index) == 0x2F { // /
            isOpening = false
            index += 1
        }

        guard index + name.count <= limit else { return nil }
        let candidate = ns.substring(
            with: NSRange(location: index, length: name.count)
        ).lowercased()
        guard candidate == name else { return nil }
        index += name.count

        if index < limit {
            let next = ns.character(at: index)
            if next != 0x3E && next != 0x2F && !isWhitespace(next) {
                return nil
            }
        }

        var isOpenAttribute = false
        var isSelfClosing = false

        if isOpening {
            // Parse attributes quote-aware. Every iteration must either
            // consume an attribute or terminate the tag; a malformed
            // character must not leave `index` in place forever.
            var terminated = false
            while index < limit {
                while index < limit, isWhitespace(ns.character(at: index)) {
                    index += 1
                }
                guard index < limit else { return nil }

                if ns.character(at: index) == 0x3E { // >
                    index += 1
                    terminated = true
                    break
                }
                if ns.character(at: index) == 0x2F,
                   index + 1 < limit,
                   ns.character(at: index + 1) == 0x3E {
                    isSelfClosing = true
                    index += 2
                    terminated = true
                    break
                }

                let nameStart = index
                while index < limit, isAttributeNameCharacter(ns.character(at: index)) {
                    index += 1
                }
                guard index > nameStart else { return nil }
                let attributeName = ns.substring(
                    with: NSRange(location: nameStart, length: index - nameStart)
                ).lowercased()

                while index < limit, isWhitespace(ns.character(at: index)) {
                    index += 1
                }

                if index < limit, ns.character(at: index) == 0x3D { // =
                    index += 1
                    while index < limit, isWhitespace(ns.character(at: index)) {
                        index += 1
                    }
                    guard index < limit else { return nil }
                    let quote = ns.character(at: index)
                    if quote == 0x22 || quote == 0x27 {
                        index += 1
                        while index < limit, ns.character(at: index) != quote {
                            index += 1
                        }
                        guard index < limit else { return nil }
                        index += 1
                    } else {
                        while index < limit,
                              !isWhitespace(ns.character(at: index)),
                              ns.character(at: index) != 0x3E {
                            index += 1
                        }
                    }
                }

                if attributeName == "open", isOpening, name == "details" {
                    isOpenAttribute = true
                }
            }
            guard terminated else { return nil }
        } else {
            // A closing tag may contain whitespace before `>`, but no
            // attributes. `</details x=">` is malformed and stays raw.
            while index < limit, isWhitespace(ns.character(at: index)) {
                index += 1
            }
            guard index < limit, ns.character(at: index) == 0x3E else {
                return nil
            }
            index += 1
        }

        return ParsedTag(
            isOpening: isOpening,
            isOpenAttribute: isOpenAttribute,
            isSelfClosing: isSelfClosing,
            end: index
        )
    }

    /// Finds the matching `</details>` starting from `from`, depth-aware.
    private static func matchingClose(
        source: String,
        from: Int,
        limit: Int
    ) -> Int? {
        let ns = source as NSString
        guard from >= 0, limit <= ns.length, from <= limit else { return nil }
        let raw = ns.substring(with: NSRange(location: from, length: limit - from))
        let tags = tagsIn(raw: raw, absoluteStart: from)

        var depth = 1
        for tag in tags {
            if tag.isOpening {
                if !tag.isSelfClosing { depth += 1 }
            } else {
                depth -= 1
                if depth == 0 {
                    return tag.start
                }
            }
        }
        return nil
    }

    private struct SummarySpan {
        let openStart: Int
        let contentStart: Int
        let contentEnd: Int
        let afterClose: Int
    }

    /// Finds the outer details block's own `<summary>`.
    ///
    /// The search skips comments, inline code, and fenced code, and ignores
    /// summaries that belong to a nested details block. Picking the first
    /// substring match would let either of those masquerade as the outer
    /// summary and cause the preceding content to be discarded.
    private static func summaryRange(
        ns: NSString,
        from: Int,
        to: Int
    ) -> SummarySpan? {
        guard from < to, to <= ns.length else { return nil }
        let raw = ns.substring(
            with: NSRange(location: from, length: to - from)
        ) as NSString
        var detailsDepth = 0
        var summaryOpen: (start: Int, end: Int)?
        var lexer = Lexer(raw)

        while let token = lexer.next() {
            switch token.kind {
            case let .details(tag):
                if tag.isOpening {
                    if !tag.isSelfClosing { detailsDepth += 1 }
                } else if detailsDepth > 0 {
                    detailsDepth -= 1
                }
            case let .summary(tag):
                // Only the outer block's own summary counts; a summary inside
                // a nested details block is not it.
                guard detailsDepth == 0 else { continue }
                if let open = summaryOpen {
                    if !tag.isOpening {
                        return SummarySpan(
                            openStart: from + open.start,
                            contentStart: from + open.end,
                            contentEnd: from + token.start,
                            afterClose: from + token.end
                        )
                    }
                } else if tag.isOpening {
                    summaryOpen = (token.start, token.end)
                }
            case .other:
                continue
            }
        }

        return nil
    }

    /// Returns the range of the innermost `<details>` tag that encloses the
    /// offset, or `nil` when the offset is outside every block.
    ///
    /// A backward string search finds the nearest opener even when its close
    /// tag is before the caret, which edits a closed block instead of the
    /// enclosing one. Scanning forward with a stack matches tags properly.
    static func enclosingDetailsOpeningTag(
        in source: String,
        before offset: Int
    ) -> NSRange? {
        let ns = source as NSString
        let limit = min(max(0, offset), ns.length)
        var stack: [Int] = []

        // Lex the complete source, not the prefix up to the caret: a closing
        // backtick after the caret still makes the preceding `<details>` a
        // code-span literal.
        for tag in tagsIn(raw: source, absoluteStart: 0)
        where tag.start < limit {
            let lineRange = ns.lineRange(
                for: NSRange(location: tag.start, length: 0)
            )
            let before = ns.substring(
                with: NSRange(
                    location: lineRange.location,
                    length: tag.start - lineRange.location
                )
            )
            let indentation = before.prefix(while: { $0 == " " }).count
                + (before.hasPrefix("\t") ? 4 : 0)

            if tag.isOpening {
                if !tag.isSelfClosing {
                    // Four leading spaces make a lone opener indented code.
                    // Once a real details block is open, an indented closing
                    // tag still belongs to it.
                    if indentation >= 4, stack.isEmpty { continue }
                    stack.append(tag.start)
                }
            } else if !stack.isEmpty {
                stack.removeLast()
            }
        }

        guard let start = stack.last,
              let parsed = parseTag(ns, at: start, limit: ns.length) else {
            return nil
        }
        return NSRange(location: start, length: parsed.end - start)
    }

    private struct ParsedSummary {
        let span: SummarySpan
        let inlines: [Inline]
        let range: SourceRange?
    }

    private static func parsedSummary(
        ns: NSString,
        from: Int,
        to: Int,
        parsed: ParsedMarkdown
    ) -> ParsedSummary? {
        guard let span = summaryRange(ns: ns, from: from, to: to) else {
            return nil
        }
        let text = ns.substring(
            with: NSRange(
                location: span.contentStart,
                length: span.contentEnd - span.contentStart
            )
        )
        guard let base = parsed.fullSourceMap.position(
            atUTF16Offset: span.contentStart
        ) else {
            return ParsedSummary(span: span, inlines: [], range: nil)
        }
        return ParsedSummary(
            span: span,
            inlines: InlineFragmentParser.parse(
                text,
                baseLine: base.line,
                baseOffset: span.contentStart,
                baseColumn: base.column,
                referenceDefinitions: parsed.ast.referenceDefinitions
            ),
            range: range(
                parsed.fullSourceMap,
                lower: span.contentStart,
                upper: span.contentEnd
            )
        )
    }

    // MARK: - Tag scanning helpers

    private static func skipComment(_ ns: NSString, at start: Int, limit: Int) -> Int? {
        guard start + 4 <= ns.length else { return nil }
        guard ns.substring(with: NSRange(location: start, length: 4)) == "<!--" else {
            return nil
        }
        let end = ns.range(
            of: "-->",
            options: [],
            range: NSRange(location: start + 4, length: ns.length - start - 4)
        )
        return end.location == NSNotFound ? ns.length : end.location + 3
    }

    private static func skipInlineCode(_ ns: NSString, at start: Int, limit: Int) -> Int? {
        var length = 0
        var index = start
        while index < limit, ns.character(at: index) == 0x60 {
            length += 1
            index += 1
        }
        guard length > 0 else { return nil }
        let closing = String(repeating: "`", count: length)

        // A closing run must have exactly this length, not be a substring of
        // a longer run.
        var search = index
        while search < ns.length {
            let found = ns.range(
                of: closing,
                options: [],
                range: NSRange(location: search, length: ns.length - search)
            )
            if found.location == NSNotFound { return nil }
            let before = found.location > 0
                ? ns.character(at: found.location - 1)
                : 0
            let afterIndex = found.location + length
            let after = afterIndex < ns.length
                ? ns.character(at: afterIndex)
                : 0
            if before != 0x60 && after != 0x60 {
                return afterIndex
            }
            search = found.location + 1
        }
        return nil
    }

    private static func openingFence(_ line: String) -> (character: unichar, length: Int)? {
        var rest = line.drop(while: { $0 == " " || $0 == "\t" })

        // A fence can open after blockquote, bullet, or ordered list markers.
        while true {
            if rest.first == ">" {
                rest = rest.dropFirst().drop(while: {
                    $0 == " " || $0 == "\t"
                })
                continue
            }
            if let first = rest.first,
               first == "-" || first == "+" || first == "*" {
                let after = rest.dropFirst()
                if after.first == " " || after.first == "\t" {
                    rest = after.drop(while: { $0 == " " || $0 == "\t" })
                    continue
                }
            }

            var probe = rest.startIndex
            var digits = 0
            while probe < rest.endIndex, rest[probe].isNumber, digits < 10 {
                digits += 1
                probe = rest.index(after: probe)
            }
            if digits >= 1, digits <= 9, probe < rest.endIndex,
               rest[probe] == "." || rest[probe] == ")" {
                let after = rest.index(after: probe)
                if after == rest.endIndex
                    || rest[after] == " " || rest[after] == "\t" {
                    rest = rest[after...].drop(while: {
                        $0 == " " || $0 == "\t"
                    })
                    continue
                }
            }
            break
        }

        guard let first = rest.first, first == "`" || first == "~" else {
            return nil
        }
        let character = first.unicodeScalars.first!.value
        var length = 0
        for scalar in rest.unicodeScalars {
            if scalar.value == character { length += 1 } else { break }
        }
        guard length >= 3 else { return nil }
        if first == "`", rest.dropFirst(length).contains("`") {
            return nil
        }
        return (unichar(character), length)
    }

    private static func closesFence(
        _ line: String,
        character: unichar,
        minimumLength: Int
    ) -> Bool {
        var trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        while trimmed.first == ">" {
            trimmed = trimmed.dropFirst().drop(while: {
                $0 == " " || $0 == "\t"
            })
        }
        var length = 0
        for scalar in trimmed.unicodeScalars {
            if scalar.value == UInt32(character) { length += 1 } else { break }
        }
        guard length >= minimumLength else { return false }
        let rest = trimmed.dropFirst(length)
        return rest.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Skips any HTML tag as a unit, including quoted attribute values.
    ///
    /// `parseTag` only recognizes details and summary tags. Without this,
    /// the scanner advances one character at a time and can find a `<details>`
    /// or `<summary>` that is merely text inside another tag's attribute.
    private static func skipAnyTag(
        _ ns: NSString,
        at start: Int,
        limit: Int
    ) -> Int? {
        guard start < limit, ns.character(at: start) == 0x3C else {
            return nil
        }
        var index = start + 1
        guard index < limit else { return nil }
        if ns.character(at: index) == 0x2F { // closing tag
            index += 1
        }
        guard index < limit else { return nil }

        let first = ns.character(at: index)
        let isLetter = (first >= 0x41 && first <= 0x5A)
            || (first >= 0x61 && first <= 0x7A)
        if first == 0x21 || first == 0x3F { // <!doctype>, <?processing?>
            while index < limit, ns.character(at: index) != 0x3E {
                index += 1
            }
            return index < limit ? index + 1 : nil
        }
        guard isLetter else { return nil }

        while index < limit {
            let character = ns.character(at: index)
            let isName = (character >= 0x41 && character <= 0x5A)
                || (character >= 0x61 && character <= 0x7A)
                || (character >= 0x30 && character <= 0x39)
                || character == 0x2D || character == 0x3A
            guard isName else { break }
            index += 1
        }

        var quote: unichar = 0
        while index < limit {
            let character = ns.character(at: index)
            if quote != 0 {
                if character == quote { quote = 0 }
            } else if character == 0x22 || character == 0x27 {
                quote = character
            } else if character == 0x3E {
                return index + 1
            }
            index += 1
        }
        return nil
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }

    private static func isAttributeNameCharacter(_ character: unichar) -> Bool {
        if character >= 0x41, character <= 0x5A { return true } // A-Z
        if character >= 0x61, character <= 0x7A { return true } // a-z
        if character >= 0x30, character <= 0x39 { return true } // 0-9
        return character == 0x2D || character == 0x5F || character == 0x3A // - _ :
    }

    private static func range(
        _ map: SourceMap,
        lower: Int,
        upper: Int
    ) -> SourceRange? {
        guard let start = map.position(atUTF16Offset: lower),
              let end = map.position(atUTF16Offset: upper) else {
            return nil
        }
        return SourceRange(start: start, end: end)
    }
}
