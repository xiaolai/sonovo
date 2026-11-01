import Foundation

/// An inline link, image, or wiki link found in the source.
public struct MarkdownLinkTarget: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case link
        case image
        case wikiLink
    }

    public enum Style: String, Sendable, Equatable {
        case inline
        case reference
        case collapsed
        case shortcut
        case wiki
    }

    public let kind: Kind
    public let style: Style
    /// The whole construct, including markers.
    public let range: Range<Int>
    /// The visible text: link text, image alt, or wiki display text.
    public let text: String
    /// The resolved destination: inline destination or definition target.
    public let destination: String
    public let title: String?
    /// Reference label, or the wiki target.
    public let label: String?
    public let alias: String?
    /// The definition's source range for reference styles.
    public let definitionRange: Range<Int>?

    /// v1 edits inline constructs and wiki links only. Reference-style
    /// constructs are shown read-only because one definition can serve many
    /// occurrences.
    public var isEditable: Bool {
        style == .inline || style == .wiki
    }

    public init(
        kind: Kind,
        style: Style,
        range: Range<Int>,
        text: String,
        destination: String,
        title: String? = nil,
        label: String? = nil,
        alias: String? = nil,
        definitionRange: Range<Int>? = nil
    ) {
        self.kind = kind
        self.style = style
        self.range = range
        self.text = text
        self.destination = destination
        self.title = title
        self.label = label
        self.alias = alias
        self.definitionRange = definitionRange
    }
}

public struct MarkdownLinkValues: Sendable, Equatable {
    public var text: String
    public var destination: String
    public var title: String?
    public var target: String?
    public var alias: String?

    public init(
        text: String = "",
        destination: String = "",
        title: String? = nil,
        target: String? = nil,
        alias: String? = nil
    ) {
        self.text = text
        self.destination = destination
        self.title = title
        self.target = target
        self.alias = alias
    }
}

public enum MarkdownLinkError: Error, Equatable {
    case readOnlyReference
    case invalidTarget
    case staleTarget
}

public enum MarkdownLinkEditor {
    // MARK: - Reading

    public static func target(
        at offset: Int,
        in ast: SonovoAST,
        source: String
    ) -> MarkdownLinkTarget? {
        let context = MarkdownCursorContext.at(
            offset: offset,
            in: ast,
            source: source
        )
        guard let link = context.link else { return nil }
        let range = link.range.lowerBound..<link.range.upperBound
        let ns = source as NSString
        guard range.upperBound <= ns.length else { return nil }
        let slice = ns.substring(
            with: NSRange(
                location: range.lowerBound,
                length: range.upperBound - range.lowerBound
            )
        )
        switch link.kind {
        case .wikiLink:
            return parseWiki(slice, range: range)
        case .link:
            guard let destination = link.destination else { return nil }
            return parseBracket(
                slice,
                range: range,
                kind: .link,
                definitions: ast.referenceDefinitions,
                resolved: (destination, link.title)
            )
        case .image:
            guard let destination = link.destination else { return nil }
            return parseBracket(
                slice,
                range: range,
                kind: .image,
                definitions: ast.referenceDefinitions,
                resolved: (destination, link.title)
            )
        }
    }

    private static func parseWiki(
        _ slice: String,
        range: Range<Int>
    ) -> MarkdownLinkTarget? {
        guard slice.hasPrefix("[["), slice.hasSuffix("]]") else {
            return nil
        }
        let inner = String(slice.dropFirst(2).dropLast(2))
        let parts = inner.split(
            separator: "|",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let target = String(parts.first ?? "")
        let alias = parts.count > 1 ? String(parts[1]) : nil
        return MarkdownLinkTarget(
            kind: .wikiLink,
            style: .wiki,
            range: range,
            text: alias ?? target,
            destination: target,
            label: target,
            alias: alias
        )
    }

    private static func parseBracket(
        _ slice: String,
        range: Range<Int>,
        kind: MarkdownLinkTarget.Kind,
        definitions: [ReferenceDefinition],
        resolved: (destination: String, title: String?)
    ) -> MarkdownLinkTarget? {
        let prefix = kind == .image ? "![" : "["
        guard slice.hasPrefix(prefix) else { return nil }
        let body = String(slice.dropFirst(prefix.count))
        guard let close = matchingBracket(in: body) else { return nil }
        let text = String(body[..<close])
        let after = String(body[body.index(after: close)...])

        if after.hasPrefix("("), after.hasSuffix(")") {
            return MarkdownLinkTarget(
                kind: kind,
                style: .inline,
                range: range,
                text: text,
                destination: resolved.destination,
                title: resolved.title
            )
        }

        if after.hasPrefix("["), after.hasSuffix("]") {
            let label = String(after.dropFirst().dropLast())
            let style: MarkdownLinkTarget.Style = label.isEmpty
                ? .collapsed
                : .reference
            let lookup = label.isEmpty ? text : label
            let definition = find(lookup, in: definitions)
            return MarkdownLinkTarget(
                kind: kind,
                style: style,
                range: range,
                text: text,
                destination: definition?.destination ?? "",
                title: definition?.title,
                label: lookup,
                definitionRange: definition?.range.flatMap {
                    $0.lowerBound..<$0.upperBound
                }
            )
        }

        // Shortcut reference: the text is the label.
        let definition = find(text, in: definitions)
        return MarkdownLinkTarget(
            kind: kind,
            style: .shortcut,
            range: range,
            text: text,
            destination: definition?.destination ?? "",
            title: definition?.title,
            label: text,
            definitionRange: definition?.range.flatMap {
                $0.lowerBound..<$0.upperBound
            }
        )
    }

    private static func matchingBracket(in text: String) -> String.Index? {
        var depth = 0
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                // A code span protects its content: a bracket inside it is
                // literal text and does not change the label's depth.
                let run = backtickRun(in: text, at: index)
                let afterRun = text.index(index, offsetBy: run)
                if let close = closingBacktickRun(
                    in: text,
                    from: afterRun,
                    length: run
                ) {
                    index = text.index(close, offsetBy: run)
                    continue
                }
                index = afterRun
                continue
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                if depth == 0 { return index }
                depth -= 1
            }
            index = text.index(after: index)
        }
        return nil
    }

    // Inline destinations and titles are read from the parsed inline in the
    // AST (through `MarkdownCursorContext.LinkContext`), never decoded here:
    // a second, smaller entity table inevitably disagreed with the parser on
    // the references it did not know.

    private static func find(
        _ label: String,
        in definitions: [ReferenceDefinition]
    ) -> ReferenceDefinition? {
        // CommonMark folds case and collapses internal whitespace. It does
        // not ignore diacritics: `cafe` and `café` are distinct labels.
        let normalized = normalizedLabel(label)
        return definitions.first {
            normalizedLabel($0.label).compare(
                normalized,
                options: [.caseInsensitive]
            ) == .orderedSame
        }
    }

    private static func normalizedLabel(_ label: String) -> String {
        label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Writing

    /// Rewrites an inline construct. The caret is preserved when it lies
    /// outside the construct; otherwise it moves to the construct's start.
    public static func commit(
        _ values: MarkdownLinkValues,
        to target: MarkdownLinkTarget,
        source: String,
        selection: Range<Int>
    ) throws -> MarkdownCommandResult {
        guard target.isEditable else {
            throw MarkdownLinkError.readOnlyReference
        }
        let replacement: String
        switch target.kind {
        case .link:
            // An emptied field means an empty label (`[](url)`); falling
            // back to the old text made clearing it impossible.
            replacement = "[\(formattedLabel(values.text))](\(formattedDestination(values.destination))"
                + formattedTitle(values.title) + ")"
        case .image:
            replacement = "![\(formattedLabel(values.text))](\(formattedDestination(values.destination))"
                + formattedTitle(values.title) + ")"
        case .wikiLink:
            let name = (values.target ?? values.destination)
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw MarkdownLinkError.invalidTarget }
            let alias = (values.alias ?? "").trimmingCharacters(in: .whitespaces)
            replacement = alias.isEmpty
                ? "[[\(name)]]"
                : "[[\(name)|\(alias)]]"
        }
        let ns = source as NSString
        guard target.range.lowerBound >= 0,
              target.range.upperBound <= ns.length else {
            throw MarkdownLinkError.staleTarget
        }
        let newSource = ns.replacingCharacters(
            in: NSRange(
                location: target.range.lowerBound,
                length: target.range.upperBound - target.range.lowerBound
            ),
            with: replacement
        )
        let delta = (replacement as NSString).length
            - (target.range.upperBound - target.range.lowerBound)
        let newSelection: Range<Int>
        if selection.upperBound <= target.range.lowerBound {
            newSelection = selection
        } else if selection.lowerBound >= target.range.upperBound {
            let lower = selection.lowerBound + delta
            let upper = selection.upperBound + delta
            newSelection = lower..<upper
        } else {
            let caret = target.range.lowerBound
            newSelection = caret..<caret
        }
        return MarkdownCommandResult(
            source: newSource,
            selection: newSelection,
            actionName: "Edit Link",
            previousSource: source
        )
    }

    private static func formattedDestination(_ destination: String) -> String {
        MarkdownDestination.escaped(
            destination.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Escapes the label's delimiters without disturbing escapes the source
    /// already carries: an unchanged edit must reproduce its own bytes. A
    /// backslash that already escapes punctuation stays as written; a
    /// backslash before anything else (or at the end) becomes a literal
    /// backslash, so it can neither escape the closing bracket nor vanish.
    ///
    /// Inline code spans are copied verbatim. Brackets and backslashes inside
    /// them are literal to the Markdown parser, so escaping them would change
    /// the text the reader sees. A balanced bracket pair outside a code span
    /// is also copied verbatim: it cannot end the label early, and it may be
    /// embedded image syntax. Only an unmatched bracket is escaped.
    private static func formattedLabel(_ text: String) -> String {
        let matched = matchedBrackets(in: text)
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "`" {
                let run = backtickRun(in: text, at: index)
                let afterRun = text.index(index, offsetBy: run)
                if let close = closingBacktickRun(
                    in: text,
                    from: afterRun,
                    length: run
                ) {
                    let end = text.index(close, offsetBy: run)
                    result += text[index..<end]
                    index = end
                } else {
                    result += text[index..<afterRun]
                    index = afterRun
                }
                continue
            }
            let next = text.index(after: index)
            if character == "\\" {
                if next < text.endIndex,
                   MarkdownEscaping.punctuation.contains(text[next]) {
                    result.append("\\")
                    result.append(text[next])
                    index = text.index(after: next)
                } else {
                    result += "\\\\"
                    index = next
                }
            } else if character == "[" || character == "]" {
                if matched.contains(index) {
                    result.append(character)
                } else {
                    result += "\\\(character)"
                }
                index = next
            } else {
                result.append(character)
                index = next
            }
        }
        return result
    }

    /// The bracket characters that pair with each other outside code spans
    /// and escapes. A bracket outside this set has no partner, so it would
    /// close the label (or swallow its terminator) if written raw.
    private static func matchedBrackets(
        in text: String
    ) -> Set<String.Index> {
        var stack: [String.Index] = []
        var matched: Set<String.Index> = []
        var index = text.startIndex
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                let run = backtickRun(in: text, at: index)
                let afterRun = text.index(index, offsetBy: run)
                if let close = closingBacktickRun(
                    in: text,
                    from: afterRun,
                    length: run
                ) {
                    index = text.index(close, offsetBy: run)
                    continue
                }
                index = afterRun
                continue
            } else if character == "[" {
                stack.append(index)
            } else if character == "]" {
                if let open = stack.popLast() {
                    matched.insert(open)
                    matched.insert(index)
                }
            }
            index = text.index(after: index)
        }
        return matched
    }

    private static func backtickRun(
        in text: String,
        at start: String.Index
    ) -> Int {
        var length = 0
        var index = start
        while index < text.endIndex, text[index] == "`" {
            length += 1
            index = text.index(after: index)
        }
        return length
    }

    private static func closingBacktickRun(
        in text: String,
        from start: String.Index,
        length: Int
    ) -> String.Index? {
        var index = start
        while index < text.endIndex {
            guard text[index] == "`" else {
                index = text.index(after: index)
                continue
            }
            let run = backtickRun(in: text, at: index)
            if run == length { return index }
            index = text.index(index, offsetBy: run)
        }
        return nil
    }

    private static func formattedTitle(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "" }
        // A trailing backslash left as-is would escape the closing quote and
        // swallow the rest of the link, and a literal ampersand could form a
        // character reference on reparse.
        let escaped = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return " \"\(escaped)\""
    }
}
