import Foundation

/// The position a reader left on the source surface.
///
/// The anchor is the visible line's first UTF-16 offset plus how many points
/// of that line sat above the viewport's top edge. A line number alone would
/// drift after an edit above the reader; an offset plus a clamped restore
/// degrades into the nearest preceding line instead.
public struct SourceReadingAnchor: Sendable, Equatable {
    public let lineOffset: Int
    /// Points of the anchor line above the viewport top. May be negative when
    /// the line starts below the top edge.
    public let viewportOffset: Double
    public let selection: Range<Int>?

    public init(
        lineOffset: Int,
        viewportOffset: Double,
        selection: Range<Int>? = nil
    ) {
        self.lineOffset = max(0, lineOffset)
        self.viewportOffset = viewportOffset.isFinite ? viewportOffset : 0
        self.selection = selection
    }
}

/// The top-level block a reader left at the rendered surface's top edge.
public struct RenderedReadingAnchor: Sendable, Equatable {
    /// UTF-16 source offset where the block starts.
    public let blockOffset: Int
    public let blockKind: ReadingBlockKind
    /// How far into the block the viewport top sits, 0...1.
    public let fraction: Double

    public init(
        blockOffset: Int,
        blockKind: ReadingBlockKind,
        fraction: Double
    ) {
        self.blockOffset = max(0, blockOffset)
        self.blockKind = blockKind
        self.fraction = ReadingAnchorResolver.clampedFraction(fraction)
    }
}

/// The top-level block kinds a rendered anchor can name.
public enum ReadingBlockKind: String, Sendable, Equatable {
    case paragraph
    case heading
    case blockQuote
    case list
    case codeBlock
    case htmlBlock
    case thematicBreak
    case table
    case definitionList
    case details
    case tableOfContents
    case footnoteDefinition
    case footnotes

    public init(_ block: Block) {
        switch block {
        case .paragraph: self = .paragraph
        case .heading: self = .heading
        case .blockQuote: self = .blockQuote
        case .list: self = .list
        case .codeBlock: self = .codeBlock
        case .htmlBlock: self = .htmlBlock
        case .thematicBreak: self = .thematicBreak
        case .table: self = .table
        case .definitionList: self = .definitionList
        case .details: self = .details
        case .tableOfContents: self = .tableOfContents
        case .footnoteDefinition: self = .footnoteDefinition
        case .footnotes: self = .footnotes
        }
    }
}

/// Resolves a stored anchor against the current document.
///
/// A reload can move, replace, or delete the node an anchor names. Both
/// resolvers degrade to the nearest preceding line or block by source offset,
/// and to the start when nothing precedes it.
public enum ReadingAnchorResolver {
    public static func sourceLineStart(
        for anchor: SourceReadingAnchor,
        in source: String
    ) -> Int? {
        let ns = source as NSString
        guard ns.length > 0 else { return nil }
        // A stored offset at the end of the document is the final empty
        // line; clamping to length - 1 folded it back to an earlier line.
        var index = min(max(anchor.lineOffset, 0), ns.length)
        while index > 0, ns.character(at: index - 1) != 0x0A {
            index -= 1
        }
        return index
    }

    public static func renderedBlockIndex(
        for anchor: RenderedReadingAnchor,
        in blocks: [Block]
    ) -> Int? {
        guard !blocks.isEmpty else { return nil }
        var preceding: Int?
        for (index, block) in blocks.enumerated() {
            guard let range = block.range else { continue }
            if range.lowerBound == anchor.blockOffset,
               ReadingBlockKind(block) == anchor.blockKind {
                return index
            }
            if range.lowerBound <= anchor.blockOffset {
                preceding = index
            }
        }
        return preceding ?? 0
    }

    public static func clampedFraction(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }
}
