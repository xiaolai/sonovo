import Foundation

/// The content identity of one details block.
///
/// Position is deliberately absent: blocks are matched by content so an edit
/// that prepends or reorders content cannot move expansion state onto a
/// different block.
public struct DetailsContentKey: Sendable, Equatable, Hashable {
    /// The nearest preceding heading's slug, when one exists.
    public let anchorSlug: String?
    public let summaryHash: UInt64
    public let bodyHash: UInt64
    public let authoredOpen: Bool

    public init(
        anchorSlug: String?,
        summaryHash: UInt64,
        bodyHash: UInt64,
        authoredOpen: Bool
    ) {
        self.anchorSlug = anchorSlug
        self.summaryHash = summaryHash
        self.bodyHash = bodyHash
        self.authoredOpen = authoredOpen
    }
}

/// Reconciles details expansion across a reparse.
///
/// The cascade requires a unique match in both the old and new trees at every
/// tier:
/// 1. `(anchor heading slug, summary hash, body hash)`
/// 2. unique `body hash` globally (heading rename)
/// 3. `(anchor, summary hash)` only when exactly one old and one new remain
/// 4. `summary hash` only when exactly one old and one new remain
///
/// An ambiguous class is reset to its authored `open` value as a group and is
/// excluded from weaker tiers. A newcomer never inherits an old block's state.
public enum DetailsExpansionReconciler {
    public static func keys(for ast: SonovoAST) -> [DetailsContentKey] {
        var keys: [DetailsContentKey] = []
        var allocator = SlugAllocator()
        walk(
            ast.blocks,
            anchor: nil,
            allocator: &allocator,
            keys: &keys
        )
        return keys
    }

    public static func reconcile(
        old: [DetailsContentKey],
        oldExpansion: [Bool],
        new: [DetailsContentKey]
    ) -> [Bool] {
        precondition(
            old.count == oldExpansion.count,
            "oldExpansion must have one value per old key"
        )
        var result: [Bool?] = Array(repeating: nil, count: new.count)
        var matchedOld = Set<Int>()
        var matchedNew = Set<Int>()
        var excludedOld = Set<Int>()
        var excludedNew = Set<Int>()

        func group<T: Hashable>(_ values: [T], indices: [Int]) -> [T: [Int]] {
            var grouped: [T: [Int]] = [:]
            for index in indices {
                grouped[values[index], default: []].append(index)
            }
            return grouped
        }

        func applyTier<T: Hashable>(
            _ oldValues: [T],
            _ newValues: [T]
        ) {
            let oldIndices = old.indices.filter {
                !matchedOld.contains($0) && !excludedOld.contains($0)
            }
            let newIndices = new.indices.filter {
                !matchedNew.contains($0) && !excludedNew.contains($0)
            }
            guard !oldIndices.isEmpty, !newIndices.isEmpty else { return }

            let oldGroups = group(oldValues, indices: oldIndices)
            let newGroups = group(newValues, indices: newIndices)

            for (key, oldGroup) in oldGroups {
                guard let newGroup = newGroups[key] else { continue }
                if oldGroup.count == 1, newGroup.count == 1 {
                    matchedOld.insert(oldGroup[0])
                    matchedNew.insert(newGroup[0])
                    result[newGroup[0]] = oldExpansion[oldGroup[0]]
                } else {
                    // Ambiguous class: reset as a group and exclude from
                    // weaker tiers.
                    for index in oldGroup { excludedOld.insert(index) }
                    for index in newGroup {
                        excludedNew.insert(index)
                        result[index] = new[index].authoredOpen
                    }
                }
            }
        }

        struct FullKey: Hashable {
            let anchor: String?
            let summary: UInt64
            let body: UInt64
        }

        applyTier(
            old.map { FullKey(anchor: $0.anchorSlug, summary: $0.summaryHash, body: $0.bodyHash) },
            new.map { FullKey(anchor: $0.anchorSlug, summary: $0.summaryHash, body: $0.bodyHash) }
        )
        applyTier(old.map(\.bodyHash), new.map(\.bodyHash))

        // Tier 3: only when exactly one old and one new remain.
        let remainingOld = old.indices.filter {
            !matchedOld.contains($0) && !excludedOld.contains($0)
        }
        let remainingNew = new.indices.filter {
            !matchedNew.contains($0) && !excludedNew.contains($0)
        }
        if remainingOld.count == 1, remainingNew.count == 1,
           old[remainingOld[0]].anchorSlug == new[remainingNew[0]].anchorSlug,
           old[remainingOld[0]].summaryHash == new[remainingNew[0]].summaryHash {
            matchedOld.insert(remainingOld[0])
            matchedNew.insert(remainingNew[0])
            result[remainingNew[0]] = oldExpansion[remainingOld[0]]
        } else if remainingOld.count != 1 || remainingNew.count != 1 {
            // Only an ambiguous group is excluded from weaker tiers. A
            // unique old/new pair whose anchor changed must remain available
            // to Tier 4's summary-only match.
            for index in remainingOld { excludedOld.insert(index) }
            for index in remainingNew where result[index] == nil {
                excludedNew.insert(index)
            }
        }

        // Tier 4: only when exactly one old and one new remain.
        let finalOld = old.indices.filter {
            !matchedOld.contains($0) && !excludedOld.contains($0)
        }
        let finalNew = new.indices.filter {
            !matchedNew.contains($0) && !excludedNew.contains($0)
        }
        if finalOld.count == 1, finalNew.count == 1,
           old[finalOld[0]].summaryHash == new[finalNew[0]].summaryHash {
            matchedOld.insert(finalOld[0])
            matchedNew.insert(finalNew[0])
            result[finalNew[0]] = oldExpansion[finalOld[0]]
        }

        return new.indices.map { index in
            result[index] ?? new[index].authoredOpen
        }
    }

    // MARK: - Walking

    /// Returns the nearest heading seen in this subtree so a heading inside a
    /// blockquote or list item can anchor a following sibling.
    @discardableResult
    private static func walk(
        _ blocks: [Block],
        anchor: String?,
        allocator: inout SlugAllocator,
        keys: inout [DetailsContentKey]
    ) -> String? {
        var currentAnchor = anchor

        for block in blocks {
            switch block {
            case let .heading(_, inlines, _):
                let text = HeadingIndex.renderedText(inlines)
                if let slug = allocator.allocate(for: text) {
                    currentAnchor = slug
                }
            case let .details(details, _):
                keys.append(
                    DetailsContentKey(
                        anchorSlug: currentAnchor,
                        summaryHash: hash(HeadingIndex.renderedText(details.summary)),
                        bodyHash: hash(canonical(details.blocks)),
                        authoredOpen: details.isOpen
                    )
                )
                // Details content is a scoping boundary; its headings do not
                // anchor siblings outside the block.
                _ = walk(
                    details.blocks,
                    anchor: currentAnchor,
                    allocator: &allocator,
                    keys: &keys
                )
            case let .blockQuote(children, _):
                currentAnchor = walk(
                    children,
                    anchor: currentAnchor,
                    allocator: &allocator,
                    keys: &keys
                ) ?? currentAnchor
            case let .list(list, _):
                for item in list.items {
                    currentAnchor = walk(
                        item.blocks,
                        anchor: currentAnchor,
                        allocator: &allocator,
                        keys: &keys
                    ) ?? currentAnchor
                }
            default:
                continue
            }
        }
        return currentAnchor
    }

    // MARK: - Stable hashing

    /// FNV-1a 64 over UTF-8. Swift's `Hasher` is seeded per process and is not
    /// stable across launches.
    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        return value
    }

    static func canonical(_ blocks: [Block]) -> String {
        var result = ""
        for block in blocks {
            result += canonical(block)
            result += "\u{1F}"
        }
        return result
    }

    private static func canonical(_ block: Block) -> String {
        switch block {
        case let .paragraph(inlines, _):
            return "p:" + canonical(inlines)
        case let .heading(level, inlines, _):
            return "h\(level):" + canonical(inlines)
        case let .blockQuote(children, _):
            return "q:" + canonical(children)
        case let .list(list, _):
            let kind: String
            switch list.kind {
            case .bullet: kind = "b"
            case .ordered(let start): kind = "o\(start)"
            }
            return "l\(kind):" + list.items.map {
                canonical($0.blocks) + ($0.checked.map { $0 ? "x" : "o" } ?? "-")
            }.joined(separator: ",")
        case let .codeBlock(code, _):
            let language = code.language ?? ""
            return "c:\(code.fenced):\(language.utf8.count):\(language):"
                + "\(code.code.utf8.count):\(code.code)"
        case let .htmlBlock(raw, _):
            return "html:\(raw.utf8.count):\(raw)"
        case .thematicBreak:
            return "hr"
        case let .table(table, _):
            // Length-prefixed fields and explicit counts: joining cells with
            // a delimiter alone lets one empty row collide with no rows, and
            // lets delimiter characters inside cells shift boundaries.
            let alignments = encodeList(table.alignments.map(\.rawValue))
            let header = encodeList(
                table.header.map { canonical($0.inlines) }
            )
            let rows = "\(table.rows.count):" + table.rows.map { row in
                encodeList(row.map { canonical($0.inlines) })
            }.joined()
            return "t:\(alignments)\(header)\(rows)"
        case let .details(details, _):
            return "d:\(details.isOpen):" + canonical(details.summary)
                + ":" + canonical(details.blocks)
        case .tableOfContents:
            return "toc"
        }
    }

    /// Encodes a list as a count followed by length-prefixed elements, so no
    /// element's content can be mistaken for a separator or another count.
    private static func encodeList(_ values: [String]) -> String {
        "\(values.count):" + values.map {
            "\($0.utf8.count):\($0)"
        }.joined()
    }

    private static func canonical(_ inlines: [Inline]) -> String {
        inlines.map { inline in
            switch inline {
            case let .text(value, _):
                return "t:\(value.utf8.count):\(value)"
            case .softBreak: return "sb"
            case .lineBreak: return "lb"
            case let .inlineCode(value, _):
                return "c:\(value.utf8.count):\(value)"
            case let .emphasis(children, _): return "e(" + canonical(children) + ")"
            case let .strong(children, _): return "s(" + canonical(children) + ")"
            case let .strikethrough(children, _): return "d(" + canonical(children) + ")"
            case let .link(destination, title, children, _):
                let titleValue = title ?? ""
                return "a:\(destination.utf8.count):\(destination):"
                    + "\(titleValue.utf8.count):\(titleValue):("
                    + canonical(children) + ")"
            case let .image(destination, title, description, _):
                let titleValue = title ?? ""
                return "i:\(destination.utf8.count):\(destination):"
                    + "\(titleValue.utf8.count):\(titleValue):("
                    + canonical(description) + ")"
            case let .inlineHTML(raw, _):
                return "h:\(raw.utf8.count):\(raw)"
            case let .wikiLink(link, _):
                let fragment = link.fragment ?? ""
                let alias = link.alias ?? ""
                return "w:\(link.target.utf8.count):\(link.target):"
                    + "\(fragment.utf8.count):\(fragment):"
                    + "\(alias.utf8.count):\(alias)"
            }
        }.joined(separator: "\u{1E}")
    }
}
