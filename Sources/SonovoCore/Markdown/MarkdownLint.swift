import Foundation

/// One lint result over an exact source range.
public struct MarkdownDiagnostic: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
        case error
        case warning
    }

    public let ruleID: String
    public let severity: Severity
    public let range: Range<Int>
    public let message: String

    public init(
        ruleID: String,
        severity: Severity,
        range: Range<Int>,
        message: String
    ) {
        self.ruleID = ruleID
        self.severity = severity
        self.range = range
        self.message = message
    }
}

public struct MarkdownLintResult: Sendable, Equatable {
    public let documentID: UUID?
    public let revision: UInt64?
    public let diagnostics: [MarkdownDiagnostic]

    public init(
        documentID: UUID? = nil,
        revision: UInt64? = nil,
        diagnostics: [MarkdownDiagnostic]
    ) {
        self.documentID = documentID
        self.revision = revision
        self.diagnostics = diagnostics
    }
}

/// Correctness-only lint over canonical Markdown source.
///
/// The engine performs no filesystem access. Local link existence is appended
/// later by the probe service. One protected-region mask covers fenced and
/// indented code, frontmatter, inline code, and raw HTML, so a construct that
/// looks like a defect inside code is never reported.
public enum MarkdownLintEngine {
    public static func lint(
        source: String,
        ast: SonovoAST,
        documentID: UUID? = nil,
        revision: UInt64? = nil
    ) -> MarkdownLintResult {
        let ns = source as NSString
        let mask = protectedRanges(source: source, ast: ast)
        var diagnostics: [MarkdownDiagnostic] = []

        appendReferenceDiagnostics(
            ns: ns,
            ast: ast,
            mask: mask,
            into: &diagnostics
        )
        appendTableDiagnostics(ns: ns, mask: mask, into: &diagnostics)
        appendHeadingDiagnostics(ns: ns, ast: ast, mask: mask, into: &diagnostics)
        appendInlineDiagnostics(
            ns: ns,
            mask: mask,
            into: &diagnostics
        )
        appendFenceDiagnostics(ast: ast, source: source, into: &diagnostics)
        appendLinkDiagnostics(ast: ast, into: &diagnostics)
        appendDefinitionDiagnostics(
            ast: ast,
            uses: referenceUses(in: ns),
            mask: mask,
            into: &diagnostics
        )

        diagnostics.sort {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.ruleID < $1.ruleID
        }
        return MarkdownLintResult(
            documentID: documentID,
            revision: revision,
            diagnostics: diagnostics
        )
    }

    // MARK: - Protected regions

    /// Ranges where lint must not report anything: frontmatter, fenced code,
    /// inline code, and raw HTML. Indented code is added by line shape.
    static func protectedRanges(
        source: String,
        ast: SonovoAST
    ) -> [Range<Int>] {
        let ns = source as NSString
        var ranges: [Range<Int>] = []
        if let frontmatter = ast.frontmatter?.range {
            ranges.append(frontmatter.lowerBound..<frontmatter.upperBound)
        }
        ranges.append(contentsOf: fencedCodeRanges(ns: ns))
        ranges.append(contentsOf: indentedCodeRanges(ns: ns))
        // The AST knows the true extent of code and HTML blocks, including
        // a fence inside a block quote: a raw line scan missed the `>` and
        // let reference-shaped text inside them reach the rules.
        walkBlocks(ast.blocks) { block in
            switch block {
            case let .codeBlock(_, range), let .htmlBlock(_, range):
                if let range {
                    ranges.append(range.lowerBound..<range.upperBound)
                }
            default:
                break
            }
        }
        walkInlines(ast.blocks) { inline in
            switch inline {
            case .inlineCode(_, let range), .inlineHTML(_, let range):
                if let range {
                    ranges.append(
                        range.lowerBound..<range.upperBound
                    )
                }
            default:
                break
            }
        }
        return ranges
    }

    private static func fencedCodeRanges(ns: NSString) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var openStart: Int?
        var openMarker: unichar = 0
        var openLength = 0
        var lineStart = 0
        while lineStart < ns.length {
            var lineEnd = lineStart
            while lineEnd < ns.length, ns.character(at: lineEnd) != 0x0A {
                lineEnd += 1
            }
            let line = ns.substring(
                with: NSRange(location: lineStart, length: lineEnd - lineStart)
            )
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if let first = trimmed.first, first == "`" || first == "~" {
                let run = trimmed.prefix(while: { $0 == first }).count
                if run >= 3 {
                    let marker: unichar = first == "`" ? 0x60 : 0x7E
                    if openStart == nil {
                        openStart = lineStart
                        openMarker = marker
                        openLength = run
                    } else if marker == openMarker, run >= openLength,
                              trimmed.dropFirst(run).allSatisfy({
                                  $0 == " " || $0 == "\t"
                              }) {
                        ranges.append(openStart!..<lineEnd)
                        openStart = nil
                    }
                }
            }
            lineStart = lineEnd + 1
        }
        if let openStart {
            ranges.append(openStart..<ns.length)
        }
        return ranges
    }

    /// A line indented four or more columns directly after a blank line is
    /// indented code. This is deliberately conservative: a false positive
    /// here hides real diagnostics, so only the unambiguous form counts.
    private static func indentedCodeRanges(ns: NSString) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var previousBlank = true
        var lineStart = 0
        var blockStart: Int?
        while lineStart < ns.length {
            var lineEnd = lineStart
            while lineEnd < ns.length, ns.character(at: lineEnd) != 0x0A {
                lineEnd += 1
            }
            let line = ns.substring(
                with: NSRange(location: lineStart, length: lineEnd - lineStart)
            )
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            let indented = line.hasPrefix("    ") || line.hasPrefix("\t")
            if indented, previousBlank {
                blockStart = blockStart ?? lineStart
            } else if !indented, !blank, let start = blockStart {
                ranges.append(start..<lineStart)
                blockStart = nil
            }
            if blank, let start = blockStart {
                ranges.append(start..<lineStart)
                blockStart = nil
            }
            previousBlank = blank
            lineStart = lineEnd + 1
        }
        if let blockStart {
            ranges.append(blockStart..<ns.length)
        }
        return ranges
    }

    private static func isProtected(
        _ range: Range<Int>,
        by mask: [Range<Int>]
    ) -> Bool {
        mask.contains { $0.lowerBound < range.upperBound && range.lowerBound < $0.upperBound }
    }

    // MARK: - Reference uses

    struct ReferenceUse {
        let label: String
        let range: Range<Int>
        let isImage: Bool
        let style: String
    }

    /// Scans full/collapsed reference uses and shortcut uses. Inline links are
    /// skipped; escaped brackets are literal.
    static func referenceUses(in ns: NSString) -> [ReferenceUse] {
        var uses: [ReferenceUse] = []
        var index = 0
        while index < ns.length {
            let character = ns.character(at: index)
            if character == 0x5C {
                index += 2
                continue
            }
            guard character == 0x5B else {
                index += 1
                continue
            }
            let isImage = index > 0 && ns.character(at: index - 1) == 0x21
            let constructStart = isImage ? index - 1 : index
            guard let close = matchingBracket(in: ns, from: index) else {
                index += 1
                continue
            }
            let text = ns.substring(
                with: NSRange(
                    location: index + 1,
                    length: close - index - 1
                )
            )
            let after = close + 1
            if after < ns.length, ns.character(at: after) == 0x3A {
                // A reference definition line, not a use.
                index = close + 1
                continue
            }
            if after < ns.length, ns.character(at: after) == 0x28 {
                // Inline link: skip to its closing parenthesis.
                index = skipParenthesis(ns, from: after)
                continue
            }
            if after < ns.length, ns.character(at: after) == 0x5B {
                guard let labelClose = matchingBracket(in: ns, from: after)
                else {
                    index = close + 1
                    continue
                }
                let label = ns.substring(
                    with: NSRange(
                        location: after + 1,
                        length: labelClose - after - 1
                    )
                )
                let effective = label.isEmpty ? text : label
                uses.append(
                    ReferenceUse(
                        label: effective,
                        range: constructStart..<(labelClose + 1),
                        isImage: isImage,
                        style: label.isEmpty ? "collapsed" : "reference"
                    )
                )
                index = labelClose + 1
                continue
            }
            uses.append(
                ReferenceUse(
                    label: text,
                    range: constructStart..<(close + 1),
                    isImage: isImage,
                    style: "shortcut"
                )
            )
            index = close + 1
        }
        return uses
    }

    private static func matchingBracket(
        in ns: NSString,
        from open: Int
    ) -> Int? {
        var depth = 0
        var index = open + 1
        while index < ns.length {
            let character = ns.character(at: index)
            if character == 0x5C {
                index += 2
                continue
            }
            if character == 0x5B {
                depth += 1
            } else if character == 0x5D {
                if depth == 0 { return index }
                depth -= 1
            }
            index += 1
        }
        return nil
    }

    private static func skipParenthesis(
        _ ns: NSString,
        from open: Int
    ) -> Int {
        var depth = 0
        var index = open + 1
        while index < ns.length {
            let character = ns.character(at: index)
            if character == 0x5C {
                index += 2
                continue
            }
            if character == 0x28 {
                depth += 1
            } else if character == 0x29 {
                if depth == 0 { return index + 1 }
                depth -= 1
            } else if character == 0x0A {
                return index
            }
            index += 1
        }
        return ns.length
    }

    // MARK: - Rules

    private static func appendReferenceDiagnostics(
        ns: NSString,
        ast: SonovoAST,
        mask: [Range<Int>],
        into diagnostics: inout [MarkdownDiagnostic]
    ) {
        let definitions = ast.referenceDefinitions
        for use in referenceUses(in: ns) {
            guard use.style != "shortcut" else { continue }
            // Footnote syntax owns `[^label]`; its definitions are not link
            // targets, so their absence from `referenceDefinitions` is not
            // an undefined reference.
            guard !use.label.hasPrefix("^") else { continue }
            guard !isProtected(use.range, by: mask) else { continue }
            // CommonMark folds case and collapses internal whitespace; it
            // does not ignore diacritics. A whitespace-equivalent label is
            // the same reference, while `cafe` and `café` are distinct.
            let normalizedUse = normalizedReferenceLabel(use.label)
            let found = definitions.contains {
                normalizedReferenceLabel($0.label).compare(
                    normalizedUse,
                    options: [.caseInsensitive]
                ) == .orderedSame
            }
            if !found {
                diagnostics.append(
                    MarkdownDiagnostic(
                        ruleID: "E01",
                        severity: .error,
                        range: use.range,
                        message: "Undefined reference: \(use.label)"
                    )
                )
            }
        }
    }

    private static func appendTableDiagnostics(
        ns: NSString,
        mask: [Range<Int>],
        into diagnostics: inout [MarkdownDiagnostic]
    ) {
        for table in MarkdownTableScanner.tables(in: ns as String) {
            for rowIndex in table.columnMismatchRows {
                guard rowIndex >= 0, rowIndex < table.body.count else {
                    continue
                }
                let row = table.body[rowIndex]
                let range = row.range.lowerBound..<row.range.upperBound
                // The scanner excludes code but sees frontmatter and raw
                // HTML as ordinary text; a table-shaped literal there is not
                // a table.
                guard !isProtected(range, by: mask) else { continue }
                diagnostics.append(
                    MarkdownDiagnostic(
                        ruleID: "E02",
                        severity: .error,
                        range: range,
                        message: "Table row has a different column count"
                    )
                )
            }
        }
    }

    private static func appendHeadingDiagnostics(
        ns: NSString,
        ast: SonovoAST,
        mask: [Range<Int>],
        into diagnostics: inout [MarkdownDiagnostic]
    ) {
        // E04: an ATX heading without a space after the hashes.
        var lineStart = 0
        while lineStart < ns.length {
            var lineEnd = lineStart
            while lineEnd < ns.length, ns.character(at: lineEnd) != 0x0A {
                lineEnd += 1
            }
            var index = lineStart
            while index < lineEnd, isSpace(ns.character(at: index)) {
                index += 1
            }
            // Skip container markers: `> ` and list markers.
            while index < lineEnd {
                let character = ns.character(at: index)
                if character == 0x3E {
                    index += 1
                    if index < lineEnd, isSpace(ns.character(at: index)) {
                        index += 1
                    }
                    while index < lineEnd, isSpace(ns.character(at: index)) {
                        index += 1
                    }
                    continue
                }
                break
            }
            let hashes = hashRun(ns, from: index, to: lineEnd)
            if hashes > 0, hashes <= 6, index + hashes < lineEnd {
                let next = ns.character(at: index + hashes)
                let headingRange = index..<(index + hashes + 1)
                if !isSpace(next), next != 0x23,
                   !isProtected(headingRange, by: mask) {
                    diagnostics.append(
                        MarkdownDiagnostic(
                            ruleID: "E04",
                            severity: .error,
                            range: headingRange,
                            message: "ATX heading needs a space after #"
                        )
                    )
                }
            }
            lineStart = lineEnd + 1
        }

        // W01: heading level skip.
        var previous: Int?
        for entry in HeadingIndex(ast: ast).headings {
            if let previous, entry.level > previous + 1 {
                if let range = entry.range {
                    diagnostics.append(
                        MarkdownDiagnostic(
                            ruleID: "W01",
                            severity: .warning,
                            range: range.lowerBound..<range.upperBound,
                            message: "Heading level jumps from \(previous)"
                        )
                    )
                }
            }
            previous = entry.level
        }
    }

    private static func appendInlineDiagnostics(
        ns: NSString,
        mask: [Range<Int>],
        into diagnostics: inout [MarkdownDiagnostic]
    ) {
        // E03 reversed link: `(text)[url]`.
        let reversed = try? NSRegularExpression(
            pattern: #"\(([^)\n]+)\)\[([^\]\n]+)\]"#
        )
        reversed?.enumerateMatches(
            in: ns as String,
            range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            guard let match else { return }
            let lower = match.range.location
            let upper = lower + match.range.length
            let range = lower..<upper
            guard !isProtected(range, by: mask) else { return }
            diagnostics.append(
                MarkdownDiagnostic(
                    ruleID: "E03",
                    severity: .error,
                    range: range,
                    message: "Link text and destination are reversed"
                )
            )
        }

        // E05 symmetric spaces inside emphasis, excluding arithmetic like
        // `3 * 4 * 5`: the opener must not follow a space or digit.
        var index = 0
        while index < ns.length {
            let character = ns.character(at: index)
            guard character == 0x2A || character == 0x5F else {
                index += 1
                continue
            }
            if index > 0 {
                let before = ns.character(at: index - 1)
                if isSpace(before) || isDigit(before) {
                    index += 1
                    continue
                }
            }
            var probe = index + 1
            while probe < ns.length, isSpace(ns.character(at: probe)) {
                probe += 1
            }
            guard probe > index + 1 else {
                index += 1
                continue
            }
            var closer = probe
            while closer < ns.length,
                  ns.character(at: closer) != character,
                  ns.character(at: closer) != 0x0A {
                closer += 1
            }
            guard closer < ns.length,
                  ns.character(at: closer) == character else {
                index += 1
                continue
            }
            guard closer > probe, isSpace(ns.character(at: closer - 1))
            else {
                index = closer + 1
                continue
            }
            let range = index..<(closer + 1)
            if !isProtected(range, by: mask) {
                diagnostics.append(
                    MarkdownDiagnostic(
                        ruleID: "E05",
                        severity: .warning,
                        range: range,
                        message: "Spaces inside emphasis delimiters"
                    )
                )
            }
            index = closer + 1
        }
    }

    /// Reports a fenced block the parser could not close.
    ///
    /// The AST already knows which blocks are fenced and where their content
    /// ends, including container prefixes and frontmatter — a raw line scan
    /// re-implemented the grammar and produced false positives on indented
    /// literal backticks inside block quotes.
    private static func appendFenceDiagnostics(
        ast: SonovoAST,
        source: String,
        into diagnostics: inout [MarkdownDiagnostic]
    ) {
        let ns = source as NSString
        walkBlocks(ast.blocks) { block in
            guard case let .codeBlock(code, range) = block,
                  code.fenced,
                  let range,
                  range.lowerBound >= 0,
                  range.upperBound <= ns.length,
                  range.lowerBound < range.upperBound else {
                return
            }
            let slice = ns.substring(
                with: NSRange(
                    location: range.lowerBound,
                    length: range.upperBound - range.lowerBound
                )
            ) as NSString
            let lines = slice.components(separatedBy: "\n")
            guard let opener = lines.first else { return }
            let openerMarker = fenceMarker(in: opener)
            guard let openerMarker else { return }
            let lastLine = lines.last ?? ""
            // A one-line block is only the opener; it cannot close itself.
            let closed = lines.count >= 2 && isClosingFence(
                lastLine,
                marker: openerMarker.character,
                minimum: openerMarker.length
            )
            guard !closed else { return }
            diagnostics.append(
                MarkdownDiagnostic(
                    ruleID: "E08",
                    severity: .error,
                    range: range.lowerBound..<range.upperBound,
                    message: "Unclosed fenced code block"
                )
            )
        }
    }

    /// The fence run that opens a line, after any container marker.
    private static func fenceMarker(
        in line: String
    ) -> (character: Character, length: Int)? {
        let trimmed = stripContainerPrefixes(line)
        guard let first = trimmed.first,
              first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix(while: { $0 == first }).count
        guard run >= 3 else { return nil }
        return (first, run)
    }

    private static func isClosingFence(
        _ line: String,
        marker: Character,
        minimum: Int
    ) -> Bool {
        let trimmed = stripContainerPrefixes(line)
        let run = trimmed.prefix(while: { $0 == marker }).count
        guard run >= minimum else { return false }
        return trimmed.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// A line without its blockquote markers and leading whitespace, so a
    /// fenced block inside a quote is measured on its own text.
    private static func stripContainerPrefixes(_ line: String) -> String {
        var rest = Substring(line)
        while true {
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard rest.first == ">" else { break }
            rest = rest.dropFirst()
            if rest.first == " " || rest.first == "\t" {
                rest = rest.dropFirst()
            }
        }
        return String(rest.drop(while: { $0 == " " || $0 == "\t" }))
    }

    /// Visits every block, descending into containers.
    static func walkBlocks(
        _ blocks: [Block],
        _ visit: (Block) -> Void
    ) {
        for block in blocks {
            visit(block)
            switch block {
            case let .blockQuote(children, _):
                walkBlocks(children, visit)
            case let .list(list, _):
                for item in list.items {
                    walkBlocks(item.blocks, visit)
                }
            case let .details(details, _):
                walkBlocks(details.blocks, visit)
            case let .definitionList(list, _):
                _ = list
            default:
                break
            }
        }
    }

    private static func appendLinkDiagnostics(
        ast: SonovoAST,
        into diagnostics: inout [MarkdownDiagnostic]
    ) {
        let headings = HeadingIndex(ast: ast)
        walkInlines(ast.blocks) { inline in
            switch inline {
            case .link(let destination, _, let children, let range):
                guard let range else { return }
                let span = range.lowerBound..<range.upperBound
                let text = HeadingIndex.renderedText(children)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty, !containsImage(children) {
                    diagnostics.append(
                        MarkdownDiagnostic(
                            ruleID: "E06",
                            severity: .error,
                            range: span,
                            message: "Link has no text"
                        )
                    )
                }
                let trimmed = destination
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    diagnostics.append(
                        MarkdownDiagnostic(
                            ruleID: "W05",
                            severity: .warning,
                            range: span,
                            message: "Link destination is empty"
                        )
                    )
                } else if trimmed.hasPrefix("#"), trimmed.count > 1 {
                    let fragment = String(trimmed.dropFirst())
                    let decoded = fragment.removingPercentEncoding
                        ?? fragment
                    if headings.heading(forFragment: decoded) == nil {
                        diagnostics.append(
                            MarkdownDiagnostic(
                                ruleID: "W04",
                                severity: .warning,
                                range: span,
                                message: "Fragment matches no heading: \(decoded)"
                            )
                        )
                    }
                }
            case .image(_, _, let description, let range):
                guard let range else { return }
                let alt = HeadingIndex.renderedText(description)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if alt.isEmpty {
                    diagnostics.append(
                        MarkdownDiagnostic(
                            ruleID: "W02",
                            severity: .warning,
                            range: range.lowerBound..<range.upperBound,
                            message: "Image has no alt text"
                        )
                    )
                }
            default:
                break
            }
        }
    }

    private static func containsImage(_ inlines: [Inline]) -> Bool {
        for inline in inlines {
            switch inline {
            case .image:
                return true
            case .emphasis(let children, _),
                 .strong(let children, _),
                 .strikethrough(let children, _),
                 .link(_, _, let children, _):
                if containsImage(children) { return true }
            default:
                break
            }
        }
        return false
    }

    private static func appendDefinitionDiagnostics(
        ast: SonovoAST,
        uses: [ReferenceUse],
        mask: [Range<Int>],
        into diagnostics: inout [MarkdownDiagnostic]
    ) {
        let definitions = ast.referenceDefinitions
        // E07 duplicate labels; the first wins. The same normalized label
        // rule decides duplicates and uses, or the two rules disagree.
        var seen: [String: Int] = [:]
        for definition in definitions {
            let key = normalizedReferenceLabel(definition.label)
            if seen[key] != nil, let range = definition.range {
                diagnostics.append(
                    MarkdownDiagnostic(
                        ruleID: "E07",
                        severity: .error,
                        range: range.lowerBound..<range.upperBound,
                        message: "Duplicate reference definition: \(definition.label)"
                    )
                )
            } else {
                seen[key] = 1
            }
        }
        // W03 unused definitions. Only uses outside protected regions count.
        for definition in definitions {
            let key = normalizedReferenceLabel(definition.label)
            let used = uses.contains { use in
                !isProtected(use.range, by: mask)
                    && normalizedReferenceLabel(use.label)
                        .compare(key, options: [.caseInsensitive])
                        == .orderedSame
            }
            if !used, let range = definition.range {
                diagnostics.append(
                    MarkdownDiagnostic(
                        ruleID: "W03",
                        severity: .warning,
                        range: range.lowerBound..<range.upperBound,
                        message: "Unused reference definition: \(definition.label)"
                    )
                )
            }
        }
    }

    // MARK: - Helpers

    /// CommonMark's label rule: trim and collapse internal whitespace, then
    /// fold case. Diacritics stay significant.
    static func normalizedReferenceLabel(_ label: String) -> String {
        // CommonMark compares labels case-insensitively after collapsing
        // whitespace; the same key decides uses, definitions, and duplicates.
        label.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    static func walkInlines(
        _ blocks: [Block],
        _ visit: (Inline) -> Void
    ) {
        for block in blocks {
            switch block {
            case .paragraph(let inlines, _),
                 .heading(_, let inlines, _):
                walk(inlines, visit)
            case .blockQuote(let children, _):
                walkInlines(children, visit)
            case .list(let list, _):
                for item in list.items {
                    walkInlines(item.blocks, visit)
                }
            case .definitionList(let list, _):
                for item in list.items {
                    for term in item.terms { walk(term.inlines, visit) }
                    for definition in item.definitions {
                        walk(definition.inlines, visit)
                    }
                }
            case .table(let table, _):
                // A table cell is an inline container like any paragraph;
                // skipping it hid its links from every inline rule.
                for cell in table.header { walk(cell.inlines, visit) }
                for row in table.rows {
                    for cell in row { walk(cell.inlines, visit) }
                }
            case .details(let details, _):
                walk(details.summary, visit)
                walkInlines(details.blocks, visit)
            default:
                break
            }
        }
    }

    private static func walk(
        _ inlines: [Inline],
        _ visit: (Inline) -> Void
    ) {
        for inline in inlines {
            visit(inline)
            switch inline {
            case .emphasis(let children, _),
                 .strong(let children, _),
                 .strikethrough(let children, _):
                walk(children, visit)
            case .link(_, _, let children, _):
                walk(children, visit)
            case .image(_, _, let description, _):
                walk(description, visit)
            default:
                break
            }
        }
    }

    private static func hashRun(
        _ ns: NSString,
        from start: Int,
        to end: Int
    ) -> Int {
        var index = start
        while index < end, ns.character(at: index) == 0x23 {
            index += 1
        }
        return index - start
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= 0x30 && character <= 0x39
    }
}
