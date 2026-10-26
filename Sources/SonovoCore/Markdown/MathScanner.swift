import Foundation

/// A math span found in the raw source.
///
/// `range` covers the delimiters, `source` is the TeX between them, and `raw`
/// is the exact authored slice, kept so a renderer failure can fall back to
/// what the author wrote.
struct MathMatch: Equatable {
    let range: Range<Int>
    let source: String
    let raw: String
    let display: Bool
}

extension MathMatch: InlineSpanMatch {}

/// The public boundary for TeX the renderer may typeset.
///
/// The scanner applies this policy while parsing; the renderer applies it
/// again so no caller can bypass the length, nesting, and command limits.
public enum MarkdownMathPolicy {
    public static func accepts(_ source: String) -> Bool {
        MathScanner.isValidTeX(source)
    }
}

/// Display-math detection shared by the viewer and the exporter.
public enum MarkdownInlineMath {
    /// Returns the sole display formula when the paragraph is exactly one
    /// `$$…$$` span. Break nodes the block parser appends at the end of a
    /// paragraph, and whitespace-only text, do not count as content.
    public static func soleDisplay(
        in inlines: [Inline]
    ) -> (source: String, raw: String)? {
        var found: (source: String, raw: String)?
        for inline in inlines {
            switch inline {
            case .softBreak, .lineBreak:
                continue
            case let .text(value, _)
                where value.trimmingCharacters(in: .whitespaces).isEmpty:
                continue
            case let .math(source, raw, display, _) where display && found == nil:
                found = (source: source, raw: raw)
            default:
                return nil
            }
        }
        return found
    }
}

/// Finds `$…$` and `$$…$$` in a raw source span.
///
/// The scanner runs over raw source and rejects spans inside code, links,
/// images, and raw HTML, which the caller passes as exclusions. Display math
/// is recognized only when the span is a block's entire content: a `$$…$$`
/// in the middle of a paragraph stays literal, as it does in the source.
enum MathScanner {
    private static let dollar: unichar = 0x24

    static func scan(
        source: String,
        span: SourceRange,
        excluding excluded: [SourceRange]
    ) -> [MathMatch] {
        let ns = source as NSString
        let spanRange = NSRange(location: span.lowerBound, length: span.length)
        guard spanRange.location >= 0, spanRange.length >= 0,
              spanRange.location + spanRange.length <= ns.length else {
            return []
        }

        let spanEnd = spanRange.location + spanRange.length
        let soleContent = ns.substring(with: spanRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let orderedExcluded = excluded.sorted { $0.lowerBound < $1.lowerBound }
        var exclusionIndex = 0

        var matches: [MathMatch] = []
        var index = spanRange.location
        // The line end is cached: rescanning to the newline for every `$` on
        // one long line was quadratic.
        var cachedLineEnd = -1

        while index < spanEnd {
            while exclusionIndex < orderedExcluded.count,
                  orderedExcluded[exclusionIndex].upperBound <= index {
                exclusionIndex += 1
            }
            if exclusionIndex < orderedExcluded.count,
               orderedExcluded[exclusionIndex].contains(offset: index) {
                index = max(index + 1, orderedExcluded[exclusionIndex].upperBound)
                continue
            }

            guard ns.character(at: index) == dollar else {
                index += 1
                continue
            }
            if isEscaped(ns, at: index) {
                index += 1
                continue
            }

            if index + 1 < spanEnd, ns.character(at: index + 1) == dollar {
                guard let close = displayCloser(
                    ns,
                    from: index + 2,
                    before: spanEnd
                ) else {
                    index += 2
                    continue
                }
                let range = index..<(close + 2)
                let raw = ns.substring(
                    with: NSRange(location: index, length: range.count)
                )
                let content = ns.substring(
                    with: NSRange(
                        location: index + 2,
                        length: close - index - 2
                    )
                )
                // Move past the whole pair even when it is rejected: a `$`
                // inside rejected display syntax must not become inline math.
                index = close + 2
                guard !content.isEmpty,
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      soleContent == raw,
                      !intersects(orderedExcluded, range),
                      isValidTeX(content) else {
                    continue
                }
                matches.append(
                    MathMatch(
                        range: range,
                        source: content,
                        raw: raw,
                        display: true
                    )
                )
                continue
            }

            let lineEnd: Int
            if cachedLineEnd >= index + 1 {
                lineEnd = cachedLineEnd
            } else {
                lineEnd = lineLimit(ns, from: index + 1, before: spanEnd)
                cachedLineEnd = lineEnd
            }
            guard let close = inlineCloser(
                ns,
                from: index + 1,
                before: lineEnd
            ) else {
                index += 1
                continue
            }

            let content = ns.substring(
                with: NSRange(location: index + 1, length: close - index - 1)
            )
            let range = index..<(close + 1)
            let raw = ns.substring(
                with: NSRange(location: index, length: range.count)
            )
            let after = close + 1 < spanEnd ? ns.character(at: close + 1) : 0
            // `$5 and $10` and `$x$2` are prose, not math. An opening `$`
            // followed by whitespace is currency too.
            let opensCleanly = content.first.map {
                !$0.isWhitespace
            } ?? false
            let closesCleanly = content.last.map {
                !$0.isWhitespace
            } ?? false
            let followedByDigit = after >= 0x30 && after <= 0x39
            guard opensCleanly, closesCleanly, !followedByDigit,
                  !intersects(orderedExcluded, range),
                  isValidTeX(content) else {
                index += 1
                continue
            }
            matches.append(
                MathMatch(range: range, source: content, raw: raw, display: false)
            )
            index = close + 1
        }

        return matches
    }

    /// The next unescaped `$$` at or after `location`.
    private static func displayCloser(
        _ ns: NSString,
        from location: Int,
        before limit: Int
    ) -> Int? {
        var search = location
        while search + 1 < limit {
            let found = ns.range(
                of: "$$",
                options: [],
                range: NSRange(location: search, length: limit - search)
            )
            if found.location == NSNotFound { return nil }
            if !isEscaped(ns, at: found.location) {
                return found.location
            }
            search = found.location + 2
        }
        return nil
    }

    /// The next unescaped `$` at or after `location` on the same line.
    private static func inlineCloser(
        _ ns: NSString,
        from location: Int,
        before limit: Int
    ) -> Int? {
        var search = location
        while search < limit {
            let found = ns.range(
                of: "$",
                options: [],
                range: NSRange(location: search, length: limit - search)
            )
            if found.location == NSNotFound { return nil }
            if !isEscaped(ns, at: found.location) {
                return found.location
            }
            search = found.location + 1
        }
        return nil
    }

    private static func lineLimit(
        _ ns: NSString,
        from location: Int,
        before spanEnd: Int
    ) -> Int {
        guard location < spanEnd else { return spanEnd }
        let newline = ns.range(
            of: "\n",
            options: [],
            range: NSRange(location: location, length: spanEnd - location)
        )
        return newline.location == NSNotFound
            ? spanEnd
            : min(newline.location, spanEnd)
    }

    /// True when the character at `location` follows an odd run of
    /// backslashes, which makes it literal source.
    private static func isEscaped(_ ns: NSString, at location: Int) -> Bool {
        var backslashes = 0
        var probe = location - 1
        while probe >= 0, ns.character(at: probe) == 0x5C {
            backslashes += 1
            probe -= 1
        }
        return backslashes % 2 == 1
    }

    private static func intersects(
        _ excluded: [SourceRange],
        _ range: Range<Int>
    ) -> Bool {
        for exclusion in excluded {
            if exclusion.lowerBound < range.upperBound,
               range.lowerBound < exclusion.upperBound {
                return true
            }
            if exclusion.lowerBound >= range.upperBound { break }
        }
        return false
    }

    // MARK: - TeX limits

    /// Commands that could read files or reach beyond math typesetting in a
    /// renderer that implements them. SwiftMath does not implement any of
    /// these today; the deny list makes the boundary explicit and testable.
    static let deniedCommands: Set<String> = [
        "catcode", "class", "csname", "cssid", "data", "def", "edef",
        "gdef", "href", "html", "include", "includegraphics", "input",
        "newcommand", "openin", "openout", "providecommand", "read",
        "renewcommand", "require", "style", "url", "write", "xdef"
    ]

    static func isValidTeX(_ source: String) -> Bool {
        guard source.utf16.count <= MarkdownLimits.maxMathSourceCharacters else {
            return false
        }
        guard !source.contains("\0") else { return false }

        var depth = 0
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "\\" {
                let commandStart = source.index(after: index)
                var end = commandStart
                while end < source.endIndex,
                      source[end].isLetter,
                      source[end].isASCII {
                    end = source.index(after: end)
                }
                if end > commandStart {
                    let command = source[commandStart..<end].lowercased()
                    if deniedCommands.contains(command)
                        || command.hasPrefix("html")
                        || command.hasPrefix("css") {
                        return false
                    }
                    index = end
                    continue
                }
                // An escaped delimiter or symbol: skip the next character.
                index = source.index(after: index)
                if index < source.endIndex {
                    index = source.index(after: index)
                }
                continue
            }
            if character == "{" {
                depth += 1
                if depth > MarkdownLimits.maxMathBraceDepth { return false }
            } else if character == "}" {
                // An unmatched closer is malformed TeX, and letting depth go
                // negative would let later nesting pass the limit.
                guard depth > 0 else { return false }
                depth -= 1
            }
            index = source.index(after: index)
        }
        return true
    }
}
