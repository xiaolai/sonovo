import Foundation

/// Converts clipboard HTML to Markdown source.
///
/// This is a small, tolerant HTML parser for the constructs a clipboard
/// carries: headings, paragraphs, lists, tables, links, emphasis, inline and
/// fenced code, images, blockquotes, and line breaks. It never fetches
/// anything and never invokes WebKit. Unknown elements keep their text;
/// scripts, styles, and embedded media are dropped.
///
/// The converter returns `nil` when it cannot produce Markdown (oversized
/// input, malformed markup, no visible content, or no HTML at all). The paste
/// chain then falls back to plain text.
public enum MarkdownHTMLPaste {
    /// Clipboard payloads above this size are pasted literally.
    public static let maximumBytes = 100 * 1024

    public static func convert(_ html: String) -> String? {
        guard !html.isEmpty, html.utf8.count <= maximumBytes else {
            return nil
        }
        do {
            var tokenizer = HTMLTokenizer(html)
            let builder = HTMLTreeBuilder()
            var sawElement = false
            while let token = try tokenizer.next() {
                if builder.exceededDepth { break }
                switch token {
                case let .text(text):
                    builder.text(text)
                case let .startTag(name, attributes, selfClosing):
                    sawElement = true
                    if selfClosing {
                        builder.emptyElement(name, attributes)
                    } else {
                        builder.start(name, attributes)
                    }
                case let .endTag(name):
                    sawElement = true
                    builder.end(name)
                }
            }
            guard sawElement else { return nil }
            builder.finish()
            // Rendering and traversal recurse; an unbounded depth can
            // exhaust the stack even below the byte cap.
            guard !builder.exceededDepth else { return nil }
            let rendered = HTMLRenderer.render(builder.nodes)
            let trimmed = rendered
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed + "\n"
        } catch {
            return nil
        }
    }
}

// MARK: - Tokens

private enum HTMLToken: Equatable {
    case text(String)
    case startTag(name: String, attributes: [String: String], selfClosing: Bool)
    case endTag(String)
}

private enum HTMLTokenizerError: Error {
    case unterminatedConstruct
}

/// A tolerant tokenizer: unknown tags pass through, unclosed quotes do not.
private struct HTMLTokenizer {
    private let text: String
    private var index: String.Index
    /// A raw-text element whose content must not be parsed as markup.
    private var rawTag: String?

    init(_ text: String) {
        self.text = text
        self.index = text.startIndex
    }

    mutating func next() throws -> HTMLToken? {
        // Comments and declarations are skipped iteratively: recursing once
        // per construct lets thousands of them inside the byte cap exhaust
        // the stack.
        while true {
            if let rawTag {
                return skipRawText(until: rawTag)
            }
            guard index < text.endIndex else { return nil }
            if text[index] != "<" {
                return .text(try readText())
            }
            if peek("<!--") {
                try skipPast("-->")
                continue
            }
            if peek("<!") || peek("<?") {
                try skipPast(">")
                continue
            }
            break
        }
        if peek("</") {
            advance(by: 2)
            let name = readTagName()
            try skipPast(">")
            guard !name.isEmpty else { throw HTMLTokenizerError.unterminatedConstruct }
            return .endTag(name)
        }
        let nextIndex = text.index(after: index)
        guard nextIndex < text.endIndex,
              isTagNameStart(text[nextIndex]) else {
            // A literal less-than sign, not a tag.
            advance(by: 1)
            return .text("<")
        }
        advance(by: 1)
        let name = readTagName()
        guard !name.isEmpty else {
            throw HTMLTokenizerError.unterminatedConstruct
        }
        var attributes: [String: String] = [:]
        var selfClosing = false
        while index < text.endIndex {
            skipWhitespace()
            guard index < text.endIndex else {
                throw HTMLTokenizerError.unterminatedConstruct
            }
            if peek("/>") {
                advance(by: 2)
                selfClosing = true
                break
            }
            if peek(">") {
                advance(by: 1)
                break
            }
            let attribute = readAttributeName()
            guard !attribute.isEmpty else {
                advance(by: 1)
                continue
            }
            skipWhitespace()
            var value = ""
            if peek("=") {
                advance(by: 1)
                skipWhitespace()
                value = try readAttributeValue()
            }
            attributes[attribute] = HTMLEntities.decode(value)
        }
        if HTMLRenderer.rawTextNames.contains(name), !selfClosing {
            rawTag = name
        }
        return .startTag(
            name: name,
            attributes: attributes,
            selfClosing: selfClosing
        )
    }

    // MARK: - Reading

    private mutating func readText() throws -> String {
        let start = index
        while index < text.endIndex, text[index] != "<" {
            advance(by: 1)
        }
        return HTMLEntities.decode(String(text[start..<index]))
    }

    private mutating func readTagName() -> String {
        var name = ""
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber
                || character == "-" || character == ":"
                || character == "_" {
                name.append(character)
                advance(by: 1)
            } else {
                break
            }
        }
        return name.lowercased()
    }

    private mutating func readAttributeName() -> String {
        var name = ""
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace || character == "="
                || character == ">" || character == "/" {
                break
            }
            name.append(character)
            advance(by: 1)
        }
        return name.lowercased()
    }

    private mutating func readAttributeValue() throws -> String {
        guard index < text.endIndex else {
            throw HTMLTokenizerError.unterminatedConstruct
        }
        let quote = text[index]
        if quote == "\"" || quote == "'" {
            advance(by: 1)
            let start = index
            while index < text.endIndex, text[index] != quote {
                advance(by: 1)
            }
            guard index < text.endIndex else {
                throw HTMLTokenizerError.unterminatedConstruct
            }
            let value = String(text[start..<index])
            advance(by: 1)
            return value
        }
        let start = index
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace || character == ">" {
                break
            }
            advance(by: 1)
        }
        return String(text[start..<index])
    }

    /// Consumes the contents of a raw-text element and returns its end tag.
    private mutating func skipRawText(
        until name: String
    ) -> HTMLToken? {
        let closing = "</\(name)"
        var searchStart = index
        while let range = text.range(
            of: closing,
            options: .caseInsensitive,
            range: searchStart..<text.endIndex
        ) {
            // The name must end there: `</scripture>` does not close a
            // `script` element.
            let after = range.upperBound
            guard after < text.endIndex else { break }
            let character = text[after]
            guard character == ">"
                || character == "/"
                || character.isWhitespace else {
                searchStart = text.index(after: range.lowerBound)
                continue
            }
            index = range.lowerBound
            rawTag = nil
            // Consume the whole end tag, whitespace and `>` included.
            advance(by: closing.count)
            while index < text.endIndex, text[index] != ">" {
                advance(by: 1)
            }
            if index < text.endIndex {
                advance(by: 1)
            }
            return .endTag(name)
        }
        index = text.endIndex
        rawTag = nil
        return .endTag(name)
    }

    private mutating func skipPast(_ terminator: String) throws {
        guard let range = text.range(
            of: terminator,
            range: index..<text.endIndex
        ) else {
            throw HTMLTokenizerError.unterminatedConstruct
        }
        index = range.upperBound
    }

    private mutating func skipWhitespace() {
        while index < text.endIndex, text[index].isWhitespace {
            advance(by: 1)
        }
    }

    private mutating func advance(by count: Int) {
        index = text.index(index, offsetBy: count)
    }

    private func peek(_ prefix: String) -> Bool {
        text[index...].hasPrefix(prefix)
    }

    private func isTagNameStart(_ character: Character) -> Bool {
        character.isLetter
    }
}

// MARK: - Entities

enum HTMLEntities {
    /// The longest entity spelling worth considering. Beyond it there is no
    /// valid reference, so an unmatched `&` cannot force a scan of the whole
    /// remaining text.
    private static let maximumEntityLength = 34

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&",
               let reference = decodeReference(in: text, at: index) {
                result.append(reference.character)
                index = reference.end
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    /// Decodes one character reference starting at an ampersand, returning
    /// the character and the index just past its semicolon. `nil` means no
    /// valid reference starts here, so the ampersand is literal text.
    static func decodeReference(
        in text: String,
        at ampersand: String.Index
    ) -> (character: Character, end: String.Index)? {
        guard ampersand < text.endIndex, text[ampersand] == "&" else {
            return nil
        }
        var cursor = text.index(after: ampersand)
        var name = ""
        while cursor < text.endIndex, name.count < maximumEntityLength {
            if text[cursor] == ";" {
                guard let entity = entity(name) else { return nil }
                return (entity, text.index(after: cursor))
            }
            name.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func entity(_ name: String) -> Character? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            let digits = String(name.dropFirst(2))
            guard let value = UInt32(digits, radix: 16),
                  let scalar = Unicode.Scalar(value) else {
                return nil
            }
            return Character(scalar)
        }
        if name.hasPrefix("#") {
            let digits = String(name.dropFirst())
            guard let value = UInt32(digits),
                  let scalar = Unicode.Scalar(value) else {
                return nil
            }
            return Character(scalar)
        }
        guard let scalar = named[name] else { return nil }
        return Character(scalar)
    }

    private static let named: [String: Unicode.Scalar] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}",
        "thinsp": "\u{2009}", "copy": "\u{00A9}", "reg": "\u{00AE}",
        "trade": "\u{2122}", "hellip": "\u{2026}", "mdash": "\u{2014}",
        "ndash": "\u{2013}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "laquo": "\u{00AB}",
        "raquo": "\u{00BB}", "middot": "\u{00B7}", "bull": "\u{2022}",
        "deg": "\u{00B0}", "plusmn": "\u{00B1}", "times": "\u{00D7}",
        "divide": "\u{00F7}", "frac12": "\u{00BD}", "frac14": "\u{00BC}",
        "frac34": "\u{00BE}", "sup2": "\u{00B2}", "sup3": "\u{00B3}",
        "micro": "\u{00B5}", "para": "\u{00B6}", "sect": "\u{00A7}",
        "euro": "\u{20AC}", "pound": "\u{00A3}", "yen": "\u{00A5}",
        "cent": "\u{00A2}", "larr": "\u{2190}", "rarr": "\u{2192}",
        "uarr": "\u{2191}", "darr": "\u{2193}", "harr": "\u{2194}",
        "zwj": "\u{200D}", "zwnj": "\u{200C}",
    ]
}

// MARK: - Tree

private indirect enum HTMLNode {
    case text(String)
    case element(name: String, attributes: [String: String], children: [HTMLNode])
}

private final class HTMLTreeBuilder {
    static let maximumDepth = 256

    private struct OpenElement {
        let name: String
        let attributes: [String: String]
        var children: [HTMLNode]
    }

    private var root: [HTMLNode] = []
    private var stack: [OpenElement] = []
    private(set) var exceededDepth = false

    var nodes: [HTMLNode] { root }

    func text(_ text: String) {
        guard !text.isEmpty, !exceededDepth else { return }
        append(.text(text))
    }

    func start(_ name: String, _ attributes: [String: String]) {
        guard !exceededDepth else { return }
        applyImplicitClose(for: name)
        if HTMLRenderer.voidNames.contains(name) {
            append(.element(name: name, attributes: attributes, children: []))
            return
        }
        guard stack.count < Self.maximumDepth else {
            exceededDepth = true
            return
        }
        stack.append(
            OpenElement(name: name, attributes: attributes, children: [])
        )
    }

    func emptyElement(_ name: String, _ attributes: [String: String]) {
        guard !exceededDepth else { return }
        applyImplicitClose(for: name)
        append(.element(name: name, attributes: attributes, children: []))
    }

    func end(_ name: String) {
        guard !exceededDepth else { return }
        guard let index = stack.lastIndex(where: { $0.name == name })
        else {
            return
        }
        close(through: index)
    }

    func finish() {
        while !stack.isEmpty {
            close(through: stack.count - 1)
        }
    }

    private func append(_ node: HTMLNode) {
        if stack.isEmpty {
            root.append(node)
        } else {
            stack[stack.count - 1].children.append(node)
        }
    }

    private func close(through index: Int) {
        while stack.count > index {
            let open = stack.removeLast()
            append(
                .element(
                    name: open.name,
                    attributes: open.attributes,
                    children: open.children
                )
            )
        }
    }

    private func applyImplicitClose(for name: String) {
        if HTMLRenderer.blockNames.contains(name) {
            closeLast(["p"])
        }
        switch name {
        case "li":
            closeScoped(["li"], barriers: ["ul", "ol"])
        case "tr":
            closeScoped(["tr"], barriers: ["table"])
        case "td", "th":
            closeScoped(["td", "th"], barriers: ["tr", "table"])
        case "dt", "dd":
            closeScoped(["dt", "dd"], barriers: ["dl"])
        default:
            break
        }
    }

    private func closeLast(_ names: Set<String>) {
        guard let index = stack.lastIndex(where: {
            names.contains($0.name)
        }) else {
            return
        }
        close(through: index)
    }

    private func closeScoped(
        _ names: Set<String>,
        barriers: Set<String>
    ) {
        guard let index = stack.lastIndex(where: {
            names.contains($0.name)
        }) else {
            return
        }
        let above = stack[(index + 1)...]
        guard !above.contains(where: { barriers.contains($0.name) })
        else {
            return
        }
        close(through: index)
    }
}

// MARK: - Renderer

private enum HTMLRenderer {
    static let rawTextNames: Set<String> = [
        "script", "style", "head", "title", "noscript", "template",
    ]

    /// Void elements never contain the text that follows them.
    static let voidNames: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    static let skipNames: Set<String> = rawTextNames.union([
        "meta", "link", "base", "iframe", "object", "embed", "video",
        "audio", "canvas", "svg", "source", "track", "param",
    ])

    static let blockNames: Set<String> = [
        "html", "body", "p", "div", "section", "article", "header",
        "footer", "main", "aside", "nav", "figure", "figcaption",
        "blockquote", "pre", "ul", "ol", "li", "table", "thead", "tbody",
        "tfoot", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6",
        "hr", "address", "form", "fieldset", "dl", "dt", "dd",
    ]

    static func render(_ nodes: [HTMLNode]) -> String {
        renderBlocks(nodes, depth: 0)
    }

    // MARK: - Blocks

    private static func renderBlocks(
        _ nodes: [HTMLNode],
        depth: Int
    ) -> String {
        var blocks: [String] = []
        let writer = InlineWriter()
        func flush() {
            let text = writer.take()
            guard !text.isEmpty else { return }
            blocks.append(escapeBlockStarts(text))
        }

        for node in nodes {
            switch node {
            case let .text(text):
                writer.appendText(text)
            case let .element(name, attributes, children):
                if skipNames.contains(name) {
                    continue
                }
                if blockNames.contains(name) {
                    flush()
                    let block = renderBlock(
                        name,
                        attributes,
                        children,
                        depth: depth
                    )
                    if !block.isEmpty {
                        blocks.append(block)
                    }
                } else {
                    renderInlineNode(
                        name,
                        attributes,
                        children,
                        into: writer
                    )
                }
            }
        }
        flush()
        return blocks.joined(separator: "\n\n")
    }

    private static func renderBlock(
        _ name: String,
        _ attributes: [String: String],
        _ children: [HTMLNode],
        depth: Int
    ) -> String {
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(name.dropFirst()) ?? 1
            let text = inlineText(children)
            guard !text.isEmpty else { return "" }
            return String(repeating: "#", count: level) + " " + text
        case "p":
            return escapeBlockStarts(inlineText(children))
        case "hr":
            return "---"
        case "ul":
            return renderList(children, ordered: false, start: 1, depth: depth)
        case "ol":
            // `<ol start="5">` carries meaningful numbering; restarting at
            // 1 silently changes the list's content. A Markdown ordered
            // marker holds at most nine digits, and clamping before the
            // arithmetic keeps any attribute value from overflowing it.
            let start = attributes["start"].flatMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }.map { min(max($0, 0), 999_999_999) } ?? 1
            return renderList(
                children,
                ordered: true,
                start: start,
                depth: depth
            )
        case "li":
            return renderBlocks(children, depth: depth)
        case "blockquote":
            let body = renderBlocks(children, depth: depth)
            guard !body.isEmpty else { return "" }
            return body.components(separatedBy: "\n").map { line in
                line.isEmpty ? ">" : "> " + line
            }.joined(separator: "\n")
        case "pre":
            return renderPre(attributes, children)
        case "table":
            return renderTable(children)
        default:
            if containsBlock(children) {
                return renderBlocks(children, depth: depth)
            }
            return escapeBlockStarts(inlineText(children))
        }
    }

    private static func containsBlock(_ nodes: [HTMLNode]) -> Bool {
        for node in nodes {
            if case let .element(name, _, children) = node {
                if blockNames.contains(name) { return true }
                if containsBlock(children) { return true }
            }
        }
        return false
    }

    private static func renderList(
        _ nodes: [HTMLNode],
        ordered: Bool,
        start: Int,
        depth: Int
    ) -> String {
        var items: [String] = []
        for node in nodes {
            guard case let .element("li", _, children) = node else {
                continue
            }
            let content = renderBlocks(children, depth: depth + 1)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            items.append(content)
        }
        guard !items.isEmpty else { return "" }
        return items.enumerated().map { offset, content in
            // Nine digits is the longest ordered marker Markdown parses; a
            // clamp keeps a pathological start representable.
            let marker = ordered
                ? "\(min(start + offset, 999_999_999)). "
                : "- "
            let indent = String(repeating: " ", count: marker.count)
            let lines = content.components(separatedBy: "\n")
            let first = marker + lines[0]
            let rest = lines.dropFirst().map { line in
                line.isEmpty ? line : indent + line
            }
            return ([first] + rest).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private static func renderPre(
        _ attributes: [String: String],
        _ children: [HTMLNode]
    ) -> String {
        let code = firstElement(named: "code", in: children)
        let codeChildren = code?.children ?? children
        let language = (code.flatMap { language(of: $0.attributes) }
            ?? language(of: attributes)) ?? ""
        var body = rawText(codeChildren)
        if body.hasSuffix("\n") { body.removeLast() }
        let fence = String(
            repeating: "`",
            count: max(3, longestBacktickRun(body) + 1)
        )
        return "\(fence)\(language)\n\(body)\n\(fence)"
    }

    private static func renderTable(_ nodes: [HTMLNode]) -> String {
        var rows: [[(text: String, alignment: String)]] = []
        collectRows(nodes, into: &rows)
        guard !rows.isEmpty else { return "" }
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return "" }
        guard rows.count * columnCount <= MarkdownLimits.maxPastedTableCells
        else {
            // Padding every row to the widest row is quadratic: a small
            // payload with many rows and one wide row can expand into
            // millions of cells. The rows stay readable as plain lines.
            return rows.map { row in
                row.map(\.text).joined(separator: " | ")
            }.joined(separator: "\n")
        }

        var cells: [[(text: String, alignment: String)]] = rows.map { row in
            var padded = row
            while padded.count < columnCount {
                padded.append(("", "left"))
            }
            return padded
        }
        let header = cells.removeFirst()
        let headerLine = "| " + header.map { $0.text }.joined(separator: " | ")
            + " |"
        let delimiter = "| " + header.map { cell in
            switch cell.alignment {
            case "center": return ":---:"
            case "right": return "---:"
            case "left": return ":---"
            default: return "---"
            }
        }.joined(separator: " | ") + " |"
        let body = cells.map { row in
            "| " + row.map { $0.text }.joined(separator: " | ") + " |"
        }
        return ([headerLine, delimiter] + body).joined(separator: "\n")
    }

    private static func collectRows(
        _ nodes: [HTMLNode],
        into rows: inout [[(text: String, alignment: String)]]
    ) {
        for node in nodes {
            guard case let .element(name, _, children) = node else {
                continue
            }
            if name == "tr" {
                var row: [(String, String)] = []
                for child in children {
                    guard case let .element(cellName, attributes, cellChildren)
                        = child,
                          cellName == "td" || cellName == "th" else {
                        continue
                    }
                    row.append(
                        (
                            tableCell(inlineText(cellChildren)),
                            alignment(of: attributes)
                        )
                    )
                }
                if !row.isEmpty { rows.append(row) }
            } else if name == "thead" || name == "tbody" || name == "tfoot"
                        || name == "table" {
                collectRows(children, into: &rows)
            }
        }
    }

    private static func tableCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func alignment(
        of attributes: [String: String]
    ) -> String {
        if let align = attributes["align"]?.lowercased() {
            return align
        }
        guard let style = attributes["style"]?.lowercased(),
              let range = style.range(
                  of: #"text-align\s*:\s*(left|center|right)"#,
                  options: .regularExpression
              ) else {
            return ""
        }
        return String(style[range])
            .components(separatedBy: ":")
            .last?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func language(
        of attributes: [String: String]
    ) -> String? {
        guard let classes = attributes["class"] else { return nil }
        for token in classes.split(separator: " ") {
            for prefix in ["language-", "lang-", "highlight-source-"] {
                if token.hasPrefix(prefix) {
                    let language = String(token.dropFirst(prefix.count))
                    return language.isEmpty ? nil : language
                }
            }
        }
        return nil
    }

    private static func firstElement(
        named name: String,
        in nodes: [HTMLNode]
    ) -> (attributes: [String: String], children: [HTMLNode])? {
        for node in nodes {
            guard case let .element(nodeName, attributes, children) = node
            else {
                continue
            }
            if nodeName == name { return (attributes, children) }
            if let found = firstElement(named: name, in: children) {
                return found
            }
        }
        return nil
    }

    // MARK: - Inline

    private static func inlineText(_ nodes: [HTMLNode]) -> String {
        let writer = InlineWriter()
        renderInline(nodes, into: writer)
        return writer.finish()
    }

    private static func renderInline(
        _ nodes: [HTMLNode],
        into writer: InlineWriter
    ) {
        for node in nodes {
            switch node {
            case let .text(text):
                writer.appendText(text)
            case let .element(name, attributes, children):
                renderInlineNode(
                    name,
                    attributes,
                    children,
                    into: writer
                )
            }
        }
    }

    private static func renderInlineNode(
        _ name: String,
        _ attributes: [String: String],
        _ children: [HTMLNode],
        into writer: InlineWriter
    ) {
        if skipNames.contains(name) { return }
        switch name {
        case "strong", "b":
            wrap("**", children, into: writer)
        case "em", "i":
            wrap("*", children, into: writer)
        case "del", "s", "strike":
            wrap("~~", children, into: writer)
        case "code":
            writer.appendRaw(inlineCode(rawText(children)))
        case "a":
            let text = inlineText(children)
            let (leading, trailing) = boundarySpace(children)
            guard let href = attributes["href"]?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !href.isEmpty, isSafeURL(href, image: false) else {
                renderInline(children, into: writer)
                return
            }
            let destination = markdownDestination(href)
            if !leading.isEmpty { writer.appendText(leading) }
            if text.isEmpty {
                writer.appendRaw(destination)
            } else {
                writer.appendRaw("[\(text)](\(destination))")
            }
            if !trailing.isEmpty { writer.appendText(trailing) }
        case "img":
            guard let src = attributes["src"]?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !src.isEmpty, isSafeURL(src, image: true) else {
                return
            }
            let alt = (attributes["alt"] ?? "")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            writer.appendRaw("![\(alt)](\(markdownDestination(src)))")
        case "br":
            writer.appendHardBreak()
        default:
            renderInline(children, into: writer)
        }
    }

    private static func wrap(
        _ marker: String,
        _ children: [HTMLNode],
        into writer: InlineWriter
    ) {
        let inner = inlineText(children)
        let (leading, trailing) = boundarySpace(children)
        guard !inner.isEmpty else {
            if !leading.isEmpty { writer.appendText(leading) }
            return
        }
        // The inner run is trimmed for wrapping; its boundary whitespace
        // still separates words outside the markers, or `Hello<strong>
        // world </strong>again` would paste as `Hello**world**again`.
        if !leading.isEmpty { writer.appendText(leading) }
        writer.appendRaw(marker + inner + marker)
        if !trailing.isEmpty { writer.appendText(trailing) }
    }

    /// One collapsed space when the children start or end with whitespace.
    private static func boundarySpace(
        _ nodes: [HTMLNode]
    ) -> (leading: String, trailing: String) {
        let raw = rawText(nodes)
        return (
            raw.first?.isWhitespace == true ? " " : "",
            raw.last?.isWhitespace == true ? " " : ""
        )
    }

    private static func inlineCode(_ text: String) -> String {
        let body = text
            .replacingOccurrences(of: "\n", with: " ")
        guard !body.isEmpty else { return "``" }
        let fence = String(
            repeating: "`",
            count: longestBacktickRun(body) + 1
        )
        // CommonMark strips one space from each side when both are present,
        // so authored boundary spaces need one compensating space each.
        // All-space content is exempt: the strip never applies to it.
        let allSpaces = body.allSatisfy { $0 == " " }
        let needsPadding = !allSpaces
            && (body.hasPrefix("`") || body.hasSuffix("`")
                || body.hasPrefix(" ") || body.hasSuffix(" "))
        let padded = needsPadding ? " \(body) " : body
        return fence + padded + fence
    }

    private static func rawText(_ nodes: [HTMLNode]) -> String {
        var result = ""
        for node in nodes {
            switch node {
            case let .text(text):
                result += text
            case let .element(name, _, children):
                if name == "br" { result += "\n" }
                else if !skipNames.contains(name) { result += rawText(children) }
            }
        }
        return result
    }

    // MARK: - Text helpers

    private static func escapeBlockStarts(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            guard !line.isEmpty else { return line }
            if line.range(
                of: #"^#{1,6}(\s|$)"#,
                options: .regularExpression
            ) != nil {
                return "\\" + line
            }
            if line.hasPrefix(">") { return "\\" + line }
            if line.range(
                of: #"^[-+*](\s|$)"#,
                options: .regularExpression
            ) != nil {
                return "\\" + line
            }
            // Literal text that would become structure: a thematic break or
            // a setext underline.
            if line.range(
                of: #"^([-*_])(\s*\1){2,}\s*$"#,
                options: .regularExpression
            ) != nil {
                return "\\" + line
            }
            if line.range(
                of: #"^=+\s*$"#,
                options: .regularExpression
            ) != nil {
                return "\\" + line
            }
            if line.range(
                of: #"^\d{1,9}[.)](\s|$)"#,
                options: .regularExpression
            ) != nil {
                // A backslash before a digit is not an escape and renders
                // literally; escape the list punctuation instead.
                var copy = line
                let digits = copy.prefix(while: { $0.isNumber }).count
                let marker = copy.index(
                    copy.startIndex,
                    offsetBy: digits
                )
                copy.insert("\\", at: marker)
                return copy
            }
            return line
        }.joined(separator: "\n")
    }

    private static func markdownDestination(_ url: String) -> String {
        if url.contains(where: { $0.isWhitespace || $0 == "(" || $0 == ")" })
        {
            return "<" + url.replacingOccurrences(of: ">", with: "%3E") + ">"
        }
        return url
    }

    /// Only safe link and image destinations survive conversion. A pasted
    /// `javascript:` URL or embedded payload is dropped; the text stays.
    static func isSafeURL(_ raw: String, image: Bool) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }) else {
            return false
        }
        guard let colon = trimmed.firstIndex(of: ":") else {
            // Relative or protocol-relative URL: no scheme of its own.
            return true
        }
        let firstDelimiter = trimmed.firstIndex(where: {
            $0 == "/" || $0 == "?" || $0 == "#"
        }) ?? trimmed.endIndex
        guard colon < firstDelimiter else {
            // A colon inside a path or query, not a scheme.
            return true
        }
        let scheme = trimmed[..<colon].lowercased()
        if scheme == "mailto" { return !image }
        return scheme == "http" || scheme == "https"
    }

    private static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}

/// Collapses HTML whitespace and escapes Markdown inline markers while
/// content is appended, so protected spans (code, links, images) keep their
/// exact text.
private final class InlineWriter {
    private var output = ""
    private var pendingSpace = false
    private var endsWithHardBreak = false

    func appendText(_ raw: String) {
        let escaped = Self.escapeInline(raw)
        for character in escaped {
            if character.isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace, !output.isEmpty {
                output.append(" ")
            }
            pendingSpace = false
            output.append(character)
            endsWithHardBreak = false
        }
    }

    func appendRaw(_ raw: String) {
        if pendingSpace, !output.isEmpty,
           let first = raw.first, !first.isWhitespace {
            output.append(" ")
        }
        pendingSpace = false
        if !raw.isEmpty { endsWithHardBreak = false }
        output.append(raw)
    }

    func appendHardBreak() {
        pendingSpace = false
        output.append("\\\n")
        endsWithHardBreak = true
    }

    func finish() -> String {
        var text = output
        if endsWithHardBreak {
            // Every trailing break goes; its backslash has nothing to break.
            // Strip exactly the two characters each break appended, so a
            // literal escaped backslash just before it keeps both of its
            // characters.
            while text.hasSuffix("\\\n") {
                text.removeLast(2)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Consumes what has been written so far, so the same writer can hold the
    /// next block's inline run without repeating earlier text.
    func take() -> String {
        let text = finish()
        output = ""
        pendingSpace = false
        endsWithHardBreak = false
        return text
    }

    private static func escapeInline(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["`", "*", "_", "[", "]", "~"] {
            escaped = escaped.replacingOccurrences(
                of: character,
                with: "\\" + character
            )
        }
        escaped = escaped.replacingOccurrences(of: "<", with: "\\<")
        escaped = escaped.replacingOccurrences(
            of: #"&(?=#?[A-Za-z0-9]{1,32};)"#,
            with: "\\&",
            options: .regularExpression
        )
        return escaped
    }
}
