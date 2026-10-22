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
    let documentURL: URL?
    let workspaceRoot: URL?
    let wikiLinkState: (WikiLink) -> WikiLinkVisualState
    let onOpenWikiLink: ((WikiLink) -> Void)?
    let onOpenLocalLink: ((String) -> Void)?
    let onOpenExternalURL: ((URL) -> Void)?
    let scrollTarget: Binding<String?>?

    private let detailsIndices: [Int: Int]
    private let detailsRanges: [(index: Int, range: SourceRange)]
    private let headingIDs: [Int: String]
    private let headingByScrollID: [String: HeadingEntry]

    @State private var expansion: [Int: Bool] = [:]
    @State private var keys: [DetailsContentKey] = []

    init(
        ast: SonovoAST,
        headings: HeadingIndex,
        documentURL: URL? = nil,
        workspaceRoot: URL? = nil,
        wikiLinkState: @escaping (WikiLink) -> WikiLinkVisualState = { _ in .normal },
        onOpenWikiLink: ((WikiLink) -> Void)? = nil,
        onOpenLocalLink: ((String) -> Void)? = nil,
        onOpenExternalURL: ((URL) -> Void)? = nil,
        scrollTarget: Binding<String?>? = nil
    ) {
        self.ast = ast
        self.headings = headings
        self.documentURL = documentURL
        self.workspaceRoot = workspaceRoot
        self.wikiLinkState = wikiLinkState
        self.onOpenWikiLink = onOpenWikiLink
        self.onOpenLocalLink = onOpenLocalLink
        self.onOpenExternalURL = onOpenExternalURL
        self.scrollTarget = scrollTarget

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
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Reading.blockSpacing) {
                    blocksView(ast.blocks, proxy: proxy)
                }
                .frame(maxWidth: AppTheme.Reading.measure, alignment: .leading)
                .padding(.horizontal, AppTheme.Spacing.xl)
                .padding(.vertical, AppTheme.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onAppear {
                reconcile(initial: true)
                consumeScrollTarget(proxy: proxy)
            }
            .onChange(of: ast) { _, _ in
                reconcile(initial: false)
                consumeScrollTarget(proxy: proxy)
            }
            .onChange(of: scrollTarget?.wrappedValue) { _, _ in
                consumeScrollTarget(proxy: proxy)
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

    // MARK: - Blocks

    private func blocksView(_ blocks: [Block], proxy: ScrollViewProxy) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: AppTheme.Reading.blockSpacing) {
                ForEach(blocks.indices, id: \.self) { index in
                    blockView(blocks[index], proxy: proxy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    private func blockView(_ block: Block, proxy: ScrollViewProxy) -> AnyView {
        switch block {
        case let .heading(level, inlines, range):
            return headingBlockView(
                level: level,
                inlines: inlines,
                range: range,
                proxy: proxy
            )
        case let .paragraph(inlines, _):
            return paragraphBlockView(inlines, proxy: proxy)
        case let .blockQuote(blocks, _):
            return AnyView(
                HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.line)
                        .fill(Color.appSeparator)
                        .frame(width: AppTheme.BorderWidth.thick)
                    blocksView(blocks, proxy: proxy)
                }
                .padding(.leading, AppTheme.Spacing.xs)
            )
        case let .list(list, _):
            return AnyView(listView(list, proxy: proxy))
        case let .codeBlock(code, _):
            return AnyView(codeBlockView(code))
        case .thematicBreak:
            return AnyView(Divider())
        case let .table(table, _):
            return AnyView(tableView(table, proxy: proxy))
        case let .details(details, range):
            return detailsBlockView(details, range: range, proxy: proxy)
        case .tableOfContents:
            return AnyView(tocView(proxy: proxy))
        case .htmlBlock:
            return AnyView(EmptyView())
        }
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
                .textSelection(.enabled)
                .padding(.top, AppTheme.Reading.headingTopPadding(level))
                .id(id)
                .environment(\.openURL, openAction(proxy: proxy))
        )
    }

    private func paragraphBlockView(
        _ inlines: [Inline],
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
                    workspaceRoot: workspaceRoot
                )
            )
        }
        return AnyView(
            Text(attributed(inlines))
                .font(.system(size: AppTheme.Reading.bodySize, design: .serif))
                .lineSpacing(AppTheme.Reading.bodyLineSpacing)
                .textSelection(.enabled)
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
                        .system(
                            size: AppTheme.Reading.bodySize,
                            weight: .semibold,
                            design: .serif
                        )
                    )
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
                .font(.system(size: AppTheme.Reading.bodySize))
                .foregroundStyle(Color.appSecondaryLabel)
                .accessibilityLabel(checked ? "Completed" : "Not completed")
        } else {
            switch list.kind {
            case .bullet:
                Text("•")
                    .font(.system(size: AppTheme.Reading.bodySize))
                    .foregroundStyle(Color.appSecondaryLabel)
            case .ordered(let start):
                Text("\(start + index).")
                    .font(
                        .system(
                            size: AppTheme.Reading.bodySize,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(Color.appSecondaryLabel)
            }
        }
    }

    private func codeBlockView(_ code: CodeBlock) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            if let language = code.language, !language.isEmpty {
                Text(language)
                    .font(.system(size: AppTheme.Reading.captionSize, weight: .medium))
                    .foregroundStyle(Color.appTertiaryLabel)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.code)
                    .font(
                        .system(
                            size: AppTheme.Reading.codeSize,
                            design: .monospaced
                        )
                    )
                    .lineSpacing(AppTheme.Reading.codeLineSpacing)
                    .textSelection(.enabled)
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appCanvas)
        .clipShape(
            RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous)
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
        .background(Color.appCard)
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
            .font(.system(size: AppTheme.Reading.tableSize))
            .lineSpacing(AppTheme.Reading.codeLineSpacing)
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
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(Color.appTertiaryLabel)
            } else {
                ForEach(headings.rows.indices, id: \.self) { index in
                    let row = headings.rows[index]
                    Button {
                        navigate(to: row, proxy: proxy)
                    } label: {
                        Text(row.text.isEmpty ? "Untitled heading" : row.text)
                            .font(.system(size: AppTheme.Reading.tableSize))
                            .foregroundStyle(Color.appLabel)
                            .padding(.leading, AppTheme.Spacing.md * CGFloat(row.indent))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                if headings.totalRowCount > headings.rows.count {
                    Text(
                        "+\(headings.totalRowCount - headings.rows.count) more headings"
                    )
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(Color.appTertiaryLabel)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appCanvas)
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
                container.font = .system(
                    size: AppTheme.Reading.codeSize,
                    design: .monospaced
                )
                container.backgroundColor = Color.appCanvas
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
                    segment.foregroundColor = Color(AppTheme.Palette.info)
                } else {
                    segment.foregroundColor = Color.appSecondaryLabel
                }
                result.append(segment)
            case let .image(_, _, description, _):
                var segment = AttributedString(HeadingIndex.renderedText(description))
                segment.foregroundColor = Color.appSecondaryLabel
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
                    segment.foregroundColor = Color(AppTheme.Palette.info)
                case .missing:
                    segment.foregroundColor = Color.appSecondaryLabel
                case .ambiguous:
                    segment.foregroundColor = Color(AppTheme.Palette.warning)
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
        .system(
            size: AppTheme.Reading.headingSize(level),
            weight: level == 1 ? .bold : .semibold,
            design: .serif
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

    @State private var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

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
            } else {
                HStack(spacing: AppTheme.Spacing.s6) {
                    Image(systemName: "photo")
                    Text(alt.isEmpty ? destination : alt)
                        .lineLimit(1)
                }
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(Color.appSecondaryLabel)
                .padding(AppTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.appCard)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppTheme.Radius.surface,
                        style: .continuous
                    )
                )
                .accessibilityLabel(alt.isEmpty ? "Missing image" : alt)
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
            return
        }
        let key = identity as NSString
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }

        let data: Data? = await Task.detached(
            priority: .userInitiated
        ) {
            try? Data(contentsOf: url)
        }.value
        guard !Task.isCancelled else { return }
        guard let data, let decoded = NSImage(data: data) else {
            image = nil
            return
        }
        Self.cache.setObject(decoded, forKey: key)
        image = decoded
    }
}
