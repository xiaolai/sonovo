import Foundation

/// The four inline HTML elements Sonovo renders.
///
/// The raw values are the HTML tag names; the case names read better in Swift
/// switches. No other raw HTML element is rendered in the viewer or the
/// HTML export — an unknown tag stays hidden, exactly as before RB-26.
public enum MarkdownInlineHTMLTag: String, CaseIterable, Sendable, Equatable {
    case mark
    case underline = "u"
    case superscript = "sup"
    case subscriptTag = "sub"

    /// The opening tag, including angle brackets.
    public var openTag: String { "<\(rawValue)>" }

    /// The closing tag, including angle brackets.
    public var closeTag: String { "</\(rawValue)>" }
}

/// One recognized inline HTML tag occurrence.
public struct MarkdownInlineHTMLMatch: Sendable, Equatable {
    public let tag: MarkdownInlineHTMLTag
    public let isClosing: Bool

    public init(tag: MarkdownInlineHTMLTag, isClosing: Bool) {
        self.tag = tag
        self.isClosing = isClosing
    }
}

/// Recognizes the small inline HTML allowlist.
///
/// Only an exact `<tag>` or `</tag>`, case-insensitively, with no attributes,
/// whitespace, or self-closing slash. Everything else remains hidden raw HTML.
public enum MarkdownInlineHTML {
    public static func match(_ raw: String) -> MarkdownInlineHTMLMatch? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">"),
              trimmed.count >= 3 else { return nil }
        var inner = String(trimmed.dropFirst().dropLast())
        var isClosing = false
        if inner.hasPrefix("/") {
            isClosing = true
            inner = String(inner.dropFirst())
        }
        guard !inner.isEmpty,
              !inner.contains(where: { $0.isWhitespace || $0 == "/" }),
              let tag = MarkdownInlineHTMLTag(
                  rawValue: inner.lowercased()
              ) else { return nil }
        return MarkdownInlineHTMLMatch(tag: tag, isClosing: isClosing)
    }
}
