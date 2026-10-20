import Foundation
import cmark_gfm
import cmark_gfm_extensions

// A conformance oracle for the Markdown core.
//
// This library parses Markdown with the exact pinned cmark-gfm C API and emits
// a complete semantic projection. It deliberately does not use
// `swift-markdown` or any Sonovo code: the gate must be able to disagree with
// the implementation under test.
//
// Source positions are reported as UTF-16 offsets into the canonical LF input,
// so they can be compared directly with `SonovoAST` ranges. Input is
// canonicalized here exactly as the app canonicalizes it: a leading BOM is
// removed and CRLF and lone CR become LF.

/// Errors raised while reading or parsing reference input.
public enum ReferenceAstError: Error, CustomStringConvertible {
    case unreadableInput(String)
    case missingSyntaxExtension(String)
    case parserInitializationFailed
    case parseFailed

    public var description: String {
        switch self {
        case .unreadableInput(let path):
            return "cannot read \(path) as UTF-8"
        case .missingSyntaxExtension(let name):
            return "cannot attach cmark-gfm syntax extension \(name)"
        case .parserInitializationFailed:
            return "cannot create a cmark-gfm parser"
        case .parseFailed:
            return "cmark-gfm failed to parse the document"
        }
    }
}

/// Options for the reference projection.
public struct ReferenceAstOptions: Sendable {
    /// Attach the GFM autolink extension. CommonMark-only gates disable it.
    public var enableAutolinks: Bool

    public init(enableAutolinks: Bool = true) {
        self.enableAutolinks = enableAutolinks
    }
}

/// Produces the cmark-gfm semantic projection for a Markdown string.
public enum ReferenceAst {
    /// Parses `source` and returns the projection as sorted, pretty-printed JSON.
    public static func projection(
        for source: String,
        options: ReferenceAstOptions = ReferenceAstOptions()
    ) throws -> Data {
        let canonical = canonicalize(source)
        let roots = try buildDocument(source: canonical, options: options)
        let output: [String: Any] = ["children": roots]
        return try JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Parses the file at `path` and returns the projection as JSON.
    public static func projection(
        forFileAt path: String,
        options: ReferenceAstOptions = ReferenceAstOptions()
    ) throws -> Data {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ReferenceAstError.unreadableInput(path)
        }
        return try projection(for: text, options: options)
    }

    /// Mirrors the app's canonical form: BOM-free, LF-only. cmark treats CR
    /// as a line ending, so passing raw input through would make every
    /// position after the first line disagree with the app's source map.
    static func canonicalize(_ source: String) -> String {
        var text = source
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

/// Converts byte columns reported by cmark to UTF-16 offsets.
///
/// cmark's `SourceLocation.column` is a 1-based byte offset into a line, and
/// the end column is inclusive. The conversion is done here, independently of
/// `SonovoCore.SourceMap`, so a mapping defect in the core cannot hide itself.
struct UTF16PositionMapper {
    private struct LineMap {
        /// UTF-16 offset of the line's first character in the full source.
        let baseUTF16: Int
        let byteCount: Int
        /// `(byte offset, UTF-16 offset)` at each scalar boundary, ascending.
        /// Empty for ASCII lines, where the two offsets are identical.
        let boundaries: [(byte: Int, utf16: Int)]
    }

    private let lineMaps: [LineMap]

    init(source: String) {
        let rawLines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var maps: [LineMap] = []
        maps.reserveCapacity(rawLines.count)
        var running = 0
        for line in rawLines {
            let byteCount = line.utf8.count
            let isASCII = line.utf8.allSatisfy { $0 < 0x80 }
            var boundaries: [(byte: Int, utf16: Int)] = []
            if !isASCII {
                boundaries.reserveCapacity(byteCount + 1)
                boundaries.append((0, 0))
                var byte = 0
                var utf16 = 0
                for scalar in line.unicodeScalars {
                    byte += scalar.utf8.count
                    utf16 += scalar.value > 0xFFFF ? 2 : 1
                    boundaries.append((byte, utf16))
                }
            }
            maps.append(
                LineMap(
                    baseUTF16: running,
                    byteCount: byteCount,
                    boundaries: boundaries
                )
            )
            running += line.utf16.count + 1
        }
        lineMaps = maps
    }

    func offset(line: Int, byteColumn: Int) -> Int? {
        guard line >= 1, line <= lineMaps.count, byteColumn >= 1 else {
            return nil
        }
        let map = lineMaps[line - 1]
        let target = byteColumn - 1
        guard target <= map.byteCount else { return nil }

        if map.boundaries.isEmpty {
            // ASCII: byte and UTF-16 offsets coincide.
            return map.baseUTF16 + target
        }

        var low = 0
        var high = map.boundaries.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let boundary = map.boundaries[mid]
            if boundary.byte == target {
                return map.baseUTF16 + boundary.utf16
            }
            if boundary.byte < target {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        // The column fell inside a multi-byte scalar.
        return nil
    }

    /// cmark reports an inclusive end column; the canonical range is exclusive.
    func endOffset(line: Int, inclusiveByteColumn: Int) -> Int? {
        offset(line: line, byteColumn: inclusiveByteColumn + 1)
    }
}

func nodeKind(_ node: UnsafeMutablePointer<cmark_node>?) -> String {
    guard let type = cmark_node_get_type_string(node) else { return "unknown" }
    return String(cString: type)
}

func alignmentName(_ raw: UInt8) -> String {
    // cmark-gfm stores table alignments as ASCII: 'l', 'c', 'r', or 0.
    switch raw {
    case UInt8(ascii: "l"): return "left"
    case UInt8(ascii: "c"): return "center"
    case UInt8(ascii: "r"): return "right"
    default: return "none"
    }
}

func delimiterName(_ node: UnsafeMutablePointer<cmark_node>?) -> String? {
    switch cmark_node_get_list_delim(node) {
    case CMARK_PERIOD_DELIM: return "period"
    case CMARK_PAREN_DELIM: return "paren"
    default: return nil
    }
}

func listTypeName(_ node: UnsafeMutablePointer<cmark_node>?) -> String? {
    switch cmark_node_get_list_type(node) {
    case CMARK_BULLET_LIST: return "bullet"
    case CMARK_ORDERED_LIST: return "ordered"
    default: return nil
    }
}

func markerName(_ node: UnsafeMutablePointer<cmark_node>?) -> String? {
    switch cmark_node_get_list_marker(node) {
    case CMARK_HYPHEN_LIST_MARKER: return "dash"
    case CMARK_PLUS_LIST_MARKER: return "plus"
    case CMARK_ASTERISK_LIST_MARKER: return "asterisk"
    default: return nil
    }
}

func projectionFor(
    node: UnsafeMutablePointer<cmark_node>?,
    mapper: UTF16PositionMapper
) -> [String: Any]? {
    guard let node else { return nil }
    let kind = nodeKind(node)
    let startLine = Int(cmark_node_get_start_line(node))
    let endLine = Int(cmark_node_get_end_line(node))

    let startOffset = startLine > 0
        ? mapper.offset(
            line: startLine,
            byteColumn: Int(cmark_node_get_start_column(node))
        )
        : nil
    let endOffset = endLine > 0
        ? mapper.endOffset(
            line: endLine,
            inclusiveByteColumn: Int(cmark_node_get_end_column(node))
        )
        : nil
    let hasPosition = startOffset != nil && endOffset != nil

    var item: [String: Any] = [
        "kind": kind,
        "literal": cmark_node_get_literal(node).map { String(cString: $0) } ?? NSNull(),
        "startLine": hasPosition ? startLine : NSNull(),
        "startUtf16": hasPosition ? startOffset! : NSNull(),
        "endLine": hasPosition ? endLine : NSNull(),
        "endUtf16": hasPosition ? endOffset! : NSNull()
    ]

    switch kind {
    case "heading":
        item["headingLevel"] = Int(cmark_node_get_heading_level(node))
    case "list":
        item["listType"] = listTypeName(node)
        item["listStart"] = Int(cmark_node_get_list_start(node))
        item["listTight"] = cmark_node_get_list_tight(node) != 0
        item["listDelimiter"] = delimiterName(node)
        item["listMarker"] = markerName(node)
    case "code_block":
        var fenceLength: Int32 = 0
        var fenceOffset: Int32 = 0
        var fenceCharacter: CChar = 0
        let fenced = cmark_node_get_fenced(
            node,
            &fenceLength,
            &fenceOffset,
            &fenceCharacter
        )
        item["fenced"] = fenced != 0
        if fenced != 0 {
            item["fenceLength"] = Int(fenceLength)
            item["fenceOffset"] = Int(fenceOffset)
            item["fenceCharacter"] = String(
                Character(UnicodeScalar(UInt8(bitPattern: fenceCharacter)))
            )
        } else {
            item["fenceLength"] = NSNull()
            item["fenceOffset"] = NSNull()
            item["fenceCharacter"] = NSNull()
        }
        item["fenceInfo"] = cmark_node_get_fence_info(node).map { String(cString: $0) } ?? NSNull()
    case "link", "image":
        item["destination"] = cmark_node_get_url(node).map { String(cString: $0) } ?? NSNull()
        item["title"] = cmark_node_get_title(node).map { String(cString: $0) } ?? NSNull()
    case "table":
        let columns = Int(cmark_gfm_extensions_get_table_columns(node))
        item["tableColumns"] = columns
        if let alignments = cmark_gfm_extensions_get_table_alignments(node) {
            item["tableAlignments"] = (0..<columns).map { alignmentName(alignments[$0]) }
        } else {
            item["tableAlignments"] = [String]()
        }
    case "table_row":
        item["tableRowIsHeader"] = cmark_gfm_extensions_get_table_row_is_header(node) != 0
    case "tasklist":
        item["taskChecked"] = cmark_gfm_extensions_get_tasklist_item_checked(node)
    default:
        break
    }

    return item
}

/// Node kinds for which cmark emits both ENTER and EXIT events.
let containerKinds: Set<String> = [
    "document",
    "block_quote",
    "list",
    "item",
    "tasklist",
    "paragraph",
    "heading",
    "table",
    "table_header",
    "table_row",
    "table_cell",
    "emph",
    "strong",
    "strikethrough",
    "link",
    "image",
    "custom_block",
    "custom_inline",
    "footnote_definition"
]

func buildDocument(
    source: String,
    options: ReferenceAstOptions
) throws -> [Any] {
    cmark_gfm_core_extensions_ensure_registered()

    let cmarkOptions = Int32(CMARK_OPT_SOURCEPOS | CMARK_OPT_TABLE_SPANS)
    guard let parser = cmark_parser_new(cmarkOptions) else {
        throw ReferenceAstError.parserInitializationFailed
    }
    defer { cmark_parser_free(parser) }

    var extensionNames = ["table", "strikethrough", "tasklist"]
    if options.enableAutolinks {
        extensionNames.append("autolink")
    }
    for name in extensionNames {
        guard let ext = cmark_find_syntax_extension(name),
              cmark_parser_attach_syntax_extension(parser, ext) != 0 else {
            // Silently continuing would produce successful JSON with reduced
            // Markdown semantics and weaken the conformance oracle.
            throw ReferenceAstError.missingSyntaxExtension(name)
        }
    }

    source.withCString { pointer in
        cmark_parser_feed(parser, pointer, source.utf8.count)
    }

    guard let document = cmark_parser_finish(parser) else {
        throw ReferenceAstError.parseFailed
    }
    defer { cmark_node_free(document) }

    guard let iterator = cmark_iter_new(document) else { return [] }
    defer { cmark_iter_free(iterator) }

    let mapper = UTF16PositionMapper(source: source)
    var roots: [Any] = []
    var stack: [NSMutableDictionary] = []

    while true {
        let event = cmark_iter_next(iterator)
        if event == CMARK_EVENT_DONE { break }

        let node = cmark_iter_get_node(iterator)
        if event == CMARK_EVENT_ENTER {
            guard let projection = projectionFor(node: node, mapper: mapper) else {
                continue
            }
            let mutable = NSMutableDictionary()
            for (key, value) in projection {
                mutable[key] = value
            }
            let children = NSMutableArray()
            mutable["children"] = children
            if let parent = stack.last {
                (parent["children"] as! NSMutableArray).add(mutable)
            } else {
                roots.append(mutable)
            }
            // cmark emits EXIT only for container nodes. Leaf nodes emit a
            // single ENTER event, so pushing them would nest every following
            // sibling beneath them.
            if containerKinds.contains(projection["kind"] as? String ?? "") {
                stack.append(mutable)
            }
        } else if event == CMARK_EVENT_EXIT {
            if !stack.isEmpty {
                stack.removeLast()
            }
        }
    }

    return roots
}
