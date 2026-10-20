import Foundation

/// One subtitle cue projected from the canonical source.
///
/// All ranges are UTF-16 offsets into the document's canonical (LF-only)
/// text. They are the contract between the parser and the range-based editor:
/// an edit replaces a range and leaves every other byte alone.
public struct SubtitleCue: Identifiable, Hashable, Sendable {
    public var id: Int { ordinal }

    public let ordinal: Int
    public let startMilliseconds: Int
    public let endMilliseconds: Int

    /// The exact text stored in the file, without a trailing newline.
    public let rawText: String
    /// The exact timing text, used for diagnostics and display.
    public let rawTiming: String

    /// The whole cue without its trailing separator.
    public let blockRange: Range<Int>
    /// The text content, excluding the timing line and any SRT coordinate
    /// line. For an empty cue this is a zero-length range where text would
    /// be inserted.
    public let textRange: Range<Int>
    /// The start timestamp token or ASS field value.
    public let startRange: Range<Int>?
    /// The end timestamp token or ASS field value.
    public let endRange: Range<Int>?
    /// The SRT/VTT timing line, or the ASS Dialogue line (without newline).
    public let timingLineRange: Range<Int>?
    /// The SRT/VTT blank-line run after the cue, or the ASS line's newline.
    public let separatorRangeAfter: Range<Int>?

    /// SRT numeric index, VTT cue identifier, or nil.
    public let identifier: String?
    /// VTT cue settings or SRT trailing coordinate text.
    public let settings: String?
    /// SRT X1/Y1 coordinate line when present.
    public let coordinateLine: String?
    /// ASS Style field.
    public let style: String?

    public var durationMilliseconds: Int {
        max(0, endMilliseconds - startMilliseconds)
    }

    public var hasValidTiming: Bool {
        startMilliseconds >= 0 && endMilliseconds > startMilliseconds
    }

    public init(
        ordinal: Int,
        startMilliseconds: Int,
        endMilliseconds: Int,
        rawText: String,
        rawTiming: String,
        blockRange: Range<Int>,
        textRange: Range<Int>,
        startRange: Range<Int>?,
        endRange: Range<Int>?,
        timingLineRange: Range<Int>?,
        separatorRangeAfter: Range<Int>?,
        identifier: String?,
        settings: String?,
        coordinateLine: String?,
        style: String?
    ) {
        self.ordinal = ordinal
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.rawText = rawText
        self.rawTiming = rawTiming
        self.blockRange = blockRange
        self.textRange = textRange
        self.startRange = startRange
        self.endRange = endRange
        self.timingLineRange = timingLineRange
        self.separatorRangeAfter = separatorRangeAfter
        self.identifier = identifier
        self.settings = settings
        self.coordinateLine = coordinateLine
        self.style = style
    }
}

/// A source block that looks structural but could not be parsed. It is
/// preserved verbatim and shown to the user instead of being dropped.
public struct SubtitleUnparsedBlock: Hashable, Sendable {
    public let range: Range<Int>
    public let text: String
    public let reason: String

    public init(range: Range<Int>, text: String, reason: String) {
        self.range = range
        self.text = text
        self.reason = reason
    }
}

public struct SubtitleDiagnostic: Identifiable, Hashable, Sendable {
    public enum Severity: String, Hashable, Sendable {
        case warning
        case error
    }

    public enum Kind: Hashable, Sendable {
        case malformedBlock(reason: String)
        case malformedTimestamp(String)
        case negativeTimestamp
        case endNotAfterStart
        case emptyText
        case overlappingCue(previousOrdinal: Int)
        case duplicateIndex(String)
        case missingFormatLine
        case unsupportedTimestampStyle(String)
        case cueLimitReached
        case diagnosticsLimitReached
    }

    public let id: Int
    public let severity: Severity
    public let kind: Kind
    public let message: String
    public let cueOrdinal: Int?
    public let range: Range<Int>?

    public init(
        id: Int,
        severity: Severity,
        kind: Kind,
        message: String,
        cueOrdinal: Int? = nil,
        range: Range<Int>? = nil
    ) {
        self.id = id
        self.severity = severity
        self.kind = kind
        self.message = message
        self.cueOrdinal = cueOrdinal
        self.range = range
    }
}

/// The timestamp spelling the file uses, so diagnostics can name a
/// non-canonical separator without rewriting the file.
public struct SubtitleTimestampStyle: Hashable, Sendable {
    public let decimalSeparator: Character
    public let fractionDigits: Int
    public let includesHours: Bool

    public init(
        decimalSeparator: Character,
        fractionDigits: Int,
        includesHours: Bool
    ) {
        self.decimalSeparator = decimalSeparator
        self.fractionDigits = fractionDigits
        self.includesHours = includesHours
    }
}

/// ASS/SSA event layout captured from the `[Events]` section.
public struct ASSInfo: Hashable, Sendable {
    public let formatFields: [String]
    public let eventsSectionRange: Range<Int>?
    public let defaultStyle: String?
    public let dialoguePrefix: String

    public init(
        formatFields: [String],
        eventsSectionRange: Range<Int>?,
        defaultStyle: String?,
        dialoguePrefix: String
    ) {
        self.formatFields = formatFields
        self.eventsSectionRange = eventsSectionRange
        self.defaultStyle = defaultStyle
        self.dialoguePrefix = dialoguePrefix
    }

    public func fieldIndex(_ name: String) -> Int? {
        formatFields.firstIndex(of: name.lowercased())
    }
}

/// A parsed projection of one source revision.
public struct SubtitleParseResult: Equatable, Sendable {
    public let format: SubtitleFormat
    public let cues: [SubtitleCue]
    public let diagnostics: [SubtitleDiagnostic]
    public let unparsedBlocks: [SubtitleUnparsedBlock]
    public let timeline: SubtitleTimeline
    public let hasCueIndexes: Bool
    public let assInfo: ASSInfo?
    public let timestampStyle: SubtitleTimestampStyle

    public init(
        format: SubtitleFormat,
        cues: [SubtitleCue],
        diagnostics: [SubtitleDiagnostic],
        unparsedBlocks: [SubtitleUnparsedBlock],
        timeline: SubtitleTimeline,
        hasCueIndexes: Bool,
        assInfo: ASSInfo?,
        timestampStyle: SubtitleTimestampStyle
    ) {
        self.format = format
        self.cues = cues
        self.diagnostics = diagnostics
        self.unparsedBlocks = unparsedBlocks
        self.timeline = timeline
        self.hasCueIndexes = hasCueIndexes
        self.assInfo = assInfo
        self.timestampStyle = timestampStyle
    }

    public var errorCount: Int {
        diagnostics.count { $0.severity == .error }
    }

    public var warningCount: Int {
        diagnostics.count { $0.severity == .warning }
    }

    public func cue(ordinal: Int) -> SubtitleCue? {
        cues.first { $0.ordinal == ordinal }
    }

    public func diagnostics(forCueOrdinal ordinal: Int) -> [SubtitleDiagnostic] {
        diagnostics.filter { $0.cueOrdinal == ordinal }
    }
}

/// An index over valid cues for active-cue lookup during playback.
///
/// Entries are sorted by start time. Lookup walks backward only as far as the
/// longest cue, so a 30 Hz playhead does not rescan the whole file.
public struct SubtitleTimeline: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        let start: Int
        let end: Int
        let ordinal: Int
    }

    private let entries: [Entry]
    private let maximumDuration: Int
    public let durationMilliseconds: Int

    public static let empty = SubtitleTimeline(cues: [])

    public init(cues: [SubtitleCue]) {
        let valid = cues.filter {
            $0.startMilliseconds >= 0
                && $0.endMilliseconds > $0.startMilliseconds
        }
        entries = valid.map {
            Entry(
                start: $0.startMilliseconds,
                end: $0.endMilliseconds,
                ordinal: $0.ordinal
            )
        }.sorted {
            if $0.start == $1.start { return $0.ordinal < $1.ordinal }
            return $0.start < $1.start
        }
        maximumDuration = valid.map {
            $0.endMilliseconds - $0.startMilliseconds
        }.max() ?? 0
        durationMilliseconds = valid.map(\.endMilliseconds).max() ?? 0
    }

    public func activeOrdinals(atMilliseconds time: Int) -> [Int] {
        guard !entries.isEmpty, time >= 0 else { return [] }

        // Last entry whose start is at or before `time`.
        var low = 0
        var high = entries.count - 1
        var last = -1
        while low <= high {
            let middle = (low + high) / 2
            if entries[middle].start <= time {
                last = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard last >= 0 else { return [] }

        let earliest = time - maximumDuration
        var active: [Entry] = []
        var index = last
        while index >= 0, entries[index].start >= earliest {
            let entry = entries[index]
            if entry.end > time, entry.start <= time {
                active.append(entry)
            }
            index -= 1
        }
        return active
            .sorted {
                if $0.start == $1.start { return $0.ordinal < $1.ordinal }
                return $0.start < $1.start
            }
            .map(\.ordinal)
    }
}
