import Foundation

enum SRTParser {
    static func parse(_ source: String) -> SubtitleParseParts {
        let ns = source as NSString
        let lines = SubtitleLineIndex.lines(in: ns)
        var parts = SubtitleParseParts()
        var builder = SubtitleDiagnosticBuilder()
        var index = 0
        var ordinal = 0
        var sawIndex = false

        while index < lines.count {
            while index < lines.count,
                  SubtitleLineIndex.isBlank(lines[index], in: ns) {
                index += 1
            }
            guard index < lines.count else { break }

            let blockStart = index
            let first = SubtitleLineIndex.trimmed(lines[index], in: ns)
            var timingLineNumber = -1
            var identifier: String?

            if first.contains("-->") {
                timingLineNumber = index
            } else if !first.isEmpty,
                      first.allSatisfy({ $0.isNumber }),
                      index + 1 < lines.count,
                      SubtitleLineIndex.trimmed(lines[index + 1], in: ns)
                        .contains("-->") {
                identifier = first
                sawIndex = true
                timingLineNumber = index + 1
            } else {
                let end = consumeBlock(from: index, lines: lines, ns: ns)
                let range = lines[index].content.lowerBound..<lines[end - 1].content.upperBound
                recordSubtitleUnparsed(
                    range: range,
                    reason: "Expected an SRT timestamp line",
                    ns: ns,
                    parts: &parts,
                    builder: &builder
                )
                index = end
                continue
            }

            let timingLine = lines[timingLineNumber]
            let timingText = SubtitleLineIndex.text(timingLine, in: ns)
            guard let timing = parseTiming(
                timingText,
                line: timingLine,
                ns: ns
            ) else {
                let end = consumeBlock(
                    from: timingLineNumber + 1,
                    lines: lines,
                    ns: ns
                )
                let lastLine = min(
                    max(end - 1, timingLineNumber),
                    lines.count - 1
                )
                let range = lines[blockStart].content.lowerBound..<lines[lastLine].content.upperBound
                recordSubtitleUnparsed(
                    range: range,
                    reason: "Malformed SRT timestamps",
                    ns: ns,
                    parts: &parts,
                    builder: &builder
                )
                index = end
                continue
            }

            var textIndex = timingLineNumber + 1
            var coordinateLine: String?
            if textIndex < lines.count,
               !SubtitleLineIndex.isBlank(lines[textIndex], in: ns),
               isCoordinateLine(
                   SubtitleLineIndex.trimmed(lines[textIndex], in: ns)
               ) {
                coordinateLine = SubtitleLineIndex.trimmed(
                    lines[textIndex],
                    in: ns
                )
                textIndex += 1
            }

            var textEnd = textIndex
            while textEnd < lines.count,
                  !SubtitleLineIndex.isBlank(lines[textEnd], in: ns) {
                textEnd += 1
            }

            let text: String
            let textRange: Range<Int>
            let blockEnd: Int
            if textIndex < textEnd {
                textRange = lines[textIndex].content.lowerBound..<lines[textEnd - 1].content.upperBound
                text = ns.substring(with: NSRange(
                    location: textRange.lowerBound,
                    length: textRange.count
                ))
                blockEnd = textRange.upperBound
            } else {
                var anchor = timingLine.content.upperBound
                if textIndex > timingLineNumber + 1,
                   textIndex - 1 >= timingLineNumber + 1 {
                    anchor = lines[textIndex - 1].content.upperBound
                }
                text = ""
                textRange = anchor..<anchor
                blockEnd = anchor
            }

            // Consume the blank-line separator up to the next block.
            var next = textEnd
            while next < lines.count,
                  SubtitleLineIndex.isBlank(lines[next], in: ns) {
                next += 1
            }
            let nextStart = next < lines.count
                ? lines[next].content.lowerBound
                : ns.length
            let separator = blockEnd < nextStart
                ? blockEnd..<nextStart
                : nil

            if ordinal == 0 {
                parts.timestampStyle = SubtitleTimestampStyle(
                    decimalSeparator: timing.separator,
                    fractionDigits: timing.fractionDigits,
                    includesHours: timing.includesHours
                )
            }

            let cue = SubtitleCue(
                ordinal: ordinal,
                startMilliseconds: timing.start,
                endMilliseconds: timing.end,
                rawText: text,
                rawTiming: timingText.trimmingCharacters(in: .whitespaces),
                blockRange: lines[blockStart].content.lowerBound..<blockEnd,
                textRange: textRange,
                startRange: timing.startRange,
                endRange: timing.endRange,
                timingLineRange: timingLine.content,
                separatorRangeAfter: separator,
                identifier: identifier,
                settings: timing.trailing.isEmpty
                    ? nil
                    : timing.trailing,
                coordinateLine: coordinateLine,
                style: nil
            )
            guard parts.cues.count < SubtitleLimits.maxCueCount else {
                parts.truncated = true
                break
            }
            parts.cues.append(cue)
            ordinal += 1
            index = next
        }

        parts.hasCueIndexes = sawIndex
        parts.diagnostics = builder.diagnostics
        return parts
    }

    /// Advances past the blank line that ends a malformed block.
    private static func consumeBlock(
        from start: Int,
        lines: [SubtitleLine],
        ns: NSString
    ) -> Int {
        var index = start
        while index < lines.count,
              !SubtitleLineIndex.isBlank(lines[index], in: ns) {
            index += 1
        }
        return max(index, start + 1)
    }


    private static func isCoordinateLine(_ text: String) -> Bool {
        // A coordinate record is exactly four labelled integers and nothing
        // else. Dialogue that merely mentions the labels stays cue text.
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        let labels = ["X1:", "X2:", "Y1:", "Y2:"]
        guard tokens.count == labels.count else { return false }
        for (token, label) in zip(tokens, labels) {
            let upper = token.uppercased()
            guard upper.hasPrefix(label) else { return false }
            var value = Substring(upper.dropFirst(label.count))
            if value.first == "-" { value = value.dropFirst() }
            guard !value.isEmpty,
                  value.allSatisfy({ ("0"..."9").contains($0) }) else {
                return false
            }
        }
        return true
    }

    struct Timing {
        let start: Int
        let end: Int
        let startRange: Range<Int>
        let endRange: Range<Int>
        let trailing: String
        let separator: Character
        let fractionDigits: Int
        let includesHours: Bool
    }

    static func parseTiming(
        _ text: String,
        line: SubtitleLine,
        ns: NSString
    ) -> Timing? {
        let arrow = (text as NSString).range(of: "-->")
        guard arrow.location != NSNotFound else { return nil }

        let contentStart = line.content.lowerBound
        let leftRange = contentStart..<(contentStart + arrow.location)
        let rightRange = (contentStart + NSMaxRange(arrow))..<line.content.upperBound
        let left = SubtitleLineIndex.trimmedRange(leftRange, in: ns)
        let right = SubtitleLineIndex.trimmedRange(rightRange, in: ns)
        guard !left.isEmpty, !right.isEmpty else { return nil }

        // The end token is the first whitespace-delimited run on the right;
        // anything after it is an SRT settings/coordinate tail.
        var endTokenEnd = right.lowerBound
        while endTokenEnd < right.upperBound,
              ns.character(at: endTokenEnd) != 0x20,
              ns.character(at: endTokenEnd) != 0x09 {
            endTokenEnd += 1
        }
        let endRange = right.lowerBound..<endTokenEnd
        let startText = ns.substring(with: NSRange(
            location: left.lowerBound,
            length: left.count
        ))
        let endText = ns.substring(with: NSRange(
            location: endRange.lowerBound,
            length: endRange.count
        ))
        guard let start = SubtitleTimecode.parse(
            startText,
            allowsHourless: true,
            decimalSeparator: nil
        ), let end = SubtitleTimecode.parse(
            endText,
            allowsHourless: true,
            decimalSeparator: nil
        ) else {
            return nil
        }

        let trailingRange = endTokenEnd..<right.upperBound
        let trailing = ns.substring(with: NSRange(
            location: trailingRange.lowerBound,
            length: trailingRange.count
        )).trimmingCharacters(in: .whitespaces)

        let separator: Character = startText.contains(",") ? "," : "."
        let fractionDigits: Int
        if let separatorIndex = startText.lastIndex(of: separator) {
            fractionDigits = startText.distance(
                from: startText.index(after: separatorIndex),
                to: startText.endIndex
            )
        } else {
            fractionDigits = 0
        }

        return Timing(
            start: start,
            end: end,
            startRange: left,
            endRange: endRange,
            trailing: trailing,
            separator: separator,
            fractionDigits: fractionDigits,
            includesHours: startText.split(separator: ":").count == 3
        )
    }
}
