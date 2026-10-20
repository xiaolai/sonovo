import Foundation

/// The owned Markdown tree the editor and viewer render.
///
/// The tree is value-typed and `Sendable`. It is derived from `swift-markdown`
/// and then augmented with Sonovo's custom syntax. The source string is never
/// stored in the tree; every node that has a position carries a `SourceRange`
/// into the canonical source, and a node without a valid upstream position
/// carries `nil`.
public struct SonovoAST: Sendable, Equatable {
    /// Top-level blocks in document order.
    public var blocks: [Block]

    /// Leading YAML frontmatter, preserved verbatim.
    public var frontmatter: Frontmatter?

    /// Reference definitions found in the document.
    ///
    /// `swift-markdown` resolves references and does not expose the labels, so
    /// this list is populated by the source scanner when it is needed.
    public var referenceDefinitions: [ReferenceDefinition]

    public init(
        blocks: [Block] = [],
        frontmatter: Frontmatter? = nil,
        referenceDefinitions: [ReferenceDefinition] = []
    ) {
        self.blocks = blocks
        self.frontmatter = frontmatter
        self.referenceDefinitions = referenceDefinitions
    }
}

/// Leading YAML frontmatter. The raw text includes the delimiters.
public struct Frontmatter: Sendable, Equatable {
    public let raw: String
    public let body: String
    public let range: SourceRange

    public init(raw: String, body: String, range: SourceRange) {
        self.raw = raw
        self.body = body
        self.range = range
    }
}

/// A Markdown link reference definition.
public struct ReferenceDefinition: Sendable, Equatable {
    public let label: String
    public let destination: String
    public let title: String?
    public let range: SourceRange?

    public init(label: String, destination: String, title: String?, range: SourceRange?) {
        self.label = label
        self.destination = destination
        self.title = title
        self.range = range
    }
}

// MARK: - Blocks

/// A block-level Markdown node.
public indirect enum Block: Sendable, Equatable {
    case paragraph(inlines: [Inline], range: SourceRange?)
    case heading(level: Int, inlines: [Inline], range: SourceRange?)
    case blockQuote(blocks: [Block], range: SourceRange?)
    case list(ListBlock, range: SourceRange?)
    case codeBlock(CodeBlock, range: SourceRange?)
    case htmlBlock(raw: String, range: SourceRange?)
    case thematicBreak(range: SourceRange?)
    case table(TableBlock, range: SourceRange?)
    case details(DetailsBlock, range: SourceRange?)
    case tableOfContents(range: SourceRange?)

    /// The source range, when upstream reported one.
    public var range: SourceRange? {
        switch self {
        case .paragraph(_, let range),
             .heading(_, _, let range),
             .blockQuote(_, let range),
             .list(_, let range),
             .codeBlock(_, let range),
             .htmlBlock(_, let range),
             .thematicBreak(let range),
             .table(_, let range),
             .details(_, let range),
             .tableOfContents(let range):
            return range
        }
    }
}

/// A bullet or ordered list.
public struct ListBlock: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case bullet
        case ordered(start: Int)
    }

    public let kind: Kind
    public let items: [ListItem]

    /// Whether the list is tight. Derived from the source when available.
    public let tight: Bool?

    public init(kind: Kind, items: [ListItem], tight: Bool? = nil) {
        self.kind = kind
        self.items = items
        self.tight = tight
    }
}

/// One list item. `checked` is non-nil only for GFM task-list items.
public struct ListItem: Sendable, Equatable {
    public let blocks: [Block]
    public let checked: Bool?
    public let range: SourceRange?

    public init(blocks: [Block], checked: Bool?, range: SourceRange?) {
        self.blocks = blocks
        self.checked = checked
        self.range = range
    }
}

/// A fenced or indented code block.
public struct CodeBlock: Sendable, Equatable {
    public let code: String
    public let language: String?
    public let fenced: Bool
    public let info: String?

    public init(code: String, language: String?, fenced: Bool, info: String?) {
        self.code = code
        self.language = language
        self.fenced = fenced
        self.info = info
    }
}

/// GFM table content.
public struct TableBlock: Sendable, Equatable {
    public enum Alignment: String, Sendable, Equatable {
        case none
        case left
        case center
        case right
    }

    public let header: [TableCell]
    public let rows: [[TableCell]]
    public let alignments: [Alignment]

    public init(header: [TableCell], rows: [[TableCell]], alignments: [Alignment]) {
        self.header = header
        self.rows = rows
        self.alignments = alignments
    }
}

/// One table cell.
public struct TableCell: Sendable, Equatable {
    public let inlines: [Inline]
    public let colspan: Int
    public let rowspan: Int
    public let range: SourceRange?

    public init(inlines: [Inline], colspan: Int, rowspan: Int, range: SourceRange?) {
        self.inlines = inlines
        self.colspan = colspan
        self.rowspan = rowspan
        self.range = range
    }
}

/// A `<details>` block. The body is ordinary Markdown.
public struct DetailsBlock: Sendable, Equatable {
    public let summary: [Inline]
    public let blocks: [Block]
    public let isOpen: Bool
    public let range: SourceRange?
    /// The raw range of the summary content, used to scan it for wiki links.
    public let summaryRange: SourceRange?

    public init(
        summary: [Inline],
        blocks: [Block],
        isOpen: Bool,
        range: SourceRange?,
        summaryRange: SourceRange? = nil
    ) {
        self.summary = summary
        self.blocks = blocks
        self.isOpen = isOpen
        self.range = range
        self.summaryRange = summaryRange
    }
}

// MARK: - Inlines

/// An inline-level Markdown node.
public indirect enum Inline: Sendable, Equatable {
    case text(String, range: SourceRange?)
    case softBreak(range: SourceRange?)
    case lineBreak(range: SourceRange?)
    case inlineCode(String, range: SourceRange?)
    case emphasis(inlines: [Inline], range: SourceRange?)
    case strong(inlines: [Inline], range: SourceRange?)
    case strikethrough(inlines: [Inline], range: SourceRange?)
    case link(destination: String, title: String?, inlines: [Inline], range: SourceRange?)
    case image(destination: String, title: String?, description: [Inline], range: SourceRange?)
    case inlineHTML(String, range: SourceRange?)
    case wikiLink(WikiLink, range: SourceRange?)

    /// The source range, when upstream reported one.
    public var range: SourceRange? {
        switch self {
        case .text(_, let range),
             .softBreak(let range),
             .lineBreak(let range),
             .inlineCode(_, let range),
             .emphasis(_, let range),
             .strong(_, let range),
             .strikethrough(_, let range),
             .link(_, _, _, let range),
             .image(_, _, _, let range),
             .inlineHTML(_, let range),
             .wikiLink(_, let range):
            return range
        }
    }
}

/// A `[[target|alias]]` link.
public struct WikiLink: Sendable, Equatable {
    /// The path part of the target, before any `#` fragment.
    public let target: String

    /// The heading fragment after `#`, without the `#`.
    public let fragment: String?

    /// The alias as authored, trimmed. `nil` when no `|` alias was written.
    public let alias: String?

    public init(target: String, fragment: String?, alias: String?) {
        self.target = target
        self.fragment = fragment
        self.alias = alias
    }

    /// The text shown to the reader: the alias when present, otherwise the
    /// target exactly as authored (including its fragment).
    public var display: String {
        alias ?? targetWithFragment
    }

    /// The target including its fragment.
    public var targetWithFragment: String {
        if let fragment {
            return "\(target)#\(fragment)"
        }
        return target
    }
}
