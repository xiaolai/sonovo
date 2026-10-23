import Foundation

/// Timestamp parsing and formatting for subtitle formats.
///
/// Times are stored as integer milliseconds. SRT and VTT carry milliseconds;
/// ASS/SSA carry centiseconds, so a value that is not a multiple of 10 ms is
/// rounded when written in those formats. Parsing accepts one to three
/// fraction digits and never uses floating-point arithmetic.
public enum SubtitleTimecode {
    /// 99:59:59.999, wide enough for any real subtitle file and small enough
    /// that adding a cue duration cannot overflow.
    public static let maximumMilliseconds = 359_999_999

    public static func parse(
        _ raw: String,
        format: SubtitleFormat
    ) -> Int? {
        // Accept either decimal separator; the parser records a diagnostic
        // when the file uses the non-canonical one.
        parse(
            raw,
            allowsHourless: format == .vtt || format == .srt,
            decimalSeparator: nil
        )
    }

    /// Parses a user-entered timestamp. Both `.` and `,` are accepted, hours
    /// are optional, and plain seconds (`12.5`) are accepted for convenience.
    public static func parseUserInput(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(":") {
            return parse(
                trimmed,
                allowsHourless: true,
                decimalSeparator: nil
            )
        }
        return parseSeconds(trimmed)
    }

    /// Parses `H:MM:SS.cc`, `HH:MM:SS,mmm`, `MM:SS.mmm`, or `SS.mmm`.
    /// `decimalSeparator` nil accepts either `.` or `,`.
    public static func parse(
        _ raw: String,
        allowsHourless: Bool,
        decimalSeparator: Character?
    ) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 || parts.count == 3 else { return nil }
        if parts.count == 2, !allowsHourless { return nil }

        var hours = 0
        var minuteIndex = 0
        if parts.count == 3 {
            guard let parsedHours = parseNonNegativeInteger(parts[0]) else {
                return nil
            }
            hours = parsedHours
            minuteIndex = 1
        }
        guard let minutes = parseNonNegativeInteger(parts[minuteIndex]),
              let secondsAndFraction = parseSeconds(
                  String(parts[minuteIndex + 1]),
                  decimalSeparator: decimalSeparator
              ) else {
            return nil
        }
        guard minutes < 60 else { return nil }
        let seconds = secondsAndFraction / 1000
        guard seconds < 60 else { return nil }
        // Bound the hour count before multiplying, so a malformed timestamp
        // cannot trap on integer overflow.
        guard hours <= maximumMilliseconds / 3_600_000 else { return nil }

        let total = (hours * 3600 + minutes * 60 + seconds) * 1000
            + secondsAndFraction % 1000
        guard total <= maximumMilliseconds else { return nil }
        return total
    }

    /// A whole-seconds portion with up to three fraction digits.
    private static func parseSeconds(
        _ raw: String,
        decimalSeparator: Character? = nil
    ) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let separator: Character
        if let decimalSeparator {
            guard trimmed.contains(decimalSeparator) else {
                return parseWholeSeconds(trimmed)
            }
            separator = decimalSeparator
        } else if trimmed.contains(".") {
            separator = "."
        } else if trimmed.contains(",") {
            separator = ","
        } else {
            return parseWholeSeconds(trimmed)
        }

        let pieces = trimmed.split(
            separator: separator,
            omittingEmptySubsequences: false
        )
        guard pieces.count == 2,
              let seconds = parseNonNegativeInteger(pieces[0]),
              !pieces[1].isEmpty,
              pieces[1].count <= 3,
              pieces[1].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let parsedFraction = Int(pieces[1]) else {
            return nil
        }
        // Bound before multiplying; a long digit string is not a timestamp.
        guard seconds <= maximumMilliseconds / 1000 else { return nil }
        var fraction = parsedFraction
        switch pieces[1].count {
        case 1: fraction *= 100
        case 2: fraction *= 10
        default: break
        }
        let total = seconds * 1000 + fraction
        guard total <= maximumMilliseconds else { return nil }
        return total
    }

    /// Whole seconds as milliseconds, bounded before multiplication.
    private static func parseWholeSeconds<T: StringProtocol>(
        _ raw: T
    ) -> Int? {
        guard let seconds = parseNonNegativeInteger(raw),
              seconds <= maximumMilliseconds / 1000 else {
            return nil
        }
        return seconds * 1000
    }

    private static func parseNonNegativeInteger<T: StringProtocol>(
        _ raw: T
    ) -> Int? {
        guard !raw.isEmpty,
              raw.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        return Int(raw)
    }

    /// Formats a stored timestamp in the document's own syntax.
    public static func format(
        milliseconds: Int,
        format: SubtitleFormat
    ) -> String {
        let clamped = max(0, min(milliseconds, maximumMilliseconds))
        let totalSeconds = clamped / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds / 60) % 60
        let seconds = totalSeconds % 60

        switch format {
        case .srt:
            return String(
                format: "%02d:%02d:%02d,%03d",
                hours, minutes, seconds, clamped % 1000
            )
        case .vtt:
            return String(
                format: "%02d:%02d:%02d.%03d",
                hours, minutes, seconds, clamped % 1000
            )
        case .ass, .ssa:
            // ASS carries centiseconds; round the whole value so 1.999 s
            // becomes 2.00 rather than 1.99.
            let rounded = min(
                maximumMilliseconds,
                ((clamped + 5) / 10) * 10
            )
            let roundedSeconds = rounded / 1000
            return String(
                format: "%d:%02d:%02d.%02d",
                roundedSeconds / 3600,
                (roundedSeconds / 60) % 60,
                roundedSeconds % 60,
                (rounded % 1000) / 10
            )
        }
    }

    /// `HH:MM:SS.mmm` for metadata and cue ranges.
    public static func display(_ milliseconds: Int) -> String {
        let clamped = max(0, milliseconds)
        let totalSeconds = clamped / 1000
        return String(
            format: "%02d:%02d:%02d.%03d",
            totalSeconds / 3600,
            (totalSeconds / 60) % 60,
            totalSeconds % 60,
            clamped % 1000
        )
    }

    /// `MM:SS.mmm` for the preview transport.
    public static func displayShort(_ milliseconds: Int) -> String {
        let clamped = max(0, milliseconds)
        let totalSeconds = clamped / 1000
        return String(
            format: "%02d:%02d.%03d",
            totalSeconds / 60,
            totalSeconds % 60,
            clamped % 1000
        )
    }

    public static func display(seconds: TimeInterval) -> String {
        // A media player can report NaN or an infinite duration; converting
        // that to `Int` traps. `milliseconds` saturates instead.
        displayShort(NumericConversion.milliseconds(seconds))
    }
}
