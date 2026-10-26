import AppKit
import Foundation
import ImageIO
import SonovoCore
import SwiftUI
import UniformTypeIdentifiers

/// Everything the HTML projection needs besides the tree.
struct MarkdownExportContext: Sendable {
    let title: String
    let documentURL: URL?
    let workspaceRoot: URL?
    let theme: MarkdownTheme
    /// Pre-rasterized formulas, keyed by `MarkdownMathAsset.key`. A missing
    /// entry falls back to the literal source.
    let math: [String: MarkdownMathAsset]
    /// Sanitized diagram SVGs, keyed by `DiagramKey.documentKey`. A missing
    /// entry falls back to the fenced code block.
    let diagrams: [String: MarkdownDiagramAsset]

    init(
        title: String,
        documentURL: URL?,
        workspaceRoot: URL?,
        theme: MarkdownTheme,
        math: [String: MarkdownMathAsset] = [:],
        diagrams: [String: MarkdownDiagramAsset] = [:],
        mermaid: [String: MarkdownMermaidAsset] = [:]
    ) {
        self.title = title
        self.documentURL = documentURL
        self.workspaceRoot = workspaceRoot
        self.theme = theme
        self.math = math
        self.diagrams = diagrams.merging(mermaid) { current, _ in current }
    }
}

/// Projects the owned Markdown tree into one self-contained HTML document.
///
/// The projection follows the rendered viewer, not the source: raw HTML is
/// hidden, link destinations pass `MarkdownSecurity`, code uses the same
/// lexer, tables, details, footnotes, alerts, and the TOC use the same AST
/// interpretation. Styles are inlined and images become data URIs, so the
/// file makes no network request. The content security policy enforces that
/// at open time as well.
enum MarkdownHTMLExporter {
    /// The complete HTML document, with an inlined stylesheet.
    static func document(
        _ ast: SonovoAST,
        context: MarkdownExportContext,
        forPrint: Bool = false
    ) -> String {
        var renderer = Renderer(
            ast: ast,
            context: context,
            forPrint: forPrint
        )
        let article = renderer.render()
        let stylesheet = renderer.stylesheet()
        let printOverride = forPrint
            ? "\n<style>\n\(renderer.pdfOverride())\n</style>"
            : ""
        let title = escapeText(context.title.isEmpty ? "Untitled" : context.title)
        return """
        <!DOCTYPE html>
        <html lang="und">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'none'; font-src 'none'; connect-src 'none'; media-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <title>\(title)</title>
        <style>
        \(stylesheet)
        </style>\(printOverride)
        </head>
        <body>
        \(article)
        </body>
        </html>
        """
    }

    /// The article fragment alone. Snapshot tests use this so they do not
    /// pin the generated stylesheet.
    static func body(
        _ ast: SonovoAST,
        context: MarkdownExportContext
    ) -> String {
        var renderer = Renderer(ast: ast, context: context)
        return renderer.render()
    }
}

// MARK: - Renderer

private struct Renderer {
    let ast: SonovoAST
    let context: MarkdownExportContext
    let headings: HeadingIndex
    let forPrint: Bool

    private var headingIDs: [Int: String] = [:]
    private var syntheticHeading = 0
    private var footnoteOrdinals: [Int: Int] = [:]
    private var inlineHTMLStack: [MarkdownInlineHTMLTag] = []
    private var imageURIs: [String: String] = [:]
    private var failedImages: Set<String> = []

    init(
        ast: SonovoAST,
        context: MarkdownExportContext,
        forPrint: Bool = false
    ) {
        self.ast = ast
        self.context = context
        self.headings = HeadingIndex(ast: ast)
        self.forPrint = forPrint
        for (index, entry) in headings.headings.enumerated() {
            guard let range = entry.range else { continue }
            headingIDs[range.lowerBound] = entry.slug ?? "section-\(index)"
        }
    }

    mutating func render() -> String {
        let content = blocksHTML(ast.blocks)
        return "<article class=\"sonovo\">\n\(content)\n</article>"
    }

    // MARK: Blocks

    private mutating func blocksHTML(_ blocks: [Block]) -> String {
        var pieces: [String] = []
        pieces.reserveCapacity(blocks.count)
        for index in blocks.indices {
            let previous = index > 0 ? blocks[index - 1] : nil
            let piece = blockHTML(blocks[index], previous: previous)
            if !piece.isEmpty {
                pieces.append(piece)
            }
        }
        return pieces.joined(separator: "\n")
    }

    private mutating func blockHTML(_ block: Block, previous: Block?) -> String {
        switch block {
        case let .paragraph(inlines, _):
            if let math = Self.displayMath(inlines) {
                return mathHTML(math, inline: false)
            }
            if inlines.count == 1,
               case let .image(destination, title, description, _) = inlines[0] {
                return blockImage(
                    destination: destination,
                    title: title,
                    alt: HeadingIndex.renderedText(description)
                )
            }
            let indented = isIndentedParagraph(after: previous)
            let content = scopedInlinesHTML(inlines)
            return indented
                ? "<p class=\"indent\">\(content)</p>"
                : "<p>\(content)</p>"

        case let .heading(level, inlines, range):
            let tag = "h\(min(max(level, 1), 6))"
            let id = headingID(for: range)
            return "<\(tag) id=\"\(escapeAttribute(id))\">\(scopedInlinesHTML(inlines))</\(tag)>"

        case let .blockQuote(blocks, _):
            if let kind = MarkdownAlertKind.kind(in: blocks) {
                let content = kind.strippingMarker(from: blocks)
                let body = blocksHTML(content)
                return """
                <aside class="alert alert-\(kind.rawValue)">
                <p class="alert-title">\(escapeText(kind.label))</p>
                \(body)
                </aside>
                """
            }
            return """
            <blockquote>
            \(blocksHTML(blocks))
            </blockquote>
            """

        case let .list(list, _):
            return listHTML(list)

        case let .codeBlock(code, _):
            return codeHTML(code)

        case .htmlBlock:
            return ""

        case .thematicBreak:
            return "<hr>"

        case let .table(table, _):
            return tableHTML(table)

        case let .definitionList(list, _):
            return definitionListHTML(list)

        case let .details(details, _):
            let summary = details.summary.isEmpty
                ? "Details"
                : scopedInlinesHTML(details.summary)
            let open = details.isOpen ? " open" : ""
            return """
            <details\(open)>
            <summary>\(summary)</summary>
            <div class="details-body">
            \(blocksHTML(details.blocks))
            </div>
            </details>
            """

        case .tableOfContents:
            return tocHTML()

        case .footnoteDefinition:
            return ""

        case let .footnotes(section, _):
            return footnotesHTML(section)
        }
    }

    private mutating func definitionListHTML(
        _ list: DefinitionList
    ) -> String {
        let items = list.items.map { item in
            let terms = item.terms.map { term in
                "<dt>\(scopedInlinesHTML(term.inlines))</dt>"
            }.joined(separator: "\n")
            let definitions = item.definitions.map { definition in
                "<dd>\(scopedInlinesHTML(definition.inlines))</dd>"
            }.joined(separator: "\n")
            return """
            <div class="definition-item">
            \(terms)
            \(definitions)
            </div>
            """
        }.joined(separator: "\n")
        return """
        <dl>
        \(items)
        </dl>
        """
    }

    private func isIndentedParagraph(after previous: Block?) -> Bool {
        guard context.theme.paragraphIndent > 0, let previous else {
            return false
        }
        if case .paragraph = previous { return true }
        return false
    }

    private mutating func headingID(for range: SourceRange?) -> String {
        if let range, let id = headingIDs[range.lowerBound] {
            return id
        }
        syntheticHeading += 1
        return "synthetic-heading-\(syntheticHeading)"
    }

    // MARK: Lists

    private mutating func listHTML(_ list: ListBlock) -> String {
        let isTaskList = list.items.contains { $0.checked != nil }
        let tag: String
        var start = ""
        switch list.kind {
        case .bullet:
            tag = "ul"
        case .ordered(let first):
            tag = "ol"
            if first != 1 {
                start = " start=\"\(max(first, 0))\""
            }
        }
        let className = isTaskList ? " class=\"task-list\"" : ""
        let items = list.items.map { listItemHTML($0) }
        return """
        <\(tag)\(className)\(start)>
        \(items.joined(separator: "\n"))
        </\(tag)>
        """
    }

    private mutating func listItemHTML(_ item: ListItem) -> String {
        let content = blocksHTML(item.blocks)
        if let checked = item.checked {
            let checkbox = checked
                ? "<input type=\"checkbox\" disabled checked>"
                : "<input type=\"checkbox\" disabled>"
            return """
            <li class="task-item">\(checkbox)<div class="task-body">
            \(content)
            </div></li>
            """
        }
        return """
        <li><div class="item">
        \(content)
        </div></li>
        """
    }

    // MARK: Code

    private mutating func codeHTML(_ code: CodeBlock) -> String {
        if let diagram = DiagramPolicy.source(from: code),
           let asset = context.diagrams[DiagramKey.documentKey(
               engine: diagram.engine,
               source: diagram.source
           )] {
            return diagramHTML(asset)
        }
        let fence = fenceClass(code.language)
        let codeClass = fence.map { " class=\"language-\(escapeAttribute($0))\"" } ?? ""
        let header: String
        if let language = code.language, !language.isEmpty {
            header = "<div class=\"code-header\">\(escapeText(language))</div>\n"
        } else {
            header = ""
        }
        let highlighted = highlightedCode(code)
        return """
        <div class="code-block">
        \(header)<pre><code\(codeClass)>\(highlighted)</code></pre>
        </div>
        """
    }

    /// The sanitized SVG is inserted as markup, not escaped: it has already
    /// passed `SVGSanitizer`. The printed document carries one light diagram;
    /// a themed document carries both and lets CSS choose.
    private func diagramHTML(_ asset: MarkdownDiagramAsset) -> String {
        switch asset.engine {
        case .mermaid:
            return themedDiagramHTML(
                asset,
                figureClass: "mermaid-block",
                lightClass: "mermaid mermaid-light",
                darkClass: "mermaid mermaid-dark"
            )
        case .graphviz, .markmap:
            return themedDiagramHTML(
                asset,
                figureClass: "diagram-block \(asset.engine.rawValue)-block",
                lightClass: "diagram diagram-light",
                darkClass: "diagram diagram-dark"
            )
        case .svg:
            return """
            <figure class="svg-fence">
            \(asset.lightSVG)
            </figure>
            """
        }
    }

    /// The sanitized SVG is inserted as markup, not escaped: it has already
    /// passed `SVGSanitizer`. The printed document carries one light diagram;
    /// a themed document carries both and lets CSS choose.
    private func themedDiagramHTML(
        _ asset: MarkdownDiagramAsset,
        figureClass: String,
        lightClass: String,
        darkClass: String
    ) -> String {
        if forPrint {
            return """
            <figure class="\(figureClass)">
            <div class="\(lightClass)">\(asset.lightSVG)</div>
            </figure>
            """
        }
        return """
        <figure class="\(figureClass)">
        <div class="\(lightClass)">\(asset.lightSVG)</div>
        <div class="\(darkClass)">\(asset.darkSVG)</div>
        </figure>
        """
    }

    private func fenceClass(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let first = raw
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init) ?? raw
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+-_.#"
        )
        let sanitized = first.lowercased().unicodeScalars.map {
            allowed.contains($0) ? String($0) : "-"
        }.joined()
        return sanitized.isEmpty ? nil : sanitized
    }

    private func highlightedCode(_ code: CodeBlock) -> String {
        guard let language = MarkdownFenceLanguage.language(for: code.language),
              language != .plainText else {
            return escapeText(code.code)
        }
        let snapshot = CodeSyntaxHighlighter.lex(
            text: code.code,
            language: language,
            revision: 0
        )
        let ns = code.code as NSString
        let tokens = snapshot.tokens(
            intersecting: NSRange(location: 0, length: ns.length)
        ).sorted { $0.range.location < $1.range.location }
        guard !tokens.isEmpty else { return escapeText(code.code) }

        var result = ""
        var cursor = 0
        for token in tokens {
            let location = token.range.location
            guard location >= cursor,
                  location + token.range.length <= ns.length else {
                continue
            }
            if location > cursor {
                result += escapeText(
                    ns.substring(
                        with: NSRange(
                            location: cursor,
                            length: location - cursor
                        )
                    )
                )
            }
            let piece = ns.substring(with: token.range)
            let tokenClass = Self.tokenClass(
                for: CodeEditorController.role(for: token.kind)
            )
            result += "<span class=\"\(tokenClass)\">\(escapeText(piece))</span>"
            cursor = location + token.range.length
        }
        if cursor < ns.length {
            result += escapeText(ns.substring(from: cursor))
        }
        return result
    }

    private static func tokenClass(for role: AppTheme.SyntaxRole) -> String {
        switch role {
        case .keyword: "tok-keyword"
        case .typeName: "tok-type"
        case .string: "tok-string"
        case .comment: "tok-comment"
        case .number: "tok-number"
        case .function: "tok-function"
        case .property: "tok-property"
        case .punctuation: "tok-punctuation"
        case .identifier: "tok-identifier"
        case .markup: "tok-markup"
        case .inserted: "tok-inserted"
        case .deleted: "tok-deleted"
        }
    }

    // MARK: Tables

    private mutating func tableHTML(_ table: TableBlock) -> String {
        return """
        <div class="table-wrap">
        <table>
        <thead>
        <tr>\(headerCellsHTML(table))</tr>
        </thead>
        <tbody>
        \(table.rows.map { "<tr>\(bodyCellsHTML($0, table: table))</tr>" }.joined(separator: "\n"))
        </tbody>
        </table>
        </div>
        """
    }

    private mutating func headerCellsHTML(_ table: TableBlock) -> String {
        table.header.enumerated().map { column, cell in
            cellHTML(cell, tag: "th", table: table, column: column)
        }.joined()
    }

    private mutating func bodyCellsHTML(
        _ row: [TableCell],
        table: TableBlock
    ) -> String {
        row.enumerated().map { column, cell in
            cellHTML(cell, tag: "td", table: table, column: column)
        }.joined()
    }

    private mutating func cellHTML(
        _ cell: TableCell,
        tag: String,
        table: TableBlock,
        column: Int
    ) -> String {
        var attributes = ""
        if cell.colspan > 1 {
            attributes += " colspan=\"\(cell.colspan)\""
        }
        if cell.rowspan > 1 {
            attributes += " rowspan=\"\(cell.rowspan)\""
        }
        if column < table.alignments.count {
            switch table.alignments[column] {
            case .left:
                attributes += " style=\"text-align: left\""
            case .center:
                attributes += " style=\"text-align: center\""
            case .right:
                attributes += " style=\"text-align: right\""
            case .none:
                break
            }
        }
        return "<\(tag)\(attributes)>\(scopedInlinesHTML(cell.inlines))</\(tag)>"
    }

    // MARK: TOC

    private mutating func tocHTML() -> String {
        guard !headings.rows.isEmpty else {
            return """
            <nav class="toc" aria-label="Table of contents">
            <p class="toc-empty">No headings</p>
            </nav>
            """
        }
        var rows: [String] = []
        for row in headings.rows {
            let label = escapeText(
                row.text.isEmpty ? "Untitled heading" : row.text
            )
            let indent = AppTheme.Spacing.md * CGFloat(row.indent)
            let content: String
            if let slug = row.slug {
                content = "<a href=\"#\(escapeAttribute(slug))\">\(label)</a>"
            } else {
                content = "<span>\(label)</span>"
            }
            rows.append(
                "<li style=\"padding-left: \(points(indent))\">\(content)</li>"
            )
        }
        if headings.totalRowCount > headings.rows.count {
            let remaining = headings.totalRowCount - headings.rows.count
            rows.append(
                "<li class=\"toc-more\">+\(remaining) more headings</li>"
            )
        }
        return """
        <nav class="toc" aria-label="Table of contents">
        <ul>
        \(rows.joined(separator: "\n"))
        </ul>
        </nav>
        """
    }

    // MARK: Footnotes

    private mutating func footnotesHTML(_ section: FootnoteSection) -> String {
        guard !section.entries.isEmpty else { return "" }
        var items: [String] = []
        for entry in section.entries {
            let backrefs: String
            if !entry.referenceRanges.isEmpty {
                let links = entry.referenceRanges.indices.map { index in
                    let ordinal = index + 1
                    let id = ordinal == 1
                        ? "fnref-\(entry.number)"
                        : "fnref-\(entry.number)-\(ordinal)"
                    return "<a class=\"backref\" href=\"#\(id)\" aria-label=\"Back to reference \(ordinal) of footnote \(entry.number)\">↩</a>"
                }
                backrefs = "<span class=\"backrefs\">\(links.joined(separator: " "))</span>"
            } else {
                backrefs = ""
            }
            let body = scopedInlinesHTML(entry.inlines)
            let trailing = backrefs.isEmpty ? "" : " \(backrefs)"
            items.append(
                "<li id=\"fn-\(entry.number)\"><span class=\"footnote-number\">\(entry.number).</span><div class=\"footnote-body\"><p>\(body)\(trailing)</p></div></li>"
            )
        }
        return """
        <section class="footnotes">
        <hr>
        <p class="footnotes-title">Footnotes</p>
        <ol>
        \(items.joined(separator: "\n"))
        </ol>
        </section>
        """
    }

    // MARK: Inlines

    private mutating func inlinesHTML(_ inlines: [Inline]) -> String {
        inlines.map { inlineHTML($0) }.joined()
    }

    /// Renders one block-level inline sequence in its own inline-HTML
    /// scope. An opener left unmatched inside the block is closed at the
    /// block's end and cannot style or swallow later blocks; the reader's
    /// per-container styling has the same boundary.
    private mutating func scopedInlinesHTML(_ inlines: [Inline]) -> String {
        let saved = inlineHTMLStack
        inlineHTMLStack = []
        var html = inlinesHTML(inlines)
        for tag in inlineHTMLStack.reversed() {
            html += tag.closeTag
        }
        inlineHTMLStack = saved
        return html
    }

    private mutating func inlineHTML(_ inline: Inline) -> String {
        switch inline {
        case let .text(value, _):
            return escapeText(value)

        case .softBreak:
            return "\n"

        case .lineBreak:
            return "<br>\n"

        case let .inlineCode(value, _):
            return "<code>\(escapeText(value))</code>"

        case let .emphasis(children, _):
            return "<em>\(inlinesHTML(children))</em>"

        case let .strong(children, _):
            return "<strong>\(inlinesHTML(children))</strong>"

        case let .strikethrough(children, _):
            return "<del>\(inlinesHTML(children))</del>"

        case let .link(destination, title, children, _):
            return linkHTML(
                destination: destination,
                title: title,
                label: inlinesHTML(children)
            )

        case let .image(destination, title, description, _):
            return inlineImage(
                destination: destination,
                title: title,
                alt: HeadingIndex.renderedText(description)
            )

        case let .inlineHTML(raw, _):
            // Only the RB-26 allowlist survives; every other raw HTML
            // element stays hidden, as it does in the reader. A closing tag
            // is emitted only when its opener did, so a rejected
            // `<mark class="x">` cannot leave a stray `</mark>` behind.
            guard let match = MarkdownInlineHTML.match(raw) else {
                return ""
            }
            if match.isClosing {
                guard let index = inlineHTMLStack.lastIndex(of: match.tag)
                else { return "" }
                inlineHTMLStack.remove(at: index)
                return match.tag.closeTag
            }
            inlineHTMLStack.append(match.tag)
            return match.tag.openTag

        case let .wikiLink(link, _):
            return "<span class=\"wiki-link\" title=\"\(escapeAttribute(link.targetWithFragment))\">\(escapeText(link.display))</span>"

        case let .footnoteReference(reference, _):
            let ordinal = (footnoteOrdinals[reference.number] ?? 0) + 1
            footnoteOrdinals[reference.number] = ordinal
            let id = ordinal == 1
                ? "fnref-\(reference.number)"
                : "fnref-\(reference.number)-\(ordinal)"
            return "<sup class=\"footnote-ref\"><a href=\"#fn-\(reference.number)\" id=\"\(id)\">\(reference.number)</a></sup>"

        case let .math(source, raw, display, _):
            // Block layout is decided by the paragraph case above. A math
            // node reached here is inside a footnote, table cell, or other
            // inline container, where a block element would be invalid.
            return mathHTML(
                MarkdownMathPayload(
                    source: source,
                    raw: raw,
                    display: display
                ),
                inline: true
            )
        }
    }

    private static func displayMath(
        _ inlines: [Inline]
    ) -> MarkdownMathPayload? {
        guard let match = MarkdownInlineMath.soleDisplay(in: inlines) else {
            return nil
        }
        return MarkdownMathPayload(
            source: match.source,
            raw: match.raw,
            display: true
        )
    }

    private func mathHTML(
        _ payload: MarkdownMathPayload,
        inline: Bool
    ) -> String {
        guard let asset = context.math[payload.key] else {
            return "<span class=\"math math-literal\">\(escapeText(payload.raw))</span>"
        }
        let light = "data:image/png;base64,\(asset.lightPNG.base64EncodedString())"
        let dark = asset.darkPNG.map {
            "data:image/png;base64,\($0.base64EncodedString())"
        }
        let size = "width: \(points(asset.width)); height: \(points(asset.height))"
        let style = inline
            ? "\(size); vertical-align: -\(points(asset.descent))"
            : "width: \(points(asset.width)); height: auto; max-width: 100%"
        let image = "<img class=\"math-image\" src=\"\(light)\" alt=\"\(escapeAttribute(payload.source.trimmingCharacters(in: .whitespacesAndNewlines)))\" style=\"\(style)\">"
        let picture: String
        if !forPrint, let dark {
            // Screen only: print media forces the light palette, so a dark
            // formula image chosen for a dark-mode print would be unreadable
            // on the light page.
            picture = "<picture><source media=\"screen and (prefers-color-scheme: dark)\" srcset=\"\(dark)\">\(image)</picture>"
        } else {
            picture = image
        }
        if inline {
            return "<span class=\"math math-inline\">\(picture)</span>"
        }
        return "<div class=\"math math-display\">\(picture)</div>"
    }

    private func linkHTML(
        destination: String,
        title: String?,
        label: String
    ) -> String {
        let titleAttribute = title.map {
            " title=\"\(escapeAttribute($0))\""
        } ?? ""

        switch MarkdownSecurity.linkDecision(for: destination) {
        case .allowed(.external):
            guard URL(string: destination) != nil else {
                return "<span class=\"denied-link\">\(label)</span>"
            }
            return "<a href=\"\(escapeAttribute(destination))\"\(titleAttribute) rel=\"noopener noreferrer\">\(label)</a>"

        case .allowed(.mailto):
            guard URL(string: destination) != nil else {
                return "<span class=\"denied-link\">\(label)</span>"
            }
            return "<a href=\"\(escapeAttribute(destination))\"\(titleAttribute)>\(label)</a>"

        case .allowed(.fragment):
            return "<a href=\"\(escapeAttribute(destination))\"\(titleAttribute)>\(label)</a>"

        case .allowed(.local):
            // The export is one file; a workspace-local target travels only
            // by coincidence. Keep the label and the destination visible but
            // do not emit a link that would silently break.
            return "<span class=\"local-link\" data-destination=\"\(escapeAttribute(destination))\"\(titleAttribute)>\(label)</span>"

        case .allowed(.media):
            return "<span class=\"local-link\">\(label)</span>"

        case .denied:
            return "<span class=\"denied-link\">\(label)</span>"
        }
    }

    // MARK: Images

    private mutating func blockImage(
        destination: String,
        title: String?,
        alt: String
    ) -> String {
        guard let uri = imageURI(for: destination) else {
            return "<div class=\"image-placeholder\">\(escapeText(alt.isEmpty ? destination : alt))</div>"
        }
        return "<figure class=\"image\">\(imageTag(uri: uri, title: title, alt: alt))</figure>"
    }

    private mutating func inlineImage(
        destination: String,
        title: String?,
        alt: String
    ) -> String {
        guard let uri = imageURI(for: destination) else {
            return "<span class=\"image-placeholder\">\(escapeText(alt.isEmpty ? destination : alt))</span>"
        }
        return imageTag(uri: uri, title: title, alt: alt)
    }

    private func imageTag(uri: String, title: String?, alt: String) -> String {
        let titleAttribute = title.map {
            " title=\"\(escapeAttribute($0))\""
        } ?? ""
        return "<img src=\"\(uri)\" alt=\"\(escapeAttribute(alt))\"\(titleAttribute)>"
    }

    /// Resolves a document-relative image and embeds its original bytes.
    ///
    /// Only raster formats are embedded. An SVG can carry script, remote
    /// images would require a network request, and a missing or oversized
    /// file becomes a visible placeholder — the same policy the viewer uses.
    private mutating func imageURI(for destination: String) -> String? {
        if let cached = imageURIs[destination] { return cached }
        if failedImages.contains(destination) { return nil }
        guard let uri = loadImageURI(for: destination) else {
            failedImages.insert(destination)
            return nil
        }
        imageURIs[destination] = uri
        return uri
    }

    private func loadImageURI(for destination: String) -> String? {
        guard let documentURL = context.documentURL else { return nil }
        let root = context.workspaceRoot
            ?? documentURL.deletingLastPathComponent()
        guard let url = MarkdownSecurity.resolveLocalPath(
            destination,
            relativeTo: documentURL,
            root: root
        ) else {
            return nil
        }
        guard let data = BoundedImageLoader.encodedData(at: url),
              BoundedImageLoader.image(from: data) != nil else {
            return nil
        }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), let typeIdentifier = CGImageSourceGetType(source) as String?,
           let type = UTType(typeIdentifier),
           let mime = type.preferredMIMEType,
           mime.hasPrefix("image/"),
           mime != "image/svg+xml" else {
            return nil
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    // MARK: Stylesheet

    func stylesheet() -> String {
        let theme = context.theme
        let css = """
        :root {
          color-scheme: light dark;
        \(variables(for: theme.light))
        \(syntaxVariables(for: .aqua))
        \(alertVariables(for: .aqua))
          --body-font: \(fontStack(theme.bodyFont));
          --heading-font: \(fontStack(theme.headingFont));
          --ui-font: \(fontStack(theme.uiFont));
          --code-font: \(fontStack(theme.codeFont));
          --body-size: \(points(theme.bodySize));
          --body-leading: \(points(theme.bodySize + theme.bodyLineSpacing));
          --code-size: \(points(theme.codeSize));
          --code-leading: \(points(theme.codeSize + theme.codeLineSpacing));
          --table-size: \(points(theme.tableSize));
          --caption-size: \(points(theme.captionSize));
          --measure: \(points(theme.measure));
          --page-padding: \(points(theme.pagePadding));
          --block-spacing: \(points(theme.blockSpacing));
          --code-padding: \(points(theme.codePadding));
          --code-radius: \(points(theme.codeRadius));
          --paragraph-indent: \(points(theme.bodySize * theme.paragraphIndent));
        }

        @media (prefers-color-scheme: dark) {
          :root {
        \(variables(for: theme.dark))
        \(syntaxVariables(for: .darkAqua))
        \(alertVariables(for: .darkAqua))
          }
        }

        * {
          box-sizing: border-box;
          -webkit-print-color-adjust: exact;
          print-color-adjust: exact;
        }

        html {
          background: var(--paper);
        }

        body {
          margin: 0;
          background: var(--paper);
          color: var(--ink);
          font-family: var(--body-font);
          font-size: var(--body-size);
          line-height: var(--body-leading);
          -webkit-font-smoothing: antialiased;
          text-rendering: optimizeLegibility;
        }

        .sonovo {
          max-width: var(--measure);
          margin: 0 auto;
          padding: var(--page-padding);
        }

        p {
          margin: 0 0 var(--block-spacing);
        }

        .indent {
          padding-left: var(--paragraph-indent);
        }

        h1, h2, h3, h4, h5, h6 {
          font-family: var(--heading-font);
          color: var(--ink);
          line-height: \(AppTheme.MarkdownChrome.Export.headingLineHeight);
          margin: 0 0 var(--block-spacing);
          break-after: avoid;
        }

        h1 {
          font-size: \(points(theme.headingSize(1)));
          font-weight: 700;
          padding-top: \(points(theme.headingTopPadding(1)));
        }

        h2, h3, h4, h5, h6 {
          font-weight: 600;
        }

        h2 { font-size: \(points(theme.headingSize(2))); padding-top: \(points(theme.headingTopPadding(2))); }
        h3 { font-size: \(points(theme.headingSize(3))); padding-top: \(points(theme.headingTopPadding(3))); }
        h4 { font-size: \(points(theme.headingSize(4))); padding-top: \(points(theme.headingTopPadding(4))); }
        h5 { font-size: \(points(theme.headingSize(5))); padding-top: \(points(theme.headingTopPadding(5))); }
        h6 { font-size: \(points(theme.headingSize(6))); padding-top: \(points(theme.headingTopPadding(6))); }

        a {
          color: var(--link);
          text-decoration: none;
        }

        a:hover {
          text-decoration: underline;
        }

        .local-link {
          color: var(--link);
          text-decoration: underline;
          text-decoration-style: dotted;
        }

        .denied-link {
          color: var(--secondary-ink);
        }

        .wiki-link {
          color: var(--link);
          text-decoration: underline;
          text-decoration-style: dotted;
        }

        .math-inline {
          white-space: nowrap;
        }

        .math-image {
          max-width: 100%;
        }

        /* The base sheet makes images block-level illustrations; a formula is
           a text run and must stay in its line. */
        .math-inline .math-image,
        .math-display .math-image {
          display: inline;
          border-radius: 0;
        }

        .math-display {
          margin: 0 0 var(--block-spacing);
          text-align: center;
        }

        .math-display .math-image {
          height: auto;
        }

        .math-literal {
          font-family: var(--code-font);
          color: var(--secondary-ink);
          white-space: pre-wrap;
        }

        /* RB-26 inline HTML. `u`, `sup`, and `sub` use the browser's
           default geometry; only `mark` needs a theme-aware tint because
           the default yellow ignores the reading theme. */
        mark {
          background: \(css(markHighlight));
          color: inherit;
        }

        .mermaid-block {
          margin: 0 0 var(--block-spacing);
          padding: var(--code-padding);
          background: var(--code-ground);
          border-radius: var(--code-radius);
        }

        .mermaid svg {
          display: block;
          max-width: 100%;
          height: auto;
          margin: 0 auto;
        }

        .mermaid-dark {
          display: none;
        }

        dl {
          margin: 0 0 var(--block-spacing);
        }

        .definition-item {
          margin: 0 0 var(--block-spacing);
        }

        dt {
          font-weight: 600;
        }

        dd {
          margin: 0;
          padding-left: \(points(AppTheme.Spacing.lg));
        }

        .diagram-block {
          margin: 0 0 var(--block-spacing);
          padding: var(--code-padding);
          background: var(--code-ground);
          border-radius: var(--code-radius);
        }

        .diagram svg {
          display: block;
          max-width: 100%;
          height: auto;
          margin: 0 auto;
        }

        .diagram-dark {
          display: none;
        }

        /* An authored SVG keeps its own colours, so its figure stays on a
           light paper surface in either palette. */
        .svg-fence {
          margin: 0 0 var(--block-spacing);
          padding: var(--code-padding);
          background: \(css(theme.light.paper));
          border-radius: var(--code-radius);
        }

        .svg-fence svg {
          display: block;
          max-width: 100%;
          height: auto;
          margin: 0 auto;
        }

        @media (prefers-color-scheme: dark) {
          .mermaid-light { display: none; }
          .mermaid-dark { display: block; }
          .diagram-light { display: none; }
          .diagram-dark { display: block; }
        }

        blockquote {
          margin: 0 0 var(--block-spacing);
          padding-left: \(points(AppTheme.Spacing.md));
          border-left: \(points(AppTheme.BorderWidth.thick)) solid var(--quote-bar);
        }

        blockquote > :last-child {
          margin-bottom: 0;
        }

        .alert {
          margin: 0 0 var(--block-spacing);
          padding: \(points(AppTheme.MarkdownChrome.Alerts.inset));
          background: var(--alert-bg);
          border-left: \(points(AppTheme.MarkdownChrome.Alerts.borderWidth)) solid var(--alert-color);
          border-radius: var(--code-radius);
        }

        .alert-title {
          margin: 0 0 \(points(AppTheme.Spacing.xs));
          font-family: var(--ui-font);
          font-size: var(--caption-size);
          font-weight: 600;
          color: var(--alert-color);
        }

        .alert > :last-child {
          margin-bottom: 0;
        }

        .alert-note { --alert-color: var(--alert-note); --alert-bg: var(--alert-note-bg); }
        .alert-tip { --alert-color: var(--alert-tip); --alert-bg: var(--alert-tip-bg); }
        .alert-important { --alert-color: var(--alert-important); --alert-bg: var(--alert-important-bg); }
        .alert-warning { --alert-color: var(--alert-warning); --alert-bg: var(--alert-warning-bg); }
        .alert-caution { --alert-color: var(--alert-caution); --alert-bg: var(--alert-caution-bg); }

        ul, ol {
          margin: 0 0 var(--block-spacing);
          padding-left: \(points(AppTheme.Spacing.xl));
        }

        li {
          margin: 0;
        }

        li + li {
          margin-top: \(points(AppTheme.Spacing.sm));
        }

        li > .item > :last-child,
        li > .task-body > :last-child {
          margin-bottom: 0;
        }

        li > .item > ul,
        li > .item > ol,
        li > .task-body > ul,
        li > .task-body > ol {
          margin-top: \(points(AppTheme.Spacing.sm));
          margin-bottom: 0;
        }

        .task-list {
          list-style: none;
          padding-left: 0;
        }

        .task-item {
          display: grid;
          grid-template-columns: auto 1fr;
          column-gap: \(points(AppTheme.Spacing.sm));
          align-items: start;
        }

        .task-item input {
          margin: \(points(AppTheme.Spacing.xxs)) 0 0;
        }

        .task-body {
          min-width: 0;
        }

        .code-block {
          margin: 0 0 var(--block-spacing);
          padding: var(--code-padding);
          background: var(--code-ground);
          border-radius: var(--code-radius);
          overflow-x: auto;
        }

        .code-header {
          margin-bottom: \(points(AppTheme.Spacing.xs));
          font-family: var(--ui-font);
          font-size: var(--caption-size);
          color: var(--secondary-ink);
        }

        pre {
          margin: 0;
          font-family: var(--code-font);
          font-size: var(--code-size);
          line-height: var(--code-leading);
          white-space: pre;
          tab-size: 4;
        }

        pre code {
          font-family: inherit;
          font-size: inherit;
        }

        :not(pre) > code {
          padding: \(points(AppTheme.MarkdownChrome.Export.inlineCodeVerticalPadding)) \(points(AppTheme.MarkdownChrome.Export.inlineCodeHorizontalPadding));
          border-radius: \(points(AppTheme.Radius.micro));
          background: var(--code-ground);
          color: var(--code-ink);
          font-family: var(--code-font);
          font-size: var(--code-size);
        }

        .tok-keyword { color: var(--syntax-keyword); }
        .tok-type { color: var(--syntax-type); }
        .tok-string { color: var(--syntax-string); }
        .tok-comment { color: var(--syntax-comment); }
        .tok-number { color: var(--syntax-number); }
        .tok-function { color: var(--syntax-function); }
        .tok-property { color: var(--syntax-property); }
        .tok-punctuation { color: var(--syntax-punctuation); }
        .tok-identifier { color: var(--syntax-identifier); }
        .tok-markup { color: var(--syntax-markup); }
        .tok-inserted { color: var(--syntax-inserted); }
        .tok-deleted { color: var(--syntax-deleted); }

        hr {
          margin: var(--block-spacing) 0;
          border: 0;
          border-top: \(points(AppTheme.BorderWidth.hairline)) solid var(--rule);
        }

        .table-wrap {
          margin: 0 0 var(--block-spacing);
          background: var(--table-ground);
          border-radius: \(points(AppTheme.Radius.surface));
          overflow-x: auto;
        }

        table {
          width: 100%;
          border-collapse: collapse;
          font-family: var(--ui-font);
          font-size: var(--table-size);
        }

        th, td {
          padding: \(points(AppTheme.Spacing.s6)) \(points(AppTheme.Spacing.md));
          vertical-align: top;
        }

        th {
          font-weight: 600;
        }

        .image {
          margin: 0 0 var(--block-spacing);
        }

        img {
          display: block;
          max-width: 100%;
          height: auto;
          border-radius: \(points(AppTheme.Radius.surface));
        }

        .image-placeholder {
          display: inline-block;
          padding: \(points(AppTheme.Spacing.md));
          border-radius: \(points(AppTheme.Radius.surface));
          background: var(--code-ground);
          color: var(--secondary-ink);
          font-family: var(--ui-font);
          font-size: var(--caption-size);
        }

        details {
          margin: 0 0 var(--block-spacing);
        }

        summary {
          font-weight: 600;
          cursor: default;
        }

        .details-body {
          padding-left: \(points(AppTheme.Spacing.md));
          padding-top: \(points(AppTheme.Spacing.xs));
        }

        .details-body > :last-child {
          margin-bottom: 0;
        }

        .toc {
          margin: 0 0 var(--block-spacing);
          padding: \(points(AppTheme.Spacing.md));
          background: var(--code-ground);
          border-radius: \(points(AppTheme.Radius.surface));
        }

        .toc ul {
          margin: 0;
          padding: 0;
          list-style: none;
        }

        .toc li {
          margin: 0 0 \(points(AppTheme.Spacing.xxs));
        }

        .toc a {
          color: var(--ink);
          font-family: var(--ui-font);
          font-size: var(--table-size);
        }

        .toc-empty,
        .toc-more {
          margin: 0;
          color: var(--secondary-ink);
          font-family: var(--ui-font);
          font-size: var(--caption-size);
        }

        .footnotes {
          margin-top: \(points(AppTheme.Spacing.lg));
        }

        .footnotes > hr {
          margin: 0 0 \(points(AppTheme.Spacing.sm));
        }

        .footnotes-title {
          margin: 0 0 \(points(AppTheme.Spacing.sm));
          color: var(--secondary-ink);
          font-family: var(--ui-font);
          font-size: var(--caption-size);
        }

        .footnotes ol {
          margin: 0;
          padding: 0;
          list-style: none;
        }

        .footnotes li {
          display: grid;
          grid-template-columns: auto 1fr;
          column-gap: \(points(AppTheme.Spacing.sm));
          margin: 0 0 \(points(AppTheme.Spacing.sm));
        }

        .footnote-number {
          color: var(--secondary-ink);
        }

        .footnote-body p {
          margin: 0;
        }

        .footnote-ref {
          font-size: \(points(theme.bodySize * AppTheme.Reading.footnoteScale));
          line-height: 0;
        }

        .backrefs {
          font-size: var(--caption-size);
        }

        .backref {
          color: var(--link);
        }

        @media print {
          :root {
        \(variables(for: theme.light))
        \(syntaxVariables(for: .aqua))
        \(alertVariables(for: .aqua))
          }

          html, body {
            background: var(--paper);
          }

          .sonovo {
            max-width: none;
            padding: 0;
          }

          .code-block {
            overflow: visible;
          }

          pre {
            white-space: pre-wrap;
            overflow-wrap: anywhere;
          }

          .table-wrap {
            overflow: visible;
          }

          tr, img, figure, .mermaid-block, .diagram-block, .svg-fence, .code-block, blockquote, .alert, .toc {
            break-inside: avoid;
          }

          .mermaid-dark, .diagram-dark { display: none !important; }
          .mermaid-light, .diagram-light { display: block !important; }
        }
        """
        return css
    }

    private func variables(for palette: ThemePalette) -> String {
        """
          --paper: \(css(palette.paper));
          --ink: \(css(palette.ink));
          --secondary-ink: \(css(palette.secondaryInk));
          --link: \(css(palette.link));
          --code-ground: \(css(palette.codeGround));
          --code-ink: \(css(palette.codeInk));
          --quote-bar: \(css(palette.quoteBar));
          --rule: \(css(palette.rule));
          --table-ground: \(css(palette.tableGround));
          --warning: \(css(palette.warning));
        """
    }

    private func syntaxVariables(for appearance: NSAppearance.Name) -> String {
        let roles: [(String, AppTheme.SyntaxRole)] = [
            ("keyword", .keyword),
            ("type", .typeName),
            ("string", .string),
            ("comment", .comment),
            ("number", .number),
            ("function", .function),
            ("property", .property),
            ("punctuation", .punctuation),
            ("identifier", .identifier),
            ("markup", .markup),
            ("inserted", .inserted),
            ("deleted", .deleted)
        ]
        let lines = roles.map { role, syntaxRole in
            "  --syntax-\(role): \(css(AppTheme.Syntax.color(for: syntaxRole), in: appearance));"
        }
        return lines.joined(separator: "\n")
    }

    private func alertVariables(for appearance: NSAppearance.Name) -> String {
        let lines = MarkdownAlertKind.allCases.map { kind -> String in
            let color = NSColor(kind.color)
            let solid = css(color, in: appearance)
            let tinted = css(
                color,
                in: appearance,
                alpha: AppTheme.Opacity.subtle
            )
            return "  --alert-\(kind.rawValue): \(solid);\n  --alert-\(kind.rawValue)-bg: \(tinted);"
        }
        return lines.joined(separator: "\n")
    }

    private func fontStack(_ font: ThemeFont) -> String {
        var families = font.families
        if let resolved = font.resolvedFamily, !families.contains(resolved) {
            families.insert(resolved, at: 0)
        }
        let quoted = families.map { family in
            let escaped = family
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                // CSS escapes for angle brackets. Without them a family
                // name containing `</style>` would end the stylesheet and
                // let a theme inject markup into the export; CSP does not
                // stop markup injection.
                .replacingOccurrences(of: "<", with: "\\3C ")
                .replacingOccurrences(of: ">", with: "\\3E ")
            return "\"\(escaped)\""
        }
        let generic: String
        switch font.design {
        case .serif: generic = "serif"
        case .sans: generic = "sans-serif"
        case .mono: generic = "monospace"
        }
        return (quoted + [generic]).joined(separator: ", ")
    }

    /// The PDF capture has no paged media: WebKit snapshots the whole
    /// document in one tall page and the exporter slices it into A4. This
    /// override removes the screen measure and padding so the content uses
    /// the printable width, keeps the light palette, and lets long code and
    /// tables wrap instead of being clipped horizontally.
    func pdfOverride() -> String {
        """
        :root {
        \(variables(for: context.theme.light))
        \(syntaxVariables(for: .aqua))
        \(alertVariables(for: .aqua))
        }

        .sonovo {
          max-width: none;
          padding: 0;
        }

        .table-wrap, .code-block {
          overflow: visible;
        }

        pre {
          white-space: pre-wrap;
          overflow-wrap: anywhere;
        }
        """
    }

    // MARK: Formatting

    private func points(_ value: CGFloat) -> String {
        String(format: "%.2fpx", Double(value))
    }

    /// The `<mark>` tint: the light palette's warning ink at the standard
    /// border opacity, so the highlight matches the reader.
    private var markHighlight: ThemeColor {
        let warning = context.theme.palette(for: .light).warning
        return ThemeColor(
            red: warning.red,
            green: warning.green,
            blue: warning.blue,
            alpha: AppTheme.Opacity.borderStrong
        )
    }

    private func css(_ color: ThemeColor) -> String {
        let red = UInt32((color.red * 255).rounded())
        let green = UInt32((color.green * 255).rounded())
        let blue = UInt32((color.blue * 255).rounded())
        if color.alpha >= 1 {
            return String(format: "#%02X%02X%02X", red, green, blue)
        }
        return String(
            format: "rgba(%u, %u, %u, %.3f)",
            red,
            green,
            blue,
            color.alpha
        )
    }

    private func css(
        _ color: NSColor,
        in appearance: NSAppearance.Name,
        alpha: Double? = nil
    ) -> String {
        var resolved: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        guard let resolved else { return "currentColor" }
        let red = UInt32((resolved.redComponent * 255).rounded())
        let green = UInt32((resolved.greenComponent * 255).rounded())
        let blue = UInt32((resolved.blueComponent * 255).rounded())
        let opacity = alpha ?? Double(resolved.alphaComponent)
        return String(
            format: "rgba(%u, %u, %u, %.3f)",
            red,
            green,
            blue,
            opacity
        )
    }
}

// MARK: - Escaping

/// Escapes text for HTML element content.
private func escapeText(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

/// Escapes text for a double-quoted HTML attribute.
private func escapeAttribute(_ text: String) -> String {
    escapeText(text)
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}
