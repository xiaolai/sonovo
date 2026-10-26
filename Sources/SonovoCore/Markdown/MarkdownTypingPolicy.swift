import Foundation

/// A pure key-handling result. The controller applies a handled plan in one
/// undo group; a refused plan makes no change; notApplicable passes the key
/// to AppKit.
public struct MarkdownEditPlan: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case handled
        case refused
        case notApplicable
    }

    public let outcome: Outcome
    /// The UTF-16 range to replace. `nil` means a selection-only move.
    public let range: Range<Int>?
    public let replacement: String
    public let selection: Range<Int>?

    public init(
        outcome: Outcome,
        range: Range<Int>? = nil,
        replacement: String = "",
        selection: Range<Int>? = nil
    ) {
        self.outcome = outcome
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    public static let refused = MarkdownEditPlan(outcome: .refused)
    public static let notApplicable = MarkdownEditPlan(outcome: .notApplicable)

    public static func handled(
        range: Range<Int>,
        replacement: String,
        selection: Range<Int>
    ) -> MarkdownEditPlan {
        MarkdownEditPlan(
            outcome: .handled,
            range: range,
            replacement: replacement,
            selection: selection
        )
    }

    public static func select(_ selection: Range<Int>) -> MarkdownEditPlan {
        MarkdownEditPlan(outcome: .handled, selection: selection)
    }
}

/// The ordered Tab/Backspace policy. Pure over source + selection; the
/// controller supplies AppKit behavior and one undo group.
public enum MarkdownTypingPolicy {
    public static let listIndent = "  "
    public static let tabSpaces = "    "

    // MARK: - Tab

    public static func tab(
        source: String,
        selection: Range<Int>,
        backwards: Bool
    ) -> MarkdownEditPlan {
        guard selection.isEmpty else { return .notApplicable }
        let offset = selection.lowerBound
        let ns = source as NSString
        guard offset >= 0, offset <= ns.length else { return .notApplicable }
        if isInsideFence(source, at: offset) { return .notApplicable }

        // A caret inside the source table navigates cells; a malformed table
        // refuses rather than falling through to spaces.
        switch MarkdownTableEditor.navigate(
            source: source,
            selection: selection,
            backwards: backwards
        ) {
        case .select(let target):
            return .select(target)
        case .edit(let edit):
            guard let range = edit.range,
                  let replacement = edit.replacement else {
                return .refused
            }
            return .handled(
                range: range,
                replacement: replacement,
                selection: edit.selection ?? selection
            )
        case .refused:
            return .refused
        case .notApplicable:
            break
        }

        if let prefix = listPrefix(
            line: lineText(ns, at: offset),
            lineStart: lineStart(ns, at: offset)
        ) {
            return indentList(
                source: source,
                offset: offset,
                prefix: prefix,
                backwards: backwards
            )
        }

        if let plan = escapePair(source: source, offset: offset, backwards: backwards) {
            return plan
        }

        if backwards { return .refused }
        return .handled(
            range: offset..<offset,
            replacement: tabSpaces,
            selection: (offset + tabSpaces.utf16.count)
                ..< (offset + tabSpaces.utf16.count)
        )
    }

    // MARK: - Backspace

    public static func backspace(
        source: String,
        selection: Range<Int>
    ) -> MarkdownEditPlan {
        guard selection.isEmpty, selection.lowerBound > 0 else {
            return .notApplicable
        }
        let offset = selection.lowerBound
        let ns = source as NSString
        guard offset <= ns.length else { return .notApplicable }

        // A composition is the controller's concern; this policy only runs
        // when the caller has already checked `hasMarkedText`.
        if let pair = emptyPairtoDelete(source: source, offset: offset) {
            return .handled(
                range: (offset - pair.before)..<(offset + pair.after),
                replacement: "",
                selection: (offset - pair.before)..<(offset - pair.before)
            )
        }

        if isInsideFence(source, at: offset) { return .notApplicable }

        let start = lineStart(ns, at: offset)
        let line = lineText(ns, at: offset)
        if let prefix = listPrefix(line: line, lineStart: start) {
            let markerContentStart = start + prefix.contentStart
            let lineEnd = start + (line as NSString).length
            let afterMarker = (line as NSString).substring(
                from: prefix.contentStart
            ).trimmingCharacters(in: .whitespaces)

            // An empty item: remove marker and its following spaces.
            if afterMarker.isEmpty, offset >= markerContentStart {
                return .handled(
                    range: start..<lineEnd,
                    replacement: "",
                    selection: start..<start
                )
            }

            // At content start, lift one level.
            if offset == markerContentStart, prefix.indent >= listIndent.utf16.count {
                let removal = min(listIndent.utf16.count, prefix.indent)
                return .handled(
                    range: start..<(start + removal),
                    replacement: "",
                    selection: (offset - removal)..<(offset - removal)
                )
            }

            // A marker is structural while the item has content.
            if offset > start + prefix.indent,
               offset <= start + prefix.indent + prefix.markerLength {
                return .refused
            }
        }

        let before = ns.character(at: offset - 1)
        if before == 0x7C,
           !isEscaped(offset - 1, in: ns),
           MarkdownTableScanner.table(at: offset, in: source)?.isValid == true {
            return .refused
        }
        let lineEnd = start + (line as NSString).length
        let quoteEnd = blockQuotePrefixEnd(ns, from: start, to: lineEnd)
        if before == 0x3E, offset - 1 < quoteEnd {
            return .refused
        }
        return .notApplicable
    }

    // MARK: - Delete forward

    public static func deleteForward(
        source: String,
        selection: Range<Int>
    ) -> MarkdownEditPlan {
        guard selection.isEmpty else { return .notApplicable }
        let offset = selection.lowerBound
        let ns = source as NSString
        guard offset >= 0, offset < ns.length else { return .notApplicable }
        if isInsideFence(source, at: offset) { return .notApplicable }
        if ns.character(at: offset) == 0x7C,
           !isEscaped(offset, in: ns),
           MarkdownTableScanner.table(at: offset, in: source)?.isValid == true {
            return .refused
        }
        return .notApplicable
    }

    // MARK: - List indentation

    private struct ListPrefix {
        let indent: Int
        let markerStart: Int
        let markerLength: Int
        let contentStart: Int
    }

    private static func indentList(
        source: String,
        offset: Int,
        prefix: ListPrefix,
        backwards: Bool
    ) -> MarkdownEditPlan {
        let ns = source as NSString
        let start = lineStart(ns, at: offset)
        if backwards {
            guard prefix.indent > 0 else { return .refused }
            let removal = min(listIndent.utf16.count, prefix.indent)
            // The caret can sit inside the removed indentation; clamping to
            // the line start keeps it there instead of drifting into the
            // previous line.
            let caret = max(start, offset - removal)
            return .handled(
                range: start..<(start + removal),
                replacement: "",
                selection: caret..<caret
            )
        }
        let insertion = listIndent as NSString
        return .handled(
            range: start..<start,
            replacement: listIndent,
            selection: (offset + insertion.length)..<(offset + insertion.length)
        )
    }

    private static func listPrefix(
        line: String,
        lineStart: Int
    ) -> ListPrefix? {
        let ns = line as NSString
        var index = 0
        while index < ns.length, isSpace(ns.character(at: index)) { index += 1 }
        let indent = index
        let markerStart = index
        guard index < ns.length else { return nil }
        let first = ns.character(at: index)
        if first == 0x2D || first == 0x2A || first == 0x2B {
            index += 1
        } else if isDigit(first) {
            while index < ns.length, isDigit(ns.character(at: index)) {
                index += 1
            }
            guard index < ns.length else { return nil }
            let punctuation = ns.character(at: index)
            guard punctuation == 0x2E || punctuation == 0x29 else {
                return nil
            }
            index += 1
        } else {
            return nil
        }
        let markerEnd = index
        // A marker at the very end of the line is an empty list item.
        if index < ns.length {
            guard isSpace(ns.character(at: index)) else { return nil }
            while index < ns.length, isSpace(ns.character(at: index)) {
                index += 1
            }
        }
        // A thematic break is not a list item. Only marker characters count
        // toward the three-marker minimum; spaces between them do not, so
        // "- -" remains a list item while "- - -" does not.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if first == 0x2D || first == 0x2A {
            let marker: Character = first == 0x2D ? "-" : "*"
            let markers = trimmed.reduce(0) { $0 + ($1 == marker ? 1 : 0) }
            let onlyMarkerAndSpaces = trimmed.allSatisfy {
                $0 == marker || $0 == " " || $0 == "\t"
            }
            if onlyMarkerAndSpaces && markers >= 3 { return nil }
        }
        return ListPrefix(
            indent: indent,
            markerStart: markerStart,
            markerLength: markerEnd - markerStart,
            contentStart: index
        )
    }

    // MARK: - Pair escape

    private struct Pair {
        let open: unichar
        let close: unichar
    }

    private static let pairs: [Pair] = [
        Pair(open: 0x28, close: 0x29), // ()
        Pair(open: 0x5B, close: 0x5D), // []
        Pair(open: 0x7B, close: 0x7D), // {}
        Pair(open: 0x22, close: 0x22), // ""
        Pair(open: 0x27, close: 0x27), // ''
        Pair(open: 0x60, close: 0x60), // ``
        Pair(open: 0x300C, close: 0x300D), // 「」
        Pair(open: 0x300E, close: 0x300F), // 『』
        Pair(open: 0xFF08, close: 0xFF09), // （）
        Pair(open: 0x3010, close: 0x3011), // 【】
        Pair(open: 0x300A, close: 0x300B), // 《》
        Pair(open: 0x3008, close: 0x3009) // 〈〉
    ]

    private static func escapePair(
        source: String,
        offset: Int,
        backwards: Bool
    ) -> MarkdownEditPlan? {
        let ns = source as NSString
        if backwards {
            guard offset > 0, offset <= ns.length else { return nil }
            let before = ns.character(at: offset - 1)
            guard pairs.contains(where: { $0.open == before }) else {
                return nil
            }
            return .select((offset - 1)..<(offset - 1))
        }
        guard offset < ns.length else { return nil }
        let after = ns.character(at: offset)
        guard pairs.contains(where: { $0.close == after }) else {
            return nil
        }
        return .select((offset + 1)..<(offset + 1))
    }

    // MARK: - Empty pair

    private static func emptyPairtoDelete(
        source: String,
        offset: Int
    ) -> (before: Int, after: Int)? {
        let ns = source as NSString
        guard offset > 0, offset < ns.length else { return nil }
        let before = ns.character(at: offset - 1)
        let after = ns.character(at: offset)
        guard before != after else { return nil }
        guard pairs.contains(where: { $0.open == before && $0.close == after })
        else {
            return nil
        }
        return (1, 1)
    }

    // MARK: - Lines and fences

    private static func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    /// Whether the character at `index` is escaped by an odd number of
    /// backslashes. An escaped pipe is cell text, not a separator.
    private static func isEscaped(_ index: Int, in ns: NSString) -> Bool {
        var backslashes = 0
        var probe = index - 1
        while probe >= 0, ns.character(at: probe) == 0x5C {
            backslashes += 1
            probe -= 1
        }
        return backslashes % 2 == 1
    }

    /// The offset just past the leading blockquote markers on a line. Only
    /// `>` characters inside this span are structural; a later `>` is text.
    private static func blockQuotePrefixEnd(
        _ ns: NSString,
        from start: Int,
        to end: Int
    ) -> Int {
        var index = start
        while index < end, isSpace(ns.character(at: index)) { index += 1 }
        var prefixEnd = index
        while prefixEnd < end, ns.character(at: prefixEnd) == 0x3E {
            prefixEnd += 1
            if prefixEnd < end, ns.character(at: prefixEnd) == 0x20 {
                prefixEnd += 1
            }
            while prefixEnd < end, isSpace(ns.character(at: prefixEnd)) {
                prefixEnd += 1
            }
        }
        return prefixEnd > index ? prefixEnd : start
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= 0x30 && character <= 0x39
    }

    private static func lineStart(_ ns: NSString, at offset: Int) -> Int {
        var index = min(offset, ns.length)
        while index > 0, ns.character(at: index - 1) != 0x0A {
            index -= 1
        }
        return index
    }

    private static func lineText(_ ns: NSString, at offset: Int) -> String {
        let start = lineStart(ns, at: offset)
        var end = min(offset, ns.length)
        while end < ns.length, ns.character(at: end) != 0x0A {
            end += 1
        }
        return lineText(ns, from: start, to: end)
    }

    /// The text between two offsets without a trailing carriage return, so
    /// CRLF documents classify like LF ones.
    private static func lineText(
        _ ns: NSString,
        from start: Int,
        to end: Int
    ) -> String {
        let text = ns.substring(
            with: NSRange(location: start, length: end - start)
        )
        return text.hasSuffix("\r") ? String(text.dropLast()) : text
    }

    /// A minimal fence tracker. A fence opens with a run of three or more
    /// backticks or tildes, indented no more than three columns beyond the
    /// enclosing list item's content column; a backtick fence's info string
    /// may not contain a backtick. It closes only with the same character, a
    /// run at least as long, nothing but whitespace after it, and the same
    /// indentation limit. Dedenting out of the enclosing list item ends the
    /// fence, exactly as it ends the item in the parser.
    ///
    /// CommonMark measures that indentation from the container's content
    /// start, so the tracker follows list content columns line by line. It
    /// models fenced code inside lists only; indented code blocks and fences
    /// inside blockquotes are not tracked.
    public static func isInsideFence(_ source: String, at offset: Int) -> Bool {
        let ns = source as NSString
        let limit = min(offset, ns.length)
        var openFence: unichar?
        var openLength = 0
        var openContainer = 0
        var listColumns: [Int] = []
        var lineStart = 0
        // The line holding the caret is read whole: its delimiters and its
        // indentation are properties of the line, not of the text before
        // the caret. Lines after the caret's line are never read.
        while lineStart <= limit, lineStart < ns.length {
            var lineEnd = lineStart
            while lineEnd < ns.length, ns.character(at: lineEnd) != 0x0A {
                lineEnd += 1
            }
            let line = lineText(ns, from: lineStart, to: lineEnd)
            let indent = indentation(of: line)
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })

            if openFence != nil {
                // A non-blank line left of the item that holds the fence
                // ends the item, and the fence with it. The line is then
                // read again in the outer context, where it may open a new
                // fence.
                let dedented = !trimmed.isEmpty && indent < openContainer
                if !dedented {
                    if closesFence(
                        trimmed,
                        indent: indent,
                        marker: openFence,
                        length: openLength,
                        limit: openContainer + 3
                    ) {
                        openFence = nil
                        openLength = 0
                        openContainer = 0
                    }
                    if lineEnd >= limit { break }
                    lineStart = lineEnd + 1
                    continue
                }
                openFence = nil
                openLength = 0
                openContainer = 0
            }
            // A fence may open directly after one or more list markers,
            // as in "- - ```".
            let stripped = stripListMarkers(&listColumns, line: line)
            let container = listColumns.last ?? 0
            if let opened = fenceOpener(
                stripped.content,
                indent: stripped.column,
                container: container
            ) {
                openFence = opened.marker
                openLength = opened.length
                openContainer = container
            }
            if lineEnd >= limit { break }
            lineStart = lineEnd + 1
        }
        return openFence != nil
    }

    private static func fenceOpener(
        _ trimmed: Substring,
        indent: Int,
        container: Int
    ) -> (marker: unichar, length: Int)? {
        guard indent <= container + 3 else { return nil }
        guard let first = trimmed.first, first == "`" || first == "~" else {
            return nil
        }
        let run = trimmed.prefix(while: { $0 == first }).count
        guard run >= 3 else { return nil }
        let marker: unichar = first == "`" ? 0x60 : 0x7E
        // A backtick fence's info string may not contain a backtick.
        if marker == 0x60, trimmed.dropFirst(run).contains("`") { return nil }
        return (marker, run)
    }

    private static func closesFence(
        _ trimmed: Substring,
        indent: Int,
        marker: unichar?,
        length: Int,
        limit: Int
    ) -> Bool {
        guard let first = trimmed.first, first == "`" || first == "~" else {
            return false
        }
        let run = trimmed.prefix(while: { $0 == first }).count
        let closeMarker: unichar = first == "`" ? 0x60 : 0x7E
        guard run >= 3,
              closeMarker == marker,
              run >= length,
              indent <= limit else {
            return false
        }
        return trimmed.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Strips every list marker at the start of the line, maintaining the
    /// content columns of the items enclosing the caret. Returns what
    /// follows the markers and the column where it starts.
    ///
    /// A blank line keeps the current item open; a line returning to the
    /// left of a content column ends every item at or beyond it.
    private static func stripListMarkers(
        _ columns: inout [Int],
        line: String
    ) -> (content: Substring, column: Int) {
        var remainder = line[...]
        var base = 0
        var sawMarker = false
        while let prefix = listPrefix(
            line: String(remainder),
            lineStart: 0
        ) {
            let markerIndent = column(
                of: remainder.prefix(prefix.markerStart),
                from: base
            )
            // A marker four or more columns right of the enclosing content
            // starts an indented code block, not a list item.
            guard markerIndent <= (columns.last ?? 0) + 3 else { break }
            let markerEnd = column(
                of: remainder.prefix(
                    prefix.markerStart + prefix.markerLength
                ),
                from: base
            )
            let padded = column(
                of: remainder.prefix(prefix.contentStart),
                from: base
            )
            let padding = padded - markerEnd
            let empty = prefix.contentStart >= remainder.count
            // One to four spaces of padding set the item's content column.
            // More than four, or an empty item, means the parser puts the
            // content column one space past the marker.
            let contentColumn = !empty && padding <= 4
                ? padded
                : markerEnd + 1
            while let top = columns.last, top > markerIndent {
                columns.removeLast()
            }
            columns.append(contentColumn)
            remainder = remainder.dropFirst(prefix.contentStart)
            base = padded
            sawMarker = true
            // The rest of this line is an indented code block or nothing;
            // it cannot hold another marker.
            if empty || padding > 4 { break }
        }
        let padding = remainder.prefix(while: { $0 == " " || $0 == "\t" })
        let content = remainder.drop(while: { $0 == " " || $0 == "\t" })
        if sawMarker {
            return (content, column(of: padding, from: base))
        }
        guard !content.isEmpty else { return (content, 0) }
        let indent = column(of: padding, from: 0)
        while let top = columns.last, indent < top {
            columns.removeLast()
        }
        return (content, indent)
    }

    /// The column reached after `text`, starting at `start`, with tab stops
    /// every four columns, as CommonMark counts indentation.
    private static func column(
        of text: Substring,
        from start: Int
    ) -> Int {
        var column = start
        for character in text {
            if character == "\t" {
                column += 4 - (column % 4)
            } else {
                column += 1
            }
        }
        return column
    }

    /// Leading whitespace width in columns, with tab stops every four
    /// columns, as CommonMark counts indentation.
    private static func indentation(of line: String) -> Int {
        column(
            of: line.prefix(while: { $0 == " " || $0 == "\t" }),
            from: 0
        )
    }
}
