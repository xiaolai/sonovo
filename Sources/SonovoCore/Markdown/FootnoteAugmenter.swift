import Foundation

/// Applies GFM footnotes to an augmented tree.
///
/// A label resolves only when exactly one `[^label]:` definition exists and
/// at least one reference points at it. Anything else — an undefined
/// reference, a duplicate definition, or a definition nobody references —
/// stays literal source text, so an authoring mistake is visible instead of
/// silently disappearing from the reading view.
///
/// The base parser has no footnote support and reads a single-word note such
/// as `[^a]: Note.` as a link reference definition, consuming the line and
/// resolving `[^a]` into a link. The pass therefore unlinks every
/// `[^...]`-shaped link before scanning, and re-inserts a literal paragraph
/// for a definition the base parser swallowed.
enum FootnoteAugmenter {
    static func apply(
        to ast: SonovoAST,
        parsed: ParsedMarkdown,
        augmenter: MarkdownSyntaxAugmenter
    ) -> SonovoAST {
        var definitionExclusions = codeAndHTMLSpans(in: ast.blocks)
        if let frontmatter = ast.frontmatter {
            definitionExclusions.append(frontmatter.range)
        }
        let definitions = FootnoteScanner.definitions(
            in: parsed.source,
            excluding: definitionExclusions
        )
        guard !definitions.isEmpty else { return ast }

        let grouped = Dictionary(grouping: definitions, by: \.label)
        let unique = grouped.compactMapValues { matches in
            matches.count == 1 ? matches[0] : nil
        }
        var blocks = ast.blocks.map {
            unlinkFootnoteLinks($0, source: parsed.source)
        }
        let collector = Collector(parsed: parsed, definitions: unique)
        let definitionSpans = definitions.compactMap {
            collector.sourceRange($0.span)
        }

        blocks = blocks.map { block in
            augmenter.replaceInlineTree(
                block,
                parsed: parsed,
                scan: { span, inlineExcluded in
                    FootnoteScanner.references(
                        in: span,
                        source: parsed.source,
                        excluding: inlineExcluded + definitionSpans
                    )
                },
                include: { collector.resolves($0) },
                makeInline: { collector.makeInline($0) }
            )
        }

        if collector.numbers.isEmpty {
            // No reference resolves, so no definition may disappear.
            var result = ast
            result.blocks = insertLiteralDefinitions(
                definitions,
                into: blocks,
                collector: collector
            )
            result.referenceDefinitions = withoutFootnoteDefinitions(in: ast)
            return result
        }

        blocks = blocks.map {
            hideDefinitions($0, collector: collector)
        }
        let literal = definitions.filter {
            collector.numbers[$0.label] == nil
        }
        blocks = insertLiteralDefinitions(
            literal,
            into: blocks,
            collector: collector
        )

        let entries = collector.entries(parsed: parsed)
        guard !entries.isEmpty else {
            var result = ast
            result.blocks = blocks
            return result
        }
        blocks.append(
            .footnotes(FootnoteSection(entries: entries), range: nil)
        )

        var result = ast
        result.blocks = blocks
        result.referenceDefinitions = withoutFootnoteDefinitions(in: ast)
        return result
    }

    // MARK: - Base-parser compensation

    /// Replaces a `.link` the base parser built from `[^label]` with the raw
    /// text, so the footnote scan can claim the span. Runs for every shaped
    /// link, resolved or not: a reference with no footnote definition must
    /// read as literal text, not as a link to a definition's first word.
    private static func unlinkFootnoteLinks(
        _ block: Block,
        source: String
    ) -> Block {
        switch block {
        case let .paragraph(inlines, range):
            return .paragraph(
                inlines: unlinkFootnoteLinks(inlines, source: source),
                range: range
            )
        case let .heading(level, inlines, range):
            return .heading(
                level: level,
                inlines: unlinkFootnoteLinks(inlines, source: source),
                range: range
            )
        case let .blockQuote(children, range):
            return .blockQuote(
                blocks: children.map {
                    unlinkFootnoteLinks($0, source: source)
                },
                range: range
            )
        case let .list(list, range):
            let items = list.items.map { item in
                ListItem(
                    blocks: item.blocks.map {
                        unlinkFootnoteLinks($0, source: source)
                    },
                    checked: item.checked,
                    range: item.range
                )
            }
            return .list(
                ListBlock(kind: list.kind, items: items, tight: list.tight),
                range: range
            )
        case let .table(table, range):
            let header = table.header.map {
                unlinkFootnoteLinks($0, source: source)
            }
            let rows = table.rows.map { row in
                row.map { unlinkFootnoteLinks($0, source: source) }
            }
            return .table(
                TableBlock(
                    header: header,
                    rows: rows,
                    alignments: table.alignments
                ),
                range: range
            )
        case let .details(details, range):
            return .details(
                DetailsBlock(
                    summary: unlinkFootnoteLinks(
                        details.summary,
                        source: source
                    ),
                    blocks: details.blocks.map {
                        unlinkFootnoteLinks($0, source: source)
                    },
                    isOpen: details.isOpen,
                    range: details.range,
                    summaryRange: details.summaryRange
                ),
                range: range
            )
        case let .definitionList(list, range):
            // Definition lists are built before this pass, so their inlines
            // still carry the base parser's link for `[^a]`. Without this
            // case the replacement scanning excludes that link and the
            // definition silently stays outside the footnote.
            let items = list.items.map { item in
                DefinitionList.Item(
                    terms: item.terms.map { term in
                        DefinitionList.Term(
                            inlines: unlinkFootnoteLinks(
                                term.inlines,
                                source: source
                            ),
                            range: term.range
                        )
                    },
                    definitions: item.definitions.map { definition in
                        DefinitionList.Definition(
                            inlines: unlinkFootnoteLinks(
                                definition.inlines,
                                source: source
                            ),
                            range: definition.range
                        )
                    },
                    range: item.range
                )
            }
            return .definitionList(
                DefinitionList(items: items),
                range: range
            )
        default:
            return block
        }
    }

    /// The base parser turns the shortcut reference `[^a]` into a link when
    /// an `[^a]:` definition exists. Only that exact shape is a footnote: an
    /// explicit `[^a](url)` or a full reference `[^a][x]` is the author's
    /// own link and must survive untouched.
    private static func isFootnoteShapedLink(_ slice: String) -> Bool {
        guard slice.hasPrefix("[^"), slice.hasSuffix("]") else {
            return false
        }
        let inner = slice.dropFirst(2).dropLast()
        return !inner.isEmpty
            && !inner.contains("[")
            && !inner.contains("]")
            && !inner.contains("(")
    }

    private static func unlinkFootnoteLinks(
        _ inlines: [Inline],
        source: String
    ) -> [Inline] {
        var result: [Inline] = []
        for inline in inlines {
            switch inline {
            case let .link(_, _, _, range):
                if let range,
                   isFootnoteShapedLink(source.utf16Range(range)) {
                    result.append(
                        .text(source.utf16Range(range), range: range)
                    )
                } else {
                    result.append(inline)
                }
            case let .emphasis(children, range):
                result.append(
                    .emphasis(
                        inlines: unlinkFootnoteLinks(
                            children,
                            source: source
                        ),
                        range: range
                    )
                )
            case let .strong(children, range):
                result.append(
                    .strong(
                        inlines: unlinkFootnoteLinks(
                            children,
                            source: source
                        ),
                        range: range
                    )
                )
            case let .strikethrough(children, range):
                result.append(
                    .strikethrough(
                        inlines: unlinkFootnoteLinks(
                            children,
                            source: source
                        ),
                        range: range
                    )
                )
            case let .image(destination, title, description, range):
                result.append(
                    .image(
                        destination: destination,
                        title: title,
                        description: unlinkFootnoteLinks(
                            description,
                            source: source
                        ),
                        range: range
                    )
                )
            default:
                result.append(inline)
            }
        }
        return result
    }

    private static func unlinkFootnoteLinks(
        _ cell: TableCell,
        source: String
    ) -> TableCell {
        TableCell(
            inlines: unlinkFootnoteLinks(cell.inlines, source: source),
            colspan: cell.colspan,
            rowspan: cell.rowspan,
            range: cell.range
        )
    }

    // MARK: - Hiding and literal fallbacks

    private static func hideDefinitions(
        _ block: Block,
        collector: Collector
    ) -> Block {
        switch block {
        case let .paragraph(_, range):
            guard let range,
                  let definition = collector.definition(at: range),
                  collector.numbers[definition.label] != nil else {
                return block
            }
            return .footnoteDefinition(label: definition.label, range: range)
        case let .blockQuote(children, range):
            return .blockQuote(
                blocks: children.map {
                    hideDefinitions($0, collector: collector)
                },
                range: range
            )
        case let .list(list, range):
            let items = list.items.map { item in
                ListItem(
                    blocks: item.blocks.map {
                        hideDefinitions($0, collector: collector)
                    },
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
                    blocks: details.blocks.map {
                        hideDefinitions($0, collector: collector)
                    },
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

    /// Restores a definition the base parser consumed as a link reference
    /// definition. A definition that is already visible anywhere in the tree
    /// is left alone; a missing one is restored inside the container that
    /// held it, not at the top level.
    private static func insertLiteralDefinitions(
        _ definitions: [FootnoteDefinitionMatch],
        into blocks: [Block],
        collector: Collector
    ) -> [Block] {
        let visible = visibleRanges(in: blocks)
        var result = blocks
        for definition in definitions.sorted(by: {
            $0.span.lowerBound < $1.span.lowerBound
        }) {
            guard !visible.contains(where: {
                $0.contains(offset: definition.span.lowerBound)
            }), let range = collector.sourceRange(definition.span) else {
                continue
            }
            let literal = Block.paragraph(
                inlines: [
                    .text(
                        collector.parsed.source.utf16Range(range),
                        range: range
                    )
                ],
                range: range
            )
            result = inserting(literal, span: range, into: result)
        }
        return result
    }

    /// Source ranges of the blocks the reader actually sees. Containers are
    /// traversed but never counted: a container's range also covers text the
    /// base parser consumed, so counting it made every definition swallowed
    /// inside a quote, list, or details body look visible and suppressed its
    /// restoration. Footnote definitions are hidden in place, not shown in
    /// the body, so they do not count either.
    private static func visibleRanges(in blocks: [Block]) -> [SourceRange] {
        var result: [SourceRange] = []
        func walk(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case let .blockQuote(children, _):
                    walk(children)
                case let .list(list, _):
                    for item in list.items { walk(item.blocks) }
                case let .details(details, _):
                    walk(details.blocks)
                case .footnoteDefinition, .footnotes:
                    break
                default:
                    if let range = block.range { result.append(range) }
                }
            }
        }
        walk(blocks)
        return result
    }

    /// Inserts `literal` into the deepest container whose range covers
    /// `span`. A definition authored inside a details body, a quote, or a
    /// list item belongs there, not outside it.
    private static func inserting(
        _ literal: Block,
        span: SourceRange,
        into blocks: [Block]
    ) -> [Block] {
        var result = blocks
        for index in result.indices {
            switch result[index] {
            case let .blockQuote(children, range):
                guard let range, range.contains(offset: span.lowerBound)
                else { continue }
                return replacing(
                    result,
                    at: index,
                    with: .blockQuote(
                        blocks: inserting(literal, span: span, into: children),
                        range: range
                    )
                )
            case let .list(list, range):
                guard let range, range.contains(offset: span.lowerBound)
                else { continue }
                let items = list.items.map { item -> ListItem in
                    guard let itemRange = item.range,
                          itemRange.contains(offset: span.lowerBound) else {
                        return item
                    }
                    return ListItem(
                        blocks: inserting(
                            literal,
                            span: span,
                            into: item.blocks
                        ),
                        checked: item.checked,
                        range: item.range
                    )
                }
                return replacing(
                    result,
                    at: index,
                    with: .list(
                        ListBlock(kind: list.kind, items: items, tight: list.tight),
                        range: range
                    )
                )
            case let .details(details, range):
                guard let range, range.contains(offset: span.lowerBound)
                else { continue }
                return replacing(
                    result,
                    at: index,
                    with: .details(
                        DetailsBlock(
                            summary: details.summary,
                            blocks: inserting(
                                literal,
                                span: span,
                                into: details.blocks
                            ),
                            isOpen: details.isOpen,
                            range: details.range,
                            summaryRange: details.summaryRange
                        ),
                        range: range
                    )
                )
            default:
                continue
            }
        }
        let insertion = result.firstIndex { block in
            guard let blockRange = block.range else { return false }
            return blockRange.lowerBound > span.lowerBound
        } ?? result.endIndex
        result.insert(literal, at: insertion)
        return result
    }

    private static func replacing(
        _ blocks: [Block],
        at index: Int,
        with block: Block
    ) -> [Block] {
        var result = blocks
        result[index] = block
        return result
    }

    private static func codeAndHTMLSpans(in blocks: [Block]) -> [SourceRange] {
        var result: [SourceRange] = []
        func walk(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case let .codeBlock(_, range), let .htmlBlock(_, range):
                    if let range { result.append(range) }
                case let .blockQuote(children, _):
                    walk(children)
                case let .list(list, _):
                    for item in list.items { walk(item.blocks) }
                case let .details(details, _):
                    walk(details.blocks)
                default:
                    break
                }
            }
        }
        walk(blocks)
        return result
    }

    /// Drops the link reference definitions the base parser derived from
    /// footnote syntax; a `[^label]:` line is a footnote, not a link target.
    private static func withoutFootnoteDefinitions(
        in ast: SonovoAST
    ) -> [ReferenceDefinition] {
        ast.referenceDefinitions.filter { definition in
            guard let normalized = FootnoteScanner.normalize(
                definition.label
            ) else {
                return true
            }
            return !normalized.hasPrefix("^")
        }
    }

    // MARK: - State

    /// Numbering and reference collection for one augmentation pass.
    private final class Collector {
        let parsed: ParsedMarkdown
        let definitions: [String: FootnoteDefinitionMatch]
        private let definitionByStart: [Int: FootnoteDefinitionMatch]
        private(set) var numbers: [String: Int] = [:]
        private var referenceRanges: [String: [SourceRange]] = [:]
        private var nextNumber = 1

        init(
            parsed: ParsedMarkdown,
            definitions: [String: FootnoteDefinitionMatch]
        ) {
            self.parsed = parsed
            self.definitions = definitions
            var byStart: [Int: FootnoteDefinitionMatch] = [:]
            for definition in definitions.values {
                byStart[definition.span.lowerBound] = definition
            }
            definitionByStart = byStart
        }

        func resolves(_ match: FootnoteReferenceMatch) -> Bool {
            definitions[match.label] != nil
        }

        func definition(at range: SourceRange) -> FootnoteDefinitionMatch? {
            definitionByStart[range.lowerBound]
        }

        func makeInline(_ match: FootnoteReferenceMatch) -> Inline {
            let number: Int
            if let existing = numbers[match.label] {
                number = existing
            } else {
                number = nextNumber
                nextNumber += 1
                numbers[match.label] = number
            }
            let range = sourceRange(match.range)
            if let range {
                referenceRanges[match.label, default: []].append(range)
            }
            return .footnoteReference(
                FootnoteReference(label: match.label, number: number),
                range: range
            )
        }

        func entries(parsed: ParsedMarkdown) -> [FootnoteEntry] {
            numbers
                .sorted { $0.value < $1.value }
                .compactMap { label, number in
                    guard let definition = definitions[label] else {
                        return nil
                    }
                    let contentRange = sourceRange(definition.contentRange)
                        ?? sourceRange(definition.span)
                    guard let contentRange else { return nil }
                    let inlines = parsed.fullSourceMap.position(
                        atUTF16Offset: definition.contentRange.lowerBound
                    ).map { start in
                        InlineFragmentParser.parse(
                            definition.content(in: parsed.source),
                            baseLine: start.line,
                            baseOffset: definition.contentRange.lowerBound,
                            baseColumn: start.column,
                            referenceDefinitions: parsed.ast
                                .referenceDefinitions
                        )
                    } ?? []
                    return FootnoteEntry(
                        number: number,
                        label: label,
                        inlines: inlines,
                        contentRange: contentRange,
                        referenceRanges: referenceRanges[label] ?? []
                    )
                }
        }

        func sourceRange(_ range: Range<Int>) -> SourceRange? {
            guard
                let start = parsed.fullSourceMap.position(
                    atUTF16Offset: range.lowerBound
                ),
                let end = parsed.fullSourceMap.position(
                    atUTF16Offset: range.upperBound
                )
            else {
                return nil
            }
            return SourceRange(start: start, end: end)
        }
    }
}
