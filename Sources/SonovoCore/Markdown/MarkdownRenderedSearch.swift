import Foundation

/// One match in the rendered reading view. The block index is the top-level
/// block in the AST; the location is a character offset inside that block's
/// rendered text.
public struct MarkdownRenderedMatch: Sendable, Equatable, Identifiable {
    public let id: Int
    public let blockIndex: Int
    public let location: Int
    public let length: Int
    public let preview: String

    public init(
        id: Int,
        blockIndex: Int,
        location: Int,
        length: Int,
        preview: String
    ) {
        self.id = id
        self.blockIndex = blockIndex
        self.location = location
        self.length = length
        self.preview = preview
    }
}

/// Rendered-view search over the same AST the reader sees.
///
/// The source find bar remains the source editor's surface; this model gives
/// the reading view its own matches without a second parser.
public enum MarkdownRenderedSearch {
    public static let defaultLimit = 500

    /// The rendered text of each top-level block, in document order.
    public static func blocks(_ ast: SonovoAST) -> [String] {
        ast.blocks.map { text(of: $0) }
    }

    public static func matches(
        query: String,
        blocks: [String],
        caseSensitive: Bool = false,
        limit: Int = defaultLimit
    ) -> [MarkdownRenderedMatch] {
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = caseSensitive
            ? []
            : [.caseInsensitive]
        var result: [MarkdownRenderedMatch] = []
        for (blockIndex, text) in blocks.enumerated() {
            var searchStart = text.startIndex
            while searchStart < text.endIndex, result.count < limit {
                guard let range = text.range(
                    of: query,
                    options: options,
                    range: searchStart..<text.endIndex
                ) else {
                    break
                }
                let location = text.distance(
                    from: text.startIndex,
                    to: range.lowerBound
                )
                let length = text.distance(
                    from: range.lowerBound,
                    to: range.upperBound
                )
                result.append(
                    MarkdownRenderedMatch(
                        id: result.count,
                        blockIndex: blockIndex,
                        location: location,
                        length: length,
                        preview: preview(text, range: range)
                    )
                )
                searchStart = range.upperBound
            }
            if result.count >= limit { break }
        }
        return result
    }

    private static func preview(
        _ text: String,
        range: Range<String.Index>
    ) -> String {
        let before = text.index(
            text.startIndex,
            offsetBy: max(0, text.distance(
                from: text.startIndex,
                to: range.lowerBound
            ) - 20)
        )
        let after = text.index(
            range.upperBound,
            offsetBy: min(
                20,
                text.distance(from: range.upperBound, to: text.endIndex)
            )
        )
        return text[before..<after]
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func text(of block: Block) -> String {
        switch block {
        case .paragraph(let inlines, _),
             .heading(_, let inlines, _):
            return HeadingIndex.renderedText(inlines)
        case .blockQuote(let children, _):
            return children.map(text(of:)).joined(separator: "\n")
        case .list(let list, _):
            return list.items
                .map { item in
                    item.blocks.map(text(of:)).joined(separator: "\n")
                }
                .joined(separator: "\n")
        case .codeBlock(let code, _):
            return code.code
        case .table(let table, _):
            let header = table.header.map {
                HeadingIndex.renderedText($0.inlines)
            }
            let rows = table.rows.map { row in
                row.map { HeadingIndex.renderedText($0.inlines) }
                    .joined(separator: " ")
            }
            return (header.joined(separator: " ") + " " + rows.joined(separator: " "))
                .trimmingCharacters(in: .whitespaces)
        case .details(let details, _):
            return (
                [HeadingIndex.renderedText(details.summary)]
                    + details.blocks.map(text(of:))
            ).joined(separator: "\n")
        default:
            return ""
        }
    }
}
