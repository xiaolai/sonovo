import Foundation

/// Serializes a decoded link destination so the Markdown reparses to the same
/// value.
///
/// The popover, the reference-definition serializer, and the paste converter
/// all edit decoded values; writing them back verbatim let a decoded
/// `foo&copy;` reparse as `foo©` and a decoded backslash escape the next
/// character. One implementation keeps the three writers in step.
enum MarkdownDestination {
    /// The inline storage form: a bare destination when it needs no
    /// protection, otherwise the angle-bracket form.
    ///
    /// Ampersands and backslashes are always escaped, because both forms
    /// process them. A space or a parenthesis forces the angle form; a
    /// control character, which neither form may contain, becomes a percent
    /// escape.
    static func escaped(_ destination: String) -> String {
        if destination.isEmpty { return "" }
        let encoded = encoded(destination)
        let needsAngle = destination.contains(where: {
            $0.isWhitespace || $0 == "(" || $0 == ")"
                || $0 == "<" || $0 == ">"
        })
        guard needsAngle else {
            return encoded.bare
        }
        return "<\(encoded.angle)>"
    }

    /// The two forms of one value. The bare form leaves spaces as-is (they
    /// are the caller's cue to use the angle form); the angle form encodes
    /// everything the angle syntax forbids.
    private static func encoded(
        _ value: String
    ) -> (bare: String, angle: String) {
        var bare = ""
        var angleBody = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                bare += "\\\\"
                angleBody += "\\\\"
            case "&":
                bare += "&amp;"
                angleBody += "&amp;"
            case "<":
                bare += "\\<"
                angleBody += "%3C"
            case ">":
                bare += "\\>"
                angleBody += "%3E"
            case "\n":
                bare += "\n"
                angleBody += "%0A"
            case "\r":
                bare += "\r"
                angleBody += "%0D"
            case "\t":
                bare += "\t"
                angleBody += "%09"
            case " ":
                bare += " "
                angleBody += " "
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    let escape = String(format: "%%%02X", scalar.value)
                    bare += escape
                    angleBody += escape
                } else {
                    let character = Character(scalar)
                    bare.append(character)
                    angleBody.append(character)
                }
            }
        }
        return (bare, angleBody)
    }
}
