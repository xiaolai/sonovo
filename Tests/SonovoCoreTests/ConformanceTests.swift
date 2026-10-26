import Foundation
import Testing
import ReferenceAst
@testable import SonovoCore

/// Compares the base `SonovoAST` with the pinned cmark-gfm reference oracle.
///
/// Both sides are projected to the same JSON-shaped dictionary. Keys the app
/// model deliberately does not carry (list marker style, fence geometry) are
/// removed from both sides before comparison. Everything else — node kind,
/// literal, source positions, heading level, list start/tightness, link and
/// image destination/title, table alignment and header state, task state — is
/// compared exactly.
@Suite("Base parser conformance")
struct ConformanceTests {
    static func fixtures() throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    }

    static func commonMarkExamples() throws -> [[String: Any]] {
        let url = try fixtures().appendingPathComponent("cm/spec.json")
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    /// Accepted divergences from CommonMark, each with an exact signature.
    ///
    /// The signature is the sorted set of differing JSON paths. A declared
    /// example that no longer differs fails the gate as stale, so the ledger
    /// cannot rot silently.
    static let acceptedDivergences: [Int: (reason: String, paths: [String])] = [
        96: (
            "Leading `---`/`---` is YAML frontmatter in Sonovo; CommonMark parses it as thematic breaks and a setext heading.",
            ["$.children[0].children", "$.children[0].endLine", "$.children[0].endUtf16"]
        ),
        98: (
            "Leading `---`/`---` is empty YAML frontmatter in Sonovo; CommonMark parses two thematic breaks.",
            ["$.children[0].children", "$.children[0].endLine", "$.children[0].endUtf16"]
        )
    ]

    @Test("CommonMark 0.31.2 conformance")
    func commonMarkConformance() throws {
        let examples = try Self.commonMarkExamples()
        var failures: [String] = []
        var seenDivergences: Set<Int> = []

        for (index, example) in examples.enumerated() {
            let markdown = try #require(example["markdown"] as? String)
            let parsed = MarkdownParser.parseCanonical(markdown, enableAutolinks: false)
            let ours: [String: Any] = [
                "children": [ConformanceProjection.project(parsed)]
            ]
            let oracleData = try ReferenceAst.projection(for: markdown, options: ReferenceAstOptions(enableAutolinks: false))
            let oracle = try #require(
                JSONSerialization.jsonObject(with: oracleData) as? [String: Any]
            )

            let normalizedOurs = ConformanceProjection.normalize(ours)
            let normalizedOracle = ConformanceProjection.normalize(oracle)
            let differences = ConformanceProjection.differences(
                normalizedOurs,
                normalizedOracle,
                path: "$"
            )
            let exampleNumber = index + 1
            if let accepted = Self.acceptedDivergences[exampleNumber],
               !differences.isEmpty {
                seenDivergences.insert(exampleNumber)
                let unexpected = differences.filter { difference in
                    let path = String(difference.split(separator: ":", maxSplits: 1)[0])
                    return !accepted.paths.contains { path.hasPrefix($0) }
                }
                if !unexpected.isEmpty {
                    failures.append(
                        "example \(exampleNumber): divergence signature changed\n"
                            + unexpected.prefix(3).joined(separator: "\n")
                    )
                }
                continue
            }

            if !differences.isEmpty {
                if failures.count < 8,
                   ProcessInfo.processInfo.environment["SONOVO_DUMP_CONFORMANCE"] != nil {
                    let base = "/tmp/conformance-\(index + 1)"
                    try JSONSerialization.data(withJSONObject: ours, options: [.prettyPrinted, .sortedKeys])
                        .write(to: URL(fileURLWithPath: base + "-ours.json"))
                    try JSONSerialization.data(withJSONObject: oracle, options: [.prettyPrinted, .sortedKeys])
                        .write(to: URL(fileURLWithPath: base + "-oracle.json"))
                }
                failures.append(
                    "example \(index + 1): \(markdown.debugDescription)\n"
                        + differences.prefix(3).joined(separator: "\n")
                )
            }
        }

        let stale = Set(Self.acceptedDivergences.keys).subtracting(seenDivergences)
        if !stale.isEmpty {
            failures.append("Stale divergence declarations: \(stale.sorted())")
        }

        if !failures.isEmpty {
            print("Conformance failures: \(failures.count) of \(examples.count)")
            for failure in failures.prefix(5) {
                print(failure)
                print("---")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) conformance failures")
    }
}

enum ConformanceProjection {
    static func project(_ parsed: ParsedMarkdown) -> [String: Any] {
        let context = Context(source: parsed.source, map: parsed.fullSourceMap)
        // cmark's document range ends at the last block or reference
        // definition, so trailing whitespace and blank lines do not extend it.
        let blockEnd = parsed.ast.blocks.last?.range?.upperBound ?? 0
        let definitionEnd = parsed.ast.referenceDefinitions.last?.range?.upperBound ?? 0
        var endOffset = max(blockEnd, definitionEnd)

        // A trailing whitespace-only line, or a trailing HTML block whose
        // cmark source position stops early, extends the document to the end
        // of the file minus its final newline.
        let withoutFinalNewline = parsed.source.hasSuffix("\n")
            ? String(parsed.source.dropLast())
            : parsed.source
        let lastLine = withoutFinalNewline.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).last ?? ""
        let lastLineIsWhitespace = lastLine.allSatisfy {
            $0 == " " || $0 == "\t" || $0 == "\r"
        }
        if lastLineIsWhitespace || isTrailingHTMLBlock(parsed.ast.blocks.last) {
            endOffset = max(endOffset, withoutFinalNewline.utf16.count)
        }
        let end = parsed.fullSourceMap.position(atUTF16Offset: endOffset)
            ?? SourcePosition(line: 1, column: 0, offset: 0)
        return [
            "kind": "document",
            "literal": NSNull(),
            "startLine": 1,
            "startUtf16": 0,
            "endLine": end.line,
            "endUtf16": end.offset,
            "children": parsed.ast.blocks.map { projectBlock($0, context: context) }
        ]
    }

    struct Context {
        let source: String
        let map: SourceMap

        func lineRange(_ line: Int) -> SourceRange? {
            guard let text = map.lineText(line),
                  let start = map.utf16Offset(line: line, utf8Column: 1),
                  let startPosition = map.position(atUTF16Offset: start) else {
                return nil
            }
            let endOffset = start + text.utf16.count
            guard let endPosition = map.position(atUTF16Offset: endOffset) else {
                return nil
            }
            return SourceRange(start: startPosition, end: endPosition)
        }
    }

    // MARK: Blocks

    static func projectBlock(_ block: Block, context: Context) -> [String: Any] {
        var node = base(kind: kind(of: block), range: block.range)

        switch block {
        case let .paragraph(inlines, _):
            node["children"] = inlines.map(projectInline)
        case let .heading(level, inlines, _):
            node["headingLevel"] = level
            node["children"] = inlines.map(projectInline)
        case let .blockQuote(blocks, _):
            node["children"] = blocks.map { projectBlock($0, context: context) }
        case let .list(list, _):
            node["listType"] = kind(of: list.kind)
            switch list.kind {
            case .bullet:
                node["listStart"] = 0
            case .ordered(let start):
                node["listStart"] = start
            }
            if let tight = list.tight {
                node["listTight"] = tight
            }
            node["children"] = list.items.map { projectListItem($0, context: context) }
        case let .codeBlock(code, _):
            node["literal"] = code.code
        case let .htmlBlock(raw, _):
            node["literal"] = raw
        case .thematicBreak:
            break
        case let .table(table, range):
            node["tableColumns"] = table.alignments.count
            node["tableAlignments"] = table.alignments.map(\.rawValue)
            var children: [[String: Any]] = []

            let headerLine = range?.start.line
            let headerRange = headerLine.flatMap { context.lineRange($0) }
            var header = base(kind: "table_header", range: headerRange)
            header["children"] = table.header.map(projectCell)
            children.append(header)

            for (index, row) in table.rows.enumerated() {
                let rowRange: SourceRange?
                if let headerLine {
                    rowRange = context.lineRange(headerLine + 2 + index)
                } else {
                    rowRange = nil
                }
                var rowNode = base(kind: "table_row", range: rowRange)
                rowNode["tableRowIsHeader"] = false
                rowNode["children"] = row.map(projectCell)
                children.append(rowNode)
            }
            node["children"] = children
        case let .definitionList(list, _):
            node["children"] = list.items.flatMap { item in
                item.terms.map { term in
                    var child = base(
                        kind: "definition_term",
                        range: term.range
                    )
                    child["children"] = term.inlines.map(projectInline)
                    return child
                } + item.definitions.map { definition in
                    var child = base(
                        kind: "definition_definition",
                        range: definition.range
                    )
                    child["children"] = definition.inlines.map(projectInline)
                    return child
                }
            }
        case let .details(details, _):
            node["detailsOpen"] = details.isOpen
            node["children"] = details.blocks.map { projectBlock($0, context: context) }
        case .tableOfContents:
            node["children"] = [Any]()
        case let .footnoteDefinition(label, _):
            node["literal"] = label
        case let .footnotes(section, _):
            node["children"] = section.entries.map { entry in
                var child = base(kind: "footnote", range: entry.contentRange)
                child["literal"] = entry.number
                child["children"] = entry.inlines.map(projectInline)
                return child
            }
        }

        return node
    }

    static func projectListItem(_ item: ListItem, context: Context) -> [String: Any] {
        var node = base(
            kind: item.checked == nil ? "item" : "tasklist",
            range: item.range
        )
        if let checked = item.checked {
            node["taskChecked"] = checked
        }
        node["children"] = item.blocks.map { projectBlock($0, context: context) }
        return node
    }

    static func projectCell(_ cell: TableCell) -> [String: Any] {
        var node = base(kind: "table_cell", range: cell.range)
        node["children"] = cell.inlines.map(projectInline)
        return node
    }

    // MARK: Inlines

    static func projectInline(_ inline: Inline) -> [String: Any] {
        var node = base(kind: kind(of: inline), range: inline.range)

        switch inline {
        case let .text(value, _):
            node["literal"] = value
        case .softBreak, .lineBreak:
            break
        case let .inlineCode(value, _):
            node["literal"] = value
        case let .emphasis(inlines, _), let .strong(inlines, _), let .strikethrough(inlines, _):
            node["children"] = inlines.map(projectInline)
        case let .link(destination, title, inlines, _):
            node["destination"] = destination
            node["title"] = title ?? NSNull()
            node["children"] = inlines.map(projectInline)
        case let .image(destination, title, description, _):
            node["destination"] = destination
            node["title"] = title ?? NSNull()
            node["children"] = description.map(projectInline)
        case let .inlineHTML(value, _):
            node["literal"] = value
        case let .wikiLink(link, _):
            node["literal"] = link.display
        case let .footnoteReference(reference, _):
            node["literal"] = "\(reference.number)"
            node["footnoteLabel"] = reference.label
        case let .math(source, _, _, _):
            node["literal"] = source
        }

        return node
    }

    static func kind(of block: Block) -> String {
        switch block {
        case .paragraph: "paragraph"
        case .heading: "heading"
        case .blockQuote: "block_quote"
        case .list: "list"
        case .codeBlock: "code_block"
        case .htmlBlock: "html_block"
        case .thematicBreak: "thematic_break"
        case .table: "table"
        case .definitionList: "definition_list"
        case .details: "details"
        case .tableOfContents: "table_of_contents"
        case .footnoteDefinition: "footnote_definition"
        case .footnotes: "footnotes"
        }
    }

    static func kind(of list: ListBlock.Kind) -> String {
        switch list {
        case .bullet: "bullet"
        case .ordered: "ordered"
        }
    }

    static func kind(of inline: Inline) -> String {
        switch inline {
        case .text: "text"
        case .softBreak: "softbreak"
        case .lineBreak: "linebreak"
        case .inlineCode: "code"
        case .emphasis: "emph"
        case .strong: "strong"
        case .strikethrough: "strikethrough"
        case .link: "link"
        case .image: "image"
        case .inlineHTML: "html_inline"
        case .wikiLink: "wiki_link"
        case .footnoteReference: "footnote_reference"
        case .math: "math"
        }
    }

    static func isTrailingHTMLBlock(_ block: Block?) -> Bool {
        if case .htmlBlock = block { return true }
        return false
    }

    static func base(kind: String, range: SourceRange?) -> [String: Any] {
        [
            "kind": kind,
            "literal": NSNull(),
            "startLine": range?.start.line ?? NSNull(),
            "startUtf16": range?.lowerBound ?? NSNull(),
            "endLine": range?.end.line ?? NSNull(),
            "endUtf16": range?.upperBound ?? NSNull(),
            "children": [Any]()
        ]
    }

    // MARK: Normalization and comparison

    static let ignoredKeys: Set<String> = [
        // Not exposed by swift-markdown; source style is preserved verbatim
        // rather than modeled.
        "listDelimiter",
        "listMarker",
        // Fence geometry is lexical; the model carries fenced/info only.
        "fenced",
        "fenceLength",
        "fenceOffset",
        "fenceCharacter",
        "fenceInfo"
    ]

    /// Node kinds whose upstream range swift-markdown omits even though
    /// cmark reports one. The divergence is recorded here rather than guessed.
    static let ignoredPositionKinds: Set<String> = ["softbreak", "linebreak"]

    /// cmark's autolink extension reports a source position that can include
    /// the preceding character or be null. The semantic identity is the
    /// destination and display text, so positions are ignored for autolinks.
    static func isAutolinkNode(_ dictionary: [String: Any]) -> Bool {
        guard dictionary["kind"] as? String == "link",
              let destination = dictionary["destination"] as? String,
              let children = dictionary["children"] as? [Any],
              children.count == 1,
              let child = children[0] as? [String: Any],
              child["kind"] as? String == "text",
              let literal = child["literal"] as? String else {
            return false
        }
        return destination == literal
            || destination == "http://" + literal
            || destination == "mailto:" + literal
    }

    static func normalize(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            let kind = dictionary["kind"] as? String ?? ""
            let autolink = isAutolinkNode(dictionary)
            for (key, child) in dictionary where !ignoredKeys.contains(key) {
                if ignoredPositionKinds.contains(kind) || autolink,
                   ["startLine", "startUtf16", "endLine", "endUtf16"].contains(key) {
                    continue
                }
                if key == "title", let title = child as? String, title.isEmpty {
                    result[key] = NSNull()
                    continue
                }
                result[key] = normalize(child)
            }
            return result
        }
        if let array = value as? [Any] {
            // cmark's autolink extension sometimes emits empty text nodes;
            // they carry no semantics and would otherwise force structural
            // mismatches.
            let filtered = array
                .map(normalize)
                .filter { child in
                    guard let dictionary = child as? [String: Any],
                          dictionary["kind"] as? String == "text",
                          let literal = dictionary["literal"] as? String else {
                        return true
                    }
                    return !literal.isEmpty
                }

            // cmark's autolink extension may split adjacent text into several
            // nodes. Merge them; segmentation is not semantic.
            var merged: [Any] = []
            for child in filtered {
                if let dictionary = child as? [String: Any],
                   dictionary["kind"] as? String == "text",
                   let last = merged.last as? [String: Any],
                   last["kind"] as? String == "text" {
                    var combined = last
                    combined["literal"] =
                        (last["literal"] as? String ?? "")
                        + (dictionary["literal"] as? String ?? "")
                    combined["startLine"] = last["startLine"] ?? NSNull()
                    combined["startUtf16"] = last["startUtf16"] ?? NSNull()
                    combined["endLine"] = dictionary["endLine"] ?? NSNull()
                    combined["endUtf16"] = dictionary["endUtf16"] ?? NSNull()
                    merged[merged.count - 1] = combined
                } else {
                    merged.append(child)
                }
            }
            return merged
        }
        return value
    }

    static func differences(_ lhs: Any, _ rhs: Any, path: String) -> [String] {
        if let left = lhs as? [String: Any], let right = rhs as? [String: Any] {
            var result: [String] = []
            let keys = Set(left.keys).union(right.keys).sorted()
            for key in keys {
                let leftValue = left[key] ?? "<absent>"
                let rightValue = right[key] ?? "<absent>"
                result.append(
                    contentsOf: differences(
                        leftValue,
                        rightValue,
                        path: "\(path).\(key)"
                    )
                )
            }
            return result
        }

        if let left = lhs as? [Any], let right = rhs as? [Any] {
            if left.count != right.count {
                return ["\(path): child count \(left.count) != \(right.count)"]
            }
            var result: [String] = []
            for index in left.indices {
                result.append(
                    contentsOf: differences(
                        left[index],
                        right[index],
                        path: "\(path)[\(index)]"
                    )
                )
            }
            return result
        }

        if let left = lhs as? NSNumber, let right = rhs as? NSNumber {
            return left == right ? [] : ["\(path): \(left) != \(right)"]
        }
        if let left = lhs as? String, let right = rhs as? String {
            return left == right ? [] : ["\(path): \(left.debugDescription) != \(right.debugDescription)"]
        }
        if lhs is NSNull, rhs is NSNull {
            return []
        }
        return ["\(path): \(lhs) != \(rhs)"]
    }
}
