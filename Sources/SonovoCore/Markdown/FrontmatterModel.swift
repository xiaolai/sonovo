import Foundation

/// A read-only view of the production keys in a document's frontmatter.
///
/// The model never writes: the raw range editor remains the only write path,
/// and unknown keys, comments, ordering, anchors, and block scalars are left
/// exactly as authored. A minimal scanner is enough for known scalar keys; a
/// full YAML dependency would add a liability for no write-side benefit.
public struct ProductionFrontmatter: Sendable, Equatable {
    public enum Key: String, CaseIterable, Sendable {
        case title
        case episode
        case scene
        case status
        case assets

        public var displayName: String {
            switch self {
            case .title: "Title"
            case .episode: "Episode"
            case .scene: "Scene"
            case .status: "Status"
            case .assets: "Linked Assets"
            }
        }
    }

    public struct Field: Sendable, Equatable, Identifiable {
        public let key: Key
        /// The key exactly as authored.
        public let rawKey: String
        /// Every occurrence's value, in document order.
        public let values: [String]
        /// How many times the key itself appeared. A sequence has many
        /// values but one occurrence; only a second key line is a duplicate.
        public let occurrences: Int
        /// 1-based line within the frontmatter body.
        public let line: Int

        public var id: String { rawKey }
        public var isDuplicate: Bool { occurrences > 1 }
        public var displayValue: String { values.first ?? "" }

        public init(
            key: Key,
            rawKey: String,
            values: [String],
            occurrences: Int = 1,
            line: Int
        ) {
            self.key = key
            self.rawKey = rawKey
            self.values = values
            self.occurrences = occurrences
            self.line = line
        }
    }

    public struct Diagnostic: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case duplicateKey(String)
            case unterminatedQuote(String)
        }

        public let kind: Kind
        public let message: String
        /// 1-based line within the frontmatter body.
        public let line: Int

        public var id: String { "\(line):\(message)" }
    }

    /// Known fields with at least one occurrence, in document order.
    public let fields: [Field]
    /// Unknown top-level keys, in document order.
    public let unknownKeys: [String]
    public let diagnostics: [Diagnostic]

    public init(body: String) {
        var fields: [Field] = []
        var unknown: [String] = []
        var diagnostics: [Diagnostic] = []
        let lines = body.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            guard let parsed = Self.keyLine(line) else {
                index += 1
                continue
            }

            let value: (values: [String], consumed: Int)
            if parsed.rest.isEmpty || parsed.rest.hasPrefix("#") {
                value = Self.blockSequence(
                    lines: lines,
                    after: index,
                    key: parsed.key,
                    keyIndent: parsed.indent,
                    diagnostics: &diagnostics
                )
            } else if let block = Self.blockScalar(
                lines: lines,
                after: index,
                rest: parsed.rest,
                keyIndent: parsed.indent
            ) {
                value = block
            } else {
                var rest = parsed.rest
                if rest.hasPrefix("&") {
                    // The anchor stays in the source; the model shows only
                    // the scalar it tags. `&name` alone leaves an empty field.
                    let parts = rest.split(
                        maxSplits: 1,
                        whereSeparator: \.isWhitespace
                    )
                    rest = parts.count > 1
                        ? String(parts[1])
                        : ""
                }
                let scalar = Self.scalar(
                    rest,
                    line: index + 1,
                    rawKey: parsed.key,
                    diagnostics: &diagnostics
                )
                value = (scalar.isEmpty ? [] : [scalar], 1)
            }

            if let key = Key(rawValue: parsed.key) {
                if let existing = fields.firstIndex(where: {
                    $0.key == key
                }) {
                    let old = fields[existing]
                    fields[existing] = Field(
                        key: key,
                        rawKey: old.rawKey,
                        values: old.values + value.values,
                        occurrences: old.occurrences + 1,
                        line: old.line
                    )
                    diagnostics.append(
                        Diagnostic(
                            kind: .duplicateKey(parsed.key),
                            message: "Duplicate frontmatter key: \(parsed.key)",
                            line: index + 1
                        )
                    )
                } else {
                    fields.append(
                        Field(
                            key: key,
                            rawKey: parsed.key,
                            values: value.values,
                            line: index + 1
                        )
                    )
                }
            } else {
                unknown.append(parsed.key)
            }

            index += value.consumed
        }

        self.fields = fields
        self.unknownKeys = unknown
        self.diagnostics = diagnostics
    }

    public func field(for key: Key) -> Field? {
        fields.first { $0.key == key }
    }

    // MARK: - Line grammar

    /// A top-level `key:` line. Indented lines belong to a nested map or a
    /// block scalar and are never keys of this model.
    private static func keyLine(
        _ line: String
    ) -> (key: String, rest: String, indent: Int)? {
        let scalars = Array(line.unicodeScalars)
        guard let first = scalars.first,
              first != " ", first != "\t", first != "#" else {
            return nil
        }
        var index = 0
        while index < scalars.count, scalars[index] != ":" {
            index += 1
        }
        guard index < scalars.count, index > 0 else { return nil }
        let key = String(String.UnicodeScalarView(scalars[0..<index]))
        let valid = key.allSatisfy { character in
            character.isLetter || character.isNumber
                || character == "_" || character == "-"
        }
        guard valid else { return nil }
        let rest = String(
            String.UnicodeScalarView(scalars[(index + 1)...])
        ).trimmingCharacters(in: .whitespaces)
        return (key, rest, 0)
    }

    /// A block sequence (`assets:` followed by indented `- item` lines).
    private static func blockSequence(
        lines: [String],
        after index: Int,
        key: String,
        keyIndent: Int,
        diagnostics: inout [Diagnostic]
    ) -> (values: [String], consumed: Int) {
        var values: [String] = []
        var consumed = 1
        var probe = index + 1
        while probe < lines.count {
            let line = lines[probe]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                probe += 1
                consumed += 1
                continue
            }
            let indent = line.prefix { $0 == " " }.count
            // YAML allows a top-level sequence at the key's own indentation
            // (`assets:` then `- a.png`); requiring more indentation made
            // that valid form show as an empty field.
            let isItem = trimmed == "-" || trimmed.hasPrefix("- ")
            guard indent >= keyIndent, isItem else {
                break
            }
            let item = String(trimmed.dropFirst())
                .trimmingCharacters(in: .whitespaces)
            // Sequence items are scalars: they carry the same quote,
            // flow-list, comment, and diagnostic rules as a value on the
            // key's own line.
            values.append(
                scalar(
                    item,
                    line: probe + 1,
                    rawKey: key,
                    diagnostics: &diagnostics
                )
            )
            probe += 1
            consumed += 1
        }
        return (values, consumed)
    }

    /// A `|` or `>` block scalar. The value is decoded for display; the
    /// source text stays untouched.
    private static func blockScalar(
        lines: [String],
        after index: Int,
        rest: String,
        keyIndent: Int
    ) -> (values: [String], consumed: Int)? {
        guard let indicator = rest.first,
              indicator == "|" || indicator == ">" else {
            return nil
        }
        var probe = index + 1
        var content: [String] = []
        var indent: Int?
        while probe < lines.count {
            let line = lines[probe]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                content.append("")
                probe += 1
                continue
            }
            let lineIndent = line.prefix { $0 == " " }.count
            guard lineIndent > keyIndent else { break }
            let shared = min(indent ?? lineIndent, lineIndent)
            indent = shared
            content.append(line)
            probe += 1
        }
        let strip = indent ?? keyIndent
        let stripped = content.map { line -> String in
            guard line.count >= strip else { return "" }
            return String(line.dropFirst(strip))
        }
        var value: String
        if indicator == ">" {
            var folded = ""
            for line in stripped {
                if line.isEmpty {
                    folded += "\n"
                } else {
                    if !folded.isEmpty, !folded.hasSuffix("\n") {
                        folded += " "
                    }
                    folded += line
                }
            }
            value = folded
        } else {
            value = stripped.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
        }
        return ([value], max(1, probe - index))
    }

    /// Decodes one scalar: quotes, flow sequences, and inline comments.
    private static func scalar(
        _ raw: String,
        line: Int,
        rawKey: String,
        diagnostics: inout [Diagnostic]
    ) -> String {
        guard !raw.isEmpty else { return "" }
        if raw.hasPrefix("[") {
            guard let close = raw.lastIndex(of: "]"), close > raw.startIndex
            else {
                diagnostics.append(
                    Diagnostic(
                        kind: .unterminatedQuote(rawKey),
                        message: "Unterminated list: \(rawKey)",
                        line: line
                    )
                )
                return raw
            }
            let inner = raw[raw.index(after: raw.startIndex)..<close]
            return flowElements(inner)
                .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: ", ")
        }
        if raw.hasPrefix("\"") || raw.hasPrefix("'") {
            guard let value = quoted(raw) else {
                diagnostics.append(
                    Diagnostic(
                        kind: .unterminatedQuote(rawKey),
                        message: "Unterminated quoted value: \(rawKey)",
                        line: line
                    )
                )
                return raw
            }
            return value
        }
        if let comment = inlineCommentIndex(raw) {
            return String(raw[..<comment])
                .trimmingCharacters(in: .whitespaces)
        }
        return raw
    }

    private static func quoted(_ raw: String) -> String? {
        let quote = raw.first
        guard let quote else { return nil }
        var result = ""
        var index = raw.index(after: raw.startIndex)
        while index < raw.endIndex {
            let character = raw[index]
            if character == quote {
                let next = raw.index(after: index)
                if quote == "'", next < raw.endIndex, raw[next] == "'" {
                    result.append("'")
                    index = raw.index(after: next)
                    continue
                }
                return result
            }
            if quote == "\"", character == "\\" {
                if let decoded = decodedEscape(at: index, in: raw) {
                    result += decoded.text
                    index = decoded.next
                    continue
                }
            }
            result.append(character)
            index = raw.index(after: index)
        }
        return nil
    }

    /// One YAML double-quoted escape, starting at the backslash.
    ///
    /// Returns nil for an unknown or malformed escape: YAML has no meaning
    /// for it, and dropping the backslash would invent a different value.
    /// The caller then keeps the authored characters verbatim.
    private static func decodedEscape(
        at index: String.Index,
        in raw: String
    ) -> (text: String, next: String.Index)? {
        let marker = raw.index(after: index)
        guard marker < raw.endIndex else { return nil }
        let character = raw[marker]
        let simple: [Character: String] = [
            "0": "\0", "a": "\u{7}", "b": "\u{8}", "t": "\t", "n": "\n",
            "v": "\u{B}", "f": "\u{C}", "r": "\r", "e": "\u{1B}",
            " ": " ", "\"": "\"", "/": "/", "\\": "\\"
        ]
        if let decoded = simple[character] {
            return (decoded, raw.index(after: marker))
        }
        let width: Int
        switch character {
        case "x": width = 2
        case "u": width = 4
        case "U": width = 8
        default:
            return nil
        }
        let start = raw.index(after: marker)
        guard let end = raw.index(
            start,
            offsetBy: width,
            limitedBy: raw.endIndex
        ), let value = UInt32(raw[start..<end], radix: 16),
        let scalar = Unicode.Scalar(value) else {
            return nil
        }
        return (String(Character(scalar)), end)
    }

    /// Splits a flow sequence's inner text on commas that sit outside a
    /// quoted element, so `["a,b.png"]` stays one value.
    private static func flowElements(_ inner: Substring) -> [String] {
        var elements: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in inner {
            if let active = quote {
                current.append(character)
                if escaped {
                    escaped = false
                } else if active == "\"", character == "\\" {
                    escaped = true
                } else if character == active {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
                continue
            }
            if character == "," {
                elements.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        elements.append(current)
        return elements
    }

    private static func unquoted(_ raw: String) -> String {
        if raw.hasPrefix("\"") || raw.hasPrefix("'") {
            return quoted(raw) ?? raw
        }
        return raw
    }

    /// A ` #` comment starts outside quotes; a `#` inside a value (a URL
    /// fragment, a color) is content.
    private static func inlineCommentIndex(_ raw: String) -> String.Index? {
        var previous: Character?
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "#", previous == " " || previous == "\t" {
                return index
            }
            previous = character
            index = raw.index(after: index)
        }
        return nil
    }
}
