import Foundation

/// Finds CommonMark link reference definitions in the source.
///
/// `swift-markdown` resolves references and drops the definitions from the
/// tree, so the scanner recovers them for the document model and for the
/// document-end range. It is intentionally conservative: a match inside a code
/// or HTML block is discarded by the caller.
enum ReferenceDefinitionScanner {
    // A definition can sit inside a blockquote or a list item. Allow the
    // container markers that can precede it on the line; the label and
    // destination groups still start at the definition itself.
    // A continuation line must contain a non-whitespace character: a
    // whitespace-only line is blank, and a label cannot cross one. Rejecting
    // such a match after the fact would consume the following definition.
    private static let pattern = #"(?m)^(?:[ \t>]|(?:[-*+]|[0-9]{1,9}[.)])(?=[ \t]))*+[ \t]*+\[((?:\\.|[^\]\\\n])+(?:(?=\n[ \t]*(?:\\.|[^ \t\n\]\\]))\n(?:\\.|[^\]\\\n])+)*)\]:[ \t]*(?:\n[ \t>]*)?(<[^>\n]*>|[^ \t\n]+)(?:[ \t]*(?:\n[ \t>]*)?(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|\(((?:\\.|[^)\\])*)\)))?[ \t]*$"#

    private static let regex = try! NSRegularExpression(pattern: pattern)

    static func scan(
        _ source: String,
        sourceMap: SourceMap,
        excluding excludedRanges: [SourceRange]
    ) -> [ReferenceDefinition] {
        // Most documents have no definitions; skip the regex entirely.
        guard source.contains("]:") else { return [] }
        let ns = source as NSString
        let matches = regex.matches(
            in: source,
            range: NSRange(location: 0, length: ns.length)
        )

        var definitions: [ReferenceDefinition] = []
        for match in matches {
            let fullRange = match.range

            // Regex ranges already are UTF-16 offsets.
            guard
                let start = sourceMap.position(atUTF16Offset: fullRange.location),
                let end = sourceMap.position(
                    atUTF16Offset: fullRange.location + fullRange.length
                )
            else {
                continue
            }
            let range = SourceRange(start: start, end: end)

            if excludedRanges.contains(where: {
                $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound
            }) {
                continue
            }

            // A label cannot span a blank line; a match that does is not a
            // definition.
            let rawLabel = ns.substring(with: match.range(at: 1))
            if rawLabel.range(
                of: "\\n\\s*\\n",
                options: .regularExpression
            ) != nil {
                continue
            }

            // Strip `>` continuation markers only when the definition itself
            // is inside a blockquote. A top-level label can contain `>`.
            let full = ns.substring(with: match.range)
            let labelOffset = match.range(at: 1).location
                - match.range.location
            let matchPrefix = (full as NSString).substring(to: labelOffset)
            let inContainer = matchPrefix.contains(">")

            let label = rawLabel
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .map { index, line -> String in
                    var text = String(line)
                        .trimmingCharacters(in: .whitespaces)
                    if inContainer, index > 0 {
                        while text.hasPrefix(">") {
                            text.removeFirst()
                            if text.hasPrefix(" ") || text.hasPrefix("\t") {
                                text.removeFirst()
                            }
                            text = text.trimmingCharacters(in: .whitespaces)
                        }
                    }
                    return text
                }
                .joined(separator: " ")
            var destination = ns.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if destination.hasPrefix("<"), destination.hasSuffix(">"), destination.count >= 2 {
                destination = String(destination.dropFirst().dropLast())
            }

            var title: String?
            for group in 3...5 where match.range(at: group).location != NSNotFound {
                title = ns.substring(with: match.range(at: group))
                break
            }

            definitions.append(
                ReferenceDefinition(
                    label: label,
                    destination: destination,
                    title: title,
                    range: range
                )
            )
        }

        return definitions
    }
}
