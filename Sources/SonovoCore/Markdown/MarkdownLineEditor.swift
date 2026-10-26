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
                mask: protectedSpans(source: source)
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
        let start = table.offset(line: block.lowerBound, column: 0)
        let end = table.offset(
            line: block.upperBound,
            column: lines[block.upperBound].utf16.count
        )
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
        let newTable = LineTable(lines: lines, trailingNewline: table.trailingNewline)
        let caretOffset = newTable.offset(
            line: min(newCaretLine, lines.count - 1),
            column: min(
                newCaretColumn,
                lines[min(newCaretLine, lines.count - 1)].utf16.count
            )
        )
        _ = start
        _ = end
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
        case .sortAscending:
            let sorted = lines[block].sorted()
            lines.replaceSubrange(block, with: sorted)
        case .sortDescending:
            let sorted = lines[block].sorted(by: >)
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
        var index = 0
        while index < ns.length {
            let characterRange = ns.rangeOfComposedCharacterSequence(at: index)
            let scalar = ns.substring(with: characterRange)
            let inside = index >= lower && index < max(upper, lower + 1)
            let protected = mask.contains {
                $0.lowerBound < characterRange.location + characterRange.length
                    && characterRange.location < $0.upperBound
            }
            if inside, !protected {
                switch command {
                case .uppercase:
                    result += scalar.uppercased()
                case .lowercase:
                    result += scalar.lowercased()
                case .titleCase:
                    let before = index > 0
                        ? ns.character(at: index - 1)
                        : 0x20
                    result += isWordBoundary(before)
                        ? scalar.uppercased()
                        : scalar.lowercased()
                case .toggleCase:
                    let upper = scalar.uppercased()
                    let lower = scalar.lowercased()
                    result += scalar == upper && scalar != lower
                        ? lower
                        : upper
                default:
                    result += scalar
                }
            } else {
                result += scalar
            }
            index = characterRange.location + characterRange.length
        }
        guard result != source else {
            return .notApplicable
        }
        return MarkdownLineEdit(
            outcome: .handled,
            range: 0..<ns.length,
            replacement: result,
            selection: selection
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
                while probe < ns.length {
                    if ns.character(at: probe) == 0x60 {
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
                            break
                        }
                    }
                    probe += 1
                }
                if index != probe { continue }
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
        return ranges
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
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
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
        // Indented code: a four-space line after a blank line.
        var previousBlank = true
        for (index, line) in table.lines.enumerated() {
            let start = table.offset(line: index, column: 0)
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            let indented = line.hasPrefix("    ") || line.hasPrefix("\t")
            if indented, previousBlank {
                ranges.append(start..<ns.length)
            }
            previousBlank = blank
        }
        return ranges
    }
}

/// Lines with their offsets. Offsets are UTF-16, matching source ranges.
struct LineTable {
    let lines: [String]
    let trailingNewline: Bool
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
        self.trailingNewline = ns.length > 0
            && ns.character(at: ns.length - 1) == 0x0A
    }

    init(lines: [String], trailingNewline: Bool) {
        self.lines = lines
        self.trailingNewline = trailingNewline
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
