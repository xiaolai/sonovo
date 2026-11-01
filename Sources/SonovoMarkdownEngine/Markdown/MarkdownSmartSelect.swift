import Foundation

/// Cmd+A expansion: one container at a time, ending at the document.
///
/// The expansion is computed from the current selection, so no stack is kept
/// and no undo entry is created. A content edit moves the caret, which
/// restarts the expansion at the innermost container.
public enum MarkdownSmartSelect {
    public static func next(
        source: String,
        selection: Range<Int>,
        ast: SonovoAST
    ) -> Range<Int>? {
        let ns = source as NSString
        guard selection.lowerBound >= 0,
              selection.upperBound <= ns.length,
              selection.lowerBound <= selection.upperBound else {
            return nil
        }
        let document = 0..<ns.length
        var candidates: [Range<Int>] = []

        if let table = MarkdownTableScanner.table(
            at: selection.lowerBound,
            in: source
        ), table.isValid {
            if let cell = cell(at: selection.lowerBound, in: table) {
                let lower = cell.segmentRange.lowerBound
                let upper = cell.segmentRange.upperBound
                candidates.append(lower..<upper)
            }
            if let row = row(at: selection.lowerBound, in: table) {
                candidates.append(
                    row.range.lowerBound..<row.range.upperBound
                )
            }
            candidates.append(
                table.range.lowerBound..<table.range.upperBound
            )
        }

        var containing: [Range<Int>] = []
        collectContaining(
            blocks: ast.blocks,
            offset: selection.lowerBound,
            documentEnd: ns.length,
            into: &containing
        )
        containing.sort {
            if $0.count != $1.count { return $0.count < $1.count }
            return $0.lowerBound < $1.lowerBound
        }
        for range in containing {
            if !candidates.contains(range) {
                candidates.append(range)
            }
        }
        if !candidates.contains(document) {
            candidates.append(document)
        }

        if selection.isEmpty {
            return candidates.first {
                $0.count > 0
            }
        }
        return candidates.first {
            $0.lowerBound <= selection.lowerBound
                && selection.upperBound <= $0.upperBound
                && $0 != selection
                && $0.count > selection.count
        }
    }

    private static func cell(
        at offset: Int,
        in table: MarkdownTable
    ) -> MarkdownTable.Cell? {
        for row in [table.header] + table.body {
            if let cell = row.cells.first(where: {
                offset >= $0.segmentRange.lowerBound
                    && offset <= $0.segmentRange.upperBound
            }) {
                return cell
            }
        }
        return nil
    }

    private static func row(
        at offset: Int,
        in table: MarkdownTable
    ) -> MarkdownTable.Row? {
        ([table.header] + table.body).first {
            offset >= $0.range.lowerBound && offset <= $0.range.upperBound
        }
    }

    private static func collectContaining(
        blocks: [Block],
        offset: Int,
        documentEnd: Int,
        into ranges: inout [Range<Int>]
    ) {
        for block in blocks {
            // Half-open: an offset exactly at a block's end belongs to the
            // next block, not the one that just ended. The document's own
            // end stays inside the final block.
            guard let range = block.range,
                  offset >= range.lowerBound,
                  offset < range.upperBound
                    || (offset == range.upperBound
                        && range.upperBound == documentEnd) else {
                continue
            }
            ranges.append(range.lowerBound..<range.upperBound)
            switch block {
            case .blockQuote(let children, _):
                collectContaining(
                    blocks: children,
                    offset: offset,
                    documentEnd: documentEnd,
                    into: &ranges
                )
            case .list(let list, _):
                for item in list.items {
                    collectContaining(
                        blocks: item.blocks,
                        offset: offset,
                        documentEnd: documentEnd,
                        into: &ranges
                    )
                }
            case .details(let details, _):
                collectContaining(
                    blocks: details.blocks,
                    offset: offset,
                    documentEnd: documentEnd,
                    into: &ranges
                )
            default:
                break
            }
        }
    }
}
