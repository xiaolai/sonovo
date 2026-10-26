import Foundation

/// Exact position mapping between the source and rendered surfaces.
///
/// Scroll sync is only useful when the two surfaces agree on what is under
/// the viewport. A nearest-neighbour guess would jump a reader somewhere they
/// did not ask to go, so every mapping here refuses instead of falling back:
/// an offset outside every block, or a rendered anchor that no longer names
/// the same block and kind, returns `nil`.
public enum MarkdownSplitSync {
    /// The top-level block whose source range contains `offset`.
    ///
    /// Block ranges are half-open: an offset at a block's end belongs to the
    /// next block, or to no block when only whitespace follows.
    public static func renderedBlockIndex(
        forSourceOffset offset: Int,
        in blocks: [Block]
    ) -> Int? {
        for (index, block) in blocks.enumerated() {
            guard let range = block.range else { continue }
            if range.lowerBound <= offset, offset < range.upperBound {
                return index
            }
        }
        return nil
    }

    /// The source offset of the block a rendered anchor names exactly.
    ///
    /// The rendered anchor already carries the block's start offset and kind;
    /// both must still match the current tree. A reparse that moved or
    /// retyped the block refuses rather than syncing to a different one.
    public static func sourceOffset(
        for anchor: RenderedReadingAnchor,
        in blocks: [Block]
    ) -> Int? {
        guard let index = ReadingAnchorResolver.renderedBlockIndex(
            for: anchor,
            in: blocks
        ), let range = blocks[index].range,
           range.lowerBound == anchor.blockOffset,
           ReadingBlockKind(blocks[index]) == anchor.blockKind else {
            return nil
        }
        return range.lowerBound
    }

    /// The scroll ID the rendered viewer assigned to a top-level block.
    ///
    /// Headings use their slug-based ID; every other block uses its index.
    /// This mirrors `MarkdownViewer.blockAnchor` so a sync target lands on the
    /// same view the viewer would scroll to for that block.
    public static func renderedScrollAnchor(
        forBlockIndex index: Int,
        in blocks: [Block],
        headings: [HeadingEntry]
    ) -> String? {
        guard blocks.indices.contains(index),
              let range = blocks[index].range else {
            return nil
        }
        if case .heading = blocks[index],
           let heading = headings.first(where: {
               $0.range?.lowerBound == range.lowerBound
           }),
           let scrollID = heading.scrollID {
            return scrollID
        }
        return "block-\(index)"
    }
}
