import Foundation

enum WebVTTParser {
    static func parse(_ source: String) -> SubtitleParseParts {
        let ns = source as NSString
        let lines = SubtitleLineIndex.lines(in: ns)
        var parts = SubtitleParseParts()
        var builder = SubtitleDiagnosticBuilder()
        var index = 0
        var ordinal = 0
        var identifiers = Set<String>()

        // Header: WEBVTT plus metadata until a blank line or the first cue.
        if let first = lines.first,
           SubtitleLineIndex.trimmed(first, in: ns)
            .uppercased().hasPrefix("WEBVTT") {
            index = 1
            while index < lines.count {
                if SubtitleLineIndex.isBlank(lines[index], in: ns) {
                    break
                }
                let text = SubtitleLineIndex.trimmed(lines[index], in: ns)
                if text.contains("-->") { break }
                let upper = text.uppercased()
                if upper.hasPrefix("NOTE")
                    || upper.hasPrefix("STYLE")
                    || upper.hasPrefix("REGION") {
                    break
                }
                index += 1
            }
        } else {
            builder.add(
                .warning,
                .malformedBlock(reason: "Missing WEBVTT header"),
                "This file does not start with a WEBVTT header."
            )
        }

        while index < lines.count {
            while index < lines.count,
                  SubtitleLineIndex.isBlank(lines[index], in: ns) {
                index += 1
            }
            guard index < lines.count else { break }

            let blockStart = index
            var blockEnd = index
            while blockEnd < lines.count,
                  !SubtitleLineIndex.isBlank(lines[blockEnd], in: ns) {
                blockEnd += 1
            }

            let firstText = SubtitleLineIndex.trimmed(
                lines[blockStart],
                in: ns
            )
            let upper = firstText.uppercased()
            if upper.hasPrefix("NOTE")
                || upper.hasPrefix("STYLE")
                || upper.hasPrefix("REGION") {
                index = blockEnd
                continue
            }

            var timingLineNumber = -1
            var identifier: String?
            if firstText.contains("-->") {
                timingLineNumber = blockStart
            } else if blockStart + 1 < blockEnd,
                      SubtitleLineIndex.trimmed(
                          lines[blockStart + 1],
                          in: ns
                      ).contains("-->") {
                identifier = firstText
                timingLineNumber = blockStart + 1
            } else {
                let range = lines[blockStart].content.lowerBound..<lines[blockEnd - 1].content.upperBound
                recordSubtitleUnparsed(
                    range: range,
                    reason: "Expected a WebVTT cue timestamp",
                    ns: ns,
                    parts: &parts,
                    builder: &builder
                )
                index = blockEnd
                continue
            }

            let timingLine = lines[timingLineNumber]
            let timingText = SubtitleLineIndex.text(timingLine, in: ns)
            guard let timing = SRTParser.parseTiming(
                timingText,
                line: timingLine,
                ns: ns
            ) else {
                let range = lines[blockStart].content.lowerBound..<lines[blockEnd - 1].content.upperBound
                recordSubtitleUnparsed(
                    range: range,
                    reason: "Malformed WebVTT timestamps",
                    ns: ns,
                    parts: &parts,
                    builder: &builder
                )
                index = blockEnd
                continue
            }

            if let identifier {
                if !identifiers.insert(identifier).inserted {
                    builder.add(
                        .warning,
                        .duplicateIndex(identifier),
                        "Duplicate WebVTT cue identifier \(identifier).",
                        cueOrdinal: ordinal,
                        range: lines[blockStart].content
                    )
                }
            }

            let textStart = timingLineNumber + 1
            let text: String
            let textRange: Range<Int>
            let cueEnd: Int
            if textStart < blockEnd {
                textRange = lines[textStart].content.lowerBound..<lines[blockEnd - 1].content.upperBound
                text = ns.substring(with: NSRange(
                    location: textRange.lowerBound,
                    length: textRange.count
                ))
                cueEnd = textRange.upperBound
            } else {
                text = ""
                textRange = timingLine.content.upperBound..<timingLine.content.upperBound
                cueEnd = timingLine.content.upperBound
            }

            var next = blockEnd
            while next < lines.count,
                  SubtitleLineIndex.isBlank(lines[next], in: ns) {
                next += 1
            }
            let nextStart = next < lines.count
                ? lines[next].content.lowerBound
                : ns.length
            let separator = cueEnd < nextStart
                ? cueEnd..<nextStart
                : nil

            if ordinal == 0 {
                parts.timestampStyle = SubtitleTimestampStyle(
                    decimalSeparator: timing.separator,
                    fractionDigits: timing.fractionDigits,
                    includesHours: timing.includesHours
                )
            }

            parts.cues.append(
                SubtitleCue(
                    ordinal: ordinal,
                    startMilliseconds: timing.start,
                    endMilliseconds: timing.end,
                    rawText: text,
                    rawTiming: timingText.trimmingCharacters(
                        in: .whitespaces
                    ),
                    blockRange: lines[blockStart].content.lowerBound..<cueEnd,
                    textRange: textRange,
                    startRange: timing.startRange,
                    endRange: timing.endRange,
                    timingLineRange: timingLine.content,
                    separatorRangeAfter: separator,
                    identifier: identifier,
                    settings: timing.trailing.isEmpty
                        ? nil
                        : timing.trailing,
                    coordinateLine: nil,
                    style: nil
                )
            )
            ordinal += 1
            index = next
        }

        parts.diagnostics = builder.diagnostics
        return parts
    }

}
