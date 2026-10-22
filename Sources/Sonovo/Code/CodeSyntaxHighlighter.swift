import Foundation

/// A lexical role the theme can color.
enum CodeTokenKind: Sendable, Equatable {
    case keyword
    case typeName
    case string
    case comment
    case number
    case function
    case property
    case punctuation
    case identifier
    case markup
}

/// A token inside one line. Offsets are relative to the line's first UTF-16
/// unit, so a shifted line can be copied without rewriting its tokens.
struct CodeLexToken: Sendable, Equatable {
    let offset: Int
    let length: Int
    let kind: CodeTokenKind
}

/// The lexer state at a line boundary. A multiline construct that begins
/// above the viewport is carried here, so a visible-line window is never
/// mistaken for a complete lexical unit.
enum CodeLineState: Hashable, Sendable {
    case normal
    case blockComment(depth: Int, close: String, nested: Bool)
    case multilineString(delimiter: String)
    /// Rust `#"…"#` or C++ `R"tag(…)tag"`.
    case rawString(endMarker: String)
    /// One or more heredoc bodies opened on the same command line. The first
    /// terminator is the body currently being read; the rest follow it.
    case heredoc(pending: [CodeHeredocTerminator])
    case markupTag(quote: unichar?)

    /// A single pending heredoc, for callers that do not need a queue.
    static func heredoc(
        delimiter: String,
        indentation: CodeHeredocIndentation
    ) -> CodeLineState {
        .heredoc(
            pending: [
                CodeHeredocTerminator(
                    delimiter: delimiter,
                    indentation: indentation
                )
            ]
        )
    }
}

/// One lexed line and the state on both sides of it.
struct CodeLexLine: Sendable, Equatable {
    /// Absolute UTF-16 offset of the line's first unit.
    let start: Int
    /// UTF-16 length of the line's content, excluding its terminator.
    let contentLength: Int
    let hash: UInt64
    let stateAtStart: CodeLineState
    let endState: CodeLineState
    let tokens: [CodeLexToken]
    /// The line exceeded the 20k UTF-8 byte cap and was not tokenized.
    let isPlain: Bool
}

/// An immutable lexing result for one revision of one document.
struct CodeLexSnapshot: Sendable, Equatable {
    let revision: UInt64
    /// The language this snapshot was lexed with. A prefix copied from a
    /// snapshot lexed as another language would carry wrong tokens and line
    /// states, so a language change forces a full pass.
    let language: CodeLanguage
    let lines: [CodeLexLine]
    /// How many lines this pass actually tokenized. A local edit relexes one
    /// or two lines; a changed multiline opener propagates to its closer.
    let reprocessedLineCount: Int

    var longLineCount: Int {
        lines.reduce(0) { $0 + ($1.isPlain ? 1 : 0) }
    }

    /// The 1-based line number containing a UTF-16 offset.
    func lineNumber(at offset: Int) -> Int {
        guard !lines.isEmpty else { return 1 }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].start <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }

    /// The absolute range of a line's content.
    func range(ofLine number: Int) -> NSRange? {
        guard number >= 1, number <= lines.count else { return nil }
        let line = lines[number - 1]
        return NSRange(location: line.start, length: line.contentLength)
    }

    /// Tokens intersecting a UTF-16 range, converted to absolute offsets.
    func tokens(intersecting range: NSRange) -> [(range: NSRange, kind: CodeTokenKind)] {
        guard range.length > 0 else { return [] }
        var result: [(NSRange, CodeTokenKind)] = []
        let first = lineNumber(at: range.location) - 1
        let last = lineNumber(at: max(range.location, NSMaxRange(range) - 1)) - 1
        guard first <= last else { return [] }
        for index in first...last {
            let line = lines[index]
            for token in line.tokens {
                let absolute = NSRange(
                    location: line.start + token.offset,
                    length: token.length
                )
                if NSIntersectionRange(absolute, range).length > 0 {
                    result.append((absolute, token.kind))
                }
            }
        }
        return result
    }
}

/// A line-state lexer with checkpoints.
///
/// The first pass lexes every line. Later passes start at the edited line and
/// copy downstream lines whose content hash and start state both match the
/// previous snapshot; when a multiline construct changed, propagation
/// continues until the state and the content line up again or EOF.
enum CodeSyntaxHighlighter {
    /// A full pass. Used for the first revision, reloads, and tests.
    static func lex(
        text: String,
        language: CodeLanguage,
        revision: UInt64
    ) -> CodeLexSnapshot {
        let units = Array(text.utf16)
        let ranges = lineRanges(units)
        let spec = CompiledSyntax(language.syntax)
        var lines: [CodeLexLine] = []
        lines.reserveCapacity(ranges.count)
        var state = CodeLineState.normal
        for range in ranges {
            if Task.isCancelled { break }
            let startState = state
            let result = lexLine(
                units,
                range: range,
                state: startState,
                spec: spec
            )
            state = result.endState
            lines.append(
                CodeLexLine(
                    start: range.start,
                    contentLength: range.contentEnd - range.start,
                    hash: hash(units, range: range.start..<range.contentEnd),
                    stateAtStart: startState,
                    endState: result.endState,
                    tokens: result.tokens,
                    isPlain: result.isPlain
                )
            )
        }
        return CodeLexSnapshot(
            revision: revision,
            language: language,
            lines: lines,
            reprocessedLineCount: lines.count
        )
    }

    /// An incremental pass after an edit on `editedLine` (0-based).
    static func relex(
        previous: CodeLexSnapshot,
        text: String,
        language: CodeLanguage,
        revision: UInt64,
        editedLine: Int
    ) -> CodeLexSnapshot {
        // The prefix copy is valid only when the previous snapshot is the
        // revision immediately before this one, in the same language. A
        // debounced edit can skip revisions, and Save As can change the
        // language without changing the text; a full pass is then the only
        // safe base.
        guard previous.revision &+ 1 == revision,
              previous.language == language else {
            return lex(text: text, language: language, revision: revision)
        }
        let units = Array(text.utf16)
        let ranges = lineRanges(units)
        let spec = CompiledSyntax(language.syntax)
        guard !ranges.isEmpty else {
            return CodeLexSnapshot(
                revision: revision,
                language: language,
                lines: [],
                reprocessedLineCount: 0
            )
        }

        let delta = ranges.count - previous.lines.count
        let start = min(max(0, editedLine), ranges.count - 1)
        // Lines before the edit are untouched, so their start state is still
        // the previous snapshot's state at the same index.
        var state = start < previous.lines.count
            ? previous.lines[start].stateAtStart
            : CodeLineState.normal
        var lines: [CodeLexLine] = []
        lines.reserveCapacity(ranges.count)
        if start > 0, previous.lines.count >= start {
            lines.append(contentsOf: previous.lines.prefix(start))
        }
        var candidate = start + 1 - delta
        var reprocessed = 0
        var index = start

        while index < ranges.count {
            if Task.isCancelled { break }
            let range = ranges[index]
            let lineHash = hash(units, range: range.start..<range.contentEnd)

            if candidate >= 0,
               candidate < previous.lines.count,
               previous.lines[candidate].hash == lineHash,
               previous.lines[candidate].stateAtStart == state {
                let copied = previous.lines[candidate]
                lines.append(
                    CodeLexLine(
                        start: range.start,
                        contentLength: range.contentEnd - range.start,
                        hash: lineHash,
                        stateAtStart: state,
                        endState: copied.endState,
                        tokens: copied.tokens,
                        isPlain: copied.isPlain
                    )
                )
                state = copied.endState
                candidate += 1
            } else {
                let result = lexLine(
                    units,
                    range: range,
                    state: state,
                    spec: spec
                )
                lines.append(
                    CodeLexLine(
                        start: range.start,
                        contentLength: range.contentEnd - range.start,
                        hash: lineHash,
                        stateAtStart: state,
                        endState: result.endState,
                        tokens: result.tokens,
                        isPlain: result.isPlain
                    )
                )
                state = result.endState
                reprocessed += 1
                // After a relexed line, the untouched remainder of the old
                // file is aligned by the line-count delta.
                candidate = index + 1 - delta
            }
            index += 1
        }

        return CodeLexSnapshot(
            revision: revision,
            language: language,
            lines: lines,
            reprocessedLineCount: reprocessed
        )
    }

    // MARK: - Lines

    struct LineRange: Sendable, Equatable {
        let start: Int
        let contentEnd: Int
        let end: Int
    }

    /// Splits UTF-16 units into lines. A trailing newline produces a final
    /// empty line, matching how an editor shows the caret position after it.
    static func lineRanges(_ units: [unichar]) -> [LineRange] {
        var ranges: [LineRange] = []
        var start = 0
        var index = 0
        while index < units.count {
            if units[index] == 0x0A {
                var contentEnd = index
                if contentEnd > start, units[contentEnd - 1] == 0x0D {
                    contentEnd -= 1
                }
                ranges.append(
                    LineRange(start: start, contentEnd: contentEnd, end: index + 1)
                )
                start = index + 1
            }
            index += 1
        }
        ranges.append(
            LineRange(start: start, contentEnd: units.count, end: units.count)
        )
        return ranges
    }

    private static func hash(_ units: [unichar], range: Range<Int>) -> UInt64 {
        var value = FNV.offset
        for index in range {
            value = FNV.step(value, units[index])
        }
        return value
    }

    // MARK: - One line

    private struct LineResult {
        let tokens: [CodeLexToken]
        let endState: CodeLineState
        let isPlain: Bool
    }

    private static func lexLine(
        _ units: [unichar],
        range: LineRange,
        state: CodeLineState,
        spec: CompiledSyntax
    ) -> LineResult {
        let start = range.start
        let end = range.contentEnd
        let byteCount = utf8Length(units, range: start..<end)
        if byteCount > CodeLimits.highlightLineBytes {
            // The line is not painted, but its state transitions must still
            // advance; a long `*/` or an opener would otherwise desync every
            // following line.
            var scanner = LineScanner(
                units: units,
                start: start,
                end: end,
                spec: spec
            )
            scanner.suppressTokens = true
            scanner.run(state: state)
            return LineResult(
                tokens: [],
                endState: scanner.endState,
                isPlain: true
            )
        }

        var scanner = LineScanner(
            units: units,
            start: start,
            end: end,
            spec: spec
        )
        scanner.run(state: state)
        return LineResult(
            tokens: scanner.tokens,
            endState: scanner.endState,
            isPlain: false
        )
    }

    /// UTF-8 length without allocating. A surrogate pair is one scalar and
    /// four bytes, not four plus three.
    private static func utf8Length(_ units: [unichar], range: Range<Int>) -> Int {
        var bytes = 0
        var index = range.lowerBound
        while index < range.upperBound {
            let unit = units[index]
            if unit < 0x80 {
                bytes += 1
            } else if unit < 0x800 {
                bytes += 2
            } else if (0xD800...0xDBFF).contains(unit) {
                bytes += 4
                if index + 1 < range.upperBound,
                   (0xDC00...0xDFFF).contains(units[index + 1]) {
                    index += 1
                }
            } else {
                bytes += 3
            }
            index += 1
        }
        return bytes
    }
}

// MARK: - Compiled syntax

/// One FNV-1a implementation for the line hash, the keyword prechecks, and
/// the identifier scan.
private enum FNV {
    static let offset: UInt64 = 14_695_981_039_346_656_037
    static let prime: UInt64 = 1_099_511_628_211

    static func step(_ value: UInt64, _ unit: unichar) -> UInt64 {
        (value ^ UInt64(unit)) &* prime
    }
}

private struct CompiledSyntax {
    struct BlockComment {
        let open: [unichar]
        let close: [unichar]
        let closeString: String
        let nested: Bool
    }

    struct MultilineString {
        let open: [unichar]
        let close: [unichar]
        let closeString: String
        let escapes: Bool
    }

    let lineComments: [[unichar]]
    let blockComments: [BlockComment]
    let stringQuotes: Set<unichar>
    let multilineStrings: [MultilineString]
    let backtickStrings: Bool
    let backtickEscapes: Bool
    let singleQuoteEscapes: Bool
    let doubleQuoteEscapes: Bool
    let doubledQuoteEscapes: Bool
    let hashCommentRequiresBoundary: Bool
    let rawStrings: CodeRawStringStyle?
    let heredocs: [CodeHeredocStyle]
    let keywords: Set<String>
    let typeKeywords: Set<String>
    let keywordHashes: Set<UInt64>
    let typeKeywordHashes: Set<UInt64>
    let markupTags: Bool
    let caseInsensitiveKeywords: Bool

    init(_ spec: CodeSyntaxSpec) {
        lineComments = spec.lineComments.map { Array($0.utf16) }
        blockComments = spec.blockComments.map {
            BlockComment(
                open: Array($0.open.utf16),
                close: Array($0.close.utf16),
                closeString: $0.close,
                nested: $0.nested
            )
        }
        stringQuotes = Set(spec.stringQuotes.map { unichar($0.utf16.first ?? 0) })
        multilineStrings = spec.multilineStrings.map {
            MultilineString(
                open: Array($0.open.utf16),
                close: Array($0.close.utf16),
                closeString: $0.close,
                escapes: $0.escapes
            )
        }
        backtickStrings = spec.backtickStrings
        backtickEscapes = spec.backtickEscapes
        singleQuoteEscapes = spec.singleQuoteEscapes
        doubleQuoteEscapes = spec.doubleQuoteEscapes
        doubledQuoteEscapes = spec.doubledQuoteEscapes
        hashCommentRequiresBoundary = spec.hashCommentRequiresBoundary
        rawStrings = spec.rawStrings
        heredocs = spec.heredocs
        keywords = spec.keywords
        typeKeywords = spec.typeKeywords
        keywordHashes = Self.hashes(
            of: spec.keywords,
            lowercased: spec.caseInsensitiveKeywords
        )
        typeKeywordHashes = Self.hashes(
            of: spec.typeKeywords,
            lowercased: spec.caseInsensitiveKeywords
        )
        markupTags = spec.markupTags
        caseInsensitiveKeywords = spec.caseInsensitiveKeywords
    }

    /// Hash prechecks keep the per-identifier cost at an integer hash and a
    /// set lookup; a String is built only for a possible keyword, which is a
    /// small fraction of the identifiers in a real file.
    private static func hashes(
        of words: Set<String>,
        lowercased: Bool
    ) -> Set<UInt64> {
        var result: Set<UInt64> = []
        result.reserveCapacity(words.count)
        for word in words {
            let text = lowercased ? word.lowercased() : word
            result.insert(fnvHash(Array(text.utf16)))
        }
        return result
    }

    static func fnvHash<S: Sequence>(_ units: S) -> UInt64
    where S.Element == unichar {
        var value = FNV.offset
        for unit in units {
            value = FNV.step(value, unit)
        }
        return value
    }
}

// MARK: - Line scanner

private struct LineScanner {
    let units: [unichar]
    let start: Int
    let end: Int
    let spec: CompiledSyntax
    var tokens: [CodeLexToken] = []
    var endState = CodeLineState.normal
    /// Long lines advance the state machine without producing attributes.
    var suppressTokens = false

    init(units: [unichar], start: Int, end: Int, spec: CompiledSyntax) {
        self.units = units
        self.start = start
        self.end = end
        self.spec = spec
        tokens.reserveCapacity(8)
    }

    mutating func run(state: CodeLineState) {
        var index = start
        if state != .normal, resume(from: &index, state: state) {
            return
        }
        scanCode(from: &index)
    }

    /// Resumes a construct that began on an earlier line. Returns true when
    /// the line ends inside the construct, so the state carries forward.
    private mutating func resume(
        from index: inout Int,
        state: CodeLineState
    ) -> Bool {
        switch state {
        case .normal:
            return false
        case .blockComment(let depth, let close, let nested):
            guard let comment = spec.blockComments.first(
                where: { $0.closeString == close }
            ) else {
                endState = .normal
                return false
            }
            var currentDepth = depth
            let closed = scanBlockComment(
                from: &index,
                comment: comment,
                depth: &currentDepth
            )
            appendToken(
                offset: 0,
                length: index - start,
                kind: .comment
            )
            if !closed {
                endState = .blockComment(
                    depth: currentDepth,
                    close: close,
                    nested: nested
                )
                return true
            }
            endState = .normal
        case .multilineString(let delimiter):
            if delimiter == "`", spec.backtickStrings {
                let closed = scanUntil(
                    from: &index,
                    terminator: [0x60],
                    escapeAware: spec.backtickEscapes
                )
                appendToken(
                    offset: 0,
                    length: index - start,
                    kind: .string
                )
                if !closed {
                    endState = .multilineString(delimiter: "`")
                    return true
                }
                endState = .normal
            } else {
                guard let string = spec.multilineStrings.first(
                    where: { $0.closeString == delimiter }
                ) else {
                    endState = .normal
                    return false
                }
                let closed = scanUntil(
                    from: &index,
                    terminator: string.close,
                    escapeAware: string.escapes
                )
                appendToken(
                    offset: 0,
                    length: index - start,
                    kind: .string
                )
                if !closed {
                    endState = .multilineString(delimiter: delimiter)
                    return true
                }
                endState = .normal
            }
        case .rawString(let endMarker):
            let closed = scanUntil(
                from: &index,
                terminator: Array(endMarker.utf16),
                escapeAware: false
            )
            appendToken(
                offset: 0,
                length: index - start,
                kind: .string
            )
            if !closed {
                endState = .rawString(endMarker: endMarker)
                return true
            }
            endState = .normal
        case .heredoc(let pending):
            let line = String(
                decoding: Array(units[start..<end]),
                as: UTF16.self
            )
            appendToken(offset: 0, length: end - start, kind: .string)
            guard let closing = pending.first,
                  closing.indentation.closes(
                      line,
                      delimiter: closing.delimiter
                  ) else {
                endState = state
                return true
            }
            let remaining = Array(pending.dropFirst())
            endState = remaining.isEmpty ? .normal : .heredoc(pending: remaining)
            return true
        case .markupTag(let quote):
            let result = scanMarkupTag(
                from: &index,
                initialQuote: quote
            )
            appendToken(
                offset: 0,
                length: index - start,
                kind: .markup
            )
            if !result.closed {
                endState = .markupTag(quote: result.openQuote)
                return true
            }
            endState = .normal
        }
        return false
    }

    /// Scans the rest of a line that starts in normal state.
    private mutating func scanCode(from index: inout Int) {
        while index < end {
            // A block opener must win over a line comment that is its
            // prefix: Lua's `--[[` is not a `--` comment.
            if let block = matchingBlockComment(at: index) {
                let openIndex = index
                index += block.open.count
                var depth = 1
                let closed = scanBlockComment(
                    from: &index,
                    comment: block,
                    depth: &depth
                )
                appendToken(
                    offset: openIndex - start,
                    length: index - openIndex,
                    kind: .comment
                )
                if !closed {
                    endState = .blockComment(
                        depth: depth,
                        close: block.closeString,
                        nested: block.nested
                    )
                    return
                }
                continue
            }

            if matchingLineComment(at: index) != nil {
                appendToken(
                    offset: index - start,
                    length: end - index,
                    kind: .comment
                )
                index = end
                continue
            }

            if let multiline = matchingMultilineString(at: index) {
                let openIndex = index
                index += multiline.open.count
                let closed = scanUntil(
                    from: &index,
                    terminator: multiline.close,
                    escapeAware: multiline.escapes
                )
                appendToken(
                    offset: openIndex - start,
                    length: index - openIndex,
                    kind: .string
                )
                if !closed {
                    endState = .multilineString(
                        delimiter: multiline.closeString
                    )
                    return
                }
                continue
            }

            if spec.rawStrings != nil, let raw = matchRawString(at: index) {
                let openIndex = index
                index = raw.contentStart
                let closed = scanUntil(
                    from: &index,
                    terminator: Array(raw.endMarker.utf16),
                    escapeAware: false
                )
                appendToken(
                    offset: openIndex - start,
                    length: index - openIndex,
                    kind: .string
                )
                if !closed {
                    endState = .rawString(endMarker: raw.endMarker)
                    return
                }
                continue
            }

            if !spec.heredocs.isEmpty, let first = matchHeredoc(at: index) {
                let openIndex = index
                // One command line can open several heredocs; all of their
                // bodies follow the line, in order. Collect every opener
                // outside quotes and comments before consuming the line.
                var pending = [first.terminator]
                var probe = first.afterDelimiter
                var quote: unichar = 0
                while probe < end {
                    let unit = units[probe]
                    if unit == 0x5C {
                        // A backslash escapes the next unit, inside a
                        // double-quoted string and outside quotes.
                        let escapes = quote == 0
                            || (quote == 0x22 && spec.doubleQuoteEscapes)
                            || (quote == 0x27 && spec.singleQuoteEscapes)
                        probe = escapes ? min(probe + 2, end) : probe + 1
                        continue
                    }
                    if quote != 0 {
                        if unit == quote { quote = 0 }
                        probe += 1
                        continue
                    }
                    if unit == 0x22 || unit == 0x27 {
                        quote = unit
                        probe += 1
                        continue
                    }
                    // `#` follows the language's comment rule: always a
                    // comment in Ruby; in shell-family languages only at a
                    // word boundary (the same set the main scanner uses).
                    if startsHashComment(at: probe) { break }
                    if unit == 0x3C, let next = matchHeredoc(at: probe) {
                        pending.append(next.terminator)
                        probe = max(next.afterDelimiter, probe + 1)
                        continue
                    }
                    probe += 1
                }
                index = end
                appendToken(
                    offset: openIndex - start,
                    length: index - openIndex,
                    kind: .string
                )
                endState = .heredoc(pending: pending)
                return
            }

            if spec.backtickStrings, units[index] == 0x60 {
                let openIndex = index
                index += 1
                let closed = scanUntil(
                    from: &index,
                    terminator: [0x60],
                    escapeAware: spec.backtickEscapes
                )
                appendToken(
                    offset: openIndex - start,
                    length: index - openIndex,
                    kind: .string
                )
                if !closed {
                    endState = .multilineString(delimiter: "`")
                    return
                }
                continue
            }

            if spec.stringQuotes.contains(units[index]) {
                let openIndex = index
                let quote = units[openIndex]
                if spec.rawStrings == .rust, quote == 0x27 {
                    // Rust uses `'` for lifetimes as well as character
                    // literals; only a literal shape starts a string.
                    if let literalEnd = rustCharLiteralEnd(at: index) {
                        index = literalEnd
                        appendToken(
                            offset: openIndex - start,
                            length: index - openIndex,
                            kind: .string
                        )
                    } else {
                        appendToken(
                            offset: openIndex - start,
                            length: 1,
                            kind: .punctuation
                        )
                        index += 1
                    }
                    continue
                }
                index += 1
                let closed = scanQuoted(quote: quote, from: &index)
                appendToken(
                    offset: openIndex - start,
                    length: index - openIndex,
                    kind: .string
                )
                if !closed {
                    endState = .normal
                    return
                }
                continue
            }

            if spec.markupTags, units[index] == 0x3C {
                let openIndex = index
                index += 1
                let result = scanMarkupTag(
                    from: &index,
                    initialQuote: nil
                )
                appendToken(
                    offset: openIndex - start,
                    length: index - openIndex,
                    kind: .markup
                )
                if !result.closed {
                    endState = .markupTag(quote: result.openQuote)
                    return
                }
                continue
            }

            let unit = units[index]
            if isIdentifierStart(unit) {
                let identifierStart = index
                var identifierHash = FNV.offset
                while index < end, isIdentifierContinue(units[index]) {
                    let scanned = units[index]
                    let folded: unichar
                    if spec.caseInsensitiveKeywords,
                       (0x41...0x5A).contains(scanned) {
                        folded = scanned + 0x20
                    } else {
                        folded = scanned
                    }
                    identifierHash = FNV.step(identifierHash, folded)
                    index += 1
                }
                appendToken(
                    offset: identifierStart - start,
                    length: index - identifierStart,
                    kind: classify(
                        hash: identifierHash,
                        at: identifierStart,
                        end: index
                    )
                )
                continue
            }

            if isDigit(unit) {
                let numberStart = index
                scanNumber(from: &index)
                appendToken(
                    offset: numberStart - start,
                    length: index - numberStart,
                    kind: .number
                )
                continue
            }

            if isPunctuation(unit) {
                appendToken(
                    offset: index - start,
                    length: 1,
                    kind: .punctuation
                )
            } else {
                appendToken(
                    offset: index - start,
                    length: 1,
                    kind: .identifier
                )
            }
            index += 1
        }
    }

    // MARK: - Token classification

    private func classify(
        hash: UInt64,
        at location: Int,
        end wordEnd: Int
    ) -> CodeTokenKind {
        if spec.keywordHashes.contains(hash)
            || spec.typeKeywordHashes.contains(hash) {
            let word = String(
                decoding: Array(units[location..<wordEnd]),
                as: UTF16.self
            )
            let key = spec.caseInsensitiveKeywords
                ? word.lowercased()
                : word
            if spec.keywords.contains(key) {
                return .keyword
            }
            if spec.typeKeywords.contains(key) {
                return .typeName
            }
        }
        var probe = wordEnd
        while probe < end, units[probe] == 0x20 || units[probe] == 0x09 {
            probe += 1
        }
        if probe < end, units[probe] == 0x28 {
            return .function
        }
        var before = location - 1
        while before >= start, units[before] == 0x20 || units[before] == 0x09 {
            before -= 1
        }
        if before >= start, units[before] == 0x2E {
            return .property
        }
        return .identifier
    }

    // MARK: - Scanner helpers

    private mutating func appendToken(
        offset: Int,
        length: Int,
        kind: CodeTokenKind
    ) {
        guard !suppressTokens, length > 0 else { return }
        tokens.append(
            CodeLexToken(offset: offset, length: length, kind: kind)
        )
    }

    private func matchingLineComment(at index: Int) -> [unichar]? {
        for comment in spec.lineComments where matches(comment, at: index) {
            if spec.hashCommentRequiresBoundary,
               comment == Array("#".utf16), index > start {
                let previous = units[index - 1]
                // `$#`, `#{`, and `#` inside a word are not comments in
                // shell-family languages; the boundary check keeps them out.
                if previous != 0x20, previous != 0x09, previous != 0x3B,
                   previous != 0x28, previous != 0x7B, previous != 0x7C,
                   previous != 0x26 {
                    continue
                }
            }
            return comment
        }
        return nil
    }

    private func matchingBlockComment(at index: Int) -> CompiledSyntax.BlockComment? {
        spec.blockComments.first { matches($0.open, at: index) }
    }

    /// Whether a `#` at `index` starts a line comment under this language's
    /// rule. Shared with the heredoc opener probe.
    private func startsHashComment(at index: Int) -> Bool {
        guard index < end, units[index] == 0x23 else { return false }
        guard spec.hashCommentRequiresBoundary else { return true }
        guard index > start else { return true }
        let previous = units[index - 1]
        return previous == 0x20 || previous == 0x09 || previous == 0x3B
            || previous == 0x28 || previous == 0x7B || previous == 0x7C
            || previous == 0x26
    }

    private func matchingMultilineString(
        at index: Int
    ) -> CompiledSyntax.MultilineString? {
        spec.multilineStrings.first { matches($0.open, at: index) }
    }

    private func matches(_ pattern: [unichar], at index: Int) -> Bool {
        guard !pattern.isEmpty, index + pattern.count <= end else {
            return false
        }
        for offset in pattern.indices where units[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    /// Scans a block comment to its close, updating `depth`.
    private mutating func scanBlockComment(
        from index: inout Int,
        comment: CompiledSyntax.BlockComment,
        depth: inout Int
    ) -> Bool {
        while index < end {
            if comment.nested, matches(comment.open, at: index) {
                depth += 1
                index += comment.open.count
                continue
            }
            if matches(comment.close, at: index) {
                depth -= 1
                index += comment.close.count
                if depth <= 0 {
                    return true
                }
                continue
            }
            index += 1
        }
        return false
    }

    /// Scans to a terminator. Returns true when the terminator was consumed.
    /// `escapeAware` skips a backslash and the unit after it, so an escaped
    /// delimiter does not close the string. Raw strings scan literally.
    private mutating func scanUntil(
        from index: inout Int,
        terminator: [unichar],
        escapeAware: Bool
    ) -> Bool {
        while index < end {
            if escapeAware, units[index] == 0x5C {
                index = min(end, index + 2)
                continue
            }
            if matches(terminator, at: index) {
                index += terminator.count
                return true
            }
            index += 1
        }
        return false
    }

    /// One-line quoted string. Escapes and doubled-quote escaping depend on
    /// the language and the quote kind: shell single quotes are literal,
    /// SQL and YAML double a quote.
    private mutating func scanQuoted(
        quote: unichar,
        from index: inout Int
    ) -> Bool {
        let isSingle = quote == 0x27
        let escapes = isSingle
            ? spec.singleQuoteEscapes
            : spec.doubleQuoteEscapes
        while index < end {
            let unit = units[index]
            if escapes, unit == 0x5C {
                index = min(end, index + 2)
                continue
            }
            if unit == quote {
                if spec.doubledQuoteEscapes,
                   index + 1 < end,
                   units[index + 1] == quote {
                    index += 2
                    continue
                }
                index += 1
                return true
            }
            index += 1
        }
        return false
    }

    /// The end offset of a Rust character literal, or nil for a lifetime or
    /// a bare apostrophe.
    private func rustCharLiteralEnd(at index: Int) -> Int? {
        var probe = index + 1
        guard probe < end else { return nil }
        if units[probe] == 0x5C {
            probe += 1
            guard probe < end else { return nil }
            if units[probe] == 0x75 { // \u{...}
                probe += 1
                guard probe < end, units[probe] == 0x7B else { return nil }
                probe += 1
                while probe < end, units[probe] != 0x7D {
                    probe += 1
                }
                guard probe < end else { return nil }
                probe += 1
            } else if units[probe] == 0x78 { // \xNN
                probe += 1
                guard probe + 1 < end,
                      isHexDigit(units[probe]),
                      isHexDigit(units[probe + 1]) else {
                    return nil
                }
                probe += 2
            } else {
                probe += 1
            }
        } else {
            // One scalar; a surrogate pair is one character.
            probe += 1
            if probe < end,
               (0xD800...0xDBFF).contains(units[probe - 1]),
               (0xDC00...0xDFFF).contains(units[probe]) {
                probe += 1
            }
        }
        guard probe < end, units[probe] == 0x27 else { return nil }
        return probe + 1
    }

    // MARK: - Raw strings and heredocs

    private struct RawStringMatch {
        let contentStart: Int
        let endMarker: String
    }

    private func matchRawString(at index: Int) -> RawStringMatch? {
        switch spec.rawStrings {
        case .rust:
            var prefix = index
            if matches(Array("br".utf16), at: index)
                || matches(Array("rb".utf16), at: index) {
                prefix += 2
            } else if units[index] == 0x72 { // r
                prefix += 1
            } else {
                return nil
            }
            // `arr"` is an identifier: inspect the character before the
            // opener, not the opener itself.
            if index > start, isIdentifierContinue(units[index - 1]) {
                return nil
            }
            var hashes = 0
            while prefix < end, units[prefix] == 0x23 {
                hashes += 1
                prefix += 1
            }
            guard prefix < end, units[prefix] == 0x22 else { return nil }
            let endMarker = "\"" + String(repeating: "#", count: hashes)
            return RawStringMatch(
                contentStart: prefix + 1,
                endMarker: endMarker
            )
        case .cPlusPlus:
            guard matches(Array("R\"".utf16), at: index) else { return nil }
            var probe = index + 2
            var delimiter = ""
            while probe < end, units[probe] != 0x28, delimiter.count <= 16 {
                delimiter += String(
                    decoding: [units[probe]],
                    as: UTF16.self
                )
                probe += 1
            }
            guard probe < end, units[probe] == 0x28 else { return nil }
            return RawStringMatch(
                contentStart: probe + 1,
                endMarker: ")" + delimiter + "\""
            )
        case .none:
            return nil
        }
    }

    private struct HeredocMatch {
        let delimiter: String
        let indentation: CodeHeredocIndentation
        /// The unit index just past this opener's delimiter, where the next
        /// opener on the same line can be searched for.
        let afterDelimiter: Int

        var terminator: CodeHeredocTerminator {
            CodeHeredocTerminator(
                delimiter: delimiter,
                indentation: indentation
            )
        }
    }

    private func matchHeredoc(at index: Int) -> HeredocMatch? {
        guard units[index] == 0x3C,
              index + 1 < end,
              units[index + 1] == 0x3C else {
            return nil
        }
        // The second `<` of a here-string `<<<` must not look like `<<`.
        if index > start, units[index - 1] == 0x3C {
            return nil
        }
        var probe = index + 2
        var squiggly = false
        var required = CodeHeredocIndentation.exact
        if probe < end, units[probe] == 0x2D {
            required = .tabs
            probe += 1
        } else if probe < end, units[probe] == 0x7E {
            squiggly = true
            required = .whitespace
            probe += 1
        }
        // A style accepts the modifier when its indentation policy is at
        // least as permissive: Ruby's `<<-` allows any whitespace, shell's
        // `<<-` allows tabs only. The first style that fits wins, so shell's
        // plain `<<` selects `.exact` rather than `.tabs`.
        guard let style = spec.heredocs.first(where: {
            $0.indentation >= required && (!squiggly || $0.allowsSquiggly)
        }) else {
            return nil
        }
        if !style.requiresAdjacentDelimiter {
            while probe < end, units[probe] == 0x20 || units[probe] == 0x09 {
                probe += 1
            }
        }
        var quote: unichar = 0
        if probe < end, units[probe] == 0x22 || units[probe] == 0x27 {
            quote = units[probe]
            probe += 1
        }
        let delimiterStart = probe
        while probe < end, isHeredocDelimiter(units[probe]) {
            probe += 1
        }
        let length = probe - delimiterStart
        guard length > 0 else { return nil }
        if quote != 0 {
            guard probe < end, units[probe] == quote else { return nil }
            probe += 1
        }
        let delimiter = String(
            decoding: Array(
                units[delimiterStart..<(delimiterStart + length)]
            ),
            as: UTF16.self
        )
        // The heredoc body starts after the line's newline; the scanner
        // returns at the end of this line and carries the state forward.
        return HeredocMatch(
            delimiter: delimiter,
            indentation: style.indentation,
            afterDelimiter: probe
        )
    }

    private func isHeredocDelimiter(_ unit: unichar) -> Bool {
        isIdentifierContinue(unit) || unit == 0x2D
    }

    // MARK: - Markup

    private struct MarkupScanResult {
        let closed: Bool
        let openQuote: unichar?
    }

    /// Scans one XML/HTML tag from just after `<` to `>`. A quote open at the
    /// end of the line is carried in the state so a `>` inside the quoted
    /// attribute does not close the tag on the next line.
    private mutating func scanMarkupTag(
        from index: inout Int,
        initialQuote: unichar?
    ) -> MarkupScanResult {
        var quote = initialQuote ?? 0
        while index < end {
            let unit = units[index]
            if quote != 0 {
                if unit == quote {
                    quote = 0
                }
                index += 1
                continue
            }
            if unit == 0x22 || unit == 0x27 {
                quote = unit
                index += 1
                continue
            }
            index += 1
            if unit == 0x3E {
                return MarkupScanResult(closed: true, openQuote: nil)
            }
        }
        return MarkupScanResult(
            closed: false,
            openQuote: quote == 0 ? nil : quote
        )
    }

    // MARK: - Numbers

    /// Scans one numeric literal with explicit radix, fraction, and exponent
    /// state. A sign belongs to the number only after an exponent marker, so
    /// `1+2` is two numbers and a plus.
    private mutating func scanNumber(from index: inout Int) {
        if units[index] == 0x30, index + 1 < end {
            switch units[index + 1] {
            case 0x78, 0x58: // x, X
                index += 2
                while index < end,
                      isHexDigit(units[index]) || units[index] == 0x5F {
                    index += 1
                }
                scanExponent(from: &index, marker: 0x70, alternate: 0x50)
                return
            case 0x62, 0x42: // b, B
                index += 2
                while index < end,
                      units[index] == 0x30 || units[index] == 0x31
                        || units[index] == 0x5F {
                    index += 1
                }
                return
            case 0x6F, 0x4F: // o, O
                index += 2
                while index < end,
                      (0x30...0x37).contains(units[index])
                        || units[index] == 0x5F {
                    index += 1
                }
                return
            default:
                break
            }
        }
        while index < end, isDigit(units[index]) || units[index] == 0x5F {
            index += 1
        }
        if index + 1 < end, units[index] == 0x2E,
           isDigit(units[index + 1]) {
            index += 1
            while index < end, isDigit(units[index]) || units[index] == 0x5F {
                index += 1
            }
        }
        scanExponent(from: &index, marker: 0x65, alternate: 0x45)
    }

    private mutating func scanExponent(
        from index: inout Int,
        marker: unichar,
        alternate: unichar
    ) {
        guard index < end,
              units[index] == marker || units[index] == alternate else {
            return
        }
        let save = index
        index += 1
        if index < end, units[index] == 0x2B || units[index] == 0x2D {
            index += 1
        }
        guard index < end, isDigit(units[index]) else {
            index = save
            return
        }
        while index < end, isDigit(units[index]) || units[index] == 0x5F {
            index += 1
        }
    }

    // MARK: - Character classes

    private func isIdentifierStart(_ unit: unichar) -> Bool {
        if unit == 0x5F || unit == 0x24 { return true }
        if (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) {
            return true
        }
        return unit >= 0x80
    }

    private func isIdentifierContinue(_ unit: unichar) -> Bool {
        isIdentifierStart(unit) || isDigit(unit)
    }

    private func isDigit(_ unit: unichar) -> Bool {
        (0x30...0x39).contains(unit)
    }

    private func isHexDigit(_ unit: unichar) -> Bool {
        (0x30...0x39).contains(unit)
            || (0x41...0x46).contains(unit)
            || (0x61...0x66).contains(unit)
    }

    private func isPunctuation(_ unit: unichar) -> Bool {
        switch unit {
        case 0x7B, 0x7D, 0x28, 0x29, 0x5B, 0x5D, 0x3B, 0x2C, 0x2E,
             0x3A, 0x2B, 0x2D, 0x2A, 0x2F, 0x25, 0x3D, 0x26, 0x7C,
             0x21, 0x3F, 0x5E, 0x7E, 0x40, 0x23, 0x5C, 0x3C, 0x3E:
            return true
        default:
            return false
        }
    }
}
