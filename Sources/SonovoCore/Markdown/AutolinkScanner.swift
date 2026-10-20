import Foundation

/// Finds GFM extended autolinks inside a plain text node.
///
/// `swift-markdown` attaches the table, strikethrough, and task-list GFM
/// extensions but not the autolink extension. This native pass supplies the
/// missing behavior. It runs on text nodes only, and the caller must not run it
/// inside a link or image label, where a nested link would be invalid.
enum AutolinkScanner {
    struct Match: Equatable {
        /// UTF-16 offsets into the text node.
        let range: Range<Int>
        let display: String
        let destination: String
    }

    /// A cheap UTF-8 gate: every autolink form contains `@`, `://`, or
    /// `www.` (case-insensitive). Ordinary prose skips the per-character
    /// scanner entirely.
    static func mightContainLink(_ text: String) -> Bool {
        if text.utf8.contains(0x40) { return true }
        if text.contains("://") { return true }

        return text.utf8.withContiguousStorageIfAvailable { buffer in
            var index = buffer.startIndex
            while index < buffer.endIndex {
                let byte = buffer[index]
                if byte == 0x77 || byte == 0x57 { // w / W
                    let distance = buffer.distance(from: index, to: buffer.endIndex)
                    if distance >= 4 {
                        let second = buffer[buffer.index(after: index)]
                        let thirdIndex = buffer.index(index, offsetBy: 2)
                        let fourthIndex = buffer.index(index, offsetBy: 3)
                        let third = buffer[thirdIndex]
                        let fourth = buffer[fourthIndex]
                        if (second | 0x20) == 0x77,
                           (third | 0x20) == 0x77,
                           fourth == 0x2E {
                            return true
                        }
                    }
                }
                index = buffer.index(after: index)
            }
            return false
        } ?? true
    }

    static func scan(_ text: String) -> [Match] {
        var matches: [Match] = []
        let characters = Array(text)
        var offsets = [Int](repeating: 0, count: characters.count + 1)
        for position in 0..<characters.count {
            offsets[position + 1] = offsets[position]
                + String(characters[position]).utf16.count
        }
        var index = 0

        while index < characters.count {
            let boundary = index == 0 || isBoundary(characters[index - 1])
            guard boundary else {
                index += 1
                continue
            }

            if let match = scanSchemeEmail(characters, offsets: offsets, from: index)
                ?? scanURL(characters, offsets: offsets, from: index)
                ?? scanWWW(characters, offsets: offsets, from: index)
                ?? scanEmail(characters, offsets: offsets, from: index) {
                matches.append(match)
                // `index` counts Characters; the match range counts UTF-16
                // code units. Advancing by the UTF-16 length skips extra
                // Characters after astral scalars.
                index += match.display.count
            } else if isEmailLocal(characters[index]) {
                // A failed email scan already walked this run. Skipping it
                // prevents a long underscore run before `@` from being
                // rescanned from every character. Only skip when the run
                // actually contains `@`; otherwise `_www.example.com` would
                // lose the `www.` autolink.
                var end = index
                var sawAt = false
                while end < characters.count,
                      isEmailLocal(characters[end])
                        || characters[end] == "@"
                        || isEmailDomain(characters[end]) {
                    if characters[end] == "@" { sawAt = true }
                    end += 1
                }
                if sawAt {
                    index = max(index + 1, end)
                } else {
                    // No `@` means no email here. Jump to the next position
                    // that could actually start an autolink; an `_h_h_h`
                    // run must not rescan the rest of the run at every `h`.
                    var next = end
                    var candidate = index + 1
                    while candidate < end {
                        if matchesASCII(
                            characters,
                            from: candidate,
                            wwwLiteral
                        ) || matchesASCII(
                            characters,
                            from: candidate,
                            httpLiteral
                        ) || matchesASCII(
                            characters,
                            from: candidate,
                            httpsLiteral
                        ) {
                            next = candidate
                            break
                        }
                        candidate += 1
                    }
                    index = next
                }
            } else {
                index += 1
            }
        }

        return matches
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character.isWhitespace
            || character == "*"
            || character == "_"
            || character == "~"
            || character == "("
            || character == "["
            || character == ":"
            || character == "/"
            || character == "\""
            || character == "'"
    }

    /// GFM's extension links `mailto:` and `xmpp:` prefixes as part of the
    /// autolink; other schemes are not included in the link.
    private static func scanSchemeEmail(
        _ characters: [Character],
        offsets: [Int],
        from start: Int
    ) -> Match? {
        for (prefix, literal) in [("mailto:", mailtoLiteral), ("xmpp:", xmppLiteral)] {
            guard start + prefix.count < characters.count else { continue }
            guard matchesASCII(characters, from: start, literal) else { continue }

            let emailStart = start + prefix.count
            guard let email = scanEmail(characters, offsets: offsets, from: emailStart) else {
                continue
            }
            let emailEnd = start + prefix.count + email.display.count
            guard emailEnd <= characters.count else { continue }

            if prefix == "xmpp:" {
                // xmpp behaves like a URL scheme: consume the path.
                var end = emailEnd
                while end < characters.count {
                    let character = characters[end]
                    if character.isWhitespace || character == "<" || character == ">" {
                        break
                    }
                    end += 1
                }
                let raw = String(characters[start..<end])
                let display = trimTrailingPunctuation(raw)
                guard display.count > prefix.count else { continue }
                return makeMatch(
                    offsets: offsets,
                    start: start,
                    length: display.count,
                    display: display,
                    destination: display
                )
            }

            let display = String(characters[start..<emailEnd])
            return makeMatch(
                offsets: offsets,
                start: start,
                length: emailEnd - start,
                display: display,
                destination: prefix + email.display
            )
        }
        return nil
    }

    private static let httpsLiteral: [UInt32] = Array("https://".unicodeScalars.map(\.value))
    private static let httpLiteral: [UInt32] = Array("http://".unicodeScalars.map(\.value))
    private static let wwwLiteral: [UInt32] = Array("www.".unicodeScalars.map(\.value))
    private static let mailtoLiteral: [UInt32] = Array("mailto:".unicodeScalars.map(\.value))
    private static let xmppLiteral: [UInt32] = Array("xmpp:".unicodeScalars.map(\.value))

    /// ASCII-only case-insensitive prefix test without allocating a String.
    private static func matchesASCII(
        _ characters: [Character],
        from start: Int,
        _ literal: [UInt32]
    ) -> Bool {
        guard start + literal.count <= characters.count else { return false }
        for offset in 0..<literal.count {
            guard let value = asciiValue(characters[start + offset]),
                  value == literal[offset] else {
                return false
            }
        }
        return true
    }

    private static func asciiValue(_ character: Character) -> UInt32? {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return nil }
        var value = scalar.value
        if value >= 65, value <= 90 { value += 32 }
        return value
    }

    private static func scanURL(_ characters: [Character], offsets: [Int], from start: Int) -> Match? {
        var schemeLength = 0
        var scheme: String?

        if matchesASCII(characters, from: start, httpsLiteral) {
            scheme = "https://"
            schemeLength = 8
        } else if matchesASCII(characters, from: start, httpLiteral) {
            scheme = "http://"
            schemeLength = 7
        }
        guard scheme != nil else { return nil }

        let bodyStart = start + schemeLength
        let end = runEnd(characters, from: bodyStart)
        guard end > bodyStart else { return nil }

        let raw = String(characters[start..<end])
        let trimmed = trimTrailingPunctuation(raw)
        guard trimmed.count > schemeLength + 1 else { return nil }
        guard let schemeRange = trimmed.range(of: "://") else {
            return nil
        }
        // Take the authority up to the first path/query/fragment delimiter.
        // Splitting and taking `.first` would drop an empty authority
        // (`https://?a` yields `a`), which must not become a link.
        let rest = trimmed[schemeRange.upperBound...]
        let authorityEnd = rest.firstIndex(where: { "/?#".contains($0) })
            ?? rest.endIndex
        let authority = String(rest[rest.startIndex..<authorityEnd])
        guard isValidAuthority(authority) else { return nil }

        return makeMatch(
            offsets: offsets,
            start: start,
            length: trimmed.count,
            display: trimmed,
            destination: trimmed
        )
    }

    private static func scanWWW(_ characters: [Character], offsets: [Int], from start: Int) -> Match? {
        let prefix = "www."
        guard start + prefix.count < characters.count else { return nil }
        guard matchesASCII(characters, from: start, wwwLiteral) else {
            return nil
        }

        let end = runEnd(characters, from: start + prefix.count)
        guard end > start + prefix.count else { return nil }

        let raw = String(characters[start..<end])
        let trimmed = trimTrailingPunctuation(raw)
        // The `www.` prefix is part of the hostname; `www.foo` has two labels.
        let hostEnd = trimmed.firstIndex(where: { "/?#".contains($0) })
            ?? trimmed.endIndex
        let host = String(trimmed[trimmed.startIndex..<hostEnd])
        guard isValidDomain(host) else { return nil }

        return makeMatch(
            offsets: offsets,
            start: start,
            length: trimmed.count,
            display: trimmed,
            destination: "http://" + trimmed
        )
    }

    private static func scanEmail(_ characters: [Character], offsets: [Int], from start: Int) -> Match? {
        var index = start
        while index < characters.count, isEmailLocal(characters[index]) {
            index += 1
        }
        guard index > start, index < characters.count, characters[index] == "@" else {
            return nil
        }

        let domainStart = index + 1
        index = domainStart
        while index < characters.count, isEmailDomain(characters[index]) {
            index += 1
        }
        guard index > domainStart else { return nil }

        let raw = String(characters[start..<index])
        let pieces = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        var domain = String(pieces[1])
        while domain.hasSuffix(".") { domain.removeLast() }
        guard domain.contains("."), !domain.hasPrefix(".") else {
            return nil
        }
        guard domain.split(
            separator: ".",
            omittingEmptySubsequences: false
        ).allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        // The final domain character must be a letter or number.
        guard let last = domain.last, last.isLetter || last.isNumber else {
            return nil
        }
        // A following underscore means the domain was cut short.
        if index < characters.count, characters[index] == "_" {
            return nil
        }

        // Strip trailing dots from the domain.
        var trimmed = raw
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }

        return makeMatch(
            offsets: offsets,
            start: start,
            length: trimmed.count,
            display: trimmed,
            destination: "mailto:" + trimmed
        )
    }

    private static func makeMatch(
        offsets: [Int],
        start: Int,
        length: Int,
        display: String,
        destination: String
    ) -> Match {
        let utf16Start = offsets[start]
        let utf16Length = offsets[start + length] - utf16Start
        return Match(
            range: utf16Start..<(utf16Start + utf16Length),
            display: display,
            destination: destination
        )
    }

    private static func runEnd(
        _ characters: [Character],
        from start: Int
    ) -> Int {
        var index = start
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace
                || character == "<"
                || character == ">"
                || character == "\""
                || character == "'" {
                break
            }
            index += 1
        }
        return index
    }

    private static func trimTrailingPunctuation(_ text: String) -> String {
        var result = text
        let punctuation: Set<Character> = ["?", "!", ".", ",", ":", "*", "_", "~", ";"]
        // Entity-like names are letters, digits, or a numeric prefix. Any
        // other character before a `;` proves it cannot complete an entity,
        // so no backward search is needed.
        // Count parentheses once. Recounting the whole string for each
        // trimmed `)` made a long run of unmatched closers quadratic.
        let openCount = result.reduce(0) { $0 + ($1 == "(" ? 1 : 0) }
        var closeCount = result.reduce(0) { $0 + ($1 == ")" ? 1 : 0) }
        let mayContainEntity = result.contains("&")
        var changed = true
        while changed {
            changed = false
            // Leave a `;` that completes an entity for the entity trimmer.
            while let last = result.last, punctuation.contains(last) {
                if last == ";", mayContainEntity {
                    let before = result.dropLast().last
                    let couldNameEntity = before?.isLetter == true
                        || before?.isNumber == true
                        || before == "#"
                    if couldNameEntity,
                       trailingEntityRange(result) != nil {
                        break
                    }
                }
                result.removeLast()
                changed = true
            }
            if mayContainEntity, trimTrailingEntity(&result) {
                changed = true
            }
            while result.hasSuffix(")"), openCount < closeCount {
                result.removeLast()
                closeCount -= 1
                changed = true
            }
        }
        return result
    }

    /// The range of a trailing entity-like suffix, if present.
    private static func trailingEntityRange(
        _ text: String
    ) -> Range<String.Index>? {
        guard text.hasSuffix(";"), let amp = text.lastIndex(of: "&") else {
            return nil
        }
        let nameStart = text.index(after: amp)
        let nameEnd = text.index(before: text.endIndex)
        guard nameStart < nameEnd else { return nil }
        let name = text[nameStart..<nameEnd]

        let valid: Bool
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            let digits = name.dropFirst(2)
            valid = !digits.isEmpty && digits.allSatisfy { $0.isHexDigit }
        } else if name.hasPrefix("#") {
            let digits = name.dropFirst()
            valid = !digits.isEmpty && digits.allSatisfy { $0.isNumber }
        } else {
            valid = name.first?.isLetter == true
                && name.count <= 32
                && name.allSatisfy { $0.isLetter || $0.isNumber }
        }
        return valid ? amp..<text.endIndex : nil
    }

    /// GFM excludes an entity-like suffix as a whole: `...&hl;` is not part
    /// of the link, while trimming only the `;` would link through `&hl`.
    private static func trimTrailingEntity(_ text: inout String) -> Bool {
        guard let range = trailingEntityRange(text) else { return false }
        text.removeSubrange(range)
        return true
    }

    /// GFM domain rule: at least two non-empty labels; underscores are not
    /// allowed in the last two labels.
    private static func isValidAuthority(_ authority: String) -> Bool {
        guard !authority.isEmpty else { return false }
        if authority.hasPrefix("[") {
            return authority.contains("]")
        }
        let host = authority.split(separator: ":", maxSplits: 1)
            .first.map(String.init) ?? ""
        guard !host.isEmpty else { return false }
        guard host.contains(".") else { return true } // localhost
        return isValidDomain(host)
    }

    private static func isValidDomain(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else {
            return false
        }
        for label in labels.suffix(2) where label.contains("_") {
            return false
        }
        for label in labels {
            guard label.allSatisfy({
                $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
                    || !$0.isASCII
            }) else {
                return false
            }
            guard label.contains(where: {
                $0.isLetter || $0.isNumber || !$0.isASCII
            }) else {
                return false
            }
        }
        return true
    }

    private static func isEmailLocal(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
            || character == "." || character == "_"
            || character == "+" || character == "-"
    }

    private static func isEmailDomain(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
            || character == "." || character == "-"
    }
}
