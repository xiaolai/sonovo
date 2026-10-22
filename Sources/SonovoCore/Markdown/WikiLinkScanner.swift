import Foundation

/// A wiki link found in the raw source.
struct WikiLinkMatch: Equatable {
    /// Global UTF-16 range covering `[[...]]`.
    let range: Range<Int>
    let target: String
    let fragment: String?
    let alias: String?
}

/// Finds `[[target]]` and `[[target|alias]]` in a raw source span.
///
/// The scanner runs over raw source, not decoded text nodes: `[[Page|*alias*]]`
/// stays one span even when CommonMark splits the alias into emphasis, and
/// `&#91;&#91;` cannot manufacture an opener. Ranges that sit inside an
/// excluded node (code, link, image, raw HTML) are rejected by the caller.
enum WikiLinkScanner {
    static func scan(
        source: String,
        span: SourceRange,
        excluding excluded: [SourceRange]
    ) -> [WikiLinkMatch] {
        let ns = source as NSString
        let spanRange = NSRange(location: span.lowerBound, length: span.length)
        guard spanRange.location >= 0, spanRange.length >= 0,
              spanRange.location + spanRange.length <= ns.length else {
            return []
        }

        var matches: [WikiLinkMatch] = []
        var searchLocation = spanRange.location
        let spanEnd = spanRange.location + spanRange.length
        let orderedExcluded = excluded.sorted {
            $0.lowerBound < $1.lowerBound
        }
        var exclusionIndex = 0

        // Cache the current line's limit. Searching for the newline from
        // every opener rescanned overlapping suffixes and was quadratic on a
        // long line containing many openers.
        var cachedLineStart = -1
        var cachedLineEnd = -1
        var cachedClosers: [Int] = []
        func lineLimit(from location: Int) -> Int {
            if location >= cachedLineStart, location <= cachedLineEnd {
                return cachedLineEnd
            }
            let newline = ns.range(
                of: "\n",
                options: [],
                range: NSRange(location: location, length: spanEnd - location)
            )
            let limit = newline.location == NSNotFound
                ? spanEnd
                : min(newline.location, spanEnd)
            cachedLineStart = location
            cachedLineEnd = limit

            // Find every closer on this line once. Searching from each
            // opener made a line with many unmatched openers quadratic.
            cachedClosers.removeAll(keepingCapacity: true)
            var search = location
            while search < limit {
                let found = ns.range(
                    of: "]]",
                    options: [],
                    range: NSRange(location: search, length: limit - search)
                )
                if found.location == NSNotFound { break }
                cachedClosers.append(found.location)
                search = found.location + 2
            }
            return limit
        }

        func firstCloser(atOrAfter location: Int, before limit: Int) -> Int? {
            var low = 0
            var high = cachedClosers.count
            while low < high {
                let middle = (low + high) / 2
                if cachedClosers[middle] < location {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            guard low < cachedClosers.count else { return nil }
            let candidate = cachedClosers[low]
            return candidate < limit ? candidate : nil
        }

        while searchLocation < spanEnd {
            let remaining = NSRange(
                location: searchLocation,
                length: spanEnd - searchLocation
            )
            let opener = ns.range(of: "[[", options: [], range: remaining)
            if opener.location == NSNotFound { break }
            let open = opener.location

            // `![[...]]` is an embed, not a wiki link.
            if open > 0, ns.character(at: open - 1) == 0x21 {
                searchLocation = open + 2
                continue
            }

            // An odd number of backslashes escapes the opener.
            var backslashes = 0
            var probe = open - 1
            while probe >= 0, ns.character(at: probe) == 0x5C {
                backslashes += 1
                probe -= 1
            }
            if backslashes % 2 == 1 {
                searchLocation = open + 2
                continue
            }

            // An opener inside excluded code must not consume a later valid
            // link by pairing with its closer.
            while exclusionIndex < orderedExcluded.count,
                  orderedExcluded[exclusionIndex].upperBound <= open {
                exclusionIndex += 1
            }
            if exclusionIndex < orderedExcluded.count,
               orderedExcluded[exclusionIndex].contains(offset: open) {
                searchLocation = open + 2
                continue
            }

            let contentStart = open + 2
            let contentLimit = lineLimit(from: contentStart)

            guard let closer = firstCloser(
                atOrAfter: contentStart,
                before: contentLimit
            ) else {
                searchLocation = contentStart
                continue
            }

            let range = open..<(closer + 2)
            let resolved = SourceRange(
                start: position(range.lowerBound),
                end: position(range.upperBound)
            )
            while exclusionIndex < orderedExcluded.count,
                  orderedExcluded[exclusionIndex].upperBound <= resolved.lowerBound {
                exclusionIndex += 1
            }
            if exclusionIndex < orderedExcluded.count,
               orderedExcluded[exclusionIndex].lowerBound < resolved.upperBound {
                searchLocation = range.upperBound
                continue
            }

            let content = ns.substring(
                with: NSRange(location: contentStart, length: closer - contentStart)
            )

            let pieces = content.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let targetRaw = pieces[0].trimmingCharacters(in: .whitespaces)
            let aliasRaw = pieces.count > 1
                ? pieces[1].trimmingCharacters(in: .whitespaces)
                : nil

            if !targetRaw.isEmpty || targetRaw.contains("#") {
                let targetPieces = targetRaw.split(
                    separator: "#",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                let path = targetPieces[0].trimmingCharacters(in: .whitespaces)
                let fragment = targetPieces.count > 1
                    ? targetPieces[1].trimmingCharacters(in: .whitespaces)
                    : nil
                if !path.isEmpty || (fragment?.isEmpty == false) {
                    matches.append(
                        WikiLinkMatch(
                            range: range,
                            target: path,
                            fragment: fragment,
                            alias: (aliasRaw?.isEmpty ?? true) ? nil : aliasRaw
                        )
                    )
                }
            }

            searchLocation = range.upperBound
        }

        return matches
    }

    private static func position(_ offset: Int) -> SourcePosition {
        // Only the offset participates in exclusion tests; line and column
        // are filled by the caller's map when the match is built.
        SourcePosition(line: 1, column: 0, offset: offset)
    }
}
