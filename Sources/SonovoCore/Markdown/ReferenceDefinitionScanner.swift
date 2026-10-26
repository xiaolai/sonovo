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
    private static let pattern = #"(?m)^(?:[ \t>]|(?:[-*+]|[0-9]{1,9}[.)])(?=[ \t]))*+[ \t]*+\[((?:\\.|[^\]\\\n])+(?:(?=\n[ \t]*(?:\\.|[^ \t\n\]\\]))\n(?:\\.|[^\]\\\n])+)*)\]:[ \t]*(?:\n[ \t>]*)?(<(?:\\.|[^>\\\n])*>|[^ \t\n]+)(?:[ \t]*(?:\n[ \t>]*)?(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|\(((?:\\.|[^)\\])*)\)))?[ \t]*$"#

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
            // Store the semantic value: backslash escapes and character
            // references decoded, and no container continuation markers.
            // Serializers escape it once.
            destination = decodeEscapesAndEntities(destination)

            var title: String?
            for group in 3...5 where match.range(at: group).location != NSNotFound {
                title = normalizedTitle(
                    ns.substring(with: match.range(at: group)),
                    inContainer: inContainer
                )
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

    /// Removes blockquote continuation prefixes from a multiline title and
    /// decodes its backslash escapes exactly once.
    private static func normalizedTitle(
        _ raw: String,
        inContainer: Bool
    ) -> String {
        var lines = raw.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        if inContainer, lines.count > 1 {
            for index in 1..<lines.count {
                var line = lines[index]
                // Strip only the continuation prefix. Trailing spaces are
                // part of the title and must survive reconstruction.
                while line.hasPrefix(" ") || line.hasPrefix("\t") {
                    line.removeFirst()
                }
                while line.hasPrefix(">") {
                    line.removeFirst()
                    if line.hasPrefix(" ") || line.hasPrefix("\t") {
                        line.removeFirst()
                    }
                }
                lines[index] = line
            }
        }
        // Keep the line endings: a space would change the parsed title.
        // The definition serializer emits the title across lines exactly as
        // stored.
        return decodeEscapesAndEntities(lines.joined(separator: "\n"))
    }

    /// Decodes backslash escapes and character references in one pass.
    ///
    /// The order matters: decoding escapes first turns `\&copy;` into
    /// `&copy;`, which a later entity pass rewrites to `©`, so an escaped
    /// ampersand would silently become an entity introducer. Processing the
    /// source left to right keeps an escaped `&` literal and lets the
    /// serializer escape it on the way out.
    static func decodeEscapesAndEntities(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)
            if character == "\\",
               nextIndex < text.endIndex,
               MarkdownEscaping.punctuation.contains(text[nextIndex]) {
                result.append(text[nextIndex])
                index = text.index(after: nextIndex)
            } else if character == "&",
                      let reference = HTMLEntities.decodeReference(
                          in: text,
                          at: index
                      ) {
                result.append(reference.character)
                index = reference.end
            } else {
                result.append(character)
                index = nextIndex
            }
        }
        return result
    }
}

/// Builds a one-line definition that re-parses to the stored semantics.
enum ReferenceDefinitionSerializer {
    static func line(_ definition: ReferenceDefinition) -> String {
        var line = "[\(definition.label)]: "
            + destination(definition.destination)
        if let title = definition.title, !title.isEmpty {
            line += " \"\(escapedTitle(title))\""
        }
        return line
    }

    /// Serializes a decoded destination so it re-parses to the same value.
    ///
    /// The bare form has no escape of its own beyond backslash escapes and
    /// must keep parentheses balanced; the angle form takes its text
    /// literally but cannot contain `<`, `>`, or a line ending. A literal
    /// ampersand is escaped in both forms: the semantic `&copy;` would
    /// otherwise reparse as `©`.
    static func destination(_ value: String) -> String {
        let needsAngle = value.isEmpty
            || value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            || value.contains("<")
            || value.contains(">")
            || value.contains("\\")
            || !parenthesesBalanced(value)
        let escaped = value.replacingOccurrences(of: "&", with: "&amp;")
        guard needsAngle else { return escaped }
        // Angle destinations still process backslash escapes: a literal
        // backslash must be doubled or the reparse changes the value.
        let encoded = escaped
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "<\(encoded)>"
    }

    private static func parenthesesBalanced(_ value: String) -> Bool {
        var depth = 0
        for character in value {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }

    static func escapedTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
