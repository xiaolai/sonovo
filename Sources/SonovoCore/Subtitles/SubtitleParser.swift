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

        if cues.count > SubtitleLimits.maxCueCount {
            cues = Array(cues.prefix(SubtitleLimits.maxCueCount))
            diagnostics.append(
                SubtitleDiagnostic(
                    id: nextID,
                    severity: .warning,
                    kind: .cueLimitReached,
                    message: "Only the first \(SubtitleLimits.maxCueCount) cues are shown."
                )
            )
            nextID += 1
        }

        for cue in cues {
            if cue.endMilliseconds <= cue.startMilliseconds {
                diagnostics.append(
                    SubtitleDiagnostic(
                        id: nextID,
                        severity: .error,
                        kind: cue.endMilliseconds < 0
                            ? .negativeTimestamp
                            : .endNotAfterStart,
                        message: "Cue \(cue.ordinal + 1) ends before it starts.",
                        cueOrdinal: cue.ordinal,
                        range: cue.startRange
                    )
                )
                nextID += 1
            }
            if cue.rawText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                diagnostics.append(
                    SubtitleDiagnostic(
                        id: nextID,
                        severity: .warning,
                        kind: .emptyText,
                        message: "Cue \(cue.ordinal + 1) has no text.",
                        cueOrdinal: cue.ordinal,
                        range: cue.blockRange
                    )
                )
                nextID += 1
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
                diagnostics.append(
                    SubtitleDiagnostic(
                        id: nextID,
                        severity: .warning,
                        kind: .overlappingCue(
                            previousOrdinal: furthestOrdinal
                        ),
                        message: "Cue \(cue.ordinal + 1) overlaps the previous cue.",
                        cueOrdinal: cue.ordinal,
                        range: cue.startRange
                    )
                )
                nextID += 1
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
}
