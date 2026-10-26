import Foundation

/// Turns a raw paragraph with the shape
///
/// ```
/// Term
/// : definition
/// ```
///
/// into a `DefinitionList` block. The source is never rewritten: the
/// paragraph's bytes become term and definition ranges, and every inline
/// fragment is parsed with its absolute source position.
///
/// The rule is deliberately strict. A paragraph converts only when every
/// line belongs to a complete item: one or more term lines, each followed by
/// at least one `:` line with non-empty content. Anything else — a term with
/// no definition, a definition with no term, a blank line, a wrapped
/// definition — stays the ordinary paragraph the base parser produced, so the
/// reader never hides authored text.
public enum DefinitionListParser {
    /// Augments every block tree the parser can nest.
    public static func augment(
        blocks: [Block],
        parsed: ParsedMarkdown
    ) -> [Block] {
        blocks.map { augment(block: $0, parsed: parsed) }
    }

    private static func augment(
        block: Block,
        parsed: ParsedMarkdown
    ) -> Block {
        switch block {
        case let .paragraph(inlines, range):
            guard let range,
                  let list = parse(
                      inlines: inlines,
                      paragraph: range,
                      parsed: parsed
                  ) else {
                return block
            }
            return .definitionList(list, range: range)
        case let .blockQuote(children, range):
            return .blockQuote(
                blocks: augment(blocks: children, parsed: parsed),
                range: range
            )
        case let .list(list, range):
            let items = list.items.map { item in
                ListItem(
                    blocks: augment(blocks: item.blocks, parsed: parsed),
                    checked: item.checked,
                    range: item.range
                )
            }
            return .list(
                ListBlock(kind: list.kind, items: items, tight: list.tight),
                range: range
            )
        case let .details(details, range):
            return .details(
                DetailsBlock(
                    summary: details.summary,
                    blocks: augment(blocks: details.blocks, parsed: parsed),
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

    // MARK: - Parsing

    private struct Line {
        /// The trimmed line content, in absolute UTF-16 offsets.
        let content: Range<Int>
    }

    private static func parse(
        inlines: [Inline],
        paragraph: SourceRange,
        parsed: ParsedMarkdown
    ) -> DefinitionList? {
        guard paragraph.lowerBound >= 0,
              paragraph.upperBound <= (parsed.source as NSString).length else {
            return nil
        }
        let lines = lines(in: inlines, paragraph: paragraph, source: parsed.source)
        guard lines.count >= 2 else { return nil }

        var items: [DefinitionList.Item] = []
        var index = 0
        while index < lines.count {
            var termLines: [Line] = []
            while index < lines.count, !isDefinition(lines[index], source: parsed.source) {
                termLines.append(lines[index])
                index += 1
            }
            guard !termLines.isEmpty else { return nil }

            var definitionLines: [Line] = []
            while index < lines.count,
                  isDefinition(lines[index], source: parsed.source) {
                guard let content = definitionContent(
                    lines[index],
                    source: parsed.source
                ) else { return nil }
                definitionLines.append(content)
                index += 1
            }
            guard !definitionLines.isEmpty else { return nil }

            guard let item = makeItem(
                terms: termLines,
                definitions: definitionLines,
                parsed: parsed
            ) else { return nil }
            items.append(item)
        }
        guard !items.isEmpty else { return nil }
        return DefinitionList(items: items)
    }

    /// Splits a paragraph into logical source lines using the inline tree.
    ///
    /// The inline ranges already skip container markers, so a term inside a
    /// block quote or a list item is found at `Term`, not at `> Term`. Raw
    /// line scanning would have to re-implement every marker rule; the tree
    /// has already applied them.
    ///
    /// An inline range is not the same as a line's extent: an inline code
    /// node covers only its content, not its backticks. Line starts come from
    /// the tree; each line then extends to the next line's start, minus the
    /// newline, so delimiters after the last inline stay in the slice.
    private static func lines(
        in inlines: [Inline],
        paragraph: SourceRange,
        source: String
    ) -> [Line] {
        let ns = source as NSString
        var starts: [Int] = []
        var expectingLine = true
        for inline in inlines {
            switch inline {
            case .softBreak, .lineBreak:
                expectingLine = true
            default:
                guard let range = inline.range else { continue }
                // An inline whose range crosses a newline (emphasis around a
                // soft break, a multi-line code span) is not one logical
                // line. Refuse the conversion instead of truncating the term
                // at its first newline and dropping the rest.
                if containsNewline(
                    range.lowerBound..<range.upperBound,
                    in: ns
                ) { return [] }
                if expectingLine {
                    var start = range.lowerBound
                    if case .inlineCode = inline {
                        // A code span's range covers its content, not its
                        // backticks; a line that begins with one must begin
                        // at the opener or the term loses it.
                        while start > paragraph.lowerBound,
                              ns.character(at: start - 1) == 0x60 {
                            start -= 1
                        }
                    }
                    starts.append(start)
                    expectingLine = false
                }
            }
        }
        guard !starts.isEmpty else { return [] }

        var result: [Line] = []
        for (index, start) in starts.enumerated() {
            var lower = max(start, paragraph.lowerBound)
            var upper: Int
            if index + 1 < starts.count {
                // Each logical line ends at its own newline. The next line's
                // first inline starts after that line's container markers,
                // so using it directly pulled `> ` into this line's slice.
                let nextStart = min(starts[index + 1], paragraph.upperBound)
                upper = firstNewline(
                    from: lower,
                    before: nextStart,
                    in: ns
                ) ?? nextStart
            } else {
                upper = paragraph.upperBound
            }
            if index + 1 < starts.count, upper > lower,
               ns.character(at: upper - 1) == 0x0A {
                upper -= 1
            }
            while lower < upper, isSpace(ns.character(at: lower)) {
                lower += 1
            }
            while upper > lower,
                  isSpace(ns.character(at: upper - 1))
                    || ns.character(at: upper - 1) == 0x0A {
                upper -= 1
            }
            guard lower < upper else { return [] }
            result.append(Line(content: lower..<upper))
        }
        return result
    }

    private static func firstNewline(
        from lower: Int,
        before limit: Int,
        in ns: NSString
    ) -> Int? {
        var cursor = lower
        while cursor < limit {
            if ns.character(at: cursor) == 0x0A { return cursor }
            cursor += 1
        }
        return nil
    }

    private static func containsNewline(
        _ range: Range<Int>,
        in ns: NSString
    ) -> Bool {
        guard range.lowerBound >= 0, range.upperBound <= ns.length else {
            return false
        }
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            if ns.character(at: cursor) == 0x0A { return true }
            cursor += 1
        }
        return false
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    private static func isDefinition(_ line: Line, source: String) -> Bool {
        (source as NSString).character(at: line.content.lowerBound) == 0x3A
    }

    /// The content after `:` and one optional space, with surrounding
    /// whitespace removed. `nil` for an empty definition.
    private static func definitionContent(
        _ line: Line,
        source: String
    ) -> Line? {
        let ns = source as NSString
        var lower = line.content.lowerBound + 1
        var upper = line.content.upperBound
        if lower < upper, isSpace(ns.character(at: lower)) { lower += 1 }
        while lower < upper, isSpace(ns.character(at: upper - 1)) {
            upper -= 1
        }
        guard lower < upper else { return nil }
        return Line(content: lower..<upper)
    }

    private static func makeItem(
        terms: [Line],
        definitions: [Line],
        parsed: ParsedMarkdown
    ) -> DefinitionList.Item? {
        var termNodes: [DefinitionList.Term] = []
        for line in terms {
            guard let range = sourceRange(line.content, parsed: parsed) else {
                return nil
            }
            termNodes.append(
                DefinitionList.Term(
                    inlines: inlines(line.content, parsed: parsed),
                    range: range
                )
            )
        }
        var definitionNodes: [DefinitionList.Definition] = []
        for line in definitions {
            guard let range = sourceRange(line.content, parsed: parsed) else {
                return nil
            }
            definitionNodes.append(
                DefinitionList.Definition(
                    inlines: inlines(line.content, parsed: parsed),
                    range: range
                )
            )
        }
        guard let first = termNodes.first,
              let last = definitionNodes.last else { return nil }
        return DefinitionList.Item(
            terms: termNodes,
            definitions: definitionNodes,
            range: SourceRange(start: first.range.start, end: last.range.end)
        )
    }

    private static func sourceRange(
        _ range: Range<Int>,
        parsed: ParsedMarkdown
    ) -> SourceRange? {
        guard let start = parsed.fullSourceMap.position(
            atUTF16Offset: range.lowerBound
        ), let end = parsed.fullSourceMap.position(
            atUTF16Offset: range.upperBound
        ) else { return nil }
        return SourceRange(start: start, end: end)
    }

    private static func inlines(
        _ range: Range<Int>,
        parsed: ParsedMarkdown
    ) -> [Inline] {
        guard let start = parsed.fullSourceMap.position(
            atUTF16Offset: range.lowerBound
        ) else { return [] }
        let text = (parsed.source as NSString).substring(
            with: NSRange(
                location: range.lowerBound,
                length: range.upperBound - range.lowerBound
            )
        )
        return InlineFragmentParser.parse(
            text,
            baseLine: start.line,
            baseOffset: range.lowerBound,
            baseColumn: start.column,
            referenceDefinitions: parsed.ast.referenceDefinitions
        )
    }
}
