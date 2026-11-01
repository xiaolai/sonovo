import Foundation

package enum MarkdownWordCount {
    package static func count(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                inWord = false
            } else if Self.isCJK(scalar) {
                count += 1
                inWord = false
            } else if !inWord {
                count += 1
                inWord = true
            }
        }
        return count
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana and Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0x20000...0x2FA1F: // CJK Extension B and later
            return true
        default:
            return false
        }
    }

}
