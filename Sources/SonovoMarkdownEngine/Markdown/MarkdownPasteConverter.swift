import Foundation

/// The flavors a paste offer can carry.
public struct MarkdownPasteInput: Sendable, Equatable {
    public enum Flavor: Sendable, Equatable {
        case text(String)
        case url(String)
        case html(String)
    }

    public let flavors: [Flavor]
    public let selectionText: String
    public let isInsideFence: Bool
    /// The document around the insertion point, when the caller can supply
    /// it. Block conversion reads the selection's own line from it so the
    /// fence starts and ends on line boundaries instead of splitting a
    /// paragraph.
    public let documentSource: String?

    public init(
        flavors: [Flavor],
        selectionText: String,
        isInsideFence: Bool = false,
        documentSource: String? = nil
    ) {
        self.flavors = flavors
        self.selectionText = selectionText
        self.isInsideFence = isInsideFence
        self.documentSource = documentSource
    }

    public var url: String? {
        for flavor in flavors {
            if case .url(let value) = flavor { return value }
        }
        return nil
    }

    public var text: String? {
        for flavor in flavors {
            if case .text(let value) = flavor { return value }
        }
        return nil
    }

    public var html: String? {
        for flavor in flavors {
            if case .html(let value) = flavor { return value }
        }
        return nil
    }
}

public enum MarkdownPastePlan: Sendable, Equatable {
    /// Let AppKit paste the text unchanged.
    case plain
    /// Replace the selection with Markdown source in one undoable edit.
    case insert(range: Range<Int>, replacement: String, selection: Range<Int>)
}

/// The fixed paste chain: URL over a selection, clipboard HTML, detected
/// code, then plain text.
///
/// HTML conversion is enabled because the clipboard corpus passes
/// (`MarkdownHTMLPasteTests`); any failure in it falls back to the plain-text
/// path, so a malformed payload can never corrupt the document. Paste as
/// Plain Text remains a separate command and never reaches this chain.
public enum MarkdownPasteConverter {
    /// Above this size the content is pasted literally.
    public static let maximumConvertedBytes = 100 * 1024

    public static func plan(
        input: MarkdownPasteInput,
        selection: Range<Int>
    ) -> MarkdownPastePlan {
        if input.isInsideFence { return .plain }

        if let url = input.url,
           !input.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty,
           MarkdownSecurity.linkDecision(for: url).isAllowed {
            let text = input.selectionText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = "[\(linkLabel(text))](\(linkDestination(url)))"
            let caret = selection.lowerBound + (replacement as NSString).length
            return .insert(
                range: selection,
                replacement: replacement,
                selection: caret..<caret
            )
        }

        if let html = input.html,
           html.utf8.count <= maximumConvertedBytes,
           let converted = MarkdownHTMLPaste.convert(html) {
            let caret = selection.lowerBound
                + (converted as NSString).length
            return .insert(
                range: selection,
                replacement: converted,
                selection: caret..<caret
            )
        }

        guard let text = input.text,
              !text.isEmpty,
              text.utf8.count <= maximumConvertedBytes else {
            return .plain
        }
        if let language = codeLanguage(for: text) {
            let replacement = blockPlacement(
                fenced(text, language: language),
                selection: selection,
                in: input.documentSource
            )
            let caret = selection.lowerBound
                + (replacement as NSString).length
            return .insert(
                range: selection,
                replacement: replacement,
                selection: caret..<caret
            )
        }
        return .plain
    }

    /// Keeps a block construct on its own lines.
    ///
    /// A fence pasted mid-paragraph would otherwise start after prose and
    /// attach the following text to its closing fence. When the caller
    /// supplied the document, add the line boundary on each side that the
    /// selection does not already have.
    static func blockPlacement(
        _ block: String,
        selection: Range<Int>,
        in source: String?
    ) -> String {
        guard let source else { return block }
        let ns = source as NSString
        guard selection.lowerBound >= 0,
              selection.upperBound <= ns.length,
              selection.lowerBound <= selection.upperBound else {
            return block
        }
        var lineStart = selection.lowerBound
        while lineStart > 0, ns.character(at: lineStart - 1) != 0x0A {
            lineStart -= 1
        }
        var lineEnd = selection.upperBound
        while lineEnd < ns.length, ns.character(at: lineEnd) != 0x0A {
            lineEnd += 1
        }
        let before = ns.substring(
            with: NSRange(
                location: lineStart,
                length: selection.lowerBound - lineStart
            )
        ).trimmingCharacters(in: .whitespaces)
        let after = ns.substring(
            with: NSRange(
                location: selection.upperBound,
                length: lineEnd - selection.upperBound
            )
        ).trimmingCharacters(in: .whitespaces)
        var replacement = block
        if !before.isEmpty { replacement = "\n" + replacement }
        if !after.isEmpty { replacement += "\n" }
        return replacement
    }

    /// A conservative detector: at least three code-shaped lines, or one
    /// line with an unmistakable construct.
    static func codeLanguage(for text: String) -> String? {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        let pythonMarkers = lines.contains {
            $0.hasPrefix("def ") || $0.hasPrefix("from ")
                || $0.hasPrefix("class ")
        } && lines.contains { $0.hasSuffix(":") }
        if pythonMarkers { return "python" }

        let swiftMarkers = ["import ", "func ", "let ", "var ", "struct ",
                            "class ", "enum ", "guard "]
        let swiftShape = lines.contains {
            $0.hasSuffix("{") || $0 == "}"
        } || lines.contains { $0.hasPrefix("import ") }
        if lines.contains(where: { line in
            swiftMarkers.contains { line.hasPrefix($0) }
        }), swiftShape {
            return "swift"
        }

        let jsMarkers = lines.contains {
            $0.hasPrefix("function ") || $0.hasPrefix("const ")
                || $0.hasPrefix("let ") || $0.hasPrefix("=>")
        }
        if jsMarkers, lines.contains(where: { $0.hasSuffix(";") }) {
            return "javascript"
        }
        if lines.first == "{", lines.last == "}", text.contains(":") {
            return "json"
        }
        if lines.contains(where: {
            $0.hasPrefix("$ ") || $0.hasPrefix("#!")
        }) {
            return "shell"
        }
        return nil
    }

    /// A selection used as link text must not close the label or start
    /// markup, and a newline would end the paragraph.
    static func linkLabel(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// A pasted URL is serialized by the same writer the link popover uses:
    /// whitespace, parentheses, and angle brackets select the angle form, and
    /// the bytes each form cannot carry literally are encoded.
    static func linkDestination(_ url: String) -> String {
        MarkdownDestination.escaped(
            url.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func fenced(_ text: String, language: String) -> String {
        let body = text.hasSuffix("\n") ? text : text + "\n"
        // The wrapper must be longer than any backtick run in the pasted
        // code, or a triple-backtick line closes it early.
        var longest = 0
        var current = 0
        for character in body {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(language)\n\(body)\(fence)"
    }
}
