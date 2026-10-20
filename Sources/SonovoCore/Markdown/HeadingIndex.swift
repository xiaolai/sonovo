import Foundation

/// Allocates globally unique heading slugs.
///
/// The index and the details reconciler must agree on a heading's slug, so
/// both use this one allocator. Caching the next suffix per base keeps a
/// document with many identical headings linear instead of rescanning from
/// zero for each one.
struct SlugAllocator {
    private var used: Set<String> = []
    private var nextSuffix: [String: Int] = [:]

    mutating func allocate(for text: String) -> String? {
        guard let base = HeadingIndex.slug(for: text) else { return nil }
        var suffix = nextSuffix[base, default: 0]
        var candidate = suffix == 0 ? base : "\(base)-\(suffix)"
        while used.contains(candidate) {
            suffix += 1
            candidate = "\(base)-\(suffix)"
        }
        nextSuffix[base] = suffix + 1
        used.insert(candidate)
        return candidate
    }
}

/// One heading in document order.
public struct HeadingEntry: Sendable, Equatable {
    public let level: Int
    public let text: String
    /// The globally unique slug, or `nil` when the heading text produces an
    /// empty slug.
    public let slug: String?
    /// The 0-based occurrence index among headings sharing the same base slug.
    public let occurrence: Int
    public let range: SourceRange?
    public let isInsideDetails: Bool

    public init(
        level: Int,
        text: String,
        slug: String?,
        occurrence: Int,
        range: SourceRange?,
        isInsideDetails: Bool
    ) {
        self.level = level
        self.text = text
        self.slug = slug
        self.occurrence = occurrence
        self.range = range
        self.isInsideDetails = isInsideDetails
    }

    /// The scroll target for this heading, regenerated from the current tree.
    public var scrollID: String? {
        guard let slug else { return nil }
        return "\(slug)#\(occurrence)"
    }
}

/// One rendered table-of-contents row.
public struct TOCRow: Sendable, Equatable {
    public let level: Int
    public let indent: Int
    public let text: String
    public let slug: String?
    public let occurrence: Int
    public let range: SourceRange?
    public let isInsideDetails: Bool

    public var scrollID: String? {
        guard let slug else { return nil }
        return "\(slug)#\(occurrence)"
    }
}

/// The document-wide heading index.
///
/// The index is never truncated. Only the rendered rows are capped by
/// `MarkdownLimits.maxTOCEntries`; fragment lookup always sees every heading.
public struct HeadingIndex: Sendable, Equatable {
    public let headings: [HeadingEntry]
    public let rows: [TOCRow]
    public let totalRowCount: Int
    public let shallowestLevel: Int?

    public init(ast: SonovoAST, maxRows: Int = MarkdownLimits.maxTOCEntries) {
        var entries: [HeadingEntry] = []
        var allocator = SlugAllocator()
        var occurrences: [String: Int] = [:]

        Self.walk(ast.blocks, insideDetails: false) { level, inlines, range, insideDetails in
            let text = Self.renderedText(inlines)
            let base = Self.slug(for: text)
            var slug: String?
            var occurrence = 0

            if let base {
                occurrence = occurrences[base, default: 0]
                occurrences[base] = occurrence + 1
                slug = allocator.allocate(for: text)
            }

            entries.append(
                HeadingEntry(
                    level: level,
                    text: text,
                    slug: slug,
                    occurrence: occurrence,
                    range: range,
                    isInsideDetails: insideDetails
                )
            )
        }

        let shallowest = entries.map(\.level).min()
        let allRows = entries.map { entry in
            TOCRow(
                level: entry.level,
                indent: max(0, entry.level - (shallowest ?? entry.level)),
                text: entry.text,
                slug: entry.slug,
                occurrence: entry.occurrence,
                range: entry.range,
                isInsideDetails: entry.isInsideDetails
            )
        }

        self.headings = entries
        self.shallowestLevel = shallowest
        self.totalRowCount = allRows.count
        self.rows = Array(allRows.prefix(max(0, maxRows)))
    }

    /// Resolves a `[[Page#Fragment]]` fragment.
    public func heading(forFragment fragment: String) -> HeadingEntry? {
        if let exact = headings.first(where: { $0.slug == fragment }) {
            return exact
        }
        guard let slug = Self.slug(for: fragment) else { return nil }
        return headings.first { $0.slug == slug }
    }

    /// Rendered heading text: links use their label, code its content, wiki
    /// links their display text, and images contribute nothing.
    public static func renderedText(_ inlines: [Inline]) -> String {
        var result = ""
        for inline in inlines {
            switch inline {
            case let .text(value, _):
                result += value
            case .softBreak, .lineBreak:
                result += " "
            case let .inlineCode(value, _):
                result += value
            case let .emphasis(children, _),
                 let .strong(children, _),
                 let .strikethrough(children, _):
                result += renderedText(children)
            case let .link(_, _, children, _):
                result += renderedText(children)
            case .image:
                continue
            case .inlineHTML:
                continue
            case let .wikiLink(link, _):
                result += link.display
            }
        }
        return result
    }

    /// Slug rules: lowercase; keep letters, marks, numbers, `_`, and `-`;
    /// whitespace becomes a hyphen; collapse and trim hyphens.
    public static func slug(for text: String) -> String? {
        var scalars: [UnicodeScalar] = []
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.letters.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar) {
                scalars.append(scalar)
            } else if scalar == "_" {
                scalars.append(scalar)
            } else if scalar == "-" || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                scalars.append("-")
            }
        }

        var collapsed = ""
        var previousHyphen = true
        for scalar in scalars {
            if scalar == "-" {
                if previousHyphen { continue }
                previousHyphen = true
                collapsed.unicodeScalars.append(scalar)
            } else {
                previousHyphen = false
                collapsed.unicodeScalars.append(scalar)
            }
        }
        while collapsed.hasSuffix("-") { collapsed.removeLast() }
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func walk(
        _ blocks: [Block],
        insideDetails: Bool,
        visit: (Int, [Inline], SourceRange?, Bool) -> Void
    ) {
        for block in blocks {
            switch block {
            case let .heading(level, inlines, range):
                visit(level, inlines, range, insideDetails)
            case let .blockQuote(children, _):
                walk(children, insideDetails: insideDetails, visit: visit)
            case let .list(list, _):
                for item in list.items {
                    walk(item.blocks, insideDetails: insideDetails, visit: visit)
                }
            case let .details(details, _):
                walk(details.blocks, insideDetails: true, visit: visit)
            default:
                continue
            }
        }
    }
}
