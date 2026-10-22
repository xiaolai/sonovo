import Foundation

/// The format-specific output before the dispatcher adds cross-format
/// diagnostics and builds the timeline.
struct SubtitleParseParts {
    var cues: [SubtitleCue] = []
    var diagnostics: [SubtitleDiagnostic] = []
    var unparsedBlocks: [SubtitleUnparsedBlock] = []
    var assInfo: ASSInfo?
    var hasCueIndexes = false
    /// The format parser stopped collecting at the cue limit.
    var truncated = false
    var timestampStyle = SubtitleTimestampStyle(
        decimalSeparator: ".",
        fractionDigits: 3,
        includesHours: true
    )
}

/// Records a block that looked structural but could not be parsed. The raw
/// text is retained for the "unparsed block" UI; the diagnostic is an error.
func recordSubtitleUnparsed(
    range: Range<Int>,
    reason: String,
    ns: NSString,
    parts: inout SubtitleParseParts,
    builder: inout SubtitleDiagnosticBuilder
) {
    guard range.lowerBound < ns.length else { return }
    let text = ns.substring(with: NSRange(
        location: range.lowerBound,
        length: range.count
    ))
    if parts.unparsedBlocks.count < SubtitleLimits.maxUnparsedBlocks {
        parts.unparsedBlocks.append(
            SubtitleUnparsedBlock(range: range, text: text, reason: reason)
        )
    }
    builder.add(
        .error,
        .malformedBlock(reason: reason),
        reason,
        range: range
    )
}
