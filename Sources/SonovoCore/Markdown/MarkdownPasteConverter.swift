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

    public init(
        flavors: [Flavor],
        selectionText: String,
        isInsideFence: Bool = false
    ) {
        self.flavors = flavors
        self.selectionText = selectionText
        self.isInsideFence = isInsideFence
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

/// The fixed paste chain, minus HTML conversion.
///
/// HTML conversion is gated on F0.8b (a runtime measurement on the E2E Mac),
/// so an HTML-only paste falls back to plain text, exactly as the plan's
/// fallback specifies. URL over a selection and code detection ship now.
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
            let replacement = "[\(text)](\(url))"
            let caret = selection.lowerBound + (replacement as NSString).length
            return .insert(
                range: selection,
                replacement: replacement,
                selection: caret..<caret
            )
        }

        guard let text = input.text,
              !text.isEmpty,
              text.utf8.count <= maximumConvertedBytes else {
            return .plain
        }
        if let language = codeLanguage(for: text) {
            let replacement = fenced(text, language: language)
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

    private static func fenced(_ text: String, language: String) -> String {
        let body = text.hasSuffix("\n") ? text : text + "\n"
        return "```\(language)\n\(body)```"
    }
}
