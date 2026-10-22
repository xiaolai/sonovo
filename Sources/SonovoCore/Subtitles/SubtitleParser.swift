import Foundation

/// Parses canonical (LF-only) subtitle source into cue projections.
///
/// Parsing never rewrites the source. The result is a read-only projection
/// stamped by the caller with the document revision.
public enum SubtitleParser {
    public static func parse(
        _ source: String,
        format: SubtitleFormat
    ) -> SubtitleParseResult {
        var parts: SubtitleParseParts
        switch format {
        case .srt:
            parts = SRTParser.parse(source)
        case .vtt:
            parts = WebVTTParser.parse(source)
        case .ass, .ssa:
            parts = ASSParser.parse(source)
        }

        var cues = parts.cues
        var diagnostics = parts.diagnostics
        var nextID = (diagnostics.map(\.id).max() ?? -1) + 1

        if parts.truncated || cues.count > SubtitleLimits.maxCueCount {
            cues = Array(cues.prefix(SubtitleLimits.maxCueCount))
            appendDiagnostic(
                severity: .warning,
                kind: .cueLimitReached,
                message: "Only the first \(SubtitleLimits.maxCueCount) cues are shown.",
                diagnostics: &diagnostics,
                nextID: &nextID
            )
        }

        for cue in cues {
            if cue.endMilliseconds <= cue.startMilliseconds {
                appendDiagnostic(
                    severity: .error,
                    kind: cue.endMilliseconds < 0
                        ? .negativeTimestamp
                        : .endNotAfterStart,
                    message: "Cue \(cue.ordinal + 1) ends before it starts.",
                    cueOrdinal: cue.ordinal,
                    range: cue.startRange,
                    diagnostics: &diagnostics,
                    nextID: &nextID
                )
            }
            if cue.rawText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                appendDiagnostic(
                    severity: .warning,
                    kind: .emptyText,
                    message: "Cue \(cue.ordinal + 1) has no text.",
                    cueOrdinal: cue.ordinal,
                    range: cue.blockRange,
                    diagnostics: &diagnostics,
                    nextID: &nextID
                )
            }
        }

        // Overlaps are legal in ASS (layers) but almost always a mistake in
        // SRT/VTT. Report them uniformly; the editor never blocks them.
        let ordered = cues.filter(\.hasValidTiming).sorted {
            if $0.startMilliseconds == $1.startMilliseconds {
                return $0.ordinal < $1.ordinal
            }
            return $0.startMilliseconds < $1.startMilliseconds
        }
        var furthestEnd = -1
        var furthestOrdinal = -1
        for cue in ordered {
            if cue.startMilliseconds < furthestEnd {
                appendDiagnostic(
                    severity: .warning,
                    kind: .overlappingCue(
                        previousOrdinal: furthestOrdinal
                    ),
                    message: "Cue \(cue.ordinal + 1) overlaps the previous cue.",
                    cueOrdinal: cue.ordinal,
                    range: cue.startRange,
                    diagnostics: &diagnostics,
                    nextID: &nextID
                )
            }
            if cue.endMilliseconds > furthestEnd {
                furthestEnd = cue.endMilliseconds
                furthestOrdinal = cue.ordinal
            }
        }

        return SubtitleParseResult(
            format: format,
            cues: cues,
            diagnostics: diagnostics,
            unparsedBlocks: parts.unparsedBlocks,
            timeline: SubtitleTimeline(cues: cues),
            hasCueIndexes: parts.hasCueIndexes,
            assInfo: parts.assInfo,
            timestampStyle: parts.timestampStyle
        )
    }

    /// Cross-format diagnostics share the parser's one limit. Without this,
    /// 50,000 empty cues could append 50,000 warnings after the format
    /// builder had already claimed to hide further issues.
    private static func appendDiagnostic(
        severity: SubtitleDiagnostic.Severity,
        kind: SubtitleDiagnostic.Kind,
        message: String,
        cueOrdinal: Int? = nil,
        range: Range<Int>? = nil,
        diagnostics: inout [SubtitleDiagnostic],
        nextID: inout Int
    ) {
        guard diagnostics.count < SubtitleLimits.maxDiagnostics else {
            let alreadyMarked = diagnostics.contains { diagnostic in
                if case .diagnosticsLimitReached = diagnostic.kind {
                    return true
                }
                return false
            }
            if !alreadyMarked {
                diagnostics.append(
                    SubtitleDiagnostic(
                        id: nextID,
                        severity: .warning,
                        kind: .diagnosticsLimitReached,
                        message: "Too many diagnostics; further issues are hidden."
                    )
                )
                nextID += 1
            }
            return
        }
        diagnostics.append(
            SubtitleDiagnostic(
                id: nextID,
                severity: severity,
                kind: kind,
                message: message,
                cueOrdinal: cueOrdinal,
                range: range
            )
        )
        nextID += 1
    }
}
