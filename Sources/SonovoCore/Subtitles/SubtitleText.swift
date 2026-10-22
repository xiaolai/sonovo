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
        // Override blocks are markup. Drawing mode (`\p1`) also makes the
        // text between overrides a vector command, not readable words.
        var text = ""
        var index = raw.startIndex
        var drawing = 0
        while index < raw.endIndex {
            if raw[index] == "{" {
                if let end = raw[index...].firstIndex(of: "}") {
                    let block = raw[raw.index(after: index)..<end]
                    if let mode = drawingMode(in: block) {
                        drawing = mode
                    }
                    index = raw.index(after: end)
                    continue
                }
            }
            if drawing == 0 {
                text.append(raw[index])
            }
            index = raw.index(after: index)
        }
        text = text
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
        return cleanup(text)
    }

    /// The last `\pN` tag in an override block, or nil when the block does
    /// not change drawing mode.
    private static func drawingMode(
        in block: Substring
    ) -> Int? {
        var mode: Int?
        var index = block.startIndex
        while index < block.endIndex {
            guard block[index] == "\\" else {
                index = block.index(after: index)
                continue
            }
            let tag = block.index(after: index)
            guard tag < block.endIndex, block[tag] == "p" else {
                index = tag
                continue
            }
            var probe = block.index(after: tag)
            var digits = ""
            while probe < block.endIndex, block[probe].isNumber {
                digits.append(block[probe])
                probe = block.index(after: probe)
            }
            // `\pos(...)` starts with `\p` but is a position tag, not a
            // drawing-mode switch. Only a numeric `\pN` changes mode.
            if !digits.isEmpty, let parsed = Int(digits) {
                mode = parsed
            }
            index = probe
        }
        return mode
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
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(text.count)
        var index = 0

        while index < characters.count {
            guard characters[index] == "&" else {
                result.append(characters[index])
                index += 1
                continue
            }
            // Bound the semicolon search. Searching the whole remainder for
            // every `&` without a semicolon was quadratic on long cues.
            let limit = min(index + 13, characters.count)
            var semicolon: Int?
            var probe = index + 1
            while probe < limit {
                if characters[probe] == ";" {
                    semicolon = probe
                    break
                }
                probe += 1
            }
            guard let semicolon else {
                result.append("&")
                index += 1
                continue
            }

            let entity = String(characters[(index + 1)..<semicolon])
            if let decoded = decodeEntity(entity) {
                result.append(decoded)
                index = semicolon + 1
            } else {
                result.append("&")
                index += 1
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
