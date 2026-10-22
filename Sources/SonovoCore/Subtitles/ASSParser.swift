import Foundation

enum ASSParser {
    static func parse(_ source: String) -> SubtitleParseParts {
        let ns = source as NSString
        let lines = SubtitleLineIndex.lines(in: ns)
        var parts = SubtitleParseParts()
        var builder = SubtitleDiagnosticBuilder()

        var section = ""
        var eventsFields: [String]?
        var eventsRange: Range<Int>?
        var styleFields: [String]?
        var defaultStyle: String?
        var dialoguePrefix = "Dialogue: "
        var ordinal = 0
        var reportedMissingFormat = false

        for line in lines {
            let text = SubtitleLineIndex.text(line, in: ns)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                section = trimmed.uppercased()
                if section == "[EVENTS]" {
                    eventsRange = line.content
                }
                styleFields = nil
                continue
            }

            let lower = trimmed.lowercased()
            if section == "[EVENTS]" {
                if lower.hasPrefix("format:") {
                    if let valueRange = valueRange(
                        for: line,
                        ns: ns
                    ) {
                        eventsFields = fields(
                            in: valueRange,
                            ns: ns
                        ).map { $0.lowercased() }
                    }
                    continue
                }
                guard lower.hasPrefix("dialogue:") else { continue }

                guard let fields = eventsFields else {
                    if !reportedMissingFormat {
                        reportedMissingFormat = true
                        builder.add(
                            .error,
                            .missingFormatLine,
                            "The [Events] section has no Format line."
                        )
                    }
                    recordSubtitleUnparsed(
                        range: line.content,
                        reason: "Dialogue before an [Events] Format line",
                        ns: ns,
                        parts: &parts,
                        builder: &builder
                    )
                    continue
                }
                guard let cue = parseDialogue(
                    line: line,
                    ns: ns,
                    fields: fields,
                    ordinal: ordinal,
                    parts: &parts,
                    builder: &builder
                ) else {
                    continue
                }
                if ordinal == 0 {
                    let startText = cue.startRange.map {
                        ns.substring(with: NSRange(
                            location: $0.lowerBound,
                            length: $0.count
                        ))
                    } ?? ""
                    let separator: Character = startText.contains(",") ? "," : "."
                    let fraction = startText.lastIndex(of: separator).map {
                        startText.distance(
                            from: startText.index(after: $0),
                            to: startText.endIndex
                        )
                    } ?? 0
                    parts.timestampStyle = SubtitleTimestampStyle(
                        decimalSeparator: separator,
                        fractionDigits: fraction,
                        includesHours: true
                    )
                    if let value = valueRange(for: line, ns: ns) {
                        var prefixEnd = value.lowerBound
                        while prefixEnd < value.upperBound,
                              ns.character(at: prefixEnd) == 0x20
                                || ns.character(at: prefixEnd) == 0x09 {
                            prefixEnd += 1
                        }
                        let prefix = ns.substring(with: NSRange(
                            location: line.content.lowerBound,
                            length: max(
                                0,
                                prefixEnd - line.content.lowerBound
                            )
                        ))
                        if !prefix.trimmingCharacters(in: .whitespaces)
                            .isEmpty {
                            dialoguePrefix = prefix
                        }
                    }
                }
                guard parts.cues.count < SubtitleLimits.maxCueCount else {
                    parts.truncated = true
                    break
                }
                parts.cues.append(cue)
                ordinal += 1
                continue
            }

            if section == "[V4+ STYLES]" || section == "[V4 STYLES]" {
                if lower.hasPrefix("format:") {
                    if let valueRange = valueRange(for: line, ns: ns) {
                        styleFields = fields(
                            in: valueRange,
                            ns: ns
                        ).map { $0.lowercased() }
                    }
                    continue
                }
                if lower.hasPrefix("style:") {
                    if defaultStyle == nil,
                       let valueRange = valueRange(for: line, ns: ns) {
                        let rawFields = fields(
                            in: valueRange,
                            ns: ns
                        )
                        let nameIndex = styleFields?.firstIndex(of: "name")
                            ?? 0
                        if nameIndex < rawFields.count {
                            let name = rawFields[nameIndex]
                                .trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty { defaultStyle = name }
                        }
                    }
                    continue
                }
            }
        }

        parts.assInfo = ASSInfo(
            formatFields: eventsFields ?? [],
            eventsSectionRange: eventsRange,
            defaultStyle: defaultStyle,
            dialoguePrefix: dialoguePrefix
        )
        parts.diagnostics = builder.diagnostics
        return parts
    }

    private static func parseDialogue(
        line: SubtitleLine,
        ns: NSString,
        fields: [String],
        ordinal: Int,
        parts: inout SubtitleParseParts,
        builder: inout SubtitleDiagnosticBuilder
    ) -> SubtitleCue? {
        guard !fields.isEmpty,
              let valueRange = valueRange(for: line, ns: ns) else {
            recordSubtitleUnparsed(
                range: line.content,
                reason: "Malformed Dialogue line",
                ns: ns,
                parts: &parts,
                builder: &builder
            )
            return nil
        }

        guard let rawFieldRanges = splitFields(
            valueRange,
            count: fields.count,
            line: line,
            ns: ns
        ) else {
            recordSubtitleUnparsed(
                range: line.content,
                reason: "Dialogue field count does not match Format",
                ns: ns,
                parts: &parts,
                builder: &builder
            )
            return nil
        }

        let ranges = rawFieldRanges.map {
            SubtitleLineIndex.trimmedRange($0, in: ns)
        }
        guard let startIndex = fields.firstIndex(of: "start"),
              let endIndex = fields.firstIndex(of: "end"),
              let textIndex = fields.firstIndex(of: "text"),
              startIndex < ranges.count,
              endIndex < ranges.count,
              textIndex < ranges.count else {
            recordSubtitleUnparsed(
                range: line.content,
                reason: "Dialogue Format is missing Start, End, or Text",
                ns: ns,
                parts: &parts,
                builder: &builder
            )
            return nil
        }

        let startText = ns.substring(
            with: NSRange(
                location: ranges[startIndex].lowerBound,
                length: ranges[startIndex].count
            )
        ).trimmingCharacters(in: .whitespaces)
        let endText = ns.substring(
            with: NSRange(
                location: ranges[endIndex].lowerBound,
                length: ranges[endIndex].count
            )
        ).trimmingCharacters(in: .whitespaces)
        guard let start = SubtitleTimecode.parse(
            startText,
            allowsHourless: false,
            decimalSeparator: nil
        ), let end = SubtitleTimecode.parse(
            endText,
            allowsHourless: false,
            decimalSeparator: nil
        ) else {
            recordSubtitleUnparsed(
                range: line.content,
                reason: "Malformed ASS timestamps",
                ns: ns,
                parts: &parts,
                builder: &builder
            )
            return nil
        }

        let textRange = ranges[textIndex]
        let rawText = ns.substring(
            with: NSRange(
                location: textRange.lowerBound,
                length: textRange.count
            )
        )
        let style: String?
        if let styleIndex = fields.firstIndex(of: "style"),
           styleIndex < ranges.count {
            style = ns.substring(
                with: NSRange(
                    location: ranges[styleIndex].lowerBound,
                    length: ranges[styleIndex].count
                )
            ).trimmingCharacters(in: .whitespaces)
        } else {
            style = nil
        }

        let separator: Range<Int>? = line.full.upperBound
            > line.content.upperBound
            ? line.content.upperBound..<line.full.upperBound
            : nil

        return SubtitleCue(
            ordinal: ordinal,
            startMilliseconds: start,
            endMilliseconds: end,
            rawText: rawText,
            rawTiming: "\(startText) --> \(endText)",
            blockRange: line.content,
            textRange: textRange,
            startRange: ranges[startIndex],
            endRange: ranges[endIndex],
            timingLineRange: line.content,
            separatorRangeAfter: separator,
            identifier: nil,
            settings: nil,
            coordinateLine: nil,
            style: style
        )
    }

    /// The range after the first colon on a key/value line.
    private static func valueRange(
        for line: SubtitleLine,
        ns: NSString
    ) -> Range<Int>? {
        let colon = ns.range(
            of: ":",
            options: [],
            range: NSRange(
                location: line.content.lowerBound,
                length: line.content.count
            )
        )
        guard colon.location != NSNotFound else { return nil }
        let start = NSMaxRange(colon)
        guard start < line.content.upperBound else {
            return start..<start
        }
        return start..<line.content.upperBound
    }

    /// Splits `valueRange` on commas into exactly `count` fields; the last
    /// field keeps every remaining comma, which is where ASS text lives.
    private static func splitFields(
        _ valueRange: Range<Int>,
        count: Int,
        line: SubtitleLine,
        ns: NSString
    ) -> [Range<Int>]? {
        guard count > 0 else { return nil }
        var ranges: [Range<Int>] = []
        var cursor = valueRange.lowerBound
        for _ in 0..<(count - 1) {
            let comma = ns.range(
                of: ",",
                options: [],
                range: NSRange(
                    location: cursor,
                    length: max(0, line.content.upperBound - cursor)
                )
            )
            guard comma.location != NSNotFound else { return nil }
            ranges.append(cursor..<comma.location)
            cursor = comma.location + 1
        }
        ranges.append(cursor..<line.content.upperBound)
        return ranges
    }

    /// Plain comma-separated field names, used for Format lines where no
    /// field contains a comma.
    private static func fields(
        in valueRange: Range<Int>,
        ns: NSString
    ) -> [String] {
        let raw = ns.substring(with: NSRange(
            location: valueRange.lowerBound,
            length: valueRange.count
        ))
        return raw.split(
            separator: ",",
            omittingEmptySubsequences: false
        ).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}
