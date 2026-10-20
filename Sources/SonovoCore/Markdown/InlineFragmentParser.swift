import Foundation
import Markdown

/// Parses a source fragment as inline Markdown with correct global ranges.
///
/// A fragment can be a mid-paragraph slice or the contents of a `<summary>`;
/// neither is necessarily a complete document. Every top-level block is
/// flattened, so `first\n\nsecond` and `- item` keep their content instead of
/// returning only the first paragraph or nothing at all.
enum InlineFragmentParser {
    static func parse(
        _ text: String,
        baseLine: Int,
        baseOffset: Int,
        baseColumn: Int = 0,
        referenceDefinitions: [ReferenceDefinition] = []
    ) -> [Inline] {
        guard !text.isEmpty else { return [] }

        // A fragment that begins with a block marker must be read as inline
        // content: ` - &amp;` is a slice of a paragraph, not a list. A
        // one-character sentinel keeps the first line out of block parsing;
        // its positions are shifted back out before returning.
        let sentinel = startsWithBlockMarker(text)
        let parsedText = sentinel ? "x" + text : text
        let mapBaseOffset = sentinel ? 0 : baseOffset
        let fragmentEnd = mapBaseOffset
            + (sentinel ? 1 : 0)
            + text.utf16.count

        // Definitions are document-wide. Append them so a summary containing
        // `[label][ref]` resolves; the appended lines are beyond the fragment
        // and are filtered out of the result.
        let definitionText = referenceDefinitions.map { definition -> String in
            var line = "[\(definition.label)]: "
                + serializedDestination(definition.destination)
            if let title = definition.title, !title.isEmpty {
                line += " \""
                    + title.replacingOccurrences(of: "\"", with: "\\\"")
                    + "\""
            }
            return line
        }.joined(separator: "\n")
        let combined = definitionText.isEmpty
            ? parsedText
            : parsedText + "\n\n" + definitionText

        let map = SourceMap(
            source: combined,
            baseLine: baseLine,
            baseOffset: mapBaseOffset,
            baseColumn: sentinel ? 0 : baseColumn
        )
        let mapper = ASTMapper(
            sourceMap: map,
            lineOffset: baseLine - 1,
            enableAutolinks: true
        )

        var result = flatten(
            Document(parsing: combined, options: MarkdownParser.parseOptions),
            mapper: mapper,
            map: map,
            fragmentEnd: fragmentEnd
        )

        if sentinel {
            // Remove the sentinel in local coordinates first, then map the
            // remaining positions back to the document. Shifting first and
            // then adding one moved the first range past the fragment origin
            // when the origin was zero.
            result = removingSentinel(from: result)
            result = result.map {
                shifted(
                    $0,
                    offsetDelta: baseOffset - 1,
                    firstLine: baseLine,
                    columnDelta: baseColumn - 1
                )
            }
        }

        if result.isEmpty {
            // No inline-bearing block was recognized. Keep the fragment as
            // literal text rather than silently dropping it.
            let originalMap = SourceMap(
                source: text,
                baseLine: baseLine,
                baseOffset: baseOffset,
                baseColumn: baseColumn
            )
            let endOffset = baseOffset + text.utf16.count
            let range = originalMap.position(atUTF16Offset: baseOffset).flatMap {
                start in
                originalMap.position(atUTF16Offset: endOffset).map { end in
                    SourceRange(start: start, end: end)
                }
            }
            result = [.text(text, range: range)]
        }

        return result
    }

    // MARK: - Block flattening

    private static func flatten(
        _ document: Document,
        mapper: ASTMapper,
        map: SourceMap,
        fragmentEnd: Int
    ) -> [Inline] {
        var result: [Inline] = []

        func append(_ inlines: [Inline]) {
            guard !inlines.isEmpty else { return }
            if !result.isEmpty {
                result.append(.softBreak(range: nil))
            }
            result.append(contentsOf: inlines)
        }

        func appendBlocks(_ children: MarkupChildren) {
            for child in children {
                if let range = mapper.sourceRange(for: child),
                   range.lowerBound >= fragmentEnd {
                    continue
                }
                if let paragraph = child as? Paragraph {
                    append(mapper.mapInlines(paragraph.children))
                } else if let heading = child as? Heading {
                    append(mapper.mapInlines(heading.children))
                } else if child is UnorderedList || child is OrderedList {
                    for item in child.children {
                        appendBlocks(item.children)
                    }
                } else if let quote = child as? BlockQuote {
                    appendBlocks(quote.children)
                } else if let range = mapper.sourceRange(for: child) {
                    // A block with no inline children (code, raw HTML, a
                    // thematic break) must still contribute its source.
                    let raw = map.text(in: range) ?? ""
                    if !raw.isEmpty {
                        append([.text(raw, range: range)])
                    }
                }
            }
        }

        appendBlocks(document.children)
        return result
    }

    /// Serializes a destination so spaces do not change its meaning.
    private static func serializedDestination(_ destination: String) -> String {
        guard destination.rangeOfCharacter(
            from: .whitespacesAndNewlines
        ) != nil else {
            return destination
        }
        let escaped = destination
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "<", with: "\\<")
            .replacingOccurrences(of: ">", with: "\\>")
        return "<\(escaped)>"
    }

    // MARK: - Sentinel handling

    /// Whether the first line would be parsed as a block rather than inline
    /// content. Only the first line is checked; later lines of a mid-text
    /// slice cannot start a new block without a blank line.
    private static func startsWithBlockMarker(_ text: String) -> Bool {
        let firstLine = text.prefix(while: { $0 != "\n" })
        let trimmed = firstLine.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first else { return false }

        if first == ">" { return true }
        if first == "#" {
            var probe = trimmed.startIndex
            var hashes = 0
            while probe < trimmed.endIndex, trimmed[probe] == "#" {
                hashes += 1
                probe = trimmed.index(after: probe)
            }
            guard hashes <= 6 else { return false }
            return probe == trimmed.endIndex
                || trimmed[probe] == " "
                || trimmed[probe] == "\t"
        }
        if first == "-" || first == "+" || first == "*" {
            let next = trimmed.dropFirst().first
            return next == nil || next == " " || next == "\t"
        }

        var index = trimmed.startIndex
        var digits = 0
        while index < trimmed.endIndex, trimmed[index].isNumber, digits < 10 {
            digits += 1
            index = trimmed.index(after: index)
        }
        guard digits >= 1, digits <= 9, index < trimmed.endIndex else {
            return false
        }
        guard trimmed[index] == "." || trimmed[index] == ")" else {
            return false
        }
        let after = trimmed.index(after: index)
        return after == trimmed.endIndex
            || trimmed[after] == " "
            || trimmed[after] == "\t"
    }

    private static func shifted(
        _ inline: Inline,
        offsetDelta: Int,
        firstLine: Int,
        columnDelta: Int
    ) -> Inline {
        func position(_ source: SourcePosition) -> SourcePosition {
            let column = source.line == firstLine
                ? max(0, source.column + columnDelta)
                : source.column
            return SourcePosition(
                line: source.line,
                column: column,
                offset: max(0, source.offset + offsetDelta)
            )
        }

        func range(_ source: SourceRange?) -> SourceRange? {
            guard let source else { return nil }
            return SourceRange(
                start: position(source.start),
                end: position(source.end)
            )
        }

        func children(_ inlines: [Inline]) -> [Inline] {
            inlines.map {
                shifted(
                    $0,
                    offsetDelta: offsetDelta,
                    firstLine: firstLine,
                    columnDelta: columnDelta
                )
            }
        }

        switch inline {
        case let .text(value, source):
            return .text(value, range: range(source))
        case let .softBreak(source):
            return .softBreak(range: range(source))
        case let .lineBreak(source):
            return .lineBreak(range: range(source))
        case let .inlineCode(value, source):
            return .inlineCode(value, range: range(source))
        case let .emphasis(inlines, source):
            return .emphasis(inlines: children(inlines), range: range(source))
        case let .strong(inlines, source):
            return .strong(inlines: children(inlines), range: range(source))
        case let .strikethrough(inlines, source):
            return .strikethrough(inlines: children(inlines), range: range(source))
        case let .link(destination, title, inlines, source):
            return .link(
                destination: destination,
                title: title,
                inlines: children(inlines),
                range: range(source)
            )
        case let .image(destination, title, description, source):
            return .image(
                destination: destination,
                title: title,
                description: children(description),
                range: range(source)
            )
        case let .inlineHTML(raw, source):
            return .inlineHTML(raw, range: range(source))
        case let .wikiLink(link, source):
            return .wikiLink(link, range: range(source))
        }
    }

    private static func removingSentinel(from inlines: [Inline]) -> [Inline] {
        guard let first = inlines.first,
              case let .text(value, source) = first,
              value.hasPrefix("x") else {
            return inlines
        }

        let remaining = String(value.dropFirst())
        guard !remaining.isEmpty else {
            return Array(inlines.dropFirst())
        }

        let trimmed: SourceRange?
        if let source {
            let start = SourcePosition(
                line: source.start.line,
                column: source.start.column + 1,
                offset: source.start.offset + 1
            )
            trimmed = SourceRange(start: start, end: source.end)
        } else {
            trimmed = nil
        }

        var result = inlines
        result[0] = .text(remaining, range: trimmed)
        return result
    }
}
