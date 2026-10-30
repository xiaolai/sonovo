import Foundation

/// Decides whether a YAML document is a GitHub Actions workflow and whether
/// it is small enough to parse on the interaction path.
public enum WorkflowDetection {
    /// The parser cap. A workflow bigger than this is not charted; the
    /// surface falls back to the YAML source instead.
    public static let maxSourceBytes = 256 * 1024

    /// The job cap. A chart with more jobs is truncated; the dense-needs case
    /// can still exceed the renderer's DOT limit, which the renderer checks
    /// separately.
    public static let maxJobs = 120

    /// Whether the path names a file directly inside `.github/workflows/`.
    ///
    /// This mirrors the convention GitHub itself uses; it is only a
    /// candidate signal, not proof of content.
    public static func isWorkflowPath(_ path: String) -> Bool {
        let lowered = path
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        guard lowered.hasSuffix(".yml") || lowered.hasSuffix(".yaml") else {
            return false
        }
        let root = ".github/workflows/"
        if lowered.hasPrefix(root) {
            return !lowered.dropFirst(root.count).contains("/")
        }
        guard let marker = lowered.range(
            of: "/" + root,
            options: .backwards
        ) else {
            return false
        }
        return !lowered[marker.upperBound...].contains("/")
    }

    public static func isWorkflowPath(_ url: URL) -> Bool {
        isWorkflowPath(url.path)
    }

    /// Whether the document has the two top-level keys every workflow needs:
    /// `on:` and `jobs:`, both starting at column zero.
    ///
    /// The test is deliberately lexical. It runs before the YAML parser so a
    /// document that only contains YAML data is never parsed as a workflow.
    public static func hasWorkflowShape(_ source: String) -> Bool {
        let keys = topLevelKeys(in: source)
        return keys.on && keys.jobs
    }

    /// Whether a top-level `jobs:` key exists, without requiring `on:`.
    /// An explicit workflow fence uses this so a partial document still
    /// reaches the parser.
    public static func hasJobsKey(_ source: String) -> Bool {
        topLevelKeys(in: source).jobs
    }

    private static func topLevelKeys(
        in source: String
    ) -> (on: Bool, jobs: Bool) {
        var hasOn = false
        var hasJobs = false
        for line in source.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0.isNewline }
        ) {
            guard let first = line.first,
                  first != " ",
                  first != "\t",
                  first != "#" else {
                continue
            }
            guard !line.hasPrefix("---"), !line.hasPrefix("...") else {
                continue
            }
            guard let key = topLevelKey(in: line) else { continue }
            switch key {
            case "on": hasOn = true
            case "jobs": hasJobs = true
            default: break
            }
            if hasOn, hasJobs { break }
        }
        return (hasOn, hasJobs)
    }

    /// Whether the source may be handed to the parser at all.
    ///
    /// Nesting is not checked here. The bundled libyaml caps collection
    /// nesting at 1,000 levels and returns an error beyond that, so the
    /// parser already fails gracefully; a lexical pre-scan cannot tell
    /// structural brackets from text and would either miss adversarial
    /// input or reject valid block-scalar scripts.
    public static func acceptsSource(_ source: String) -> Bool {
        guard source.utf8.count <= maxSourceBytes else { return false }
        guard !source.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return false
        }
        return !source.unicodeScalars.contains { $0.value == 0 }
    }

    /// Reads one top-level mapping key from a column-zero line.
    ///
    /// Handles plain, single-quoted, and double-quoted keys, and rejects a
    /// line whose colon is not followed by a value separator (so a scalar
    /// such as `on:push` is not a key). A double-quoted key is decoded, so
    /// `"on":` is recognised as `on:`.
    private static func topLevelKey(in line: Substring) -> String? {
        var rest = line[...]
        var key = ""
        if let quote = rest.first, quote == "\"" || quote == "'" {
            rest = rest.dropFirst()
            var closed = false
            while let character = rest.first {
                rest = rest.dropFirst()
                if character == quote {
                    // A doubled single quote is an escaped quote.
                    if quote == "'", rest.first == "'" {
                        key.append("'")
                        rest = rest.dropFirst()
                        continue
                    }
                    closed = true
                    break
                }
                if quote == "\"", character == "\\", let escaped = rest.first {
                    rest = rest.dropFirst()
                    key.append(
                        decodedDoubleQuoteEscape(escaped, rest: &rest)
                    )
                    continue
                }
                key.append(character)
            }
            guard closed else { return nil }
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard rest.first == ":" else { return nil }
            rest = rest.dropFirst()
        } else {
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            let candidate = rest[..<colon]
            guard !candidate.isEmpty,
                  !candidate.contains("#"),
                  !candidate.contains(where: {
                      $0 == "{" || $0 == "[" || $0 == "," || $0 == "\""
                          || $0 == "'"
                  }) else {
                return nil
            }
            key = candidate.trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: colon)...]
        }
        // A mapping key's colon is followed by whitespace, a comment, or the
        // end of the line.
        if let next = rest.first,
           next != " ", next != "\t", next != "#" {
            return nil
        }
        return key
    }

    /// YAML double-quoted escape decoding, limited to what can appear in a
    /// key. Unknown escapes keep the escaped character.
    private static func decodedDoubleQuoteEscape(
        _ escaped: Character,
        rest: inout Substring
    ) -> Character {
        switch escaped {
        case "0": return "\0"
        case "a": return "\u{7}"
        case "b": return "\u{8}"
        case "t": return "\t"
        case "n": return "\n"
        case "v": return "\u{B}"
        case "f": return "\u{C}"
        case "r": return "\r"
        case "e": return "\u{1B}"
        case " ": return " "
        case "\"": return "\""
        case "/": return "/"
        case "\\": return "\\"
        case "N": return "\u{85}"
        case "_": return "\u{A0}"
        case "L": return "\u{2028}"
        case "P": return "\u{2029}"
        case "x", "u", "U":
            let count = escaped == "x" ? 2 : (escaped == "u" ? 4 : 8)
            var value: UInt32 = 0
            var consumed = 0
            while consumed < count, let first = rest.first,
                  let digit = first.hexDigitValue {
                value = value * 16 + UInt32(digit)
                rest = rest.dropFirst()
                consumed += 1
            }
            guard consumed == count, let scalar = UnicodeScalar(value) else {
                return "?"
            }
            return Character(scalar)
        default:
            return escaped
        }
    }
}
