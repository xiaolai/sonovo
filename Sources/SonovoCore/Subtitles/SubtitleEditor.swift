import Foundation

public enum SubtitleEdit: Sendable, Equatable {
    case setText(ordinal: Int, text: String)
    case setTiming(
        ordinal: Int,
        startMilliseconds: Int,
        endMilliseconds: Int
    )
}

public struct SubtitleEditResult: Sendable, Equatable {
    /// The new canonical source. Equal to the input for a no-op edit.
    public let source: String
    /// Where the editor should place the caret after the edit.
    public let selection: Range<Int>
    /// The minimal differing UTF-16 range, for scroll/invalidation hints.
    public let changedRange: Range<Int>
    public let actionName: String
    public let affectedCueOrdinal: Int?

    public init(
        source: String,
        selection: Range<Int>,
        changedRange: Range<Int>,
        actionName: String,
        affectedCueOrdinal: Int?
    ) {
        self.source = source
        self.selection = selection
        self.changedRange = changedRange
        self.actionName = actionName
        self.affectedCueOrdinal = affectedCueOrdinal
    }
}

public enum SubtitleEditError: Error, Equatable {
    case cueNotFound(Int)
    case invalidTiming(startMilliseconds: Int, endMilliseconds: Int)
    case missingFormatInformation
}

/// Pure, range-based cue edits over the canonical source.
///
/// Only the timestamp tokens, text ranges, and cue blocks an operation names
/// are replaced. Every other byte, including ASS styles and VTT header
/// blocks, survives untouched.
public enum SubtitleEditor {
    public static func apply(
        _ edit: SubtitleEdit,
        to parse: SubtitleParseResult,
        source: String
    ) throws -> SubtitleEditResult {
        switch edit {
        case let .setText(ordinal, text):
            return try setText(
                ordinal: ordinal,
                text: text,
                parse: parse,
                source: source
            )
        case let .setTiming(ordinal, start, end):
            return try setTiming(
                ordinal: ordinal,
                start: start,
                end: end,
                parse: parse,
                source: source
            )
        }
    }

    // MARK: - Text

    private static func setText(
        ordinal: Int,
        text: String,
        parse: SubtitleParseResult,
        source: String
    ) throws -> SubtitleEditResult {
        guard let cue = parse.cue(ordinal: ordinal) else {
            throw SubtitleEditError.cueNotFound(ordinal)
        }
        let sanitized = sanitizedText(text, format: parse.format)
        if sanitized == cue.rawText {
            return SubtitleEditResult(
                source: source,
                selection: cue.textRange,
                changedRange: 0..<0,
                actionName: "Edit Cue",
                affectedCueOrdinal: ordinal
            )
        }

        let escaped: String
        let replacement: String
        if parse.format.isASSFamily {
            escaped = sanitized
            replacement = sanitized
        } else if cue.rawText.isEmpty {
            escaped = sanitized
            replacement = sanitized.isEmpty ? "" : "\n" + sanitized
        } else {
            escaped = sanitized
            replacement = sanitized
        }

        let newSource = replacing(
            source,
            ranges: [(cue.textRange, replacement)]
        )
        let selectionStart: Int
        if parse.format.isASSFamily {
            selectionStart = cue.textRange.lowerBound
        } else if cue.rawText.isEmpty, !sanitized.isEmpty {
            selectionStart = cue.textRange.lowerBound + 1
        } else {
            selectionStart = cue.textRange.lowerBound
        }
        return SubtitleEditResult(
            source: newSource,
            selection: selectionStart..<(selectionStart + escaped.utf16.count),
            changedRange: minimalChangedRange(old: source, new: newSource),
            actionName: "Edit Cue",
            affectedCueOrdinal: ordinal
        )
    }

    // MARK: - Timing

    private static func setTiming(
        ordinal: Int,
        start: Int,
        end: Int,
        parse: SubtitleParseResult,
        source: String
    ) throws -> SubtitleEditResult {
        guard let cue = parse.cue(ordinal: ordinal) else {
            throw SubtitleEditError.cueNotFound(ordinal)
        }
        guard start >= 0, end > start,
              start <= SubtitleTimecode.maximumMilliseconds,
              end <= SubtitleTimecode.maximumMilliseconds else {
            throw SubtitleEditError.invalidTiming(
                startMilliseconds: start,
                endMilliseconds: end
            )
        }
        // ASS/SSA store centiseconds. Validate after that quantization so a
        // sub-centisecond range cannot collapse into start == end on disk.
        if parse.format.isASSFamily {
            // Match the formatter exactly: round to centiseconds, cap at the
            // format maximum, then compare in centisecond units.
            let max = SubtitleTimecode.maximumMilliseconds
            let startCentis = min(max, ((start + 5) / 10) * 10) / 10
            let endCentis = min(max, ((end + 5) / 10) * 10) / 10
            guard endCentis > startCentis else {
                throw SubtitleEditError.invalidTiming(
                    startMilliseconds: start,
                    endMilliseconds: end
                )
            }
        }
        guard let startRange = cue.startRange,
              let endRange = cue.endRange else {
            throw SubtitleEditError.missingFormatInformation
        }

        let startText = SubtitleTimecode.format(
            milliseconds: start,
            format: parse.format
        )
        let endText = SubtitleTimecode.format(
            milliseconds: end,
            format: parse.format
        )
        let newSource = replacing(
            source,
            ranges: [
                (startRange, startText),
                (endRange, endText)
            ]
        )
        return SubtitleEditResult(
            source: newSource,
            selection: startRange.lowerBound..<(startRange.lowerBound + startText.utf16.count),
            changedRange: minimalChangedRange(old: source, new: newSource),
            actionName: "Edit Timing",
            affectedCueOrdinal: ordinal
        )
    }

    // MARK: - Text helpers

    static func sanitizedText(
        _ text: String,
        format: SubtitleFormat
    ) -> String {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if format.isASSFamily {
            return normalized
                .replacingOccurrences(of: "\n", with: "\\N")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        normalized = normalized.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        // A line containing only spaces or tabs is blank to the parser and
        // would still end an SRT/VTT cue. Clear it before collapsing blank
        // lines.
        normalized = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.allSatisfy(\.isWhitespace) ? "" : String(line)
            }
            .joined(separator: "\n")
        // A blank line would end an SRT/VTT cue; collapse it to one newline.
        while normalized.contains("\n\n") {
            normalized = normalized.replacingOccurrences(
                of: "\n\n",
                with: "\n"
            )
        }
        return normalized
    }

    // MARK: - Ranges

    private static func replacing(
        _ source: String,
        ranges: [(Range<Int>, String)]
    ) -> String {
        let mutable = NSMutableString(string: source)
        for (range, replacement) in ranges.sorted(by: {
            $0.0.lowerBound > $1.0.lowerBound
        }) {
            let lower = max(0, min(range.lowerBound, mutable.length))
            let upper = max(lower, min(range.upperBound, mutable.length))
            mutable.replaceCharacters(
                in: NSRange(location: lower, length: upper - lower),
                with: replacement
            )
        }
        return mutable as String
    }

    private static func minimalChangedRange(
        old: String,
        new: String
    ) -> Range<Int> {
        let a = old as NSString
        let b = new as NSString
        let limit = min(a.length, b.length)
        var prefix = 0
        while prefix < limit,
              a.character(at: prefix) == b.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < limit - prefix,
              a.character(at: a.length - 1 - suffix)
                == b.character(at: b.length - 1 - suffix) {
            suffix += 1
        }
        return prefix..<(b.length - suffix)
    }
}
