import Foundation

public enum MarkdownLineCommand: Sendable, Equatable {
    case moveUp
    case moveDown
    case duplicate
    case delete
    case join
    case removeBlankLines
    case sortAscending
    case sortDescending
    case uppercase
    case lowercase
    case titleCase
    case toggleCase
    case trimTrailingSpaces
    case collapseBlankLines
}

public struct MarkdownLineEdit: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case handled
        case refused
        case notApplicable
    }

    public let outcome: Outcome
    public let range: Range<Int>?
    public let replacement: String?
    public let selection: Range<Int>?

    public init(
        outcome: Outcome,
        range: Range<Int>? = nil,
        replacement: String? = nil,
        selection: Range<Int>? = nil
    ) {
        self.outcome = outcome
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    public static let refused = MarkdownLineEdit(outcome: .refused)
    public static let notApplicable = MarkdownLineEdit(outcome: .notApplicable)
}

/// Line operations over canonical source.
///
/// Cleanup commands never rewrite a protected region: fenced or indented
/// code, frontmatter, inline code, URLs, and raw HTML. Case transforms skip
/// the same spans, so a URL or a code span keeps its exact text.
public enum MarkdownLineEditor {
    public static func edit(
        _ command: MarkdownLineCommand,
        source: String,
        selection: Range<Int>
    ) -> MarkdownLineEdit {
        let ns = source as NSString
        guard selection.lowerBound >= 0,
              selection.upperBound <= ns.length,
              selection.lowerBound <= selection.upperBound else {
            return .notApplicable
        }
        let table = LineTable(source: source)
        guard let first = table.lineIndex(at: selection.lowerBound),
              let last = table.lineIndex(
                  at: max(selection.lowerBound, selection.upperBound - 1)
              ) ?? table.lineIndex(at: selection.lowerBound) else {
            return .notApplicable
        }
        let block = first...last

        switch command {
        case .moveUp, .moveDown, .duplicate, .delete, .join:
            return structural(
                command,
                table: table,
                block: block,
                selection: selection
            )
        case .removeBlankLines, .sortAscending, .sortDescending,
             .trimTrailingSpaces, .collapseBlankLines:
            return lineCleanup(
                command,
                table: table,
                block: block,
                selection: selection,
                mask: protectedRanges(source: source, table: table)
            )
        case .uppercase, .lowercase, .titleCase, .toggleCase:
            return caseTransform(
                command,
                source: source,
                selection: selection,
                // Inline spans plus the block-level ones: frontmatter,
                // every fence kind, indented code, and raw HTML blocks are
                // content, not prose, and must survive case folding.
                mask: protectedSpans(source: source)
                    + protectedRanges(source: source, table: table)
            )
        }
    }

    // MARK: - Structural commands

    private static func structural(
        _ command: MarkdownLineCommand,
        table: LineTable,
        block: ClosedRange<Int>,
        selection: Range<Int>
    ) -> MarkdownLineEdit {
        var lines = table.lines
        let caretLine = table.lineIndex(at: selection.lowerBound) ?? block.lowerBound
        let caretColumn = selection.lowerBound - table.offset(line: caretLine, column: 0)
        var newCaretLine = caretLine
        var newCaretColumn = caretColumn

        switch command {
        case .moveUp:
            guard block.lowerBound > 0 else { return .refused }
            let previous = lines.remove(at: block.lowerBound - 1)
            lines.insert(previous, at: block.upperBound)
            newCaretLine = caretLine - 1
        case .moveDown:
            guard block.upperBound + 1 < lines.count else { return .refused }
            let next = lines.remove(at: block.upperBound + 1)
            lines.insert(next, at: block.lowerBound)
            newCaretLine = caretLine + 1
        case .duplicate:
            let copy = Array(lines[block.lowerBound...block.upperBound])
            lines.insert(contentsOf: copy, at: block.upperBound + 1)
        case .delete:
            lines.removeSubrange(block)
            if lines.isEmpty { lines = [""] }
            newCaretLine = min(block.lowerBound, lines.count - 1)
            newCaretColumn = 0
        case .join:
            guard block.lowerBound < block.upperBound else {
                return .refused
            }
            let joined = lines[block.lowerBound...block.upperBound]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            lines.replaceSubrange(block, with: [joined])
            newCaretLine = block.lowerBound
            newCaretColumn = joined.utf16.count
        default:
            return .notApplicable
        }

        let replacement = table.rebuild(lines)
        guard replacement != table.source else { return .notApplicable }
        let newTable = LineTable(lines: lines)
        let caretOffset = newTable.offset(
            line: min(newCaretLine, lines.count - 1),
            column: min(
                newCaretColumn,
                lines[min(newCaretLine, lines.count - 1)].utf16.count
            )
        )
        return MarkdownLineEdit(
            outcome: .handled,
            range: 0..<table.sourceLength,
            replacement: replacement,
            selection: caretOffset..<caretOffset
        )
    }

    // MARK: - Line cleanup

    private static func lineCleanup(
        _ command: MarkdownLineCommand,
        table: LineTable,
        block: ClosedRange<Int>,
        selection: Range<Int>,
        mask: [Range<Int>]
    ) -> MarkdownLineEdit {
        var lines = table.lines

        func isProtectedLine(_ index: Int) -> Bool {
            let start = table.offset(line: index, column: 0)
            return mask.contains {
                $0.lowerBound <= start && start < $0.upperBound
            }
        }

        switch command {
        case .removeBlankLines:
            for index in stride(
                from: block.upperBound,
                through: block.lowerBound,
                by: -1
            ) where !isProtectedLine(index)
                && lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.remove(at: index)
            }
        case .collapseBlankLines:
            var index = block.upperBound
            while index > block.lowerBound {
                let blank = lines[index]
                    .trimmingCharacters(in: .whitespaces).isEmpty
                let previousBlank = lines[index - 1]
                    .trimmingCharacters(in: .whitespaces).isEmpty
                if blank, previousBlank, !isProtectedLine(index) {
                    lines.remove(at: index)
                }
                index -= 1
            }
        case .trimTrailingSpaces:
            for index in block where !isProtectedLine(index) {
                lines[index] = lines[index]
                    .replacingOccurrences(
                        of: #"[ \t]+$"#,
                        with: "",
                        options: .regularExpression
                    )
            }
        case .sortAscending, .sortDescending:
            // Reordering lines out of a fence or the frontmatter corrupts
            // the document; a range that touches protected content refuses
            // instead of silently sorting around it.
            guard !block.contains(where: isProtectedLine) else {
                return .refused
            }
            let sorted = command == .sortAscending
                ? lines[block].sorted()
                : lines[block].sorted(by: >)
            lines.replaceSubrange(block, with: sorted)
        default:
            return .notApplicable
        }

        let replacement = table.rebuild(lines)
        guard replacement != table.source else { return .notApplicable }
        let newLength = (replacement as NSString).length
        let caret = min(selection.lowerBound, newLength)
        return MarkdownLineEdit(
            outcome: .handled,
            range: 0..<table.sourceLength,
            replacement: replacement,
            selection: caret..<caret
        )
    }

    // MARK: - Case transforms

    private static func caseTransform(
        _ command: MarkdownLineCommand,
        source: String,
        selection: Range<Int>,
        mask: [Range<Int>]
    ) -> MarkdownLineEdit {
        let ns = source as NSString
        let lower = selection.lowerBound
        let upper = selection.upperBound
        var result = ""
        var insideLength = 0
        var index = 0
        while index < ns.length {
            let characterRange = ns.rangeOfComposedCharacterSequence(at: index)
            let scalar = ns.substring(with: characterRange)
            let inside = index >= lower && index < max(upper, lower + 1)
            let protected = mask.contains {
                $0.lowerBound < characterRange.location + characterRange.length
                    && characterRange.location < $0.upperBound
            }
            let piece: String
            if inside, !protected {
                switch command {
                case .uppercase:
                    piece = scalar.uppercased()
                case .lowercase:
                    piece = scalar.lowercased()
                case .titleCase:
                    let before = index > 0
                        ? ns.character(at: index - 1)
                        : 0x20
                    piece = isWordBoundary(before)
                        ? scalar.uppercased()
                        : scalar.lowercased()
                case .toggleCase:
                    let upper = scalar.uppercased()
                    let lower = scalar.lowercased()
                    piece = scalar == upper && scalar != lower
                        ? lower
                        : upper
                default:
                    piece = scalar
                }
            } else {
                piece = scalar
            }
            result += piece
            if inside {
                // Case mappings change UTF-16 length (`ß` becomes `SS`);
                // the returned selection must cover what was produced.
                insideLength += piece.utf16.count
            }
            index = characterRange.location + characterRange.length
        }
        guard result != source else {
            return .notApplicable
        }
        let end = lower + insideLength
        let newSelection = upper > lower ? lower..<end : end..<end
        return MarkdownLineEdit(
            outcome: .handled,
            range: 0..<ns.length,
            replacement: result,
            selection: newSelection
        )
    }

    private static func isWordBoundary(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A
            || character == 0x28 || character == 0x5B
            || character == 0x7B || character == 0x22
            || character == 0x27 || character == 0x2D
            || character == 0x2A || character == 0x5F
    }

    // MARK: - Masks

    /// Source-only protected spans for case transforms: inline code, URLs,
    /// and raw HTML tags.
    static func protectedSpans(source: String) -> [Range<Int>] {
        let ns = source as NSString
        var ranges: [Range<Int>] = []
        var index = 0
        while index < ns.length {
            if ns.character(at: index) == 0x60 {
                var run = 0
                while index + run < ns.length,
                      ns.character(at: index + run) == 0x60 {
                    run += 1
                }
                var probe = index + run
                var matched = false
                while probe < ns.length {
                    guard ns.character(at: probe) == 0x60 else {
                        probe += 1
                        continue
                    }
                    var closing = 0
                    while probe + closing < ns.length,
                          ns.character(at: probe + closing) == 0x60 {
                        closing += 1
                    }
                    if closing == run {
                        ranges.append(
                            index..<(probe + closing)
                        )
                        index = probe + closing
                        matched = true
                        break
                    }
                    // A run of another length cannot close this span; skip
                    // the whole run, or its suffix looks like a closer.
                    probe += closing
                }
                if matched { continue }
                // An unmatched opener is literal text. Advance past the run;
                // otherwise this loop never terminates at end of file.
                index += run
                continue
            }
            index += 1
        }
        let urlPattern = try? NSRegularExpression(
            pattern: #"https?://[^\s<>()]+"#
        )
        urlPattern?.enumerateMatches(
            in: source,
            range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            guard let match else { return }
            let lower = match.range.location
            ranges.append(lower..<(lower + match.range.length))
        }
        let tagPattern = try? NSRegularExpression(
            pattern: #"</?[A-Za-z][^>\n]*>"#
        )
        tagPattern?.enumerateMatches(
            in: source,
            range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            guard let match else { return }
            let lower = match.range.location
            ranges.append(lower..<(lower + match.range.length))
        }
        ranges.append(contentsOf: linkDestinationRanges(in: ns))
        ranges.append(contentsOf: referenceDefinitionRanges(in: ns))
        return ranges
    }

    /// The destination part of every `](…)` link or image, relative paths
    /// and non-HTTP schemes included: a path is case-sensitive on the volume,
    /// so case transforms must not fold it.
    private static func linkDestinationRanges(
        in ns: NSString
    ) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var scan = 0
        while scan + 1 < ns.length {
            guard ns.character(at: scan) == 0x5D, // ]
                  ns.character(at: scan + 1) == 0x28 else { // (
                scan += 1
                continue
            }
            var start = scan + 2
            while start < ns.length,
                  ns.character(at: start) == 0x20
                    || ns.character(at: start) == 0x09
                    || ns.character(at: start) == 0x0A {
                start += 1
            }
            guard start < ns.length else { break }
            if ns.character(at: start) == 0x3C { // <
                var end = start + 1
                while end < ns.length,
                      ns.character(at: end) != 0x3E,
                      ns.character(at: end) != 0x0A {
                    end += 1
                }
                if end < ns.length, ns.character(at: end) == 0x3E {
                    ranges.append(start..<(end + 1))
                    scan = end + 1
                } else {
                    scan = start
                }
                continue
            }
            var end = start
            var depth = 0
            while end < ns.length {
                let character = ns.character(at: end)
                if character == 0x0A
                    || character == 0x20
                    || character == 0x09 {
                    break
                }
                if character == 0x5C {
                    end = min(end + 2, ns.length)
                    continue
                }
                if character == 0x28 { depth += 1 }
                if character == 0x29 {
                    if depth == 0 { break }
                    depth -= 1
                }
                end += 1
            }
            if end > start { ranges.append(start..<end) }
            scan = max(scan + 2, end)
        }
        return ranges
    }

    /// The destination and title of a `[label]: …` reference definition.
    private static func referenceDefinitionRanges(
        in ns: NSString
    ) -> [Range<Int>] {
        guard let pattern = try? NSRegularExpression(
            pattern: #"(?m)^ {0,3}\[[^\]\n]+\]:[ \t]*(\S[^\n]*)$"#
        ) else {
            return []
        }
        var ranges: [Range<Int>] = []
        pattern.enumerateMatches(
            in: ns as String,
            range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            guard let match else { return }
            let content = match.range(at: 1)
            guard content.location != NSNotFound else { return }
            ranges.append(
                content.location..<(content.location + content.length)
            )
        }
        return ranges
    }

    /// One line with its blockquote and list container prefixes removed, so a
    /// fence marker nested in a container is recognized. Repeated prefixes
    /// handle `> - ~~~`.
    private static func containerStripped(_ line: String) -> Substring {
        var remainder = line[...]
        var rounds = 0
        while rounds < 32 {
            rounds += 1
            var probe = remainder.drop(while: { $0 == " " || $0 == "\t" })
            if probe.first == ">" {
                probe = probe.dropFirst()
                if probe.first == " " { probe = probe.dropFirst() }
                remainder = probe
                continue
            }
            if let first = probe.first,
               first == "-" || first == "*" || first == "+" {
                var after = probe.dropFirst()
                if after.first == " " || after.first == "\t" {
                    after = after.drop(while: {
                        $0 == " " || $0 == "\t"
                    })
                    remainder = after
                    continue
                }
            }
            let digits = probe.prefix(while: \.isNumber)
            if !digits.isEmpty, digits.count <= 9 {
                let afterDigits = probe.dropFirst(digits.count)
                if let punctuation = afterDigits.first,
                   punctuation == "." || punctuation == ")" {
                    var after = afterDigits.dropFirst()
                    if after.first == " " || after.first == "\t" {
                        after = after.drop(while: {
                            $0 == " " || $0 == "\t"
                        })
                        remainder = after
                        continue
                    }
                }
            }
            break
        }
        return remainder
    }

    /// Protected line-level spans: frontmatter, fenced code, and indented
    /// code. Cleanup commands skip any line that starts inside one.
    static func protectedRanges(
        source: String,
        table: LineTable
    ) -> [Range<Int>] {
        let ns = source as NSString
        var ranges: [Range<Int>] = []
        if table.lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for index in 1..<table.lines.count {
                let trimmed = table.lines[index]
                    .trimmingCharacters(in: .whitespaces)
                if trimmed == "---" || trimmed == "..." {
                    let end = table.offset(
                        line: index,
                        column: table.lines[index].utf16.count
                    )
                    ranges.append(0..<end)
                    break
                }
            }
        }
        var openFence: Int?
        var fenceMarker: unichar = 0
        var fenceLength = 0
        for (index, line) in table.lines.enumerated() {
            let start = table.offset(line: index, column: 0)
            // A fence lives inside its container: `> ~~~` and `- ``` ` open
            // a fence exactly as an unquoted one does, so the marker must be
            // read after the blockquote and list prefixes.
            let trimmed = containerStripped(line)
            if let first = trimmed.first, first == "`" || first == "~" {
                let run = trimmed.prefix(while: { $0 == first }).count
                if run >= 3 {
                    let marker: unichar = first == "`" ? 0x60 : 0x7E
                    if openFence == nil {
                        openFence = start
                        fenceMarker = marker
                        fenceLength = run
                        continue
                    } else if marker == fenceMarker, run >= fenceLength,
                              trimmed.dropFirst(run).allSatisfy({
                                  $0 == " " || $0 == "\t"
                              }) {
                        ranges.append(openFence!..<(start + line.utf16.count))
                        openFence = nil
                    }
                }
            }
        }
        if let openFence {
            ranges.append(openFence..<ns.length)
        }
        // Indented code: four-space lines after a blank line, ending at the
        // first non-blank unindented line. Protecting through EOF made every
        // paragraph after a code block uneditable.
        var previousBlank = true
        var lineIndex = 0
        while lineIndex < table.lines.count {
            let line = table.lines[lineIndex]
            let start = table.offset(line: lineIndex, column: 0)
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            let indented = line.hasPrefix("    ") || line.hasPrefix("\t")
            if indented, previousBlank {
                var last = lineIndex
                while last + 1 < table.lines.count {
                    let next = table.lines[last + 1]
                    let nextBlank = next
                        .trimmingCharacters(in: .whitespaces).isEmpty
                    let nextIndented = next.hasPrefix("    ")
                        || next.hasPrefix("\t")
                    guard nextBlank || nextIndented else { break }
                    last += 1
                }
                let upper = table.offset(
                    line: last,
                    column: table.lines[last].utf16.count
                )
                ranges.append(start..<upper)
                lineIndex = last + 1
                previousBlank = false
                continue
            }
            previousBlank = blank
            lineIndex += 1
        }
        // Raw HTML blocks whose content is code, not prose. Case folding
        // inside a script or a style element corrupts it.
        var openHTML: (tag: String, start: Int)?
        for (index, line) in table.lines.enumerated() {
            let start = table.offset(line: index, column: 0)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
                .lowercased()
            if let open = openHTML {
                if trimmed.contains("</" + open.tag) {
                    ranges.append(open.start..<(start + line.utf16.count))
                    openHTML = nil
                }
                continue
            }
            for tag in ["script", "style", "pre", "textarea"] {
                guard trimmed.hasPrefix("<" + tag) else { continue }
                let after = trimmed.dropFirst(tag.count + 1).first
                guard after == ">" || after == " " || after == "\t"
                    || after == "/" else { continue }
                if trimmed.contains("</" + tag) {
                    ranges.append(start..<(start + line.utf16.count))
                } else {
                    openHTML = (tag, start)
                }
                break
            }
        }
        if let openHTML {
            ranges.append(openHTML.start..<ns.length)
        }
        return ranges
    }
}

/// Lines with their offsets. Offsets are UTF-16, matching source ranges.
struct LineTable {
    let lines: [String]
    let source: String
    private let starts: [Int]

    var sourceLength: Int { (source as NSString).length }

    init(source: String) {
        let ns = source as NSString
        var lines: [String] = []
        var starts: [Int] = []
        var lineStart = 0
        starts.append(0)
        var index = 0
        while index < ns.length {
            if ns.character(at: index) == 0x0A {
                lines.append(
                    ns.substring(
                        with: NSRange(
                            location: lineStart,
                            length: index - lineStart
                        )
                    )
                )
                lineStart = index + 1
                starts.append(lineStart)
            }
            index += 1
        }
        lines.append(
            ns.substring(
                with: NSRange(
                    location: lineStart,
                    length: ns.length - lineStart
                )
            )
        )
        self.lines = lines
        self.starts = starts
        self.source = source
    }

    init(lines: [String]) {
        self.lines = lines
        self.source = lines.joined(separator: "\n")
        var starts: [Int] = []
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += line.utf16.count + 1
        }
        self.starts = starts
    }

    func offset(line: Int, column: Int) -> Int {
        guard line >= 0, line < lines.count else { return 0 }
        return starts[line] + min(max(column, 0), lines[line].utf16.count)
    }

    func lineIndex(at offset: Int) -> Int? {
        guard !lines.isEmpty else { return nil }
        if offset >= starts[starts.count - 1] {
            return lines.count - 1
        }
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// The split keeps a trailing empty line for a source that ends with a
    /// newline, so joining reproduces the original exactly.
    func rebuild(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }
}
