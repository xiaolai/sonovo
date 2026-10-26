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
            return parseBracket(
                slice,
                range: range,
                kind: .link,
                definitions: ast.referenceDefinitions
            )
        case .image:
            return parseBracket(
                slice,
                range: range,
                kind: .image,
                definitions: ast.referenceDefinitions
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
        definitions: [ReferenceDefinition]
    ) -> MarkdownLinkTarget? {
        let prefix = kind == .image ? "![" : "["
        guard slice.hasPrefix(prefix) else { return nil }
        let body = String(slice.dropFirst(prefix.count))
        guard let close = matchingBracket(in: body) else { return nil }
        let text = String(body[..<close])
        let after = String(body[body.index(after: close)...])

        if after.hasPrefix("("), after.hasSuffix(")") {
            let inner = String(after.dropFirst().dropLast())
            let parsed = parseInlineDestination(inner)
            return MarkdownLinkTarget(
                kind: kind,
                style: .inline,
                range: range,
                text: text,
                destination: parsed.destination,
                title: parsed.title
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

    private static func parseInlineDestination(
        _ inner: String
    ) -> (destination: String, title: String?) {
        var text = inner.trimmingCharacters(in: .whitespaces)
        var destination = ""
        if text.hasPrefix("<"), let end = text.firstIndex(of: ">") {
            destination = String(text[text.index(after: text.startIndex)..<end])
            text = String(text[text.index(after: end)...])
        } else {
            var index = text.startIndex
            while index < text.endIndex {
                let character = text[index]
                if character == " " || character == "\t" {
                    break
                }
                destination.append(character)
                index = text.index(after: index)
            }
            text = String(text[index...])
        }
        let title = parseTitle(
            text.trimmingCharacters(in: .whitespaces)
        )
        return (destination, title)
    }

    private static func parseTitle(_ text: String) -> String? {
        guard text.count >= 2, let first = text.first else { return nil }
        let last = text.last
        let closer: Character?
        switch first {
        case "\"": closer = "\""
        case "'": closer = "'"
        case "(": closer = ")"
        default: closer = nil
        }
        guard let closer, last == closer else { return nil }
        return String(text.dropFirst().dropLast())
    }

    private static func find(
        _ label: String,
        in definitions: [ReferenceDefinition]
    ) -> ReferenceDefinition? {
        definitions.first {
            $0.label.compare(
                label,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
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
            let text = values.text.isEmpty ? target.text : values.text
            replacement = "[\(text)](\(formattedDestination(values.destination))"
                + formattedTitle(values.title) + ")"
        case .image:
            let text = values.text.isEmpty ? target.text : values.text
            replacement = "![\(text)](\(formattedDestination(values.destination))"
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
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        if trimmed.contains(" ") || trimmed.contains("(")
            || trimmed.contains(")") {
            return "<\(trimmed)>"
        }
        return trimmed
    }

    private static func formattedTitle(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "" }
        let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
        return " \"\(escaped)\""
    }
}
