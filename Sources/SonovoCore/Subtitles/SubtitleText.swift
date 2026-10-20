import Foundation

/// Converts stored cue text into the plain text shown in the preview.
///
/// The file keeps its markup; only the reading projection is sanitized.
public enum SubtitleText {
    public static func plainText(
        _ raw: String,
        format: SubtitleFormat
    ) -> String {
        switch format {
        case .ass, .ssa:
            return assPlainText(raw)
        case .srt, .vtt:
            return markupPlainText(raw)
        }
    }

    public static func plainText(
        for cues: [SubtitleCue],
        format: SubtitleFormat
    ) -> String {
        cues.map { plainText($0.rawText, format: format) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func assPlainText(_ raw: String) -> String {
        var text = raw
        // Override blocks, including drawing commands, are not readable text.
        while let start = text.firstIndex(of: "{"),
              let end = text[start...].firstIndex(of: "}") {
            text.removeSubrange(start...end)
        }
        text = text
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
        return cleanup(text)
    }

    private static func markupPlainText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(
            of: "<[^>]*>",
            with: "",
            options: .regularExpression
        )
        text = decodeEntities(text)
        return cleanup(text)
    }

    private static func cleanup(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "&",
                  let semicolon = text[index...].firstIndex(of: ";"),
                  text.distance(from: index, to: semicolon) <= 12 else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }

            let entity = String(text[text.index(after: index)..<semicolon])
            if let decoded = decodeEntity(entity) {
                result.append(decoded)
                index = text.index(after: semicolon)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func decodeEntity(_ entity: String) -> String? {
        switch entity.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default: break
        }

        let value: UInt32?
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            value = UInt32(entity.dropFirst(2), radix: 16)
        } else if entity.hasPrefix("#") {
            value = UInt32(entity.dropFirst(), radix: 10)
        } else {
            value = nil
        }
        guard let value, let scalar = Unicode.Scalar(value) else {
            return nil
        }
        return String(Character(scalar))
    }
}
