import AppKit
import SonovoCore
import SwiftUI

/// How a wiki link should be styled.
enum WikiLinkVisualState: Sendable, Equatable {
    case normal
    case missing
    case ambiguous
}

/// The read-only SwiftUI projection of `SonovoAST`.
///
/// The viewer never parses Markdown and never loads a web view. Raw HTML is
/// hidden; details and TOC are the only structural constructs. Expansion state
/// is view state and is reconciled by content after a reparse.
struct MarkdownViewer: View {
    let ast: SonovoAST
    let headings: HeadingIndex
    let theme: MarkdownTheme
    let documentURL: URL?
    let workspaceRoot: URL?
    let wikiLinkState: (WikiLink) -> WikiLinkVisualState
    let onOpenWikiLink: ((WikiLink) -> Void)?
    let onOpenLocalLink: ((String) -> Void)?
    let onOpenExternalURL: ((URL) -> Void)?
    let onEditInSource: ((SourceRange) -> Void)?
    let scrollTarget: Binding<String?>?
    let lintDiagnostics: [MarkdownDiagnostic]
    let find: RenderedFindController

    private let detailsIndices: [Int: Int]
    private let detailsRanges: [(index: Int, range: SourceRange)]
    private let headingIDs: [Int: String]
    private let headingByScrollID: [String: HeadingEntry]

    @State private var expansion: [Int: Bool] = [:]
    @State private var keys: [DetailsContentKey] = []
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ThemePalette {
        theme.palette(for: colorScheme)
    }

    init(
        ast: SonovoAST,
        headings: HeadingIndex,
        theme: MarkdownTheme,
        documentURL: URL? = nil,
        workspaceRoot: URL? = nil,
        wikiLinkState: @escaping (WikiLink) -> WikiLinkVisualState = { _ in .normal },
        onOpenWikiLink: ((WikiLink) -> Void)? = nil,
        onOpenLocalLink: ((String) -> Void)? = nil,
        onOpenExternalURL: ((URL) -> Void)? = nil,
        onEditInSource: ((SourceRange) -> Void)? = nil,
        scrollTarget: Binding<String?>? = nil,
        lintDiagnostics: [MarkdownDiagnostic] = [],
        find: RenderedFindController = RenderedFindController()
    ) {
        self.ast = ast
        self.headings = headings
        self.theme = theme
        self.documentURL = documentURL
        self.workspaceRoot = workspaceRoot
        self.wikiLinkState = wikiLinkState
        self.onOpenWikiLink = onOpenWikiLink
        self.onOpenLocalLink = onOpenLocalLink
        self.onOpenExternalURL = onOpenExternalURL
        self.onEditInSource = onEditInSource
        self.scrollTarget = scrollTarget
        self.lintDiagnostics = lintDiagnostics
        self.find = find

        let metadata = Self.detailsMetadata(for: ast)
        self.detailsIndices = metadata.map
        self.detailsRanges = metadata.ranges

        var ids: [Int: String] = [:]
        var byID: [String: HeadingEntry] = [:]
        for entry in headings.headings {
            if let range = entry.range {
                ids[range.lowerBound] = entry.scrollID
            }
            if let scrollID = entry.scrollID {
                byID[scrollID] = entry
            }
        }
        self.headingIDs = ids
        self.headingByScrollID = byID
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: AppTheme.Spacing.zero) {
                if find.isVisible {
                    RenderedFindBar(find: find)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.blockSpacing) {
                        blocksView(ast.blocks, proxy: proxy)
                    }
                    .frame(maxWidth: theme.measure, alignment: .leading)
                    .padding(.horizontal, theme.pagePadding)
                    .padding(.vertical, theme.pagePadding)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .background(palette.paper.color)
                .onAppear {
                    reconcile(initial: true)
                    consumeScrollTarget(proxy: proxy)
                    // A document switch remounts the viewer while the bar can
                    // stay open; matches must follow the new document.
                    recomputeFind(proxy: proxy)
                }
                .onChange(of: ast) { _, _ in
                    reconcile(initial: false)
                    consumeScrollTarget(proxy: proxy)
                    recomputeFind(proxy: proxy)
                }
                .onChange(of: scrollTarget?.wrappedValue) { _, _ in
                    consumeScrollTarget(proxy: proxy)
                }
            }
            .onChange(of: find.isVisible) { _, visible in
                if visible {
                    recomputeFind(proxy: proxy)
                } else {
                    find.setMatches([])
                }
            }
            .onChange(of: find.query) { _, _ in
                recomputeFind(proxy: proxy)
            }
            .onChange(of: find.currentIndex) { _, _ in
                scrollToCurrent(proxy)
            }
        }
    }

    /// Consumes a navigation target queued by the workspace. The binding is
    /// cleared after the scroll so a later document switch does not replay
    /// the previous target.
    private func consumeScrollTarget(proxy: ScrollViewProxy) {
        guard let target = scrollTarget?.wrappedValue else { return }
        scroll(to: target, proxy: proxy)
        DispatchQueue.main.async {
            if scrollTarget?.wrappedValue == target {
                scrollTarget?.wrappedValue = nil
            }
        }
    }

    // MARK: - Find

    private func recomputeFind(proxy: ScrollViewProxy) {
        guard find.isVisible else {
            find.setMatches([])
            return
        }
        let blocks = MarkdownRenderedSearch.blocks(ast)
        find.setMatches(
            MarkdownRenderedSearch.matches(
                query: find.query,
                blocks: blocks
            )
        )
        scrollToCurrent(proxy)
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let match = find.current,
              match.blockIndex < ast.blocks.count else {
            return
        }
        let anchor = blockAnchor(
            ast.blocks[match.blockIndex],
            index: match.blockIndex
        )
        withAnimation { proxy.scrollTo(anchor, anchor: .center) }
    }

    private func blockAnchor(_ block: Block, index: Int) -> String {
        if case .heading(_, _, let range) = block,
           let range,
           let id = headingIDs[range.lowerBound] {
            return id
        }
        return "block-\(index)"
    }

    // MARK: - Blocks

    private func blocksView(_ blocks: [Block], proxy: ScrollViewProxy) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: theme.blockSpacing) {
                ForEach(blocks.indices, id: \.self) { index in
                    let block = blocks[index]
                    let content = blockView(
                        block,
                        previous: index > 0 ? blocks[index - 1] : nil,
                        proxy: proxy
                    )
                    if case .heading(_, _, let range) = block,
                       let range,
                       headingIDs[range.lowerBound] != nil {
                        content
                    } else {
                        content.id("block-\(index)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    private func blockView(
        _ block: Block,
        previous: Block?,
        proxy: ScrollViewProxy
    ) -> AnyView {
        let content: AnyView
        switch block {
        case let .heading(level, inlines, range):
            content = headingBlockView(
                level: level,
                inlines: inlines,
                range: range,
                proxy: proxy
            )
        case let .paragraph(inlines, _):
            content = paragraphBlockView(
                inlines,
                indented: isIndentedParagraph(after: previous),
                proxy: proxy
            )
        case let .blockQuote(blocks, _):
            content = blockQuoteView(blocks, proxy: proxy)
        case let .list(list, _):
            content = AnyView(listView(list, proxy: proxy))
        case let .codeBlock(code, _):
            content = AnyView(codeBlockView(code))
        case .thematicBreak:
            content = AnyView(
                Rectangle()
                    .fill(palette.rule.color)
                    .frame(height: AppTheme.BorderWidth.hairline)
            )
        case let .table(table, _):
            content = AnyView(tableView(table, proxy: proxy))
        case let .details(details, range):
            content = detailsBlockView(
                details,
                range: range,
                proxy: proxy
            )
        case .tableOfContents:
            content = AnyView(tocView(proxy: proxy))
        case .htmlBlock:
            content = AnyView(EmptyView())
        }

        let display = lintMarked(content, for: block)
        guard let range = block.range, let onEditInSource else {
            return display
        }
        return AnyView(
            display.contextMenu {
                Button("Edit in Source") {
                    onEditInSource(range)
                }
            }
        )
    }

    /// A blockquote whose first text begins with a GitHub alert marker is
    /// presented as a labelled callout. Source bytes are never changed; the
    /// marker is stripped only from this projection.
    private func blockQuoteView(
        _ blocks: [Block],
        proxy: ScrollViewProxy
    ) -> AnyView {
        guard let kind = alertKind(for: blocks) else {
            return AnyView(
                HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.line)
                        .fill(palette.quoteBar.color)
                        .frame(width: AppTheme.BorderWidth.thick)
                    blocksView(blocks, proxy: proxy)
                }
                .padding(.leading, AppTheme.Spacing.xs)
            )
        }

        let content = strippingAlertMarker(blocks, kind: kind)
        return AnyView(
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Label(kind.label, systemImage: kind.icon)
                    .font(
                        theme.uiFont.font(
                            size: theme.captionSize,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(kind.color)
                blocksView(content, proxy: proxy)
            }
            .padding(AppTheme.MarkdownChrome.Alerts.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kind.color.opacity(AppTheme.Opacity.subtle))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(kind.color)
                    .frame(width: AppTheme.MarkdownChrome.Alerts.borderWidth)
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: theme.codeRadius,
                    style: .continuous
                )
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(kind.label) callout")
        )
    }

    private func alertKind(for blocks: [Block]) -> AlertKind? {
        guard case .paragraph(let inlines, _) = blocks.first,
              case .text(let text, _) = inlines.first else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for kind in AlertKind.allCases
        where trimmed.lowercased().hasPrefix(kind.marker) {
            return kind
        }
        return nil
    }

    private func strippingAlertMarker(
        _ blocks: [Block],
        kind: AlertKind
    ) -> [Block] {
        guard !blocks.isEmpty,
              case .paragraph(var inlines, let range) = blocks[0],
              case .text(let text, let textRange) = inlines.first,
              let marker = text.range(
                  of: kind.marker,
                  options: .caseInsensitive
              ) else {
            return blocks
        }
        var newText = text
        newText.removeSubrange(marker)
        while newText.first == " " || newText.first == "\t" {
            newText.removeFirst()
        }
        if newText.isEmpty {
            inlines.removeFirst()
        } else {
            inlines[0] = .text(newText, range: textRange)
        }
        var result = blocks
        if inlines.isEmpty {
            result.removeFirst()
        } else {
            result[0] = .paragraph(inlines: inlines, range: range)
        }
        return result
    }

    /// Book-style paragraph indent applies as a block indent to a paragraph
    /// that follows another paragraph. The first paragraph after a heading or
    /// a list is flush, as it would be in print.
    private func isIndentedParagraph(after previous: Block?) -> Bool {
        guard theme.paragraphIndent > 0, let previous else { return false }
        if case .paragraph = previous { return true }
        return false
    }

    /// A block that intersects a diagnostic carries a leading severity bar.
    /// Only source-available blocks have a range, so a block without one is
    /// never marked.
    private func lintMarked(_ content: AnyView, for block: Block) -> AnyView {
        guard let range = block.range,
              let severity = lintSeverity(
                  intersecting: range.lowerBound..<range.upperBound
              ) else {
            return content
        }
        let color = severity == .error
            ? AppTheme.MarkdownChrome.Lint.error
            : AppTheme.MarkdownChrome.Lint.warning
        return AnyView(
            HStack(alignment: .top, spacing: AppTheme.Spacing.xs) {
                Rectangle()
                    .fill(color)
                    .frame(width: AppTheme.MarkdownChrome.Lint.markerWidth)
                    .frame(maxHeight: .infinity)
                content
            }
        )
    }

    private func lintSeverity(
        intersecting range: Range<Int>
    ) -> MarkdownDiagnostic.Severity? {
        var found: MarkdownDiagnostic.Severity?
        for diagnostic in lintDiagnostics {
            guard diagnostic.range.lowerBound < range.upperBound,
                  range.lowerBound < diagnostic.range.upperBound else {
                continue
            }
            if diagnostic.severity == .error { return .error }
            found = .warning
        }
        return found
    }

    private func headingBlockView(
        level: Int,
        inlines: [Inline],
        range: SourceRange?,
        proxy: ScrollViewProxy
    ) -> AnyView {
        let id = range.flatMap { headingIDs[$0.lowerBound] }
            ?? "heading-\(range?.lowerBound ?? 0)"
        return AnyView(
            Text(attributed(inlines))
                .font(headingFont(level))
                .foregroundStyle(palette.ink.color)
                .textSelection(.enabled)
                .padding(.top, theme.headingTopPadding(level))
                .id(id)
                .environment(\.openURL, openAction(proxy: proxy))
        )
    }

    private func paragraphBlockView(
        _ inlines: [Inline],
        indented: Bool,
        proxy: ScrollViewProxy
    ) -> AnyView {
        if inlines.count == 1,
           case let .image(destination, title, description, _) = inlines[0] {
            return AnyView(
                MarkdownImageView(
                    destination: destination,
                    title: title,
                    alt: HeadingIndex.renderedText(description),
                    documentURL: documentURL,
                    workspaceRoot: workspaceRoot,
                    theme: theme,
                    palette: palette,
                    onOpen: onOpenLocalLink.map { open in
                        { open(destination) }
                    }
                )
            )
        }
        return AnyView(
            Text(attributed(inlines))
                .font(theme.bodyFont.font(size: theme.bodySize))
                .lineSpacing(theme.bodyLineSpacing)
                .foregroundStyle(palette.ink.color)
                .textSelection(.enabled)
                .padding(
                    .leading,
                    indented
                        ? theme.bodySize * theme.paragraphIndent
                        : .zero
                )
                .environment(\.openURL, openAction(proxy: proxy))
        )
    }

    private func detailsBlockView(
        _ details: DetailsBlock,
        range: SourceRange?,
        proxy: ScrollViewProxy
    ) -> AnyView {
        let index = range.flatMap { detailsIndices[$0.lowerBound] }
        let binding: Binding<Bool>
        if let index {
            binding = Binding(
                get: {
                    expansion[index]
                        ?? (keys.indices.contains(index)
                            ? keys[index].authoredOpen
                            : details.isOpen)
                },
                set: { expansion[index] = $0 }
            )
        } else {
            binding = .constant(details.isOpen)
        }

        let label = details.summary.isEmpty
            ? [Inline.text("Details", range: nil)]
            : details.summary
        return AnyView(
            DisclosureGroup(isExpanded: binding) {
                blocksView(details.blocks, proxy: proxy)
                    .padding(.leading, AppTheme.Spacing.md)
                    .padding(.top, AppTheme.Spacing.xs)
            } label: {
                Text(attributed(label))
                    .font(
                        theme.bodyFont.font(
                            size: theme.bodySize,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(palette.ink.color)
                    .environment(\.openURL, openAction(proxy: proxy))
            }
        )
    }

    private func listView(_ list: ListBlock, proxy: ScrollViewProxy) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ForEach(list.items.indices, id: \.self) { index in
                    let item = list.items[index]
                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                        marker(for: item, list: list, index: index)
                        blocksView(item.blocks, proxy: proxy)
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func marker(for item: ListItem, list: ListBlock, index: Int) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square" : "square")
                .font(theme.uiFont.font(size: theme.bodySize))
                .foregroundStyle(palette.secondaryInk.color)
                .accessibilityLabel(checked ? "Completed" : "Not completed")
        } else {
            switch list.kind {
            case .bullet:
                Text("•")
                    .font(theme.uiFont.font(size: theme.bodySize))
                    .foregroundStyle(palette.secondaryInk.color)
            case .ordered(let start):
                Text("\(start + index).")
                    .font(
                        theme.codeFont.font(size: theme.bodySize)
                    )
                    .foregroundStyle(palette.secondaryInk.color)
            }
        }
    }

    private func codeBlockView(_ code: CodeBlock) -> some View {
        MarkdownCodeBlockView(
            code: code,
            theme: theme,
            palette: palette,
            highlightQuery: find.isVisible ? find.query : nil
        )
    }

    private func tableView(_ table: TableBlock, proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(
                alignment: .leading,
                horizontalSpacing: AppTheme.Spacing.md,
                verticalSpacing: AppTheme.Spacing.s6
            ) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        tableCell(
                            table.header[column],
                            alignment: alignment(for: table, column: column),
                            proxy: proxy
                        )
                        .fontWeight(.semibold)
                    }
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.rows[row].indices, id: \.self) { column in
                            tableCell(
                                table.rows[row][column],
                                alignment: alignment(for: table, column: column),
                                proxy: proxy
                            )
                        }
                    }
                }
            }
            .padding(AppTheme.Spacing.md)
        }
        .background(palette.tableGround.color)
        .clipShape(
            RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous)
        )
    }

    private func tableCell(
        _ cell: TableCell,
        alignment: Alignment,
        proxy: ScrollViewProxy
    ) -> some View {
        Text(attributed(cell.inlines))
            .font(theme.uiFont.font(size: theme.tableSize))
            .lineSpacing(theme.codeLineSpacing)
            .foregroundStyle(palette.ink.color)
            .multilineTextAlignment(textAlignment(alignment))
            .frame(maxWidth: .infinity, alignment: alignment)
            .environment(\.openURL, openAction(proxy: proxy))
    }

    private func alignment(for table: TableBlock, column: Int) -> Alignment {
        guard column < table.alignments.count else { return .leading }
        switch table.alignments[column] {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        case .none: return .leading
        }
    }

    private func textAlignment(_ alignment: Alignment) -> TextAlignment {
        switch alignment {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    // MARK: - TOC

    private func tocView(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            if headings.rows.isEmpty {
                Text("No headings")
                    .font(theme.uiFont.font(size: theme.captionSize))
                    .foregroundStyle(palette.secondaryInk.color)
            } else {
                ForEach(headings.rows.indices, id: \.self) { index in
                    let row = headings.rows[index]
                    Button {
                        navigate(to: row, proxy: proxy)
                    } label: {
                        Text(row.text.isEmpty ? "Untitled heading" : row.text)
                            .font(theme.uiFont.font(size: theme.tableSize))
                            .foregroundStyle(palette.ink.color)
                            .padding(.leading, AppTheme.Spacing.md * CGFloat(row.indent))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                if headings.totalRowCount > headings.rows.count {
                    Text(
                        "+\(headings.totalRowCount - headings.rows.count) more headings"
                    )
                    .font(theme.uiFont.font(size: theme.captionSize))
                    .foregroundStyle(palette.secondaryInk.color)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.codeGround.color)
        .clipShape(
            RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous)
        )
    }

    private func scroll(to scrollID: String, proxy: ScrollViewProxy) {
        if let entry = headingByScrollID[scrollID], let range = entry.range {
            for details in detailsRanges {
                if details.range.lowerBound <= range.lowerBound,
                   range.upperBound <= details.range.upperBound {
                    expansion[details.index] = true
                }
            }
        }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(scrollID, anchor: .top) }
        }
    }

    private func navigate(to row: TOCRow, proxy: ScrollViewProxy) {
        guard let scrollID = row.scrollID else { return }
        // Expansion and deferred scrolling live in `scroll(to:proxy:)`.
        scroll(to: scrollID, proxy: proxy)
    }

    // MARK: - Inline text

    private func attributed(_ inlines: [Inline]) -> AttributedString {
        var result = AttributedString()
        append(inlines, to: &result)
        return highlighted(result)
    }

    /// Marks every occurrence of the find query inside this block.
    private func highlighted(_ text: AttributedString) -> AttributedString {
        guard find.isVisible, !find.query.isEmpty else { return text }
        var result = text
        var start = result.startIndex
        while start < result.endIndex,
              let range = result[start...].range(
                  of: find.query,
                  options: .caseInsensitive
              ) {
            result[range].backgroundColor = AppTheme.Palette.selection
            start = range.upperBound
        }
        return result
    }

    private func append(_ inlines: [Inline], to result: inout AttributedString) {
        for inline in inlines {
            switch inline {
            case let .text(value, _):
                result.append(AttributedString(value))
            case .softBreak:
                result.append(AttributedString(" "))
            case .lineBreak:
                result.append(AttributedString("\n"))
            case let .inlineCode(value, _):
                var container = AttributeContainer()
                container.inlinePresentationIntent = .code
                container.font = theme.codeFont.font(size: theme.codeSize)
                container.foregroundColor = palette.codeInk.color
                container.backgroundColor = palette.codeGround.color
                var segment = AttributedString(value)
                segment.mergeAttributes(container)
                result.append(segment)
            case let .emphasis(children, _):
                var segment = AttributedString()
                append(children, to: &segment)
                result.append(applying(.emphasized, to: segment))
            case let .strong(children, _):
                var segment = AttributedString()
                append(children, to: &segment)
                result.append(applying(.stronglyEmphasized, to: segment))
            case let .strikethrough(children, _):
                var container = AttributeContainer()
                container.strikethroughStyle = .single
                var segment = AttributedString()
                append(children, to: &segment)
                segment.mergeAttributes(container)
                result.append(segment)
            case let .link(destination, _, children, _):
                var segment = AttributedString()
                append(children, to: &segment)
                if case .allowed = MarkdownSecurity.linkDecision(for: destination),
                   let url = URL(string: destination) {
                    segment.link = url
                    segment.foregroundColor = palette.link.color
                } else {
                    segment.foregroundColor = palette.secondaryInk.color
                }
                result.append(segment)
            case let .image(_, _, description, _):
                var segment = AttributedString(HeadingIndex.renderedText(description))
                segment.foregroundColor = palette.secondaryInk.color
                result.append(segment)
            case .inlineHTML:
                continue
            case let .wikiLink(link, _):
                var segment = AttributedString(link.display)
                if let url = Self.wikiURL(link) {
                    segment.link = url
                }
                switch wikiLinkState(link) {
                case .normal:
                    segment.foregroundColor = palette.link.color
                case .missing:
                    segment.foregroundColor = palette.secondaryInk.color
                case .ambiguous:
                    segment.foregroundColor = palette.warning.color
                }
                segment.underlineStyle = .single
                result.append(segment)
            }
        }
    }

    // MARK: - Links

    private func openAction(proxy: ScrollViewProxy) -> OpenURLAction {
        OpenURLAction { url in
            if let link = Self.parseWikiURL(url) {
                onOpenWikiLink?(link)
                return .handled
            }

            let absolute = url.absoluteString
            if absolute.hasPrefix("#") {
                let rawFragment = String(absolute.dropFirst())
                let fragment = rawFragment.removingPercentEncoding
                    ?? rawFragment
                if let entry = headings.heading(forFragment: fragment),
                   let scrollID = entry.scrollID {
                    scroll(to: scrollID, proxy: proxy)
                }
                return .handled
            }

            switch MarkdownSecurity.linkDecision(for: absolute) {
            case .allowed(.external), .allowed(.mailto):
                if let onOpenExternalURL {
                    onOpenExternalURL(url)
                } else {
                    NSWorkspace.shared.open(url)
                }
            case .allowed(.local):
                onOpenLocalLink?(url.relativeString)
            default:
                break
            }
            return .handled
        }
    }

    static func wikiURL(_ link: WikiLink) -> URL? {
        var components = URLComponents()
        components.scheme = "sonovo-wiki"
        components.host = "open"
        var items = [URLQueryItem(name: "target", value: link.target)]
        if let fragment = link.fragment {
            items.append(URLQueryItem(name: "fragment", value: fragment))
        }
        if let alias = link.alias {
            items.append(URLQueryItem(name: "alias", value: alias))
        }
        components.queryItems = items
        return components.url
    }

    static func parseWikiURL(_ url: URL) -> WikiLink? {
        guard url.scheme == "sonovo-wiki" else { return nil }
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        let items = components.queryItems ?? []
        let target = items.first { $0.name == "target" }?.value ?? ""
        let fragment = items.first { $0.name == "fragment" }?.value
        let alias = items.first { $0.name == "alias" }?.value
        return WikiLink(target: target, fragment: fragment, alias: alias)
    }

    // MARK: - Reconcile expansion

    private func reconcile(initial: Bool) {
        let newKeys = DetailsExpansionReconciler.keys(for: ast)
        if initial || keys.isEmpty {
            keys = newKeys
            expansion = [:]
            return
        }

        let oldStates = keys.indices.map {
            expansion[$0] ?? keys[$0].authoredOpen
        }
        let newStates = DetailsExpansionReconciler.reconcile(
            old: keys,
            oldExpansion: oldStates,
            new: newKeys
        )
        keys = newKeys
        expansion = Dictionary(
            uniqueKeysWithValues: newStates.enumerated().map { ($0.offset, $0.element) }
        )
    }

    /// Adds a presentation intent to every run without replacing an intent a
    /// nested span already set. A plain attribute merge would turn bold italic
    /// text into merely italic (or merely bold).
    private func applying(
        _ intent: InlinePresentationIntent,
        to segment: AttributedString
    ) -> AttributedString {
        var result = segment
        for run in segment.runs {
            var current = segment[run.range].inlinePresentationIntent ?? []
            current.formUnion(intent)
            result[run.range].inlinePresentationIntent = current
        }
        return result
    }

    // MARK: - Fonts

    private func headingFont(_ level: Int) -> Font {
        theme.headingFont.font(
            size: theme.headingSize(level),
            weight: level == 1 ? .bold : .semibold
        )
    }

    // MARK: - Metadata

    static func detailsMetadata(
        for ast: SonovoAST
    ) -> (map: [Int: Int], ranges: [(index: Int, range: SourceRange)]) {
        var index: [Int: Int] = [:]
        var ranges: [(Int, SourceRange)] = []
        var counter = 0
        func walk(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case let .details(details, range):
                    let current = counter
                    counter += 1
                    if let range {
                        index[range.lowerBound] = current
                        ranges.append((current, range))
                    }
                    walk(details.blocks)
                case let .blockQuote(children, _):
                    walk(children)
                case let .list(list, _):
                    for item in list.items { walk(item.blocks) }
                default:
                    continue
                }
            }
        }
        walk(ast.blocks)
        return (
            map: index,
            ranges: ranges.map { (index: $0.0, range: $0.1) }
        )
    }
}

// MARK: - Image

private struct MarkdownImageView: View {
    let destination: String
    let title: String?
    let alt: String
    let documentURL: URL?
    let workspaceRoot: URL?
    let theme: MarkdownTheme
    let palette: ThemePalette
    var onOpen: (() -> Void)?

    @State private var image: NSImage?
    /// The file exists but could not be decoded — most often because it
    /// exceeds the byte or pixel cap. Distinguished from a missing file so
    /// the placeholder can say which one happened.
    @State private var decodeFailed = false

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // A decoded thumbnail at the 4096 px cap is about 67 MB. The cost
        // limit bounds how many can be retained at once; without it NSCache
        // counts objects and can hold dozens.
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppTheme.Radius.surface,
                        style: .continuous
                    )
                )
                .accessibilityLabel(alt.isEmpty ? (title ?? destination) : alt)
                .onTapGesture { onOpen?() }
            } else {
                HStack(spacing: AppTheme.Spacing.s6) {
                    Image(systemName: "photo")
                    Text(
                        decodeFailed
                            ? "Image could not be displayed (too large or unreadable)"
                            : (alt.isEmpty ? destination : alt)
                    )
                    .lineLimit(1)
                }
                .font(theme.uiFont.font(size: theme.captionSize))
                .foregroundStyle(palette.secondaryInk.color)
                .padding(AppTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.codeGround.color)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppTheme.Radius.surface,
                        style: .continuous
                    )
                )
                .accessibilityLabel(
                    decodeFailed
                        ? "Image could not be displayed"
                        : (alt.isEmpty ? "Missing image" : alt)
                )
            }
        }
        .task(id: taskKey) {
            // The destination string does not change when the file is
            // replaced on disk. Re-check metadata while the image is mounted
            // so an external edit is visible without reopening the document.
            while !Task.isCancelled {
                await loadImage()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var resolvedURL: URL? {
        guard let documentURL, let workspaceRoot else { return nil }
        return MarkdownSecurity.resolveLocalPath(
            destination,
            relativeTo: documentURL,
            root: workspaceRoot
        )
    }

    /// Cheap identity for the task. Filesystem metadata is read off the main
    /// actor inside `loadImage`.
    private var taskKey: String {
        "\(destination)|\(documentURL?.path ?? "")|\(workspaceRoot?.path ?? "")"
    }

    private func loadImage() async {
        guard let url = resolvedURL else {
            image = nil
            decodeFailed = false
            return
        }

        // Read only metadata first. A cache hit must not pay for reading and
        // allocating the file's bytes.
        let identity: String? = await Task.detached(
            priority: .userInitiated
        ) {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else {
                return nil
            }
            let modified = values.contentModificationDate?
                .timeIntervalSince1970 ?? 0
            return "\(url.path)|\(modified)|\(values.fileSize ?? 0)"
        }.value

        // A destination change cancels this task; the old load must not
        // overwrite or clear the newer image.
        guard !Task.isCancelled else { return }
        guard let identity else {
            image = nil
            decodeFailed = false
            return
        }
        let key = identity as NSString
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            decodeFailed = false
            return
        }

        let decoded: NSImage? = await Task.detached(
            priority: .userInitiated
        ) {
            BoundedImageLoader.image(at: url)
        }.value
        guard !Task.isCancelled else { return }
        guard let decoded else {
            image = nil
            // The metadata read above succeeded, so the file is there; a nil
            // decode means it exceeded the caps or is corrupt.
            decodeFailed = true
            return
        }
        let cost = NumericConversion.int(
            decoded.size.width * decoded.size.height * 4
        ) ?? 0
        Self.cache.setObject(decoded, forKey: key, cost: max(cost, 0))
        image = decoded
        decodeFailed = false
    }
}

// MARK: - Code block

/// Rendered code with a language label and a copy button. Syntax colors come
/// from the same lexer the code workspace uses; an unknown language stays
/// plain. The view owns its highlighted value, so a document re-render does
/// not re-lex every block.
private struct MarkdownCodeBlockView: View {
    let code: CodeBlock
    let theme: MarkdownTheme
    let palette: ThemePalette
    let highlightQuery: String?

    @State private var copied = false
    @State private var highlightedText: AttributedString?

    /// The language is part of the task identity: changing `swift` to `text`
    /// must clear the previous highlighting even when the body is identical.
    private var highlightKey: String {
        "\(code.language ?? "")\u{1F}\(code.code)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                if let language = code.language, !language.isEmpty {
                    Text(language)
                        .font(
                            theme.uiFont.font(
                                size: theme.captionSize,
                                weight: .medium
                            )
                        )
                        .foregroundStyle(palette.secondaryInk.color)
                }
                Spacer(minLength: AppTheme.Spacing.sm)
                Button {
                    copy()
                } label: {
                    Label(
                        copied ? "Copied" : "Copy",
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .font(theme.uiFont.font(size: theme.captionSize))
                    .foregroundStyle(
                        copied
                            ? AppTheme.MarkdownChrome.CodeHeader.feedback
                            : palette.secondaryInk.color
                    )
                }
                .buttonStyle(.plain)
                .help("Copy this code block")
                .accessibilityLabel("Copy code block")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(displayText)
                    .font(theme.codeFont.font(size: theme.codeSize))
                    .lineSpacing(theme.codeLineSpacing)
                    .foregroundStyle(palette.codeInk.color)
                    .textSelection(.enabled)
            }
        }
        .padding(theme.codePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.codeGround.color)
        .clipShape(
            RoundedRectangle(cornerRadius: theme.codeRadius, style: .continuous)
        )
        .task(id: highlightKey) {
            highlightedText = makeHighlighted()
        }
    }

    /// Find highlighting is applied on top of the lexer's colors, so a match
    /// inside a code block is marked like every other block.
    private var displayText: AttributedString {
        var text = highlightedText ?? AttributedString(code.code)
        guard let query = highlightQuery, !query.isEmpty else {
            return text
        }
        var start = text.startIndex
        while start < text.endIndex,
              let range = text[start...].range(
                  of: query,
                  options: .caseInsensitive
              ) {
            text[range].backgroundColor = AppTheme.Palette.selection
            start = range.upperBound
        }
        return text
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.code, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(
                for: .seconds(
                    AppTheme.MarkdownChrome.CodeHeader.copyFeedbackSeconds
                )
            )
            copied = false
        }
    }

    private func makeHighlighted() -> AttributedString? {
        guard let language = fenceLanguage(code.language),
              language != .plainText else {
            return nil
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
        guard !tokens.isEmpty else { return nil }

        var result = AttributedString()
        var cursor = 0
        for token in tokens {
            let location = token.range.location
            guard location >= cursor,
                  location + token.range.length <= ns.length else {
                continue
            }
            if location > cursor {
                result += AttributedString(
                    ns.substring(
                        with: NSRange(
                            location: cursor,
                            length: location - cursor
                        )
                    )
                )
            }
            var piece = AttributedString(
                ns.substring(with: token.range)
            )
            piece.foregroundColor = AppTheme.syntaxColor(
                for: CodeEditorController.role(for: token.kind)
            )
            result += piece
            cursor = location + token.range.length
        }
        if cursor < ns.length {
            result += AttributedString(ns.substring(from: cursor))
        }
        return result
    }

    private func fenceLanguage(_ raw: String?) -> CodeLanguage? {
        guard let raw, !raw.isEmpty else { return nil }
        let name = raw
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init)?
            .lowercased() ?? raw.lowercased()
        if let exact = CodeLanguage(rawValue: name) {
            return exact
        }
        switch name {
        case "js", "jsx", "javascript": return .javascript
        case "ts", "tsx", "typescript": return .typescript
        case "py", "python": return .python
        case "sh", "bash", "zsh", "shell", "console": return .shell
        case "yml": return .yaml
        case "c++": return .cpp
        case "objc", "objective-c": return .objectiveC
        case "text", "plaintext", "plain": return .plainText
        default: return CodeLanguage.language(forExtension: name)
        }
    }
}

// MARK: - GitHub alerts

private enum AlertKind: String, CaseIterable {
    case note
    case tip
    case important
    case warning
    case caution

    var marker: String { "[!\(rawValue)]" }
    var label: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .note: "info.circle"
        case .tip: "lightbulb"
        case .important: "exclamationmark.circle"
        case .warning: "exclamationmark.triangle"
        case .caution: "xmark.octagon"
        }
    }

    var color: Color {
        switch self {
        case .note: AppTheme.MarkdownChrome.Alerts.note
        case .tip: AppTheme.MarkdownChrome.Alerts.tip
        case .important: AppTheme.MarkdownChrome.Alerts.important
        case .warning: AppTheme.MarkdownChrome.Alerts.warning
        case .caution: AppTheme.MarkdownChrome.Alerts.caution
        }
    }
}

// MARK: - Rendered find bar

private struct RenderedFindBar: View {
    @Bindable var find: RenderedFindController
    @FocusState private var fieldFocused: Bool
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
            TextField("Find in view", text: $find.query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.TypeScale.xs))
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
                .onChange(of: find.focusRequest) { _, _ in
                    fieldFocused = true
                }
                .onSubmit { find.step(1) }
            Text(find.countLabel)
                .font(.system(size: AppTheme.TypeScale.xs))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                find.step(-1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .help("Previous match")
            .accessibilityLabel("Previous match")
            Button {
                find.step(1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .help("Next match")
            .accessibilityLabel("Next match")
            Button {
                find.close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close find")
            .accessibilityLabel("Close find")
        }
        .padding(AppTheme.Spacing.sm)
        .background(AppTheme.MarkdownChrome.Popover.background)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear {
            fieldFocused = true
            installMonitor()
        }
        .onDisappear {
            removeMonitor()
        }
        .onExitCommand { find.close() }
    }

    /// AppKit matches a lowercase menu equivalent without regard to Shift, so
    /// Cmd+G and Shift+Cmd+G both reach "Find Next". The bar owns both chords
    /// while it is visible, before menu dispatch.
    private func installMonitor() {
        guard keyMonitor == nil else { return }
        let find = find
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
            guard event.charactersIgnoringModifiers?.lowercased() == "g",
                  flags.contains(.command),
                  !flags.contains(.option),
                  !flags.contains(.control) else {
                return event
            }
            let backwards = flags.contains(.shift)
            MainActor.assumeIsolated {
                find.step(backwards ? -1 : 1)
            }
            return nil
        }
    }

    private func removeMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }
}
