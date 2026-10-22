import Foundation

/// One LF-terminated line of canonical subtitle source, in UTF-16 offsets.
struct SubtitleLine: Equatable {
    let content: Range<Int>
    let full: Range<Int>
}

enum SubtitleLineIndex {
    static func lines(in ns: NSString) -> [SubtitleLine] {
        var result: [SubtitleLine] = []
        var index = 0
        while index < ns.length {
            let newline = ns.range(
                of: "\n",
                options: [],
                range: NSRange(location: index, length: ns.length - index)
            )
            let contentEnd = newline.location == NSNotFound
                ? ns.length
                : newline.location
            let fullEnd = newline.location == NSNotFound
                ? ns.length
                : newline.location + 1
            result.append(
                SubtitleLine(
                    content: index..<contentEnd,
                    full: index..<fullEnd
                )
            )
            index = fullEnd
        }
        return result
    }

    static func text(_ line: SubtitleLine, in ns: NSString) -> String {
        ns.substring(with: NSRange(
            location: line.content.lowerBound,
            length: line.content.count
        ))
    }

    static func trimmed(_ line: SubtitleLine, in ns: NSString) -> String {
        text(line, in: ns).trimmingCharacters(in: .whitespaces)
    }

    static func isBlank(_ line: SubtitleLine, in ns: NSString) -> Bool {
        trimmed(line, in: ns).isEmpty
    }

    /// The non-whitespace part of an arbitrary UTF-16 range.
    static func trimmedRange(
        _ range: Range<Int>,
        in ns: NSString
    ) -> Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper,
              ns.character(at: lower) == 0x20
                || ns.character(at: lower) == 0x09 {
            lower += 1
        }
        while upper > lower,
              ns.character(at: upper - 1) == 0x20
                || ns.character(at: upper - 1) == 0x09 {
            upper -= 1
        }
        return lower..<upper
    }
}

struct SubtitleDiagnosticBuilder {
    private(set) var diagnostics: [SubtitleDiagnostic] = []
    private var nextID = 0
    private var limitReached = false

    mutating func add(
        _ severity: SubtitleDiagnostic.Severity,
        _ kind: SubtitleDiagnostic.Kind,
        _ message: String,
        cueOrdinal: Int? = nil,
        range: Range<Int>? = nil
    ) {
        guard diagnostics.count < SubtitleLimits.maxDiagnostics else {
            if !limitReached {
                limitReached = true
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
