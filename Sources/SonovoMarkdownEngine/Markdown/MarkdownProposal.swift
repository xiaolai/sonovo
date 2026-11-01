import Foundation

/// One hunk of a unified diff, in the shape the proposal applier needs.
///
/// Old and new line numbers are 1-based as written in the file; `oldIndex` is
/// the 0-based splice position in the source line array.
public struct ProposalHunk: Equatable, Sendable, Identifiable {
    /// 1-based position in the proposal file, used for messages.
    public let id: Int
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// The text after the closing `@@`, such as a function name.
    public let section: String
    public let oldLines: [String]
    public let newLines: [String]
    /// False when the diff marks "No newline at end of file".
    public let oldLastHasNewline: Bool
    public let newLastHasNewline: Bool

    public var oldIndex: Int {
        oldCount == 0 ? oldStart : oldStart - 1
    }

    public var newIndex: Int {
        newCount == 0 ? newStart : newStart - 1
    }

    /// Lines for a diff view: unchanged edges as context, the changed middle
    /// as its removed lines followed by its added lines. This is a display
    /// projection, not the authored byte order; applying uses the old and new
    /// line arrays, which are exact.
    public var displayLines: [ProposalLine] {
        var prefix = 0
        while prefix < oldLines.count,
              prefix < newLines.count,
              oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix,
              suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix]
                == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }
        let oldMiddle = oldLines[prefix..<(oldLines.count - suffix)]
        let newMiddle = newLines[prefix..<(newLines.count - suffix)]
        var lines = oldLines[..<prefix].map(ProposalLine.context)
            + oldMiddle.map(ProposalLine.removed)
            + newMiddle.map(ProposalLine.added)
            + oldLines[(oldLines.count - suffix)...].map(ProposalLine.context)
        // A proposal whose only change is the final newline has no differing
        // line text; without an explicit marker it would display as wholly
        // unchanged. The marker belongs to the side that lacks the newline:
        // the old side when a newline was added, the new side when removed.
        if oldLines == newLines,
           oldLastHasNewline != newLastHasNewline {
            lines.append(.endOfFile(added: oldLastHasNewline))
        }
        return lines
    }
}

public enum ProposalLine: Equatable, Sendable {
    case context(String)
    case removed(String)
    case added(String)
    /// The file's final newline changed; there is no line text to show.
    case endOfFile(added: Bool)

    public var text: String {
        switch self {
        case let .context(text), let .removed(text), let .added(text):
            return text
        case .endOfFile:
            return "\\ No newline at end of file"
        }
    }
}

public enum MarkdownProposalError: Error, Equatable, Sendable {
    case unreadable(String)
    case malformed(String)
    case unsupportedVersion(Int)
    case documentMismatch(expected: String, actual: String)
    /// The document's source no longer hashes to the proposal's base.
    case staleBase
    /// The hunk's context no longer matches the source at its position.
    case hunkOutOfDate(Int)
    case overlappingHunks
    case noHunksSelected
}

/// A text proposal from an agent or CLI: a header, a base hash, and a unified
/// diff. The file carries no hidden state; the app reads it, shows its hunks,
/// and applies the accepted ones as ordinary undoable source edits.
public struct MarkdownProposal: Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let documentName: String
    /// SHA-256 of the document's canonical UTF-8 source when the proposal was
    /// written.
    public let baseHash: String
    public let hunks: [ProposalHunk]

    public init(
        version: Int = MarkdownProposal.currentVersion,
        documentName: String,
        baseHash: String,
        hunks: [ProposalHunk]
    ) {
        self.version = version
        self.documentName = documentName
        self.baseHash = baseHash
        self.hunks = hunks
    }

    /// `.name.proposal.diff` beside the document.
    public static func proposalURL(for documentURL: URL) -> URL {
        documentURL.deletingLastPathComponent().appendingPathComponent(
            ".\(documentURL.lastPathComponent).proposal.diff"
        )
    }

    public func matches(source: String) -> Bool {
        baseHash == ReviewAnchorResolver.documentIdentity(of: source)
    }

    // MARK: - Parsing

    public static func load(from url: URL) throws -> MarkdownProposal {
        let data: Data
        do {
            // Bounded before allocating: a malformed or hostile proposal
            // must not be read whole only to be rejected.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        } catch {
            throw MarkdownProposalError.unreadable(
                "\(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
        guard data.count <= 8 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else {
            throw MarkdownProposalError.malformed("not a UTF-8 proposal")
        }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> MarkdownProposal {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var version = 1
        var documentName: String?
        var baseHash: String?
        var sawAnyHeader = false
        var index = 0
        while index < lines.count, lines[index].hasPrefix("# ") {
            sawAnyHeader = true
            let header = String(lines[index].dropFirst(2))
            index += 1
            if header.hasPrefix("sonovo-proposal ") {
                let raw = header.dropFirst("sonovo-proposal ".count)
                guard let parsed = Int(raw) else {
                    throw MarkdownProposalError.malformed("bad version")
                }
                version = parsed
            } else if header.hasPrefix("document: ") {
                documentName = String(header.dropFirst("document: ".count))
            } else if header.hasPrefix("base-sha256: ") {
                baseHash = String(header.dropFirst("base-sha256: ".count))
            } else {
                throw MarkdownProposalError.malformed(
                    "unknown header: \(header)"
                )
            }
        }
        guard sawAnyHeader else {
            throw MarkdownProposalError.malformed("missing proposal headers")
        }
        guard version == currentVersion else {
            throw MarkdownProposalError.unsupportedVersion(version)
        }
        guard let documentName, !documentName.isEmpty else {
            throw MarkdownProposalError.malformed("missing document header")
        }
        guard let baseHash,
              baseHash.count == 64,
              baseHash.allSatisfy(\.isHexDigit) else {
            throw MarkdownProposalError.malformed("bad base-sha256")
        }
        guard index + 1 < lines.count,
              lines[index].hasPrefix("--- "),
              lines[index + 1].hasPrefix("+++ ") else {
            throw MarkdownProposalError.malformed("missing file headers")
        }
        index += 2

        var hunks: [ProposalHunk] = []
        var previousOldEnd = 0
        var cumulativeDelta = 0
        while index < lines.count {
            guard lines[index].hasPrefix("@@ ") else {
                throw MarkdownProposalError.malformed(
                    "expected a hunk header at line \(index + 1)"
                )
            }
            let header = lines[index]
            index += 1
            let parsed = try parseHunkHeader(header)
            var oldLines: [String] = []
            var newLines: [String] = []
            var oldLastHasNewline = true
            var newLastHasNewline = true
            var lastLineWasOld = false
            var lastLineWasNew = false
            while index < lines.count {
                let line = lines[index]
                guard let marker = line.first else {
                    throw MarkdownProposalError.malformed(
                        "empty hunk line at \(index + 1)"
                    )
                }
                if marker == "\\" {
                    guard line.hasPrefix("\\ No newline at end of file")
                    else {
                        throw MarkdownProposalError.malformed(
                            "unknown marker at line \(index + 1)"
                        )
                    }
                    if lastLineWasOld {
                        guard oldLines.count == parsed.oldCount else {
                            throw MarkdownProposalError.malformed(
                                "no-newline marker not at hunk end"
                            )
                        }
                        oldLastHasNewline = false
                    }
                    if lastLineWasNew {
                        guard newLines.count == parsed.newCount else {
                            throw MarkdownProposalError.malformed(
                                "no-newline marker not at hunk end"
                            )
                        }
                        newLastHasNewline = false
                    }
                    lastLineWasOld = false
                    lastLineWasNew = false
                    index += 1
                    continue
                }
                guard " +-".contains(marker) else { break }
                let content = String(line.dropFirst())
                switch marker {
                case " ":
                    oldLines.append(content)
                    newLines.append(content)
                    lastLineWasOld = true
                    lastLineWasNew = true
                case "-":
                    oldLines.append(content)
                    lastLineWasOld = true
                    lastLineWasNew = false
                default:
                    newLines.append(content)
                    lastLineWasOld = false
                    lastLineWasNew = true
                }
                index += 1
            }
            guard oldLines.count == parsed.oldCount,
                  newLines.count == parsed.newCount else {
                throw MarkdownProposalError.malformed(
                    "hunk at line \(index) has \(oldLines.count)/"
                        + "\(newLines.count) lines, expected "
                        + "\(parsed.oldCount)/\(parsed.newCount)"
                )
            }
            guard parsed.oldCount > 0 || parsed.newCount > 0 else {
                throw MarkdownProposalError.malformed("empty hunk")
            }
            let oldIndex = parsed.oldCount == 0
                ? parsed.oldStart
                : parsed.oldStart - 1
            guard oldIndex >= 0 else {
                throw MarkdownProposalError.malformed("bad old start")
            }
            guard oldIndex >= previousOldEnd else {
                throw MarkdownProposalError.overlappingHunks
            }
            let (expectedNewIndex, newOverflow) =
                oldIndex.addingReportingOverflow(cumulativeDelta)
            guard !newOverflow else {
                throw MarkdownProposalError.malformed(
                    "hunk offsets overflow"
                )
            }
            let newIndex = parsed.newCount == 0
                ? parsed.newStart
                : parsed.newStart - 1
            guard newIndex == expectedNewIndex else {
                throw MarkdownProposalError.malformed(
                    "new start does not follow earlier hunks"
                )
            }
            hunks.append(
                ProposalHunk(
                    id: hunks.count + 1,
                    oldStart: parsed.oldStart,
                    oldCount: parsed.oldCount,
                    newStart: parsed.newStart,
                    newCount: parsed.newCount,
                    section: parsed.section,
                    oldLines: oldLines,
                    newLines: newLines,
                    oldLastHasNewline: oldLastHasNewline,
                    newLastHasNewline: newLastHasNewline
                )
            )
            let (oldEnd, oldOverflow) =
                oldIndex.addingReportingOverflow(parsed.oldCount)
            guard !oldOverflow else {
                throw MarkdownProposalError.malformed(
                    "hunk offsets overflow"
                )
            }
            previousOldEnd = oldEnd
            let (nextDelta, deltaOverflow) = cumulativeDelta
                .addingReportingOverflow(parsed.newCount - parsed.oldCount)
            guard !deltaOverflow else {
                throw MarkdownProposalError.malformed(
                    "hunk offsets overflow"
                )
            }
            cumulativeDelta = nextDelta
        }
        guard !hunks.isEmpty else {
            throw MarkdownProposalError.malformed("no hunks")
        }
        return MarkdownProposal(
            version: version,
            documentName: documentName,
            baseHash: baseHash,
            hunks: hunks
        )
    }

    private struct ParsedHunkHeader {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let section: String
    }

    private static func parseHunkHeader(
        _ header: String
    ) throws -> ParsedHunkHeader {
        // `@@ -old[,count] +new[,count] @@ optional section`
        let rest = header.dropFirst(3)
        guard let range = rest.range(of: " @@") else {
            throw MarkdownProposalError.malformed("bad hunk header: \(header)")
        }
        let numbers = rest[..<range.lowerBound]
        let section = String(rest[range.upperBound...])
            .trimmingCharacters(in: .whitespaces)
            .drop(while: { $0 == " " })
        let parts = numbers.split(separator: " ")
        guard parts.count == 2,
              parts[0].hasPrefix("-"),
              parts[1].hasPrefix("+") else {
            throw MarkdownProposalError.malformed("bad hunk header: \(header)")
        }
        let old = try parseRange(parts[0].dropFirst())
        let new = try parseRange(parts[1].dropFirst())
        return ParsedHunkHeader(
            oldStart: old.start,
            oldCount: old.count,
            newStart: new.start,
            newCount: new.count,
            section: String(section)
        )
    }

    private static func parseRange(
        _ text: Substring
    ) throws -> (start: Int, count: Int) {
        let components = text.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        guard components.count == 1 || components.count == 2,
              let start = Int(components[0]),
              start >= 0 else {
            throw MarkdownProposalError.malformed(
                "bad range: \(text)"
            )
        }
        let count: Int
        if components.count == 2 {
            guard let parsed = Int(components[1]), parsed >= 0 else {
                throw MarkdownProposalError.malformed(
                    "bad range: \(text)"
                )
            }
            count = parsed
        } else {
            count = 1
        }
        if start == 0, count > 0 {
            throw MarkdownProposalError.malformed("bad range: \(text)")
        }
        return (start, count)
    }

    // MARK: - Encoding

    /// Writes the proposal back in the documented format, so a test or a tool
    /// can produce one without duplicating the parser's rules.
    public func encoded() -> String {
        var lines = [
            "# sonovo-proposal \(version)",
            "# document: \(documentName)",
            "# base-sha256: \(baseHash)",
            "--- a/\(documentName)",
            "+++ b/\(documentName)",
        ]
        for hunk in hunks {
            let section = hunk.section.isEmpty ? "" : " \(hunk.section)"
            lines.append(
                "@@ -\(hunk.oldStart),\(hunk.oldCount) "
                    + "+\(hunk.newStart),\(hunk.newCount) @@\(section)"
            )
            var oldIndex = 0
            var newIndex = 0
            // `old`/`new` mark which side each emitted line belongs to, so
            // a no-newline marker can follow its own side's last line.
            var emitted: [(text: String, old: Bool, new: Bool)] = []
            while oldIndex < hunk.oldLines.count
                || newIndex < hunk.newLines.count {
                let oldIsLast = oldIndex + 1 == hunk.oldLines.count
                let newIsLast = newIndex + 1 == hunk.newLines.count
                if oldIndex < hunk.oldLines.count,
                   newIndex < hunk.newLines.count,
                   hunk.oldLines[oldIndex] == hunk.newLines[newIndex] {
                    // Equal text is only a shared context line when both
                    // sides agree about the trailing newline (or neither
                    // line is a side's last).
                    let sharesContext = !oldIsLast && !newIsLast
                        || (oldIsLast && newIsLast
                            && hunk.oldLastHasNewline
                                == hunk.newLastHasNewline)
                    if sharesContext {
                        emitted.append(
                            (" " + hunk.oldLines[oldIndex], true, true)
                        )
                        oldIndex += 1
                        newIndex += 1
                        continue
                    }
                }
                if oldIndex < hunk.oldLines.count {
                    emitted.append(("-" + hunk.oldLines[oldIndex], true, false))
                    oldIndex += 1
                } else {
                    emitted.append(("+" + hunk.newLines[newIndex], false, true))
                    newIndex += 1
                }
            }
            // A marker belongs immediately after the line it describes:
            // appending every marker at the hunk's end let an old-side
            // marker attach to a final added line.
            let marker = "\\ No newline at end of file"
            if !hunk.oldLastHasNewline,
               let last = emitted.lastIndex(where: { $0.old }) {
                emitted.insert((marker, false, false), at: last + 1)
            }
            if !hunk.newLastHasNewline,
               let last = emitted.lastIndex(where: { $0.new }) {
                emitted.insert((marker, false, false), at: last + 1)
            }
            lines.append(contentsOf: emitted.map(\.text))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Applying

    /// Applies the selected hunks, in document order, to `source`. Hunks not
    /// selected are ignored even if their context no longer matches.
    public func apply(
        accepting selection: Set<Int>,
        to source: String
    ) throws -> String {
        guard matches(source: source) else {
            throw MarkdownProposalError.staleBase
        }
        guard !selection.isEmpty else {
            throw MarkdownProposalError.noHunksSelected
        }
        for index in selection where !hunks.indices.contains(index - 1) {
            throw MarkdownProposalError.malformed(
                "hunk \(index) does not exist"
            )
        }
        let split = Self.splitLines(source)
        let selected = hunks
            .filter { selection.contains($0.id) }
            .sorted { $0.oldIndex < $1.oldIndex }
        var previousEnd = 0
        for hunk in selected {
            guard hunk.oldIndex >= previousEnd else {
                throw MarkdownProposalError.overlappingHunks
            }
            let (end, overflow) = hunk.oldIndex
                .addingReportingOverflow(hunk.oldCount)
            guard !overflow else {
                throw MarkdownProposalError.hunkOutOfDate(hunk.id)
            }
            previousEnd = end
        }

        var result: [String] = []
        var cursor = 0
        var trailing = split.trailingNewline
        for hunk in selected {
            let (oldEnd, overflow) = hunk.oldIndex
                .addingReportingOverflow(hunk.oldCount)
            guard !overflow,
                  hunk.oldIndex >= cursor,
                  oldEnd <= split.lines.count else {
                throw MarkdownProposalError.hunkOutOfDate(hunk.id)
            }
            let current = Array(
                split.lines[hunk.oldIndex..<oldEnd]
            )
            guard current == hunk.oldLines else {
                throw MarkdownProposalError.hunkOutOfDate(hunk.id)
            }
            result.append(contentsOf: split.lines[cursor..<hunk.oldIndex])
            result.append(contentsOf: hunk.newLines)
            cursor = oldEnd
            if cursor == split.lines.count {
                trailing = hunk.newLastHasNewline
            }
        }
        result.append(contentsOf: split.lines[cursor...])
        return Self.joinLines(result, trailingNewline: trailing)
    }

    private static func splitLines(
        _ text: String
    ) -> (lines: [String], trailingNewline: Bool) {
        guard !text.isEmpty else { return ([], false) }
        var lines = text.components(separatedBy: "\n")
        let trailing = lines.last == ""
        if trailing { lines.removeLast() }
        return (lines, trailing)
    }

    private static func joinLines(
        _ lines: [String],
        trailingNewline: Bool
    ) -> String {
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n")
            + (trailingNewline ? "\n" : "")
    }
}
