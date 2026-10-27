import Foundation

/// A lossless GFM table read from the raw source.
///
/// The rendering AST pads a short row with a cell that has no source range and
/// truncates an overlong row, so it cannot drive editing. This scanner keeps
/// every authored cell, including empty and overlong ones, and preserves the
/// exact source slices needed to reconstruct the table.
///
/// The scanner operates on canonical Markdown source (BOM-free, LF-only). It
/// does not parse inline Markdown: a pipe inside a code span still separates
/// cells, matching the pinned parser. A pipe is literal only when escaped with
/// an odd number of backslashes.
public struct MarkdownTable: Sendable, Equatable {
    public struct Cell: Sendable, Equatable {
        /// Row index in the table: 0 is the header, 1... are body rows.
        public let row: Int
        /// Zero-based column.
        public let column: Int
        /// The trimmed content range. An authored empty cell is a zero-length
        /// range at the position between its separators.
        public let range: SourceRange
        /// The untrimmed source between separators, including the cell's
        /// surrounding whitespace.
        public let segmentRange: SourceRange
        /// The untrimmed source between separators.
        public let raw: String
        /// The trimmed content.
        public let content: String

        public init(
            row: Int,
            column: Int,
            range: SourceRange,
            segmentRange: SourceRange,
            raw: String,
            content: String
        ) {
            self.row = row
            self.column = column
            self.range = range
            self.segmentRange = segmentRange
            self.raw = raw
            self.content = content
        }
    }

    public struct Row: Sendable, Equatable {
        /// 0 is the header, 1... are body rows.
        public let index: Int
        /// The whole line, excluding its newline.
        public let range: SourceRange
        /// The line's source, excluding its newline.
        public let raw: String
        /// The container prefix (`> ` and indentation) before the first cell.
        public let containerPrefix: String
        public let leadingPipe: Bool
        public let trailingPipe: Bool
        public let cells: [Cell]

        public init(
            index: Int,
            range: SourceRange,
            raw: String,
            containerPrefix: String,
            leadingPipe: Bool,
            trailingPipe: Bool,
            cells: [Cell]
        ) {
            self.index = index
            self.range = range
            self.raw = raw
            self.containerPrefix = containerPrefix
            self.leadingPipe = leadingPipe
            self.trailingPipe = trailingPipe
            self.cells = cells
        }
    }

    /// The block range from the header line's start to the last body line's
    /// end, excluding the final newline.
    public let range: SourceRange
    public let header: Row
    public let delimiter: Row
    public let body: [Row]
    public let alignments: [TableBlock.Alignment]
    /// A malformed delimiter row or a header/delimiter column mismatch.
    /// Body-column mismatches do not make the table invalid; they are
    /// diagnostics.
    public let isValid: Bool
    /// Zero-based body-row indices whose authored cell count differs from the
    /// header count.
    public let columnMismatchRows: [Int]

    public init(
        range: SourceRange,
        header: Row,
        delimiter: Row,
        body: [Row],
        alignments: [TableBlock.Alignment],
        isValid: Bool,
        columnMismatchRows: [Int]
    ) {
        self.range = range
        self.header = header
        self.delimiter = delimiter
        self.body = body
        self.alignments = alignments
        self.isValid = isValid
        self.columnMismatchRows = columnMismatchRows
    }

    /// The exact source the scanner read.
    public var sourceText: String {
        ([header.raw, delimiter.raw] + body.map(\.raw)).joined(separator: "\n")
    }

    /// All authored rows in order.
    public var rows: [Row] { [header, delimiter] + body }
}

/// Finds GFM tables in raw source without using the rendering AST.
public enum MarkdownTableScanner {
    private struct Line {
        let number: Int
        let start: Int
        let end: Int
        let text: NSString
        let raw: String
    }

    private struct ParsedRow {
        let cells: [(segment: NSRange, content: NSRange, range: SourceRange)]
        let leadingPipe: Bool
        let trailingPipe: Bool
        let containerLength: Int
    }

    /// All tables in the source, in document order.
    public static func tables(in source: String) -> [MarkdownTable] {
        // Every table row carries an unescaped pipe, so a source with no pipe
        // at all has no tables. This runs on each edit for the caret's cell
        // highlight, where splitting a megabyte-long document into lines to
        // find nothing is the dominant cost; one string search answers it.
        guard (source as NSString).range(of: "|").location != NSNotFound else {
            return []
        }
        let lines = splitLines(source)
        // A pipe-shaped line inside code is not a table the editor may
        // rewrite; the scanner works on raw source and must exclude it.
        let codeLines = codeLineFlags(lines)
        var tables: [MarkdownTable] = []
        var index = 0
        while index + 1 < lines.count {
            let headerLine = lines[index]
            let delimiterLine = lines[index + 1]
            guard !codeLines[index], !codeLines[index + 1] else {
                index += 1
                continue
            }
            guard hasUnescapedPipe(headerLine.text),
                  hasUnescapedPipe(delimiterLine.text) else {
                index += 1
                continue
            }
            let headerPrefix = containerPrefixLength(headerLine.text)
            let delimiterPrefix = containerPrefixLength(delimiterLine.text)
            // The two rows must share a container, but they may indent
            // differently inside it: `> | A |` followed by `>|---|` is a
            // valid quoted table. Each row is parsed with its own prefix
            // length.
            guard blockquoteDepth(headerLine.text)
                    == blockquoteDepth(delimiterLine.text) else {
                index += 1
                continue
            }
            guard let header = parseRow(
                headerLine,
                containerLength: headerPrefix
            ), let delimiter = parseRow(
                delimiterLine,
                containerLength: delimiterPrefix
            ) else {
                index += 1
                continue
            }
            let alignments = delimiter.cells.map { cell in
                let content = (delimiterLine.raw as NSString).substring(
                    with: cell.content
                )
                return alignment(for: content) ?? TableBlock.Alignment.none
            }
            let delimiterValid = delimiter.cells.allSatisfy { cell in
                let content = (delimiterLine.raw as NSString).substring(
                    with: cell.content
                )
                return alignment(for: content) != nil
            }
            guard delimiter.cells.contains(where: { cell in
                let content = (delimiterLine.raw as NSString).substring(
                    with: cell.content
                )
                return alignment(for: content) != nil
            }) else {
                index += 1
                continue
            }
            let isValid = !header.cells.isEmpty
                && header.cells.count == delimiter.cells.count
                && delimiterValid

            let headerQuoteDepth = blockquoteDepth(headerLine.text)
            var bodyRows: [(line: Line, parsed: ParsedRow)] = []
            var cursor = index + 2
            while cursor < lines.count {
                let line = lines[cursor]
                // A row belongs to the table's container. Leaving the
                // blockquote ends the table; an unquoted pipe line after a
                // quoted table is ordinary text. A body row without a pipe
                // is still a row: GFM reads it as one cell and leaves the
                // remaining columns empty.
                guard blockquoteDepth(line.text) == headerQuoteDepth,
                      !isBlank(line.text),
                      !startsInterruptingBlock(line.text),
                      let parsed = parseRow(
                          line,
                          containerLength: containerPrefixLength(line.text)
                      ) else {
                    break
                }
                bodyRows.append((line, parsed))
                cursor += 1
            }

            let lastLine = bodyRows.last?.line ?? delimiterLine
            let blockRange = SourceRange(
                start: position(line: headerLine.number, offset: headerLine.start, lineStart: headerLine.start),
                end: position(line: lastLine.number, offset: lastLine.end, lineStart: lastLine.start)
            )

            let headerRow = makeRow(
                line: headerLine,
                parsed: header,
                index: 0
            )
            let delimiterRow = makeRow(
                line: delimiterLine,
                parsed: delimiter,
                index: 0
            )
            let body = bodyRows.enumerated().map { offset, entry in
                makeRow(
                    line: entry.line,
                    parsed: entry.parsed,
                    index: offset + 1
                )
            }
            let mismatches = body.enumerated().compactMap { offset, row in
                row.cells.count == headerRow.cells.count ? nil : offset
            }

            tables.append(
                MarkdownTable(
                    range: blockRange,
                    header: headerRow,
                    delimiter: delimiterRow,
                    body: body,
                    alignments: alignments,
                    isValid: isValid,
                    columnMismatchRows: mismatches
                )
            )
            index = cursor
        }
        return tables
    }

    /// The table containing a UTF-16 offset, if any.
    public static func table(
        at offset: Int,
        in source: String
    ) -> MarkdownTable? {
        tables(in: source).first { table in
            offset >= table.range.lowerBound && offset <= table.range.upperBound
        }
    }

    // MARK: - Code exclusion

    /// Marks every line that belongs to fenced or indented code.
    private static func codeLineFlags(_ lines: [Line]) -> [Bool] {
        var flags = [Bool](repeating: false, count: lines.count)
        // A fence belongs to the container that opened it. An unclosed fence
        // inside a blockquote or a list item ends with that container; it
        // must not suppress valid tables in the text that follows.
        var fence: OpenFence?
        for index in lines.indices {
            let context = fenceContext(lines[index].raw)
            if let open = fence {
                if context.quoteDepth < open.quoteDepth
                    || endsListFence(open, context: context) {
                    fence = nil
                    // The container ended on this line; it may open a new
                    // fence of its own.
                } else {
                    flags[index] = true
                    let run = context.content.prefix(while: {
                        $0 == open.marker
                    }).count
                    if run >= open.length,
                       context.content.dropFirst(run).allSatisfy({
                           $0 == " " || $0 == "\t"
                       }) {
                        fence = nil
                    }
                    continue
                }
            }
            let trimmed = context.content
            guard let first = trimmed.first,
                  first == "`" || first == "~" else { continue }
            let run = trimmed.prefix(while: { $0 == first }).count
            guard run >= 3 else { continue }
            // A backtick fence's info string may not contain a backtick.
            if first == "~" || !trimmed.dropFirst(run).contains("`") {
                fence = OpenFence(
                    marker: first,
                    length: run,
                    quoteDepth: context.quoteDepth,
                    listContentIndent: context.listContentIndent
                )
                flags[index] = true
            }
        }
        var previousBlank = true
        var index = 0
        while index < lines.count {
            let raw = lines[index].raw
            let blank = raw.trimmingCharacters(in: .whitespaces).isEmpty
            let indented = raw.hasPrefix("    ") || raw.hasPrefix("\t")
            if indented, previousBlank {
                var last = index
                flags[last] = true
                while last + 1 < lines.count {
                    let next = lines[last + 1].raw
                    let nextBlank = next
                        .trimmingCharacters(in: .whitespaces).isEmpty
                    let nextIndented = next.hasPrefix("    ")
                        || next.hasPrefix("\t")
                    guard nextBlank || nextIndented else { break }
                    last += 1
                    flags[last] = true
                }
                index = last + 1
                previousBlank = false
                continue
            }
            previousBlank = blank
            index += 1
        }
        return flags
    }

    private struct OpenFence {
        let marker: Character
        let length: Int
        let quoteDepth: Int
        /// The list item's content column when the fence opened on a list
        /// marker line; nil for a plain or quoted fence.
        let listContentIndent: Int?
    }

    /// One line's container context, used to follow a fence without losing
    /// track of the blockquote and list containers it lives in.
    private struct FenceContext {
        let content: Substring
        let quoteDepth: Int
        /// Leading indentation in columns after the quote prefixes.
        let indent: Int
        /// The list item's content column when this line starts with a list
        /// marker.
        let listContentIndent: Int?
    }

    private static func fenceContext(_ raw: String) -> FenceContext {
        var rest = Substring(raw)
        var quoteDepth = 0
        while true {
            let spaced = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard spaced.first == ">" else { break }
            rest = spaced.dropFirst()
            if rest.first == " " || rest.first == "\t" {
                rest = rest.dropFirst()
            }
            quoteDepth += 1
        }
        var indent = 0
        var probe = rest
        while let first = probe.first, first == " " || first == "\t" {
            indent += first == "\t" ? 4 : 1
            probe = probe.dropFirst()
        }
        var content = probe
        var listContentIndent: Int?
        if let first = content.first {
            if first == "-" || first == "+" || first == "*" {
                let after = content.dropFirst()
                if let next = after.first, next == " " || next == "\t" {
                    var spaces = 0
                    var remainder = after
                    while let next = remainder.first,
                          next == " " || next == "\t" {
                        spaces += next == "\t" ? 4 : 1
                        remainder = remainder.dropFirst()
                    }
                    listContentIndent = indent + 1 + min(max(spaces, 1), 4)
                    content = remainder
                }
            } else if first.isNumber {
                var cursor = content.startIndex
                var digits = 0
                while cursor < content.endIndex,
                      content[cursor].isNumber,
                      digits < 9 {
                    cursor = content.index(after: cursor)
                    digits += 1
                }
                if cursor < content.endIndex,
                   content[cursor] == "." || content[cursor] == ")",
                   content.index(after: cursor) < content.endIndex {
                    let after = content[content.index(after: cursor)...]
                    if let next = after.first, next == " " || next == "\t" {
                        var spaces = 0
                        var remainder = after
                        while let next = remainder.first,
                              next == " " || next == "\t" {
                            spaces += next == "\t" ? 4 : 1
                            remainder = remainder.dropFirst()
                        }
                        listContentIndent =
                            indent + digits + 1 + min(max(spaces, 1), 4)
                        content = remainder
                    }
                }
            }
        }
        return FenceContext(
            content: content,
            quoteDepth: quoteDepth,
            indent: indent,
            listContentIndent: listContentIndent
        )
    }

    /// A fenced code block cannot be lazily continued out of its list item.
    /// A nonblank line that is neither indented to the item's content column
    /// nor a new list marker ends the container and with it the fence.
    private static func endsListFence(
        _ open: OpenFence,
        context: FenceContext
    ) -> Bool {
        guard let required = open.listContentIndent else { return false }
        guard !context.content.allSatisfy({
            $0 == " " || $0 == "\t" || $0 == "\n"
        }) else {
            return false
        }
        return context.indent < required
    }

    /// Block starts that end a table, mirroring where a paragraph stops.
    private static func startsInterruptingBlock(_ text: NSString) -> Bool {
        var index = containerPrefixLength(text)
        while index < text.length, text.character(at: index) == 0x20 {
            index += 1
        }
        guard index < text.length else { return false }
        let first = text.character(at: index)
        if first == 0x23 { // #
            var probe = index + 1
            while probe < text.length,
                  text.character(at: probe) == 0x23,
                  probe - index < 7 {
                probe += 1
            }
            guard probe - index <= 6 else { return false }
            return probe == text.length
                || text.character(at: probe) == 0x20
                || text.character(at: probe) == 0x09
        }
        if first == 0x60 || first == 0x7E { // ` ~
            var probe = index
            while probe < text.length, text.character(at: probe) == first {
                probe += 1
            }
            return probe - index >= 3
        }
        if first == 0x3C { // < : an HTML block start
            return true
        }
        if first >= 0x30, first <= 0x39 { // 1. / 1) ordered list
            var probe = index
            while probe < text.length,
                  text.character(at: probe) >= 0x30,
                  text.character(at: probe) <= 0x39,
                  probe - index < 9 {
                probe += 1
            }
            guard probe - index <= 9, probe < text.length,
                  text.character(at: probe) == 0x2E
                    || text.character(at: probe) == 0x29,
                  probe + 1 < text.length,
                  text.character(at: probe + 1) == 0x20
                    || text.character(at: probe + 1) == 0x09 else {
                return false
            }
            return true
        }
        if first == 0x2B { // + : an unordered list item
            return index + 1 < text.length
                && (text.character(at: index + 1) == 0x20
                    || text.character(at: index + 1) == 0x09)
        }
        if first == 0x2D || first == 0x2A || first == 0x5F { // - * _
            // A single-marker list item ends the table before the thematic
            // break run check below.
            if (first == 0x2D || first == 0x2A),
               index + 1 < text.length,
               text.character(at: index + 1) == 0x20
                || text.character(at: index + 1) == 0x09 {
                return true
            }
            var probe = index
            while probe < text.length, text.character(at: probe) == first {
                probe += 1
            }
            guard probe - index >= 3 else { return false }
            while probe < text.length,
                  text.character(at: probe) == 0x20
                    || text.character(at: probe) == 0x09 {
                probe += 1
            }
            return probe == text.length
        }
        return false
    }

    // MARK: - Lines

    private static func splitLines(_ source: String) -> [Line] {
        let ns = source as NSString
        var lines: [Line] = []
        var start = 0
        var number = 1
        while start <= ns.length {
            var end = start
            while end < ns.length, ns.character(at: end) != 0x0A {
                end += 1
            }
            let raw = ns.substring(
                with: NSRange(location: start, length: end - start)
            )
            lines.append(
                Line(
                    number: number,
                    start: start,
                    end: end,
                    text: raw as NSString,
                    raw: raw
                )
            )
            if end >= ns.length { break }
            start = end + 1
            number += 1
        }
        return lines
    }

    private static func isBlank(_ text: NSString) -> Bool {
        for index in 0..<text.length {
            let character = text.character(at: index)
            if character != 0x20 && character != 0x09 {
                return false
            }
        }
        return true
    }

    private static func position(
        line: Int,
        offset: Int,
        lineStart: Int
    ) -> SourcePosition {
        SourcePosition(
            line: line,
            column: offset - lineStart,
            offset: offset
        )
    }

    // MARK: - Container prefix

    /// The length of a blockquote prefix (`> `, repeated) or of indentation
    /// before a leading pipe. A list-item table whose first cell is indented
    /// without a pipe is not recognized here; the AST block range is the
    /// caller's guide for that case.
    /// The number of blockquote markers at the start of the line.
    private static func blockquoteDepth(_ text: NSString) -> Int {
        var index = 0
        while index < text.length, isSpace(text.character(at: index)) {
            index += 1
        }
        var depth = 0
        while index < text.length, text.character(at: index) == 0x3E {
            depth += 1
            index += 1
            if index < text.length, text.character(at: index) == 0x20 {
                index += 1
            }
            while index < text.length, isSpace(text.character(at: index)) {
                index += 1
            }
        }
        return depth
    }

    private static func containerPrefixLength(_ text: NSString) -> Int {
        var index = 0
        while index < text.length, isSpace(text.character(at: index)) {
            index += 1
        }
        if index < text.length, text.character(at: index) == 0x3E {
            while index < text.length, text.character(at: index) == 0x3E {
                index += 1
                if index < text.length, text.character(at: index) == 0x20 {
                    index += 1
                }
                while index < text.length, isSpace(text.character(at: index)) {
                    index += 1
                }
            }
            return index
        }
        var probe = 0
        while probe < text.length, isSpace(text.character(at: probe)) {
            probe += 1
        }
        if probe < text.length, text.character(at: probe) == 0x7C {
            return probe
        }
        return 0
    }

    // MARK: - Row parsing

    private static func parseRow(
        _ line: Line,
        containerLength: Int
    ) -> ParsedRow? {
        let text = line.text
        guard containerLength <= text.length else { return nil }
        var scanStart = containerLength
        let leadingPipe = scanStart < text.length
            && text.character(at: scanStart) == 0x7C
        if leadingPipe { scanStart += 1 }

        var segments: [NSRange] = []
        var cellStart = scanStart
        var index = scanStart
        while index < text.length {
            let character = text.character(at: index)
            if character == 0x7C, !isEscaped(text, at: index) {
                segments.append(
                    NSRange(location: cellStart, length: index - cellStart)
                )
                cellStart = index + 1
            }
            index += 1
        }
        segments.append(
            NSRange(location: cellStart, length: text.length - cellStart)
        )

        var lastNonSpace = text.length - 1
        while lastNonSpace >= scanStart,
              isSpace(text.character(at: lastNonSpace)) {
            lastNonSpace -= 1
        }
        let trailingPipe = lastNonSpace >= scanStart
            && text.character(at: lastNonSpace) == 0x7C
            && !isEscaped(text, at: lastNonSpace)

        // The scan begins after a leading pipe, so the first segment is the
        // first authored cell, not a prefix. Only a trailing pipe leaves an
        // empty segment after the last cell.
        if trailingPipe, !segments.isEmpty {
            segments.removeLast()
        }
        guard !segments.isEmpty else { return nil }

        var cells: [(NSRange, NSRange, SourceRange)] = []
        for segment in segments {
            let content = trimmedRange(text, segment: segment)
            let range = SourceRange(
                start: position(
                    line: line.number,
                    offset: line.start + content.location,
                    lineStart: line.start
                ),
                end: position(
                    line: line.number,
                    offset: line.start + content.location + content.length,
                    lineStart: line.start
                )
            )
            cells.append((segment, content, range))
        }
        return ParsedRow(
            cells: cells.map { (segment: $0.0, content: $0.1, range: $0.2) },
            leadingPipe: leadingPipe,
            trailingPipe: trailingPipe,
            containerLength: containerLength
        )
    }

    private static func makeRow(
        line: Line,
        parsed: ParsedRow,
        index: Int
    ) -> MarkdownTable.Row {
        let prefix = (line.raw as NSString).substring(
            with: NSRange(location: 0, length: parsed.containerLength)
        )
        let cells = parsed.cells.enumerated().map { column, cell in
            let raw = (line.raw as NSString).substring(with: cell.segment)
            let content = (line.raw as NSString).substring(with: cell.content)
            let segmentRange = SourceRange(
                start: position(
                    line: line.number,
                    offset: line.start + cell.segment.location,
                    lineStart: line.start
                ),
                end: position(
                    line: line.number,
                    offset: line.start + cell.segment.location
                        + cell.segment.length,
                    lineStart: line.start
                )
            )
            return MarkdownTable.Cell(
                row: index,
                column: column,
                range: cell.range,
                segmentRange: segmentRange,
                raw: raw,
                content: content
            )
        }
        return MarkdownTable.Row(
            index: index,
            range: SourceRange(
                start: position(
                    line: line.number,
                    offset: line.start,
                    lineStart: line.start
                ),
                end: position(
                    line: line.number,
                    offset: line.end,
                    lineStart: line.start
                )
            ),
            raw: line.raw,
            containerPrefix: prefix,
            leadingPipe: parsed.leadingPipe,
            trailingPipe: parsed.trailingPipe,
            cells: cells
        )
    }

    // MARK: - Character helpers

    private static func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    private static func isEscaped(_ text: NSString, at index: Int) -> Bool {
        var backslashes = 0
        var cursor = index - 1
        while cursor >= 0, text.character(at: cursor) == 0x5C {
            backslashes += 1
            cursor -= 1
        }
        return backslashes % 2 == 1
    }

    private static func trimmedRange(
        _ text: NSString,
        segment: NSRange
    ) -> NSRange {
        var location = segment.location
        var length = segment.length
        while length > 0, isSpace(text.character(at: location)) {
            location += 1
            length -= 1
        }
        while length > 0, isSpace(text.character(at: location + length - 1)) {
            length -= 1
        }
        return NSRange(location: location, length: length)
    }

    private static func hasUnescapedPipe(_ text: NSString) -> Bool {
        for index in 0..<text.length where text.character(at: index) == 0x7C {
            if !isEscaped(text, at: index) { return true }
        }
        return false
    }

    private static func alignment(
        for content: String
    ) -> TableBlock.Alignment? {
        var text = content
        var left = false
        var right = false
        if text.hasPrefix(":") {
            left = true
            text.removeFirst()
        }
        if text.hasSuffix(":") {
            right = true
            text.removeLast()
        }
        guard !text.isEmpty, text.allSatisfy({ $0 == "-" }) else {
            return nil
        }
        switch (left, right) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        case (false, false): return TableBlock.Alignment.none
        }
    }
}
