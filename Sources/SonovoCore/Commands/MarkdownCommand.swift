import Foundation

/// A command the rail, menu, palette, and key equivalents all execute.
public enum MarkdownCommandKind: Sendable, Equatable, Hashable {
    case toggleEmphasis
    case toggleStrong
    case toggleInlineCode
    case toggleStrikethrough
    case toggleHeading(level: Int)
    case toggleBlockQuote
    case toggleList(kind: MarkdownListKind)
    case insertLink(destination: String)
    case insertImage(destination: String, alt: String)
    case insertCodeFence
    case insertRule
    case insertWikiLink(target: String, alias: String?)
    case insertDetails(summary: String)
    case insertTOC
    case replaceAll(query: String, replacement: String, caseSensitive: Bool)
    case setDetailsOpen(Bool)
}

/// The list shapes a toggle can produce.
public enum MarkdownListKind: Sendable, Equatable, Hashable {
    case bullet
    case ordered
    case task
}

/// Everything a command needs to decide availability and apply itself.
public struct MarkdownCommandContext: Sendable, Equatable {
    public var source: String
    /// UTF-16 offsets.
    public var selection: Range<Int>
    public var isReadOnly: Bool
    public var hasMarkedText: Bool
    public var mode: MarkdownDocumentMode

    public init(
        source: String,
        selection: Range<Int>,
        isReadOnly: Bool = false,
        hasMarkedText: Bool = false,
        mode: MarkdownDocumentMode = .source
    ) {
        self.source = source
        self.selection = selection
        self.isReadOnly = isReadOnly
        self.hasMarkedText = hasMarkedText
        self.mode = mode
    }
}

/// The new source and selection a command produces.
public struct MarkdownCommandResult: Sendable, Equatable {
    public let source: String
    public let selection: Range<Int>
    public let actionName: String
    /// The minimal UTF-16 range that differs from the input.
    public let changedRange: Range<Int>

    public init(
        source: String,
        selection: Range<Int>,
        actionName: String,
        previousSource: String
    ) {
        self.source = source
        self.selection = selection
        self.actionName = actionName
        self.changedRange = Self.minimalChange(
            from: previousSource,
            to: source
        )
    }

    private static func minimalChange(from old: String, to new: String) -> Range<Int> {
        let a = old as NSString
        let b = new as NSString
        let limit = min(a.length, b.length)
        var prefix = 0
        while prefix < limit, a.character(at: prefix) == b.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < limit - prefix,
              a.character(at: a.length - 1 - suffix)
                == b.character(at: b.length - 1 - suffix) {
            suffix += 1
        }
        return prefix..<(b.length - suffix)
    }
}

public enum MarkdownCommandError: Error, Equatable {
    case unavailable(String)
    case invalidSelection
    case invalidDestination(String)
    case detailsNotFound
}

/// The single command registry.
///
/// Every command is a pure source transform with an explicit resulting
/// selection. The rail, menus, palette, and keyboard all call `apply`; there is
/// no second implementation path.
public struct MarkdownCommandRegistry: Sendable {
    public init() {}

    public func isAvailable(
        _ command: MarkdownCommandKind,
        in context: MarkdownCommandContext
    ) -> Bool {
        guard !context.isReadOnly,
              !context.hasMarkedText,
              context.mode == .source else {
            return false
        }
        switch command {
        case .toggleHeading(let level):
            return (1...6).contains(level)
        case .insertLink(let destination):
            return destination.isEmpty || MarkdownSecurity.linkDecision(for: destination).isAllowed
        case .insertImage(let destination, _):
            return destination.isEmpty || MarkdownSecurity.linkDecision(for: destination).isAllowed
        case .insertWikiLink(let target, _):
            return target.isEmpty || MarkdownSecurity.isValidWikiTarget(target)
        case .replaceAll(let query, _, _):
            return !query.isEmpty
        default:
            return true
        }
    }

    public func title(for command: MarkdownCommandKind) -> String {
        switch command {
        case .toggleEmphasis: "Italic"
        case .toggleStrong: "Bold"
        case .toggleInlineCode: "Inline Code"
        case .toggleStrikethrough: "Strikethrough"
        case .toggleHeading(let level): "Heading \(level)"
        case .toggleBlockQuote: "Block Quote"
        case .toggleList(.bullet): "Bullet List"
        case .toggleList(.ordered): "Numbered List"
        case .toggleList(.task): "Task List"
        case .insertLink: "Link"
        case .insertImage: "Image"
        case .insertCodeFence: "Code Block"
        case .insertRule: "Horizontal Rule"
        case .insertWikiLink: "Wiki Link"
        case .insertDetails: "Details"
        case .insertTOC: "Table of Contents"
        case .replaceAll: "Replace All"
        case .setDetailsOpen(true): "Open Details"
        case .setDetailsOpen(false): "Close Details"
        }
    }

    public func apply(
        _ command: MarkdownCommandKind,
        to context: MarkdownCommandContext
    ) throws -> MarkdownCommandResult {
        guard isAvailable(command, in: context) else {
            throw MarkdownCommandError.unavailable(title(for: command))
        }

        switch command {
        case .toggleEmphasis:
            return try toggleWrap("*", name: "Italic", context)
        case .toggleStrong:
            return try toggleWrap("**", name: "Bold", context)
        case .toggleStrikethrough:
            return try toggleWrap("~~", name: "Strikethrough", context)
        case .toggleInlineCode:
            return try toggleInlineCode(context)
        case .toggleHeading(let level):
            return try toggleHeading(level: level, context)
        case .toggleBlockQuote:
            return try toggleBlockQuote(context)
        case .toggleList(let kind):
            return try toggleList(kind, context)
        case .insertLink(let destination):
            return try insertLink(
                destination: destination,
                image: false,
                alt: "",
                context
            )
        case .insertImage(let destination, let alt):
            return try insertLink(
                destination: destination,
                image: true,
                alt: alt,
                context
            )
        case .insertCodeFence:
            return try insertCodeFence(context)
        case .insertRule:
            return insertRule(context)
        case .insertWikiLink(let target, let alias):
            return try insertWikiLink(target: target, alias: alias, context)
        case .insertDetails(let summary):
            return try insertDetails(summary: summary, context)
        case .insertTOC:
            return insertTOC(context)
        case .replaceAll(let query, let replacement, let caseSensitive):
            return try replaceAll(
                query: query,
                replacement: replacement,
                caseSensitive: caseSensitive,
                context
            )
        case .setDetailsOpen(let open):
            return try setDetailsOpen(open, context)
        }
    }

    // MARK: - Selection helpers

    private func validatedSelection(
        _ context: MarkdownCommandContext
    ) throws -> NSRange {
        let ns = context.source as NSString
        guard context.selection.lowerBound >= 0,
              context.selection.upperBound >= context.selection.lowerBound,
              context.selection.upperBound <= ns.length else {
            throw MarkdownCommandError.invalidSelection
        }
        return NSRange(
            location: context.selection.lowerBound,
            length: context.selection.upperBound - context.selection.lowerBound
        )
    }

    private func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    private func trimmedCore(_ ns: NSString, _ selection: NSRange) -> NSRange {
        var location = selection.location
        var length = selection.length
        while length > 0, isSpace(ns.character(at: location)) {
            location += 1
            length -= 1
        }
        while length > 0, isSpace(ns.character(at: location + length - 1)) {
            length -= 1
        }
        return NSRange(location: location, length: length)
    }

    private func result(
        _ source: String,
        selection: NSRange,
        name: String,
        previous: String
    ) -> MarkdownCommandResult {
        let ns = source as NSString
        let location = min(max(0, selection.location), ns.length)
        let length = min(max(0, selection.length), ns.length - location)
        return MarkdownCommandResult(
            source: source,
            selection: location..<(location + length),
            actionName: name,
            previousSource: previous
        )
    }

    // MARK: - Wrapping

    private func toggleWrap(
        _ marker: String,
        name: String,
        _ context: MarkdownCommandContext
    ) throws -> MarkdownCommandResult {
        let ns = context.source as NSString
        let selection = try validatedSelection(context)
        let markerNS = marker as NSString
        let markerLength = markerNS.length
        let core = trimmedCore(ns, selection)

        if core.length == 0 {
            let location = min(selection.location, ns.length)
            let insertion = marker + marker
            let source = ns.replacingCharacters(
                in: NSRange(location: location, length: 0),
                with: insertion
            )
            let cursor = location + markerLength
            return result(
                source,
                selection: NSRange(location: cursor, length: 0),
                name: name,
                previous: context.source
            )
        }

        // Already wrapped from the outside. A run of exactly this command's
        // marker is the formatting it toggles; a longer run can mean combined
        // formatting. `*` inside `**word**` is bold, so italic adds a star;
        // inside `***word***` italic is already applied, so it removes one
        // and restores the bold underneath.
        let markerCharacter = marker.unicodeScalars.first!.value
        let unwrapRuns: Set<Int>
        switch marker {
        case "*", "_": unwrapRuns = [1, 3]
        case "**", "__": unwrapRuns = [2, 3]
        default: unwrapRuns = [markerLength]
        }

        var beforeRun = 0
        var probe = core.location - 1
        while probe >= 0, ns.character(at: probe) == markerCharacter {
            beforeRun += 1
            probe -= 1
        }
        var afterRun = 0
        probe = core.location + core.length
        while probe < ns.length, ns.character(at: probe) == markerCharacter {
            afterRun += 1
            probe += 1
        }
        if beforeRun == afterRun, unwrapRuns.contains(beforeRun) {
            let before = NSRange(
                location: core.location - markerLength,
                length: markerLength
            )
            let after = NSRange(
                location: core.location + core.length,
                length: markerLength
            )
            let mutable = NSMutableString(string: context.source)
            mutable.deleteCharacters(in: after)
            mutable.deleteCharacters(in: before)
            return result(
                mutable as String,
                selection: NSRange(location: before.location, length: core.length),
                name: name,
                previous: context.source
            )
        }

        // The selection itself includes the markers. The same run rule
        // applies: `**word**` is bold, `***word***` is both, and toggling
        // italic removes exactly one star from each side.
        var selectedPrefixRun = 0
        while selectedPrefixRun < core.length,
              ns.character(at: core.location + selectedPrefixRun) == markerCharacter {
            selectedPrefixRun += 1
        }
        var selectedSuffixRun = 0
        while selectedSuffixRun < core.length,
              ns.character(at: core.location + core.length - selectedSuffixRun - 1)
                == markerCharacter {
            selectedSuffixRun += 1
        }
        if core.length >= markerLength * 2,
           selectedPrefixRun == selectedSuffixRun,
           unwrapRuns.contains(selectedPrefixRun) {
            let inner = NSRange(
                location: core.location + markerLength,
                length: core.length - markerLength * 2
            )
            let source = ns.replacingCharacters(in: core, with: ns.substring(with: inner))
            // The markers are gone, so the inner text now starts where the
            // selected range started.
            return result(
                source,
                selection: NSRange(location: core.location, length: inner.length),
                name: name,
                previous: context.source
            )
        }

        let mutable = NSMutableString(string: context.source)
        mutable.insert(marker, at: core.location + core.length)
        mutable.insert(marker, at: core.location)
        return result(
            mutable as String,
            selection: NSRange(location: core.location + markerLength, length: core.length),
            name: name,
            previous: context.source
        )
    }

    private func toggleInlineCode(
        _ context: MarkdownCommandContext
    ) throws -> MarkdownCommandResult {
        let ns = context.source as NSString
        let selection = try validatedSelection(context)
        let core = trimmedCore(ns, selection)

        if core.length == 0 {
            let location = min(selection.location, ns.length)
            let source = ns.replacingCharacters(
                in: NSRange(location: location, length: 0),
                with: "``"
            )
            return result(
                source,
                selection: NSRange(location: location + 1, length: 0),
                name: "Inline Code",
                previous: context.source
            )
        }

        // Detect an existing backtick run wrapping the core. A padded fence
        // (` `` `code` `` `) has one space between the run and the content.
        var beforeRun = 0
        var beforePadding = false
        var probe = core.location - 1
        if probe >= 0, ns.character(at: probe) == 0x20 {
            beforePadding = true
            probe -= 1
        }
        while probe >= 0, ns.character(at: probe) == 0x60 {
            beforeRun += 1
            probe -= 1
        }

        var afterRun = 0
        var afterPadding = false
        probe = core.location + core.length
        if probe < ns.length, ns.character(at: probe) == 0x20 {
            afterPadding = true
            probe += 1
        }
        while probe < ns.length, ns.character(at: probe) == 0x60 {
            afterRun += 1
            probe += 1
        }

        if beforeRun > 0,
           beforeRun == afterRun,
           beforePadding == afterPadding,
           !containsBacktickRun(ofLength: beforeRun, in: ns, range: core) {
            let padding = beforePadding ? 1 : 0
            let beforeStart = core.location - beforeRun - padding
            let afterStart = core.location + core.length
            let afterEnd = afterStart + afterRun + padding
            let mutable = NSMutableString(string: context.source)
            mutable.deleteCharacters(
                in: NSRange(location: afterStart, length: afterEnd - afterStart)
            )
            mutable.deleteCharacters(
                in: NSRange(
                    location: beforeStart,
                    length: core.location - beforeStart
                )
            )
            return result(
                mutable as String,
                selection: NSRange(location: beforeStart, length: core.length),
                name: "Inline Code",
                previous: context.source
            )
        }

        var leading = 0
        while leading < core.length,
              ns.character(at: core.location + leading) == 0x60 {
            leading += 1
        }
        var trailing = 0
        while trailing < core.length,
              ns.character(at: core.location + core.length - trailing - 1) == 0x60 {
            trailing += 1
        }
        let text = ns.substring(with: core)
        if leading > 0, leading == trailing, core.length >= leading * 2,
           !containsBacktickRun(
               ofLength: leading,
               in: ns,
               range: NSRange(
                   location: core.location + leading,
                   length: core.length - leading * 2
               )
           ) {
            var innerStart = core.location + leading
            var innerLength = core.length - leading * 2
            // Padded content has one space on each side inside the fence;
            // CommonMark treats that pair as padding, not content.
            if innerLength >= 2,
               ns.character(at: innerStart) == 0x20,
               ns.character(at: innerStart + innerLength - 1) == 0x20 {
                let inner = ns.substring(
                    with: NSRange(location: innerStart, length: innerLength)
                )
                // CommonMark keeps an all-space span intact; only a mixed
                // span treats the boundary spaces as padding.
                if !inner.allSatisfy({ $0 == " " }) {
                    innerStart += 1
                    innerLength -= 2
                }
            }
            let source = ns.replacingCharacters(
                in: core,
                with: ns.substring(
                    with: NSRange(location: innerStart, length: innerLength)
                )
            )
            return result(
                source,
                selection: NSRange(location: core.location, length: innerLength),
                name: "Inline Code",
                previous: context.source
            )
        }

        // Choose a fence longer than any backtick run inside the selection.
        let longest = longestRun(of: "`", in: text)
        let fence = String(repeating: "`", count: max(1, longest + 1))
        // A space on both sides keeps the fence from merging with a backtick
        // at either edge of the content. CommonMark strips one leading and
        // trailing space from a code span, so the content is unchanged.
        let padded = text.hasPrefix("`") || text.hasSuffix("`")
        let opening = fence + (padded ? " " : "")
        let closing = (padded ? " " : "") + fence
        let mutable = NSMutableString(string: context.source)
        mutable.insert(closing, at: core.location + core.length)
        mutable.insert(opening, at: core.location)
        return result(
            mutable as String,
            selection: NSRange(
                location: core.location + (opening as NSString).length,
                length: core.length
            ),
            name: "Inline Code",
            previous: context.source
        )
    }

    // MARK: - Line transforms

    private struct Line {
        let content: String
    }

    private func lines(
        _ ns: NSString,
        covering selection: NSRange
    ) -> (block: NSRange, lines: [Line]) {
        let start = min(selection.location, ns.length)
        let end = min(selection.location + selection.length, ns.length)

        // The last selected character decides the last line. `end` is
        // exclusive, so probe once at `end - 1`; decrementing `end` first
        // skipped a selected blank line.
        let first = ns.lineRange(for: NSRange(location: start, length: 0))
        let last = ns.lineRange(for: NSRange(location: max(start, end - 1), length: end > start ? 1 : 0))
        let block = NSRange(
            location: first.location,
            length: NSMaxRange(last) - first.location
        )

        var result: [Line] = []
        var cursor = block.location
        while cursor < NSMaxRange(block) {
            let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let limited = NSIntersectionRange(lineRange, block)
            var content = ns.substring(with: limited)
            if content.hasSuffix("\n") { content.removeLast() }
            result.append(Line(content: content))
            cursor = NSMaxRange(limited)
        }

        if result.isEmpty {
            result.append(Line(content: ""))
        }
        return (block, result)
    }

    private func splitIndent(_ line: String) -> (indent: String, rest: String) {
        var indent = ""
        var rest = line
        while let first = rest.first, first == " " || first == "\t" {
            indent.append(first)
            rest.removeFirst()
        }
        return (indent, rest)
    }

    private func toggleHeading(
        level: Int,
        _ context: MarkdownCommandContext
    ) throws -> MarkdownCommandResult {
        let ns = context.source as NSString
        let selection = try validatedSelection(context)
        let (block, lines) = lines(ns, covering: selection)

        // The hashes alone are a valid empty heading; trailing content and
        // the separating space are optional.
        let pattern = try NSRegularExpression(pattern: #"^(#{1,6})(?:([ \t]+)(.*))?$"#)
        var transformed: [String] = []

        let nonEmpty = lines.filter {
            !$0.content.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let allRequested = !nonEmpty.isEmpty && nonEmpty.allSatisfy { line in
            let (_, rest) = splitIndent(line.content)
            let range = NSRange(location: 0, length: (rest as NSString).length)
            guard let match = pattern.firstMatch(in: rest, range: range) else {
                return false
            }
            return (rest as NSString).substring(with: match.range(at: 1)).count == level
        }

        for line in lines {
            let (indent, rest) = splitIndent(line.content)
            let range = NSRange(location: 0, length: (rest as NSString).length)
            let match = pattern.firstMatch(in: rest, range: range)

            if allRequested {
                // Removal must leave non-heading lines (including blank
                // separators) untouched.
                if let match {
                    transformed.append(
                        indent + headingContent(match, in: rest as NSString)
                    )
                } else {
                    transformed.append(line.content)
                }
            } else {
                let content = match.map {
                    headingContent($0, in: rest as NSString)
                } ?? rest
                let hashes = String(repeating: "#", count: level)
                let prefix = content.isEmpty ? hashes : hashes + " "
                transformed.append(
                    indent + prefix + content
                )
            }
        }

        return replaceLines(
            ns: ns,
            block: block,
            lines: transformed,
            hadTrailingNewline: block.length > 0
                && ns.substring(with: block).hasSuffix("\n"),
            name: "Heading \(level)",
            context: context
        )
    }

    /// The content of an ATX heading match, or an empty string when the
    /// heading has no content (for example `##`).
    private func headingContent(
        _ match: NSTextCheckingResult,
        in rest: NSString
    ) -> String {
        let range = match.range(at: 3)
        guard range.location != NSNotFound else { return "" }
        return rest.substring(with: range)
    }

    /// Whether `range` contains a run of exactly `length` backticks. A code
    /// span's closing run must equal its opening run, so an equal run inside
    /// the candidate means the delimiters do not enclose a single span.
    private func containsBacktickRun(
        ofLength length: Int,
        in ns: NSString,
        range: NSRange
    ) -> Bool {
        let end = NSMaxRange(range)
        var index = range.location
        while index < end {
            if ns.character(at: index) == 0x60 {
                var run = 0
                while index + run < end,
                      ns.character(at: index + run) == 0x60 {
                    run += 1
                }
                if run == length { return true }
                index += run
            } else {
                index += 1
            }
        }
        return false
    }

    private func toggleBlockQuote(
        _ context: MarkdownCommandContext
    ) throws -> MarkdownCommandResult {
        let ns = context.source as NSString
        let selection = try validatedSelection(context)
        let (block, lines) = lines(ns, covering: selection)

        let nonEmpty = lines.filter {
            !$0.content.trimmingCharacters(in: .whitespaces).isEmpty
        }
        // An empty selection has no lines to quote; it must toggle on, not
        // satisfy `allSatisfy` vacuously and do nothing.
        let allQuoted = !nonEmpty.isEmpty && nonEmpty.allSatisfy {
            splitIndent($0.content).rest.hasPrefix(">")
        }

        let transformed = lines.map { line -> String in
            let (indent, rest) = splitIndent(line.content)
            if allQuoted {
                guard rest.hasPrefix(">") else { return line.content }
                var remainder = String(rest.dropFirst())
                if remainder.hasPrefix(" ") { remainder.removeFirst() }
                return indent + remainder
            }
            return indent + "> " + rest
        }

        return replaceLines(
            ns: ns,
            block: block,
            lines: transformed,
            hadTrailingNewline: block.length > 0
                && ns.substring(with: block).hasSuffix("\n"),
            name: "Block Quote",
            context: context
        )
    }

    private func toggleList(
        _ kind: MarkdownListKind,
        _ context: MarkdownCommandContext
    ) throws -> MarkdownCommandResult {
        let ns = context.source as NSString
        let selection = try validatedSelection(context)
        let (block, lines) = lines(ns, covering: selection)

        let markerPattern = try NSRegularExpression(
            pattern: #"^(\s*)([-*+]|[0-9]{1,9}[.)])([ \t]+)(\[[ xX]\](?:[ \t]+|$))?"#
        )

        func marker(of line: String) -> (matchedKind: MarkdownListKind?, rest: String, indent: String)? {
            let range = NSRange(location: 0, length: (line as NSString).length)
            guard let match = markerPattern.firstMatch(in: line, range: range) else {
                return nil
            }
            let indent = (line as NSString).substring(with: match.range(at: 1))
            let token = (line as NSString).substring(with: match.range(at: 2))
            let hasTask = match.range(at: 4).location != NSNotFound
            let matchedKind: MarkdownListKind
            if hasTask {
                matchedKind = .task
            } else if let last = token.last, last == "." || last == ")" {
                matchedKind = .ordered
            } else {
                matchedKind = .bullet
            }
            let rest = (line as NSString).substring(from: NSMaxRange(match.range))
            return (matchedKind, rest, indent)
        }

        let nonEmpty = lines.filter {
            !$0.content.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let allRequested = !nonEmpty.isEmpty && nonEmpty.allSatisfy {
            marker(of: $0.content)?.matchedKind == kind
        }

        var counter = 1
        let transformed = lines.map { line -> String in
            let parsed = marker(of: line.content)
            let indent = parsed?.indent ?? splitIndent(line.content).indent
            let rest = parsed?.rest ?? splitIndent(line.content).rest

            if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                if allRequested { return "" }
                if parsed?.matchedKind == kind {
                    // Keep an empty task's checked state intact.
                    return line.content
                }
                return indent + markerPrefix(kind, counter: &counter)
            }
            if allRequested {
                return indent + rest
            }
            if parsed?.matchedKind == kind {
                // Already this list kind: keep authored numbering and task
                // checked state instead of re-emitting a default marker.
                return line.content
            }

            return indent + markerPrefix(kind, counter: &counter) + rest
        }

        return replaceLines(
            ns: ns,
            block: block,
            lines: transformed,
            hadTrailingNewline: block.length > 0
                && ns.substring(with: block).hasSuffix("\n"),
            name: "List",
            context: context
        )
    }

    private func markerPrefix(
        _ kind: MarkdownListKind,
        counter: inout Int
    ) -> String {
        switch kind {
        case .bullet:
            return "- "
        case .ordered:
            defer { counter += 1 }
            return "\(counter). "
        case .task:
            return "- [ ] "
        }
    }

    private func replaceLines(
        ns: NSString,
        block: NSRange,
        lines: [String],
        hadTrailingNewline: Bool,
        name: String,
        context: MarkdownCommandContext
    ) -> MarkdownCommandResult {
        var replacement = lines.joined(separator: "\n")
        if hadTrailingNewline { replacement += "\n" }
        let source = ns.replacingCharacters(in: block, with: replacement)
        return result(
            source,
            selection: NSRange(
                location: block.location,
                length: (replacement as NSString).length
            ),
            name: name,
            previous: context.source
        )
    }

    // MARK: - Insertions

    private func insertLink(
        destination: String,
        image: Bool,
        alt: String,
        _ context: MarkdownCommandContext
    ) throws -> MarkdownCommandResult {
        if !destination.isEmpty,
           !MarkdownSecurity.linkDecision(for: destination).isAllowed {
            throw MarkdownCommandError.invalidDestination(destination)
        }
        // A link destination cannot contain a line ending in either form.
        // Check scalars: Swift treats CRLF as one Character.
        if destination.unicodeScalars.contains(where: {
            $0 == "\n" || $0 == "\r"
        }) {
            throw MarkdownCommandError.invalidDestination(destination)
        }
        let ns = context.source as NSString
        let selection = try validatedSelection(context)
        let selected = ns.substring(with: selection)
        let label = image
            ? (alt.isEmpty ? selected : alt)
            : (selected.isEmpty ? "text" : selected)
        let insertion = image
            ? "![\(escapedLabel(label))](\(serializedDestination(destination)))"
            : "[\(escapedLabel(label))](\(serializedDestination(destination)))"
        let source = ns.replacingCharacters(in: selection, with: insertion)

        let cursor: Int
        if destination.isEmpty {
            cursor = selection.location + (insertion as NSString).length - 1
        } else {
            cursor = selection.location + (insertion as NSString).length
        }
        return result(
            source,
            selection: NSRange(location: cursor, length: 0),
            name: image ? "Image" : "Link",
            previous: context.source
        )
    }

    private func insertCodeFence(
        _ context: MarkdownCommandContext
    ) throws -> MarkdownCommandResult {
        let ns = context.source as NSString
        let selection = try validatedSelection(context)
        let (block, _) = lines(ns, covering: selection)
        let selectedText = ns.substring(with: block)
        let hasTrailingNewline = selectedText.hasSuffix("\n")
        let body = hasTrailingNewline ? String(selectedText.dropLast()) : selectedText

        // A fixed three-backtick fence closes early when the body itself
        // contains a fence line. Use a run longer than any backtick run.
        let fence = String(
            repeating: "`",
            count: max(3, longestRun(of: "`", in: body) + 1)
        )

        let source = ns.replacingCharacters(
            in: block,
            with: fence + "\n" + body + "\n" + fence + (hasTrailingNewline ? "\n" : "")
        )
        let contentStart = block.location + (fence as NSString).length + 1
        return result(
            source,
            selection: NSRange(
                location: contentStart,
                length: (body as NSString).length
            ),
            name: "Code Block",
            previous: context.source
        )
    }

    private func insertRule(_ context: MarkdownCommandContext) -> MarkdownCommandResult {
        insertStandaloneBlock(
            "---",
            name: "Horizontal Rule",
            context
        )
    }

    /// The blank-line padding a standalone block needs at `start..<end` so it
    /// forms its own paragraph.
    private func standalonePadding(
        in ns: NSString,
        start: Int,
        end: Int
    ) -> (prefix: String, suffix: String) {
        let before = ns.substring(to: start)
        let after = ns.substring(from: end)

        var prefix = ""
        if !before.isEmpty, !before.hasSuffix("\n\n") {
            prefix = before.hasSuffix("\n") ? "\n" : "\n\n"
        }
        var suffix = ""
        if !after.isEmpty, !after.hasPrefix("\n\n") {
            suffix = after.hasPrefix("\n") ? "\n" : "\n\n"
        }
        return (prefix, suffix)
    }

    /// Inserts a block-level marker on its own paragraph, padding the
    /// surrounding text with the blank lines the syntax needs.
    private func insertStandaloneBlock(
        _ text: String,
        name: String,
        _ context: MarkdownCommandContext
    ) -> MarkdownCommandResult {
        let ns = context.source as NSString
        let location = min(max(0, context.selection.lowerBound), ns.length)
        let (prefix, suffix) = standalonePadding(
            in: ns,
            start: location,
            end: location
        )

        let insertion = prefix + text + suffix
        let source = ns.replacingCharacters(
            in: NSRange(location: location, length: 0),
            with: insertion
        )
        let cursor = location + (insertion as NSString).length
        return result(
            source,
            selection: NSRange(location: cursor, length: 0),
            name: name,
            previous: context.source
        )
    }

    private func insertWikiLink(
        target: String,
        alias: String?,
        _ context: MarkdownCommandContext
    ) throws -> MarkdownCommandResult {
        let ns = context.source as NSString
        let selection = try validatedSelection(context)
        let selected = ns.substring(with: selection)

        let effectiveTarget = target.isEmpty ? selected : target
        guard MarkdownSecurity.isValidWikiTarget(effectiveTarget) else {
            throw MarkdownCommandError.invalidDestination(effectiveTarget)
        }
        guard !effectiveTarget.contains("]]"),
              !effectiveTarget.contains("|"),
              !effectiveTarget.unicodeScalars.contains(where: {
                  $0 == "\n" || $0 == "\r"
              }) else {
            throw MarkdownCommandError.invalidDestination(effectiveTarget)
        }

        var effectiveAlias = alias
        if effectiveAlias == nil,
           !selected.isEmpty,
           selected != effectiveTarget {
            effectiveAlias = selected
        }

        let text: String
        if let effectiveAlias, !effectiveAlias.isEmpty {
            guard !effectiveAlias.contains("]]"),
                  !effectiveAlias.unicodeScalars.contains(where: {
                      $0 == "\n" || $0 == "\r"
                  }) else {
                throw MarkdownCommandError.invalidDestination(effectiveAlias)
            }
            text = "[[\(effectiveTarget)|\(effectiveAlias)]]"
        } else {
            text = "[[\(effectiveTarget)]]"
        }

        let source = ns.replacingCharacters(in: selection, with: text)
        return result(
            source,
            selection: NSRange(
                location: selection.location + (text as NSString).length,
                length: 0
            ),
            name: "Wiki Link",
            previous: context.source
        )
    }

    private func insertDetails(
        summary: String,
        _ context: MarkdownCommandContext
    ) throws -> MarkdownCommandResult {
        let ns = context.source as NSString
        let selection = try validatedSelection(context)
        let body = ns.substring(with: selection)
        let label = escapedHTMLText(summary.isEmpty ? "Details" : summary)

        let detailsText = "<details open>\n"
            + "<summary>\(label)</summary>\n\n"
            + "\(body)\n</details>"

        let (prefix, suffix) = standalonePadding(
            in: ns,
            start: selection.location,
            end: NSMaxRange(selection)
        )

        let insertion = prefix + detailsText + suffix
        let source = ns.replacingCharacters(in: selection, with: insertion)
        let opening = prefix
            + "<details open>\n<summary>\(label)</summary>\n\n"
        let bodyOffset = (opening as NSString).length
        let selectionRange = body.isEmpty
            ? NSRange(location: selection.location + bodyOffset, length: 0)
            : NSRange(location: selection.location + bodyOffset, length: (body as NSString).length)
        return result(
            source,
            selection: selectionRange,
            name: "Details",
            previous: context.source
        )
    }

    private func insertTOC(_ context: MarkdownCommandContext) -> MarkdownCommandResult {
        insertStandaloneBlock(
            "[TOC]",
            name: "Table of Contents",
            context
        )
    }

    // MARK: - Replace all

    private func replaceAll(
        query: String,
        replacement: String,
        caseSensitive: Bool,
        _ context: MarkdownCommandContext
    ) throws -> MarkdownCommandResult {
        guard !query.isEmpty else {
            throw MarkdownCommandError.invalidSelection
        }
        let ns = context.source as NSString
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        let source = ns.replacingOccurrences(
            of: query,
            with: replacement,
            options: options,
            range: NSRange(location: 0, length: ns.length)
        )
        let location = min(context.selection.lowerBound, (source as NSString).length)
        return result(
            source,
            selection: NSRange(location: location, length: 0),
            name: "Replace All",
            previous: context.source
        )
    }

    // MARK: - Details attribute

    private func setDetailsOpen(
        _ open: Bool,
        _ context: MarkdownCommandContext
    ) throws -> MarkdownCommandResult {
        let ns = context.source as NSString
        let selection = try validatedSelection(context)
        guard let tagRange = DetailsParser.enclosingDetailsOpeningTag(
            in: context.source,
            before: selection.location
        ) else {
            throw MarkdownCommandError.detailsNotFound
        }

        let oldTag = ns.substring(with: tagRange)
        var tag = oldTag
        let openRanges = openAttributeRanges(in: oldTag)

        if open {
            if openRanges.isEmpty {
                var insertion = tag.endIndex
                if tag.hasSuffix("/>") {
                    insertion = tag.index(tag.endIndex, offsetBy: -2)
                } else if tag.hasSuffix(">") {
                    insertion = tag.index(before: tag.endIndex)
                }
                tag.insert(contentsOf: " open", at: insertion)
            }
        } else {
            let mutable = NSMutableString(string: tag)
            for range in openRanges.reversed() {
                mutable.deleteCharacters(in: range)
            }
            tag = mutable as String
        }

        let source = ns.replacingCharacters(in: tagRange, with: tag)
        let delta = (tag as NSString).length - tagRange.length
        return result(
            source,
            selection: NSRange(
                location: min(max(0, selection.location + delta),
                              (source as NSString).length),
                length: 0
            ),
            name: open ? "Open Details" : "Close Details",
            previous: context.source
        )
    }

    /// Finds exact `open` attributes, ignoring names that merely contain it
    /// and occurrences inside another attribute's quoted value.
    private func openAttributeRanges(in tag: String) -> [NSRange] {
        let ns = tag as NSString
        var index = 1 // after `<`
        while index < ns.length {
            let character = ns.character(at: index)
            if isTagWhitespace(character) || character == 0x3E || character == 0x2F {
                break
            }
            index += 1
        }

        var ranges: [NSRange] = []
        while index < ns.length {
            while index < ns.length, isTagWhitespace(ns.character(at: index)) {
                index += 1
            }
            guard index < ns.length else { break }
            let character = ns.character(at: index)
            if character == 0x3E { break }
            if character == 0x2F,
               index + 1 < ns.length,
               ns.character(at: index + 1) == 0x3E {
                break
            }

            let nameStart = index
            while index < ns.length, isAttributeNameCharacter(ns.character(at: index)) {
                index += 1
            }
            guard index > nameStart else {
                // Malformed input: make progress rather than loop.
                index += 1
                continue
            }
            let nameEnd = index
            var attributeEnd = nameEnd
            let name = ns.substring(
                with: NSRange(location: nameStart, length: nameEnd - nameStart)
            ).lowercased()

            while index < ns.length, isTagWhitespace(ns.character(at: index)) {
                index += 1
            }
            if index < ns.length, ns.character(at: index) == 0x3D { // =
                index += 1
                while index < ns.length, isTagWhitespace(ns.character(at: index)) {
                    index += 1
                }
                guard index < ns.length else { break }
                let quote = ns.character(at: index)
                if quote == 0x22 || quote == 0x27 {
                    index += 1
                    while index < ns.length, ns.character(at: index) != quote {
                        index += 1
                    }
                    if index < ns.length { index += 1 }
                } else {
                    while index < ns.length,
                          !isTagWhitespace(ns.character(at: index)),
                          ns.character(at: index) != 0x3E {
                        index += 1
                    }
                }
                attributeEnd = index
            }

            if name == "open" {
                var removalStart = nameStart
                while removalStart > 0,
                      isTagWhitespace(ns.character(at: removalStart - 1)) {
                    removalStart -= 1
                }
                // Stop at the attribute name unless a value was consumed;
                // otherwise the whitespace before the next attribute would
                // be removed too.
                ranges.append(
                    NSRange(
                        location: removalStart,
                        length: attributeEnd - removalStart
                    )
                )
            }
        }
        return ranges
    }

    private func isTagWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
            || character == 0x0A || character == 0x0D
    }

    private func isAttributeNameCharacter(_ character: unichar) -> Bool {
        if character >= 0x41, character <= 0x5A { return true }
        if character >= 0x61, character <= 0x7A { return true }
        if character >= 0x30, character <= 0x39 { return true }
        return character == 0x2D || character == 0x5F || character == 0x3A
    }

    private func longestRun(of character: Character, in text: String) -> Int {
        var longest = 0
        var current = 0
        for candidate in text {
            if candidate == character {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private func escapedHTMLText(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.append(character)
            }
        }
        return result
    }

    private func escapedLabel(_ text: String) -> String {
        var result = ""
        for character in text {
            if character == "\\" || character == "[" || character == "]" {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    private func serializedDestination(_ destination: String) -> String {
        guard !destination.isEmpty else { return "" }
        let needsAngleBrackets = destination.rangeOfCharacter(
            from: .whitespacesAndNewlines
        ) != nil || destination.contains("(") || destination.contains(")")

        if needsAngleBrackets {
            let escaped = destination
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "<", with: "\\<")
                .replacingOccurrences(of: ">", with: "\\>")
                .replacingOccurrences(of: "&", with: "\\&")
            return "<\(escaped)>"
        }
        return destination
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "<", with: "\\<")
            .replacingOccurrences(of: ">", with: "\\>")
            .replacingOccurrences(of: "&", with: "\\&")
    }
}
