import Foundation

/// What the caret is inside, computed from the latest parsed tree and the
/// canonical source.
///
/// The context is a pure value. It is recomputed from a revision-stamped parse;
/// it never guesses a range that the tree did not provide.
public struct MarkdownCursorContext: Sendable, Equatable {
    public enum BlockKind: String, Sendable, Equatable {
        case paragraph
        case heading
        case blockQuote
        case list
        case codeBlock
        case htmlBlock
        case thematicBreak
        case table
        case details
        case tableOfContents
    }

    public struct TableContext: Sendable, Equatable {
        public let tableRange: SourceRange
        /// 0 is the header; 1... are body rows.
        public let rowIndex: Int
        public let rowRange: SourceRange
        public let column: Int
        /// The trimmed content range.
        public let cellRange: SourceRange
        /// The untrimmed segment between separators.
        public let segmentRange: SourceRange
        public let isValid: Bool
    }

    public struct ListContext: Sendable, Equatable {
        /// 1 for a top-level list, 2 for a nested list, and so on.
        public let depth: Int
        public let markerRange: SourceRange?
    }

    public struct LinkContext: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case link
            case image
            case wikiLink
        }

        public let kind: Kind
        public let range: SourceRange
        /// The parser-resolved destination for an inline link or image: the
        /// escapes and character references are already decoded. The popover
        /// must show the same value the reader opens, so it reads this
        /// instead of decoding the raw slice itself.
        public let destination: String?
        public let title: String?
    }

    public let offset: Int
    public let topLevelBlockIndex: Int?
    public let block: BlockKind?
    public let headingLevel: Int?
    public let table: TableContext?
    public let list: ListContext?
    public let blockQuoteDepth: Int
    public let codeFence: SourceRange?
    public let codeLanguage: String?
    public let link: LinkContext?
    public let frontmatterRange: SourceRange?

    private init(
        offset: Int,
        topLevelBlockIndex: Int?,
        block: BlockKind?,
        headingLevel: Int?,
        table: TableContext?,
        list: ListContext?,
        blockQuoteDepth: Int,
        codeFence: SourceRange?,
        codeLanguage: String?,
        link: LinkContext?,
        frontmatterRange: SourceRange?
    ) {
        self.offset = offset
        self.topLevelBlockIndex = topLevelBlockIndex
        self.block = block
        self.headingLevel = headingLevel
        self.table = table
        self.list = list
        self.blockQuoteDepth = blockQuoteDepth
        self.codeFence = codeFence
        self.codeLanguage = codeLanguage
        self.link = link
        self.frontmatterRange = frontmatterRange
    }

    /// The context at a UTF-16 offset in canonical source.
    public static func at(
        offset: Int,
        in ast: SonovoAST,
        source: String
    ) -> MarkdownCursorContext {
        let length = (source as NSString).length
        let clamped = min(max(offset, 0), length)
        var builder = Builder(offset: clamped, source: source)
        builder.frontmatterRange = ast.frontmatter?.range

        for (index, block) in ast.blocks.enumerated() {
            guard let range = block.range else { continue }
            let isLast = index == ast.blocks.count - 1
            let contains = range.contains(offset: clamped)
                || clamped == range.lowerBound
                || (isLast && clamped == range.upperBound)
            if contains {
                builder.topLevelBlockIndex = index
                builder.inspect(block)
                break
            }
        }
        return builder.context
    }
}

private extension MarkdownCursorContext {
    struct Builder {
        let offset: Int
        let source: NSString
        var topLevelBlockIndex: Int?
        var block: BlockKind?
        var headingLevel: Int?
        var table: TableContext?
        var listDepth = 0
        var blockQuoteDepth = 0
        var codeFence: SourceRange?
        var codeLanguage: String?
        var link: LinkContext?
        var frontmatterRange: SourceRange?

        init(offset: Int, source: String) {
            self.offset = offset
            self.source = source as NSString
        }

        var context: MarkdownCursorContext {
            MarkdownCursorContext(
                offset: offset,
                topLevelBlockIndex: topLevelBlockIndex,
                block: block,
                headingLevel: headingLevel,
                table: table,
                list: listDepth > 0
                    ? ListContext(depth: listDepth, markerRange: listMarker())
                    : nil,
                blockQuoteDepth: blockQuoteDepth,
                codeFence: codeFence,
                codeLanguage: codeLanguage,
                link: link,
                frontmatterRange: frontmatterRange
            )
        }

        mutating func inspect(_ block: Block) {
            switch block {
            case .paragraph(let inlines, _):
                set(.paragraph)
                inspect(inlines)
            case .heading(let level, let inlines, _):
                set(.heading)
                headingLevel = level
                inspect(inlines)
            case .blockQuote(let blocks, _):
                blockQuoteDepth += 1
                set(.blockQuote)
                for child in blocks where blockContains(child) {
                    inspect(child)
                }
            case .list(let list, _):
                listDepth += 1
                set(.list)
                for item in list.items where itemContains(item) {
                    for child in item.blocks where blockContains(child) {
                        inspect(child)
                    }
                }
            case .codeBlock(let code, let range):
                set(.codeBlock)
                codeFence = range
                codeLanguage = code.language
            case .htmlBlock(_, _):
                set(.htmlBlock)
            case .thematicBreak(_):
                set(.thematicBreak)
            case .table(let table, let range):
                set(.table)
                self.table = tableContext(table, range: range)
                for cell in table.header { inspect(cell.inlines) }
                for row in table.rows {
                    for cell in row { inspect(cell.inlines) }
                }
            case let .definitionList(list, _):
                set(.paragraph)
                for item in list.items where containsCaret(item.range) {
                    for term in item.terms where containsCaret(term.range) {
                        inspect(term.inlines)
                    }
                    for definition in item.definitions
                        where containsCaret(definition.range) {
                        inspect(definition.inlines)
                    }
                }
            case .details(let details, _):
                set(.details)
                if let summaryRange = details.summaryRange,
                   containsCaret(summaryRange) {
                    inspect(details.summary)
                } else {
                    for child in details.blocks where blockContains(child) {
                        inspect(child)
                    }
                }
            case .tableOfContents(_):
                set(.tableOfContents)
            case .footnoteDefinition(_, _):
                set(.paragraph)
            case .footnotes(_, _):
                set(.paragraph)
            }
        }

        mutating func inspect(_ inlines: [Inline]) {
            for inline in inlines {
                guard let range = inline.range, containsCaret(range) else {
                    continue
                }
                switch inline {
                case .link(let destination, let title, let children, _):
                    link = LinkContext(
                        kind: .link,
                        range: range,
                        destination: destination,
                        title: title
                    )
                    inspect(children)
                case .image(let destination, let title, let description, _):
                    link = LinkContext(
                        kind: .image,
                        range: range,
                        destination: destination,
                        title: title
                    )
                    inspect(description)
                case .wikiLink(_, _):
                    link = LinkContext(
                        kind: .wikiLink,
                        range: range,
                        destination: nil,
                        title: nil
                    )
                case .footnoteReference(_, _):
                    break
                case .emphasis(let children, _),
                     .strong(let children, _),
                     .strikethrough(let children, _):
                    inspect(children)
                default:
                    break
                }
            }
        }

        private mutating func set(_ kind: BlockKind) {
            block = kind
        }

        private func itemContains(_ item: ListItem) -> Bool {
            guard let range = item.range else { return false }
            return containsCaret(range)
        }

        /// Only the child that contains the caret may contribute a more
        /// specific block kind or depth. Inspecting siblings makes a heading
        /// inside a quote report the following paragraph.
        private func blockContains(_ block: Block) -> Bool {
            guard let range = block.range else { return false }
            return containsCaret(range)
        }

        /// A caret at a node's upper bound still belongs to that node when
        /// only trailing whitespace follows it. Without this rule the deepest
        /// container is lost at the end of the document: the top level
        /// accepts the last block's upper bound, but the child that ends
        /// there does not, so `> # Head` at EOF would report a quote with no
        /// heading level.
        private func containsCaret(_ range: SourceRange) -> Bool {
            if range.contains(offset: offset) { return true }
            guard offset == range.upperBound else { return false }
            var index = offset
            while index < source.length {
                let character = source.character(at: index)
                if character != 0x0A, character != 0x0D,
                   character != 0x20, character != 0x09 {
                    return false
                }
                index += 1
            }
            return true
        }

        private func tableContext(
            _ table: TableBlock,
            range: SourceRange?
        ) -> TableContext? {
            guard let range,
                  let scanned = MarkdownTableScanner.table(at: offset, in: source as String)
            else {
                return nil
            }
            let row: MarkdownTable.Row?
            if scanned.header.range.contains(offset: offset) {
                row = scanned.header
            } else {
                row = scanned.body.first { $0.range.contains(offset: offset) }
            }
            guard let row else { return nil }
            let cell = row.cells.first { $0.segmentRange.contains(offset: offset) }
                ?? row.cells.last { $0.segmentRange.upperBound <= offset }
                ?? row.cells.first
            guard let cell else { return nil }
            return TableContext(
                tableRange: range,
                rowIndex: row.index,
                rowRange: row.range,
                column: cell.column,
                cellRange: cell.range,
                segmentRange: cell.segmentRange,
                isValid: scanned.isValid
            )
        }

        /// The first marker on the caret's line, if it looks like a list
        /// marker. The marker range is a hint for commands; it is not a
        /// parsed node.
        private func listMarker() -> SourceRange? {
            var lineStart = offset
            while lineStart > 0, source.character(at: lineStart - 1) != 0x0A {
                lineStart -= 1
            }
            var index = lineStart
            while index < source.length, source.character(at: index) == 0x20
                    || source.character(at: index) == 0x09 {
                index += 1
            }
            guard index < source.length else { return nil }
            let markerStart = index
            let first = source.character(at: index)
            if first == 0x2D || first == 0x2A || first == 0x2B {
                index += 1
            } else if first >= 0x30, first <= 0x39 {
                while index < source.length,
                      source.character(at: index) >= 0x30,
                      source.character(at: index) <= 0x39 {
                    index += 1
                }
                guard index < source.length else { return nil }
                let punctuation = source.character(at: index)
                guard punctuation == 0x2E || punctuation == 0x29 else {
                    return nil
                }
                index += 1
            } else {
                return nil
            }
            guard index < source.length,
                  source.character(at: index) == 0x20
                    || source.character(at: index) == 0x09 else {
                return nil
            }
            let line = lineNumber(at: markerStart)
            return SourceRange(
                start: SourcePosition(
                    line: line,
                    column: markerStart - lineStart,
                    offset: markerStart
                ),
                end: SourcePosition(
                    line: line,
                    column: index - lineStart,
                    offset: index
                )
            )
        }

        private func lineNumber(at offset: Int) -> Int {
            var line = 1
            var index = 0
            while index < offset && index < source.length {
                if source.character(at: index) == 0x0A { line += 1 }
                index += 1
            }
            return line
        }
    }
}
