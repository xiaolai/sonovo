import Foundation

/// The line-ending convention of a file.
public enum LineEnding: String, Sendable, Equatable, CaseIterable {
    case lf
    case crlf

    /// The bytes that represent a line ending in this convention.
    public var sequence: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        }
    }
}

/// A file's text after BOM removal and line-ending normalization.
public struct CanonicalText: Sendable, Equatable {
    /// The canonical text: BOM-free, LF-only.
    public let text: String

    /// Whether the original file started with a UTF-8 BOM.
    public let hasBOM: Bool

    /// The dominant line-ending convention of the original file.
    public let lineEnding: LineEnding

    /// Whether the original file mixed line endings.
    public let hadMixedLineEndings: Bool

    public init(
        text: String,
        hasBOM: Bool,
        lineEnding: LineEnding,
        hadMixedLineEndings: Bool
    ) {
        self.text = text
        self.hasBOM = hasBOM
        self.lineEnding = lineEnding
        self.hadMixedLineEndings = hadMixedLineEndings
    }
}

/// Maps upstream source locations to UTF-16 offsets in the canonical source.
///
/// `swift-markdown` reports `SourceLocation.column` as a 1-based count of
/// **UTF-8 bytes** from the start of a line. TextKit and Swift's string APIs
/// count **UTF-16 code units**. Treating one as the other corrupts every
/// non-ASCII document, so this map is mandatory for every parsed range.
///
/// Only scalar boundaries are valid. A byte column inside a multi-byte scalar
/// (for example inside a combining sequence) returns `nil`; the map never
/// rounds or guesses.
public struct SourceMap: Sendable {
    private struct Line: Sendable {
        /// The line without its newline.
        let text: Substring
        /// The global UTF-16 offset of the line's first code unit in the
        /// original document.
        let startUTF16: Int
        /// The line's start index in the source.
        let startIndex: String.Index
        /// The global 1-based line number.
        let number: Int
        /// Characters removed from this line's start before parsing.
        let prefixRemoval: Int
    }

    /// The canonical source this map describes.
    public let source: String

    /// The global 1-based line number of the first line.
    public let baseLine: Int
    /// The global UTF-16 offset of the source's first code unit.
    public let baseOffset: Int
    /// The global 0-based UTF-16 column of the source's first code unit.
    /// Nonzero when the mapped text begins mid-line, as an inline fragment
    /// does.
    public let baseColumn: Int

    private let lines: [Line]
    /// UTF-16 characters removed from the start of each line of `source`,
    /// in order. Used when a fragment is parsed without its enclosing
    /// container markers; positions still report offsets in the original
    /// document.
    private let linePrefixRemovals: [Int]

    /// Creates a map over canonical (BOM-free, LF-only) source.
    ///
    /// - Parameters:
    ///   - source: Canonical source text.
    ///   - baseLine: The global 1-based line number of `source`'s first line.
    ///     A frontmatter body parsed separately uses the line after the
    ///     closing fence.
    ///   - baseOffset: The global UTF-16 offset of `source`'s first code unit.
    ///   - linePrefixRemovals: Characters stripped from the start of each
    ///     line before parsing. Offsets and columns remain global.
    public init(
        source: String,
        baseLine: Int = 1,
        baseOffset: Int = 0,
        baseColumn: Int = 0,
        linePrefixRemovals: [Int] = []
    ) {
        precondition(baseLine >= 1, "baseLine is 1-based")
        precondition(baseOffset >= 0, "baseOffset is 0-based")
        precondition(baseColumn >= 0, "baseColumn is 0-based")
        self.source = source
        self.baseLine = baseLine
        self.baseOffset = baseOffset
        self.baseColumn = baseColumn
        self.linePrefixRemovals = linePrefixRemovals

        var result: [Line] = []
        var cursor = baseOffset
        var number = baseLine
        var start = source.startIndex
        var lineIndex = 0

        while true {
            let newline = source[start...].firstIndex(of: "\n")
            let end = newline ?? source.endIndex
            let text = source[start..<end]
            let removal = lineIndex < linePrefixRemovals.count
                ? linePrefixRemovals[lineIndex]
                : 0
            let startUTF16 = cursor + removal
            result.append(
                Line(
                    text: text,
                    startUTF16: startUTF16,
                    startIndex: start,
                    number: number,
                    prefixRemoval: removal
                )
            )
            cursor = startUTF16 + text.utf16.count
            guard let newline else { break }
            cursor += 1
            number += 1
            lineIndex += 1
            start = source.index(after: newline)
        }

        lines = result
    }

    /// The number of lines in the mapped source.
    public var lineCount: Int { lines.count }

    /// The text of a 1-based global line, without its newline.
    public func lineText(_ line: Int) -> Substring? {
        guard let entry = lineEntry(line) else { return nil }
        return entry.text
    }

    /// Converts a 1-based line and a 1-based UTF-8 byte column to a global
    /// UTF-16 offset, or `nil` when the position is outside the line or inside
    /// a multi-byte scalar.
    public func utf16Offset(line: Int, utf8Column: Int) -> Int? {
        guard let entry = lineEntry(line), utf8Column >= 1 else { return nil }

        let target = utf8Column - 1
        let line = entry.text
        guard target <= line.utf8.count else { return nil }

        guard
            let lineUTF8Start = entry.startIndex.samePosition(in: source.utf8),
            let lineUTF16Start = entry.startIndex.samePosition(in: source.utf16),
            let byteIndex = source.utf8.index(
                lineUTF8Start,
                offsetBy: target,
                limitedBy: source.utf8.endIndex
            ),
            let utf16Index = byteIndex.samePosition(in: source.utf16)
        else {
            return nil
        }

        return entry.startUTF16
            + source.utf16.distance(from: lineUTF16Start, to: utf16Index)
    }

    /// Converts an upstream range to a resolved range.
    ///
    /// The end column is exclusive, matching `swift-markdown`'s convention.
    public func sourceRange(
        startLine: Int,
        startUTF8Column: Int,
        endLine: Int,
        endUTF8Column: Int
    ) -> SourceRange? {
        guard
            let startOffset = utf16Offset(line: startLine, utf8Column: startUTF8Column),
            let endOffset = utf16Offset(line: endLine, utf8Column: endUTF8Column),
            startOffset <= endOffset,
            let start = position(atUTF16Offset: startOffset),
            let end = position(atUTF16Offset: endOffset)
        else {
            return nil
        }
        return SourceRange(start: start, end: end)
    }

    /// Resolves a position from a global UTF-16 offset.
    public func position(atUTF16Offset offset: Int) -> SourcePosition? {
        guard offset >= baseOffset else { return nil }

        // Binary search the last line whose start is not greater than offset.
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].startUTF16 <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }

        let entry = lines[low]
        let local = offset - entry.startUTF16
        guard local >= 0, local <= entry.text.utf16.count else { return nil }

        guard
            let lineUTF16Start = entry.startIndex.samePosition(in: source.utf16),
            let utf16Index = source.utf16.index(
                lineUTF16Start,
                offsetBy: local,
                limitedBy: source.utf16.endIndex
            ),
            utf16Index.samePosition(in: source.unicodeScalars) != nil
        else {
            return nil
        }

        // A fragment that starts mid-line inherits that line's column for
        // every position on its first line. Characters stripped from the
        // line start still count as columns in the original document.
        let column = (entry.number == baseLine ? baseColumn : 0)
            + local
            + entry.prefixRemoval
        return SourcePosition(line: entry.number, column: column, offset: offset)
    }

    /// Returns the source text covered by a resolved range.
    public func text(in range: SourceRange) -> String? {
        guard !linePrefixRemovals.isEmpty else {
            let lower = range.lowerBound - baseOffset
            let upper = range.upperBound - baseOffset
            return Self.slice(source, utf16Offsets: lower..<upper)
        }
        guard let lower = position(atUTF16Offset: range.lowerBound),
              let upper = position(atUTF16Offset: range.upperBound) else {
            return nil
        }
        var pieces: [String] = []
        for lineNumber in lower.line...upper.line {
            guard let entry = lineEntry(lineNumber) else { return nil }
            let lineEnd = entry.startUTF16 + entry.text.utf16.count
            let startLocal = max(
                0,
                (lineNumber == lower.line ? range.lowerBound : entry.startUTF16)
                    - entry.startUTF16
            )
            let endLocal = min(
                entry.text.utf16.count,
                max(
                    0,
                    (lineNumber == upper.line ? range.upperBound : lineEnd)
                        - entry.startUTF16
                )
            )
            if endLocal > startLocal,
               let piece = Self.slice(
                   String(entry.text),
                   utf16Offsets: startLocal..<endLocal
               ) {
                pieces.append(piece)
            }
            if lineNumber < upper.line {
                pieces.append("\n")
            }
        }
        return pieces.joined()
    }

    /// Returns the slice covered by UTF-16 offsets, or nil when the range is
    /// out of bounds or falls inside a multi-byte scalar.
    public static func slice(
        _ source: String,
        utf16Offsets: Range<Int>
    ) -> String? {
        let utf16 = source.utf16
        guard
            utf16Offsets.lowerBound >= 0,
            utf16Offsets.upperBound <= utf16.count,
            let lower = utf16.index(
                utf16.startIndex,
                offsetBy: utf16Offsets.lowerBound,
                limitedBy: utf16.endIndex
            ),
            let upper = utf16.index(
                utf16.startIndex,
                offsetBy: utf16Offsets.upperBound,
                limitedBy: utf16.endIndex
            ),
            let lowerScalar = lower.samePosition(in: source.unicodeScalars),
            let upperScalar = upper.samePosition(in: source.unicodeScalars)
        else {
            return nil
        }
        // Scalar boundaries are valid even when they fall inside a grapheme
        // cluster; `position` accepts the same boundaries.
        return String(source.unicodeScalars[lowerScalar..<upperScalar])
    }

    private func lineEntry(_ line: Int) -> Line? {
        guard let first = lines.first else { return nil }
        let index = line - first.number
        guard index >= 0, index < lines.count else { return nil }
        return lines[index]
    }
}

// MARK: - Raw text canonicalization

extension SourceMap {
    /// Strips a leading BOM and normalizes CRLF and lone CR to LF.
    ///
    /// The original convention is retained so the file layer can re-emit the
    /// same bytes on save. Mixed endings normalize to the dominant convention.
    public static func canonicalize(
        raw: String,
        stripBOM: Bool = true
    ) -> CanonicalText {
        var text = raw
        var hasBOM = false
        if stripBOM, text.hasPrefix("\u{FEFF}") {
            hasBOM = true
            text.removeFirst()
        }

        let ns = text as NSString

        // Count CRLF pairs first; remaining CR and LF are single endings.
        var crlf = 0
        var searchStart = 0
        while searchStart < ns.length {
            let found = ns.range(
                of: "\r\n",
                options: [],
                range: NSRange(location: searchStart, length: ns.length - searchStart)
            )
            if found.location == NSNotFound { break }
            crlf += 1
            searchStart = found.location + found.length
        }

        let totalCR = ns.components(separatedBy: "\r").count - 1
        let totalLF = ns.components(separatedBy: "\n").count - 1
        let loneCR = totalCR - crlf
        let bareLF = totalLF - crlf

        // A lone CR is still CR-style for convention purposes.
        let crStyle = crlf + loneCR
        let lineEnding: LineEnding = crStyle > bareLF ? .crlf : .lf
        // Any two distinct conventions are a mixed file, including CRLF plus
        // lone CR with no bare LF.
        let mixed = [crlf > 0, loneCR > 0, bareLF > 0]
            .filter { $0 }
            .count > 1

        let normalized = ns
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        return CanonicalText(
            text: normalized,
            hasBOM: hasBOM,
            lineEnding: lineEnding,
            hadMixedLineEndings: mixed
        )
    }
}
