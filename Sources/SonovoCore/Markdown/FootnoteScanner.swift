import Foundation

/// A `[^label]` reference found in raw source.
struct FootnoteReferenceMatch: Equatable {
    /// The case-folded, whitespace-normalized label used for matching.
    let label: String
    /// The label exactly as authored, trimmed of surrounding whitespace.
    let authoredLabel: String
    /// Global UTF-16 range covering `[^label]`.
    let range: Range<Int>
}

/// A `[^label]: content` definition found in raw source.
struct FootnoteDefinitionMatch: Equatable {
    let label: String
    let authoredLabel: String
    /// Global UTF-16 range covering `[^label]:`.
    let prefixRange: Range<Int>
    /// Global UTF-16 range covering the definition text after the prefix.
    let contentRange: Range<Int>
    /// The whole definition, label and content.
    let span: Range<Int>

    /// The definition's content as plain source text.
    func content(in source: String) -> String {
        source.utf16Slice(contentRange)
    }
}

/// Finds GFM footnote syntax in raw source.
///
/// The scan is deliberately source-first: swift-cmark parses without the
/// footnote option, so `[^1]` reaches the tree as ordinary text — and
/// `[^1]: note` is even consumed as an ordinary link reference definition
/// when its note is a single word. Working from the raw bytes keeps the label
/// rules, the definition extent, and the authored ranges exact; the tree is
/// only used to know which spans are inline containers, which spans must be
/// excluded, and where a definition still has a paragraph to hide.
enum FootnoteScanner {
    /// cmark-gfm's label rule: case-folded, trimmed, internal runs of
    /// whitespace collapsed to one space. An empty label is not a footnote.
    static func normalize(_ label: String) -> String? {
        let collapsed = label
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.lowercased()
    }

    /// Parses every top-level `[^label]:` definition.
    ///
    /// A definition's content is the rest of its line plus following lazy
    /// continuation lines, ending at a blank line or the next block. Matches
    /// whose label line sits inside `excluded` (code and raw HTML) are
    /// ignored. Definitions nested in blockquotes or list items are not
    /// recognized; their labels stay literal.
    static func definitions(
        in source: String,
        excluding excluded: [SourceRange]
    ) -> [FootnoteDefinitionMatch] {
        let ns = source as NSString
        var result: [FootnoteDefinitionMatch] = []
        var lineStart = 0

        while lineStart < ns.length {
            let line = ns.lineRange(
                for: NSRange(location: lineStart, length: 0)
            )
            let lineEnd = line.location + line.length
            defer { lineStart = lineEnd }
            guard let parsed = parseDefinitionLine(
                in: ns,
                lineStart: lineStart,
                lineEnd: lineEnd
            ) else {
                continue
            }
            guard !excluded.contains(where: {
                $0.contains(offset: parsed.start)
            }) else {
                continue
            }

            var blockEnd = parsed.contentEnd
            var nextStart = lineEnd
            while nextStart < ns.length {
                let nextLine = ns.lineRange(
                    for: NSRange(location: nextStart, length: 0)
                )
                let nextEnd = nextLine.location + nextLine.length
                let nextContentEnd = nextEnd > nextStart
                    && ns.character(at: nextEnd - 1) == 0x0A
                    ? nextEnd - 1
                    : nextEnd
                let text = ns.substring(
                    with: NSRange(
                        location: nextStart,
                        length: nextContentEnd - nextStart
                    )
                )
                if text.trimmingCharacters(in: .whitespaces).isEmpty
                    || startsBlock(text)
                    || excluded.contains(where: {
                        $0.contains(offset: nextStart)
                    }) {
                    break
                }
                blockEnd = nextContentEnd
                nextStart = nextEnd
            }

            let contentEnd = max(parsed.contentStart, blockEnd)
            result.append(
                FootnoteDefinitionMatch(
                    label: parsed.label,
                    authoredLabel: parsed.authoredLabel,
                    prefixRange: parsed.start..<parsed.contentStart,
                    contentRange: parsed.contentStart..<contentEnd,
                    span: parsed.start..<contentEnd
                )
            )
        }
        return result
    }

    /// Parses `[^label]:` at the start of one line.
    private static func parseDefinitionLine(
        in ns: NSString,
        lineStart: Int,
        lineEnd: Int
    ) -> (
        label: String,
        authoredLabel: String,
        start: Int,
        contentStart: Int,
        contentEnd: Int
    )? {
        let contentEnd = lineEnd > lineStart
            && ns.character(at: lineEnd - 1) == 0x0A
            ? lineEnd - 1
            : lineEnd
        var start = lineStart
        var spaces = 0
        while start < contentEnd,
              ns.character(at: start) == 0x20,
              spaces < 3 {
            start += 1
            spaces += 1
        }
        guard start + 1 < contentEnd,
              ns.character(at: start) == 0x5B, // [
              ns.character(at: start + 1) == 0x5E else { // ^
            return nil
        }
        var cursor = start + 2
        while cursor < contentEnd {
            let character = ns.character(at: cursor)
            if character == 0x5D { break }
            cursor += 1
        }
        guard cursor < contentEnd,
              ns.character(at: cursor) == 0x5D,
              cursor + 1 < contentEnd,
              ns.character(at: cursor + 1) == 0x3A else { // :
            return nil
        }
        let authored = ns.substring(
            with: NSRange(location: start + 2, length: cursor - start - 2)
        )
        guard let label = normalize(authored) else { return nil }

        var contentStart = cursor + 2
        if contentStart < contentEnd {
            let character = ns.character(at: contentStart)
            if character == 0x20 || character == 0x09 {
                contentStart += 1
            }
        }
        return (
            label,
            authored.trimmingCharacters(in: .whitespaces),
            start,
            contentStart,
            contentEnd
        )
    }

    /// Whether a line begins a block that can interrupt a paragraph.
    /// Paragraph continuation lines may start with `#hashtag`, inline code,
    /// or an inline `<span>`; treating those as blocks truncated a footnote
    /// definition and hid authored text with it.
    private static func startsBlock(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count, index < 4, scalars[index] == " " {
            index += 1
        }
        guard index < scalars.count else { return false }
        let first = scalars[index]

        if first == ">" { return true }
        if first == "#" {
            var probe = index
            var hashes = 0
            while probe < scalars.count,
                  scalars[probe] == "#",
                  hashes < 7 {
                probe += 1
                hashes += 1
            }
            guard hashes > 0, hashes <= 6 else { return false }
            return probe >= scalars.count
                || scalars[probe] == " "
                || scalars[probe] == "\t"
        }
        if first == "`" || first == "~" {
            var probe = index
            while probe < scalars.count, scalars[probe] == first {
                probe += 1
            }
            return probe - index >= 3
        }
        if first == "<" {
            return startsHTMLBlock(scalars[index...])
        }
        if first == "[" {
            // Only a complete footnote definition start `[^label]:` ends the
            // previous one; a continuation line that merely begins `[^` is
            // ordinary text.
            guard index + 1 < scalars.count, scalars[index + 1] == "^"
            else { return false }
            var probe = index + 2
            while probe < scalars.count, scalars[probe] != "]",
                  scalars[probe] != "\n" {
                probe += 1
            }
            return probe + 1 < scalars.count
                && scalars[probe] == "]"
                && scalars[probe + 1] == ":"
        }
        if first == "-" || first == "*" || first == "+" {
            if isThematicBreak(scalars, from: index, marker: first) {
                return true
            }
            var probe = index
            while probe < scalars.count, scalars[probe] == first {
                probe += 1
            }
            return probe == index + 1
                && probe < scalars.count
                && (scalars[probe] == " " || scalars[probe] == "\t")
        }
        if first == "_" {
            return isThematicBreak(scalars, from: index, marker: first)
        }
        if CharacterSet.decimalDigits.contains(first) {
            var probe = index
            while probe < scalars.count,
                  CharacterSet.decimalDigits.contains(scalars[probe]),
                  probe - index < 9 {
                probe += 1
            }
            let digits = String(
                String.UnicodeScalarView(scalars[index..<probe])
            )
            guard digits == "1" else { return false }
            guard probe < scalars.count,
                  scalars[probe] == "."
                    || scalars[probe] == ")" else {
                return false
            }
            return probe + 1 < scalars.count
                && (scalars[probe + 1] == " " || scalars[probe + 1] == "\t")
        }
        return false
    }

    /// CommonMark thematic break: three or more of one marker, and nothing
    /// but spaces and tabs on the line.
    ///
    /// A run of three is not enough by itself: `***continued***` is
    /// emphasis, and treating it as a break hid authored continuation text.
    private static func isThematicBreak(
        _ scalars: [Unicode.Scalar],
        from index: Int,
        marker: Unicode.Scalar
    ) -> Bool {
        var markers = 0
        var probe = index
        while probe < scalars.count {
            let scalar = scalars[probe]
            if scalar == marker {
                markers += 1
            } else if scalar != " " && scalar != "\t" {
                return false
            }
            probe += 1
        }
        return markers >= 3
    }

    /// CommonMark HTML block starts that interrupt a paragraph. Type 7
    /// (any complete tag on its own line) cannot interrupt, so `<span>` on a
    /// continuation line stays inline.
    private static func startsHTMLBlock(
        _ scalars: ArraySlice<Unicode.Scalar>
    ) -> Bool {
        let lowered = String(
            String.UnicodeScalarView(scalars)
        ).lowercased()
        for prefix in ["<!--", "<?", "<![cdata[", "<!"] {
            if lowered.hasPrefix(prefix) { return true }
        }
        var rest = lowered.dropFirst()
        if rest.first == "/" { rest = rest.dropFirst() }
        var nameScalars: [Unicode.Scalar] = []
        // Tag names in the type-6 list are ASCII; comparing scalar values
        // keeps this independent of locale and of `Character` segmentation.
        for scalar in rest.unicodeScalars {
            let value = scalar.value
            let isLetter = (value >= 0x41 && value <= 0x5A)
                || (value >= 0x61 && value <= 0x7A)
            let isDigit = value >= 0x30 && value <= 0x39
            if isLetter || isDigit {
                nameScalars.append(scalar)
            } else {
                break
            }
        }
        guard !nameScalars.isEmpty else { return false }
        let name = String(String.UnicodeScalarView(nameScalars))
        let after = Array(rest.unicodeScalars.dropFirst(nameScalars.count))
        let isSelfClosing = after.count >= 2
            && after[0] == "/"
            && after[1] == ">"
        guard after.isEmpty
            || after[0] == " "
            || after[0] == "\t"
            || after[0] == ">"
            || isSelfClosing else {
            return false
        }
        if ["script", "pre", "style", "textarea"].contains(name) {
            return true
        }
        return htmlBlockTags.contains(name)
    }

    private static let htmlBlockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote",
        "body", "caption", "center", "col", "colgroup", "dd", "details",
        "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption",
        "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3",
        "h4", "h5", "h6", "head", "header", "hr", "html", "iframe",
        "legend", "li", "link", "main", "menu", "menuitem", "nav",
        "noframes", "ol", "optgroup", "option", "p", "param", "search",
        "section", "summary", "table", "tbody", "td", "tfoot", "th",
        "thead", "title", "tr", "track", "ul"
    ]

    /// Finds references inside `span`, excluding code, links, images, raw
    /// HTML, and definition spans. The caller supplies those exclusions from
    /// the parsed tree; this scan itself knows only raw syntax.
    static func references(
        in span: SourceRange,
        source: String,
        excluding excluded: [SourceRange]
    ) -> [FootnoteReferenceMatch] {
        let ns = source as NSString
        guard span.lowerBound >= 0,
              span.upperBound <= ns.length,
              span.lowerBound < span.upperBound else {
            return []
        }
        let spanEnd = span.upperBound
        var matches: [FootnoteReferenceMatch] = []
        var search = span.lowerBound

        while search < spanEnd {
            let opener = ns.range(
                of: "[^",
                options: [],
                range: NSRange(location: search, length: spanEnd - search)
            )
            if opener.location == NSNotFound { break }
            let open = opener.location

            // An odd number of backslashes escapes the opener.
            var backslashes = 0
            var probe = open - 1
            while probe >= 0, ns.character(at: probe) == 0x5C {
                backslashes += 1
                probe -= 1
            }
            if backslashes % 2 == 1 {
                search = open + 2
                continue
            }

            var cursor = open + 2
            while cursor < spanEnd {
                let character = ns.character(at: cursor)
                if character == 0x0A || character == 0x5D { break }
                cursor += 1
            }
            guard cursor < spanEnd, ns.character(at: cursor) == 0x5D else {
                // No closer before this line's end: no opener inside the
                // scanned run can find one either, so resume at the point
                // the scan stopped instead of rescanning the suffix for
                // every `[^` in a malformed line.
                search = max(open + 2, cursor)
                continue
            }

            let authored = ns.substring(
                with: NSRange(location: open + 2, length: cursor - open - 2)
            )
            let range = open..<(cursor + 1)
            defer { search = cursor + 1 }
            guard let label = normalize(authored),
                  !excluded.contains(where: {
                      $0.lowerBound < range.upperBound
                          && range.lowerBound < $0.upperBound
                  })
            else {
                continue
            }
            matches.append(
                FootnoteReferenceMatch(
                    label: label,
                    authoredLabel: authored.trimmingCharacters(
                        in: .whitespaces
                    ),
                    range: range
                )
            )
        }
        return matches
    }
}
