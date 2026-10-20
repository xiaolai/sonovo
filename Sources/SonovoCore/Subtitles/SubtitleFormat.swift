import Foundation

/// The subtitle container formats the editor reads and writes.
///
/// ASS and SSA share a parser family but keep distinct identities: SSA uses
/// the legacy `[V4 Styles]` section, ASS uses `[V4+ Styles]`, and the badge
/// and file extension must match the opened file.
public enum SubtitleFormat: String, Sendable, CaseIterable, Hashable {
    case srt
    case vtt
    case ass
    case ssa

    public var fileExtension: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .srt: "SubRip"
        case .vtt: "WebVTT"
        case .ass: "ASS"
        case .ssa: "SSA"
        }
    }

    /// ASS and SSA store centiseconds; SRT and VTT store milliseconds.
    public var timestampFractionDigits: Int {
        switch self {
        case .srt, .vtt: 3
        case .ass, .ssa: 2
        }
    }

    public var usesCommaDecimal: Bool {
        self == .srt
    }

    public var isASSFamily: Bool {
        self == .ass || self == .ssa
    }

    /// Content wins over the extension: an agentic tool may write a `.txt`
    /// or a misnamed file, and the bytes are the authority.
    public static func detect(url: URL?, source: String) -> SubtitleFormat? {
        let ns = source as NSString
        let firstLine = firstNonEmptyLine(in: ns)
        let upper = firstLine.uppercased()

        if upper.hasPrefix("WEBVTT") {
            return .vtt
        }

        let upperSource = ns.length <= 512_000
            ? source.uppercased()
            : ns.substring(to: min(ns.length, 512_000)).uppercased()
        if upperSource.contains("[SCRIPT INFO]")
            || upperSource.contains("[EVENTS]") {
            if upperSource.contains("[V4 STYLES]"),
               !upperSource.contains("[V4+ STYLES]") {
                return .ssa
            }
            return .ass
        }

        if hasSRTTimingLine(in: ns) {
            return .srt
        }

        if let extensionName = url?.pathExtension.lowercased() {
            switch extensionName {
            case "srt": return .srt
            case "vtt": return .vtt
            case "ass": return .ass
            case "ssa": return .ssa
            default: break
            }
        }
        return nil
    }

    public static func format(forExtension extensionName: String) -> SubtitleFormat? {
        switch extensionName.lowercased() {
        case "srt": .srt
        case "vtt": .vtt
        case "ass": .ass
        case "ssa": .ssa
        default: nil
        }
    }

    private static func firstNonEmptyLine(in ns: NSString) -> String {
        var index = 0
        while index < ns.length {
            let lineRange = ns.lineRange(
                for: NSRange(location: index, length: 0)
            )
            var line = ns.substring(with: lineRange)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { return line }
            index = NSMaxRange(lineRange)
        }
        return ""
    }

    private static func hasSRTTimingLine(in ns: NSString) -> Bool {
        var index = 0
        var inspected = 0
        while index < ns.length, inspected < 200 {
            let lineRange = ns.lineRange(
                for: NSRange(location: index, length: 0)
            )
            let line = ns.substring(with: lineRange)
            if line.contains("-->"),
               line.contains(",") || line.contains(".") {
                return true
            }
            index = NSMaxRange(lineRange)
            inspected += 1
        }
        return false
    }
}
