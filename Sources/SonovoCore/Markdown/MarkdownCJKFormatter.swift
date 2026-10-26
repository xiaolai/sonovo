import Foundation

/// The result of one explicit CJK formatting pass.
///
/// `changed` is false when the document already satisfies the rules; the
/// command then produces no edit and therefore no undo step.
public struct MarkdownCJKFormatting: Sendable, Equatable {
    public let source: String
    public let selection: Range<Int>
    public let insertedSpaces: Int
    public let normalizedPunctuation: Int

    public var changed: Bool {
        insertedSpaces > 0 || normalizedPunctuation > 0
    }

    public init(
        source: String,
        selection: Range<Int>,
        insertedSpaces: Int,
        normalizedPunctuation: Int
    ) {
        self.source = source
        self.selection = selection
        self.insertedSpaces = insertedSpaces
        self.normalizedPunctuation = normalizedPunctuation
    }
}

/// The explicit CJK formatter.
///
/// It runs only when the user asks for it; nothing here is called from save,
/// typing, or paste. Two rules apply, and only outside protected regions:
///
/// 1. **Spacing.** One ASCII space is inserted between adjacent CJK and ASCII
///    Latin-letter/digit characters, in either order.
/// 2. **Punctuation.** A small ASCII set becomes its fullwidth form in a CJK
///    context. The table is documented in `dev-docs/MARKDOWN-CJK.md`.
///
/// Protected regions come from the parsed tree, not from heuristics: YAML
/// frontmatter, fenced and indented code, inline code, math, raw HTML blocks,
/// inline HTML tags, wiki links, footnote definitions, reference definitions,
/// and link/image destinations. Bare URLs are masked separately. The link and
/// image *text* outside a destination stays ordinary prose, so a CJK/Latin
/// boundary in a label is still corrected.
public enum MarkdownCJKFormatter {
    /// Formats `source`, mapping `selection` through the inserted characters.
    public static func format(
        source: String,
        selection: Range<Int>
    ) -> MarkdownCJKFormatting {
        let ns = source as NSString
        let lower = min(max(selection.lowerBound, 0), ns.length)
        let upper = min(max(selection.upperBound, lower), ns.length)
        let unchanged = MarkdownCJKFormatting(
            source: source,
            selection: lower..<upper,
            insertedSpaces: 0,
            normalizedPunctuation: 0
        )

        // A document without a CJK scalar cannot change; skip the parse.
        guard source.unicodeScalars.contains(where: isCJKScalar) else {
            return unchanged
        }
        let parsed = MarkdownParser.parseCanonical(source)
        // Ranges belong to the canonical source. The editor always hands us
        // canonical text; if it did not, a rewrite would change line endings
        // as a side effect, so refuse instead.
        guard parsed.source == source else { return unchanged }
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        let protected = mergedRanges(protectedRanges(in: ast, ns: ns))

        var edits: [Edit] = []
        var inserted = 0
        var normalized = 0
        var cursor = 0
        for range in protected {
            if cursor < range.lowerBound {
                transform(
                    gap: cursor..<range.lowerBound,
                    ns: ns,
                    edits: &edits,
                    inserted: &inserted,
                    normalized: &normalized
                )
            }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < ns.length {
            transform(
                gap: cursor..<ns.length,
                ns: ns,
                edits: &edits,
                inserted: &inserted,
                normalized: &normalized
            )
        }
        guard !edits.isEmpty else {
            return MarkdownCJKFormatting(
                source: source,
                selection: lower..<upper,
                insertedSpaces: 0,
                normalizedPunctuation: 0
            )
        }
        return MarkdownCJKFormatting(
            source: apply(edits, to: ns),
            selection: map(lower, through: edits)..<map(upper, through: edits),
            insertedSpaces: inserted,
            normalizedPunctuation: normalized
        )
    }

    // MARK: - Edits

    private struct Edit {
        let range: Range<Int>
        let replacement: String
    }

    private static func apply(_ edits: [Edit], to source: NSString) -> String {
        var output = ""
        output.reserveCapacity(source.length + edits.count * 2)
        var cursor = 0
        for edit in edits {
            let start = edit.range.lowerBound
            if start > cursor {
                output += source.substring(
                    with: NSRange(location: cursor, length: start - cursor)
                )
            }
            output += edit.replacement
            cursor = max(cursor, edit.range.upperBound)
        }
        if cursor < source.length {
            output += source.substring(from: cursor)
        }
        return output
    }

    /// Maps a UTF-16 offset through the edits that precede it.
    private static func map(_ offset: Int, through edits: [Edit]) -> Int {
        var mapped = offset
        for edit in edits {
            let delta = edit.replacement.utf16.count - edit.range.count
            if edit.range.upperBound <= offset {
                mapped += delta
            } else if edit.range.lowerBound < offset {
                // The offset sits inside a replaced unit; put it at the end.
                mapped += edit.replacement.utf16.count
                    - (offset - edit.range.lowerBound)
            } else {
                break
            }
        }
        return max(0, mapped)
    }

    // MARK: - Protected ranges

    private static func protectedRanges(
        in ast: SonovoAST,
        ns: NSString
    ) -> [Range<Int>] {
        var ranges: [Range<Int>] = []

        func add(_ range: SourceRange?) {
            guard let range else { return }
            add(range.lowerBound..<range.upperBound)
        }

        func add(_ range: Range<Int>) {
            let lower = min(max(range.lowerBound, 0), ns.length)
            let upper = min(max(range.upperBound, lower), ns.length)
            if lower < upper { ranges.append(lower..<upper) }
        }

        func addInline(_ node: Inline) {
            switch node {
            case .text, .softBreak, .lineBreak:
                break
            case let .inlineCode(_, range),
                 let .inlineHTML(_, range),
                 let .math(_, _, _, range):
                add(range)
            case let .emphasis(children, _),
                 let .strong(children, _),
                 let .strikethrough(children, _):
                children.forEach(addInline)
            case let .link(_, _, children, range):
                children.forEach(addInline)
                if let syntax = linkSyntaxRange(range, ns: ns) {
                    add(syntax)
                }
            case let .image(_, _, _, range), let .wikiLink(_, range),
                 let .footnoteReference(_, range):
                add(range)
            }
        }

        func addBlocks(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case let .paragraph(inlines, _), let .heading(_, inlines, _):
                    inlines.forEach(addInline)
                case let .blockQuote(children, _):
                    addBlocks(children)
                case let .list(list, _):
                    for item in list.items { addBlocks(item.blocks) }
                case let .codeBlock(_, range),
                     let .htmlBlock(_, range),
                     let .footnoteDefinition(_, range):
                    add(range)
                case let .table(table, _):
                    for cell in table.header { cell.inlines.forEach(addInline) }
                    for row in table.rows {
                        for cell in row { cell.inlines.forEach(addInline) }
                    }
                case let .definitionList(list, _):
                    for item in list.items {
                        for term in item.terms {
                            term.inlines.forEach(addInline)
                        }
                        for definition in item.definitions {
                            definition.inlines.forEach(addInline)
                        }
                    }
                case let .details(details, _):
                    details.summary.forEach(addInline)
                    addBlocks(details.blocks)
                case let .footnotes(section, _):
                    // The definition blocks are replaced by the synthesized
                    // section; its entries carry the authored content ranges.
                    for entry in section.entries {
                        add(entry.contentRange)
                    }
                case .thematicBreak, .tableOfContents:
                    break
                }
            }
        }

        if let frontmatter = ast.frontmatter { add(frontmatter.range) }
        for definition in ast.referenceDefinitions { add(definition.range) }
        addBlocks(ast.blocks)
        return ranges
    }

    /// The destination (and title) part of an inline link.
    ///
    /// The link text stays formattable, but the bytes from the closing bracket
    /// onward must not change. A shortcut reference has no visible
    /// destination; its label is the identity, so the whole node is protected.
    private static func linkSyntaxRange(
        _ range: SourceRange?,
        ns: NSString
    ) -> Range<Int>? {
        guard let range,
              range.lowerBound >= 0,
              range.upperBound <= ns.length else { return nil }
        let whole = range.lowerBound..<range.upperBound
        let slice = ns.substring(
            with: NSRange(location: range.lowerBound, length: range.length)
        ) as NSString
        // Classify only what follows the label's own closing bracket. A
        // destination may itself contain `][` — `[label](a][b)` is an inline
        // link — and searching for `][` anywhere put the protection boundary
        // inside the destination.
        guard let close = matchingLabelBracket(in: slice) else {
            return whole
        }
        let after = close + 1
        guard after < slice.length else { return whole }
        switch slice.character(at: after) {
        case 0x28: // `(`: inline destination and title
            return (range.lowerBound + close)..<range.upperBound
        case 0x5B: // `[`: reference label follows the closing bracket
            // A collapsed reference `[text][]` keeps its identity in the
            // text, so spacing it would stop it resolving to its definition.
            if after + 1 < slice.length,
               slice.character(at: after + 1) == 0x5D {
                return whole
            }
            return (range.lowerBound + close)..<range.upperBound
        default:
            // Shortcut reference: the text is the label.
            return whole
        }
    }

    /// The label's closing `]`, honoring nested brackets and backslash
    /// escapes. The slice starts at the link's opening `[` (or `![`).
    private static func matchingLabelBracket(in slice: NSString) -> Int? {
        var index = slice.character(at: 0) == 0x21 ? 1 : 0 // skip `!`
        guard index < slice.length,
              slice.character(at: index) == 0x5B else { return nil }
        var depth = 0
        var escaped = false
        index += 1
        while index < slice.length {
            let character = slice.character(at: index)
            if escaped {
                escaped = false
            } else if character == 0x5C {
                escaped = true
            } else if character == 0x5B {
                depth += 1
            } else if character == 0x5D {
                if depth == 0 { return index }
                depth -= 1
            }
            index += 1
        }
        return nil
    }

    private static func mergedRanges(
        _ ranges: [Range<Int>]
    ) -> [Range<Int>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<Int>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound
                    ..< max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: - Transform

    private static let urlPattern =
        #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s<>"'`()\[\]，。、！？；：）」』】》]+|mailto:[^\s<>"'`()\[\]，。、！？；：）」』】》]+"#

    private static let urlRegex = try? NSRegularExpression(
        pattern: urlPattern
    )

    private static func transform(
        gap: Range<Int>,
        ns: NSString,
        edits: inout [Edit],
        inserted: inout Int,
        normalized: inout Int
    ) {
        guard gap.lowerBound < gap.upperBound else { return }
        let text = ns.substring(
            with: NSRange(location: gap.lowerBound, length: gap.count)
        )
        let local = text as NSString
        var runStart = 0
        let matches = urlRegex?.matches(
            in: text,
            range: NSRange(location: 0, length: local.length)
        ) ?? []
        for match in matches {
            if match.range.location > runStart {
                transformRun(
                    local.substring(
                        with: NSRange(
                            location: runStart,
                            length: match.range.location - runStart
                        )
                    ),
                    base: gap.lowerBound + runStart,
                    edits: &edits,
                    inserted: &inserted,
                    normalized: &normalized
                )
            }
            runStart = match.range.location + match.range.length
        }
        if runStart < local.length {
            transformRun(
                local.substring(from: runStart),
                base: gap.lowerBound + runStart,
                edits: &edits,
                inserted: &inserted,
                normalized: &normalized
            )
        }
    }

    private static func transformRun(
        _ text: String,
        base: Int,
        edits: inout [Edit],
        inserted: inout Int,
        normalized: inout Int
    ) {
        guard !text.isEmpty else { return }
        var index = text.startIndex
        var offset = base
        var previous: Character?
        while index < text.endIndex {
            let character = text[index]
            let length = utf16Count(character)
            let currentOffset = offset
            let nextIndex = text.index(after: index)
            let next = nextIndex < text.endIndex ? text[nextIndex] : nil

            if let previous, shouldInsertSpace(between: previous, and: character) {
                edits.append(Edit(range: currentOffset..<currentOffset, replacement: " "))
                inserted += 1
            }
            if let replacement = normalizedPunctuation(
                for: character,
                previous: previous,
                next: next
            ) {
                edits.append(
                    Edit(
                        range: currentOffset..<(currentOffset + length),
                        replacement: String(replacement)
                    )
                )
                normalized += 1
            }
            previous = character
            offset += length
            index = nextIndex
        }
    }

    // MARK: - Rules

    private static func shouldInsertSpace(
        between left: Character,
        and right: Character
    ) -> Bool {
        if isCJK(left) { return isASCIILatinOrDigit(right) }
        if isASCIILatinOrDigit(left) { return isCJK(right) }
        return false
    }

    /// The documented punctuation table.
    private static let punctuation: [Character: Character] = [
        ",": "，",
        ".": "。",
        ":": "：",
        ";": "；",
        "!": "！",
        "?": "？"
    ]

    private static func normalizedPunctuation(
        for character: Character,
        previous: Character?,
        next: Character?
    ) -> Character? {
        guard let fullwidth = punctuation[character],
              let previous,
              isCJK(previous) else { return nil }
        switch character {
        case "!", "?":
            if let next, isASCIILatinOrDigit(next) { return nil }
            return fullwidth
        case ".":
            if let next {
                if isCJK(next) { return fullwidth }
                if next == " " || next == "\t" || next == "\n"
                    || next == "\r" {
                    return fullwidth
                }
                return nil
            }
            return fullwidth
        default:
            guard let next, isCJK(next) else { return nil }
            return fullwidth
        }
    }

    private static func isASCIILatinOrDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (value >= 0x30 && value <= 0x39)
            || (value >= 0x41 && value <= 0x5A)
            || (value >= 0x61 && value <= 0x7A)
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return isCJKScalar(scalar)
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, // Hangul Jamo
             0x2E80...0x2EFF, // CJK radicals supplement
             0x3005...0x3006, // iteration marks
             0x3040...0x309F, // Hiragana
             0x30A0...0x30FF, // Katakana
             0x3100...0x312F, // Bopomofo
             0x3130...0x318F, // Hangul compatibility Jamo
             0x3400...0x4DBF, // CJK Ext A
             0x4E00...0x9FFF, // CJK Unified
             0xA960...0xA97F, // Hangul Jamo Extended-A
             0xAC00...0xD7AF, // Hangul syllables
             0xD7B0...0xD7FF, // Hangul Jamo Extended-B
             0xF900...0xFAFF, // CJK compatibility ideographs
             0xFF66...0xFF9D, // Halfwidth Katakana
             0x20000...0x2FA1F: // CJK Ext B and compatibility supplement
            return true
        default:
            return false
        }
    }

    private static func utf16Count(_ character: Character) -> Int {
        character.unicodeScalars.reduce(0) { count, scalar in
            count + UTF16.width(scalar)
        }
    }
}
