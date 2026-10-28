import AppKit
import SonovoCore
import SwiftUI

/// How a wiki link should be styled.
enum WikiLinkVisualState: Sendable, Equatable {
    case normal
    case missing
    case ambiguous
}

/// Whether a `sonovo:` media reference points at something real.
enum MediaReferenceState: Sendable, Equatable {
    case available
    case missing
}

/// The scroll offset is read on every scroll tick. A reference box keeps it
/// out of SwiftUI state, so scrolling does not invalidate the viewer.
private final class RenderedScrollOffset {
    var y: CGFloat = 0
}

/// One top-level block's rendered frame and source identity.
private struct TopBlock {
    let frame: CGRect
    let offset: Int
    let kind: ReadingBlockKind
}

/// An in-place block edit, held independently of the current AST so an
/// external change that moves the block cannot destroy the open draft.
///
/// The editor model lives here, not inside `BlockProjectionEditor`'s
/// `@State`: the same block can be presented in two places when an external
/// change moves it, and only a model owned by the session carries the typed
/// text across that move.
private struct BlockEditingSession {
    let range: SourceRange
    let slice: String
    let model: BlockProjectionEditorModel
}

/// Collects the top-level block frames in scroll-content coordinates.
private struct BlockFramesKey: SwiftUI.PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// The read-only SwiftUI projection of `SonovoAST`.
///
/// The viewer never parses Markdown. Raw HTML is hidden; details and TOC
/// are the only structural constructs. Fenced diagrams hand off to an
/// isolated renderer that owns its own web view; the viewer itself hosts no
/// page. Expansion state is view state and is reconciled by content after a
/// reparse.
struct MarkdownViewer: View {
    let ast: SonovoAST
    let headings: HeadingIndex
    let theme: MarkdownTheme
    let documentURL: URL?
    let workspaceRoot: URL?
    let wikiLinkState: (WikiLink) -> WikiLinkVisualState
    let mediaReferenceState: ((MediaReference) -> MediaReferenceState)?
    let onOpenWikiLink: ((WikiLink) -> Void)?
    let onOpenMedia: ((MediaReference) -> Void)?
    let onOpenLocalLink: ((String) -> Void)?
    let onOpenExternalURL: ((URL) -> Void)?
    let onEditInSource: ((SourceRange) -> Void)?
    let onSetDetailsOpen: ((SourceRange, Bool) -> Void)?
    /// The exact source the AST came from. Block editing reads and writes
    /// through this text, never through a second document model.
    let source: String
    /// Commits one block's replacement: (range, expected slice, new text).
    let onCommitBlockEdit: ((SourceRange, String, String) -> Bool)?
    /// Called when a block projection or Source Peek opens. Both are
    /// collapse surfaces for the source editor's caret set.
    let onProjectionStart: (() -> Void)?
    let scrollTarget: Binding<String?>?
    let restoreAnchor: Binding<RenderedReadingAnchor?>?
    let onReadingAnchorChange: ((RenderedReadingAnchor) -> Void)?
    let lintDiagnostics: [MarkdownDiagnostic]
    let find: RenderedFindController
    /// Whether this pane owns keyboard focus. A window can host two panes,
    /// each with its own Find bar, and only the focused one may consume
    /// Cmd+G.
    let isFocusedPane: Bool

    private let detailsIndices: [Int: Int]
    private let detailsRanges: [(index: Int, range: SourceRange)]
    private let headingIDs: [Int: String]
    private let headingByScrollID: [String: HeadingEntry]

    @State private var expansion: [Int: Bool] = [:]
    @State private var keys: [DetailsContentKey] = []
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var blockFrames: [String: CGRect] = [:]
    @State private var topBlocks: [TopBlock] = []
    @State private var scrollBox = RenderedScrollOffset()
    /// The block being edited in place, if any.
    @State private var editingSession: BlockEditingSession?
    /// The block whose transient Source Peek panel is open, if any.
    @State private var peekSession: BlockEditingSession?
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
        mediaReferenceState: ((MediaReference) -> MediaReferenceState)? = nil,
        onOpenWikiLink: ((WikiLink) -> Void)? = nil,
        onOpenMedia: ((MediaReference) -> Void)? = nil,
        onOpenLocalLink: ((String) -> Void)? = nil,
        onOpenExternalURL: ((URL) -> Void)? = nil,
        onEditInSource: ((SourceRange) -> Void)? = nil,
        onSetDetailsOpen: ((SourceRange, Bool) -> Void)? = nil,
        source: String = "",
        onCommitBlockEdit: ((SourceRange, String, String) -> Bool)? = nil,
        onProjectionStart: (() -> Void)? = nil,
        scrollTarget: Binding<String?>? = nil,
        restoreAnchor: Binding<RenderedReadingAnchor?>? = nil,
        onReadingAnchorChange: ((RenderedReadingAnchor) -> Void)? = nil,
        lintDiagnostics: [MarkdownDiagnostic] = [],
        find: RenderedFindController = RenderedFindController(),
        isFocusedPane: Bool = true
    ) {
        self.ast = ast
        self.headings = headings
        self.theme = theme
        self.documentURL = documentURL
        self.workspaceRoot = workspaceRoot
        self.wikiLinkState = wikiLinkState
        self.mediaReferenceState = mediaReferenceState
        self.onOpenWikiLink = onOpenWikiLink
        self.onOpenMedia = onOpenMedia
        self.onOpenLocalLink = onOpenLocalLink
        self.onOpenExternalURL = onOpenExternalURL
        self.onEditInSource = onEditInSource
        self.onSetDetailsOpen = onSetDetailsOpen
        self.source = source
        self.onCommitBlockEdit = onCommitBlockEdit
        self.onProjectionStart = onProjectionStart
        self.scrollTarget = scrollTarget
        self.restoreAnchor = restoreAnchor
        self.onReadingAnchorChange = onReadingAnchorChange
        self.lintDiagnostics = lintDiagnostics
        self.find = find
        self.isFocusedPane = isFocusedPane

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
                    RenderedFindBar(find: find, isFocusedPane: isFocusedPane)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.blockSpacing) {
                        blocksView(ast.blocks, proxy: proxy, topLevel: true)
                    }
                    .frame(maxWidth: theme.measure, alignment: .leading)
                    .padding(.horizontal, theme.pagePadding)
                    .padding(.vertical, theme.pagePadding)
                    .frame(maxWidth: .infinity, alignment: .center)
                    // The outermost content view's origin is the scroll
                    // content's origin, so block frames compare directly with
                    // `contentOffset`.
                    .coordinateSpace(name: Self.scrollSpace)
                }
                .scrollPosition($scrollPosition)
                .background(palette.paper.color)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, offset in
                    scrollBox.y = offset
                    reportReadingAnchor(at: offset)
                }
                .onPreferenceChange(BlockFramesKey.self) { frames in
                    blockFrames = frames
                    rebuildTopBlocks()
                    applyPendingRestoreIfPossible()
                    reportReadingAnchor(at: scrollBox.y)
                }
                .onAppear {
                    reconcile(initial: true)
                    if scrollTarget?.wrappedValue == nil {
                        applyPendingRestoreIfPossible()
                    } else {
                        restoreAnchor?.wrappedValue = nil
                    }
                    consumeScrollTarget(proxy: proxy)
                    // A document switch remounts the viewer while the bar can
                    // stay open; matches must follow the new document.
                    recomputeFind(proxy: proxy)
                }
                .onChange(of: ast) { _, _ in
                    reconcile(initial: false)
                    rebuildTopBlocks()
                    consumeScrollTarget(proxy: proxy)
                    recomputeFind(proxy: proxy)
                }
                .onChange(of: scrollTarget?.wrappedValue) { _, _ in
                    consumeScrollTarget(proxy: proxy)
                }
                .onChange(of: restoreAnchor?.wrappedValue) { _, _ in
                    applyPendingRestoreIfPossible()
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

    // MARK: - Reading anchor

    private static let scrollSpace = "markdown-rendered-scroll"
    private static let footnoteScheme = "sonovo-footnote"

    private func rebuildTopBlocks() {
        var top: [TopBlock] = []
        for (index, block) in ast.blocks.enumerated() {
            guard let range = block.range,
                  let frame = blockFrames[blockAnchor(block, index: index)]
            else { continue }
            top.append(
                TopBlock(
                    frame: frame,
                    offset: range.lowerBound,
                    kind: ReadingBlockKind(block)
                )
            )
        }
        topBlocks = top.sorted { $0.frame.minY < $1.frame.minY }
    }

    private func reportReadingAnchor(at y: CGFloat) {
        guard let onReadingAnchorChange, !topBlocks.isEmpty else { return }
        var low = 0
        var high = topBlocks.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            if topBlocks[mid].frame.minY <= y {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        let block = topBlocks[found >= 0 ? found : 0]
        let fraction = block.frame.height > 0
            ? Double((y - block.frame.minY) / block.frame.height)
            : 0
        onReadingAnchorChange(
            RenderedReadingAnchor(
                blockOffset: block.offset,
                blockKind: block.kind,
                fraction: fraction
            )
        )
    }

    /// Applies a pending anchor once the block frames are known. An explicit
    /// navigation target wins: the reader asked to jump somewhere.
    private func applyPendingRestoreIfPossible() {
        guard let binding = restoreAnchor,
              let anchor = binding.wrappedValue else {
            return
        }
        if scrollTarget?.wrappedValue != nil {
            binding.wrappedValue = nil
            return
        }
        guard let index = ReadingAnchorResolver.renderedBlockIndex(
            for: anchor,
            in: ast.blocks
        ) else {
            return
        }
        let fraction = CGFloat(
            ReadingAnchorResolver.clampedFraction(anchor.fraction)
        )
        let anchorID = blockAnchor(ast.blocks[index], index: index)
        if let frame = blockFrames[anchorID] {
            let y = frame.minY + fraction * frame.height
            scrollPosition.scrollTo(point: CGPoint(x: 0, y: y))
            scrollBox.y = y
        } else {
            // A virtualized stack has no frame for an offscreen block.
            // Scroll by ID so the view materializes; the fraction is applied
            // exactly only when its frame is already known.
            scrollPosition.scrollTo(id: anchorID, anchor: .top)
        }
        binding.wrappedValue = nil
    }

    // MARK: - Blocks

    private func blocksView(
        _ blocks: [Block],
        proxy: ScrollViewProxy,
        topLevel: Bool = false
    ) -> AnyView {
        let rows = ForEach(blocks.indices, id: \.self) { index in
            blockRow(
                blocks[index],
                index: index,
                blocks: blocks,
                proxy: proxy,
                topLevel: topLevel
            )
        }
        // A session whose block no longer exists keeps its editor mounted:
        // an external change must never silently destroy typed text.
        let staleSession: BlockEditingSession? = {
            guard topLevel, let session = editingSession,
                  !blocks.contains(where: { $0.range == session.range }) else {
                return nil
            }
            return session
        }()
        return AnyView(
            Group {
                if topLevel {
                    // The top level is virtualized: a large document must
                    // not pay for thousands of offscreen block views. Nested
                    // containers (details bodies, list items) stay eager
                    // because they are bounded and small.
                    LazyVStack(
                        alignment: .leading,
                        spacing: theme.blockSpacing
                    ) {
                        if let staleSession {
                            VStack(
                                alignment: .leading,
                                spacing: theme.blockSpacing
                            ) {
                                Text(
                                    "This block changed on disk while you "
                                        + "were editing. Your draft is kept "
                                        + "below; copy anything you need, "
                                        + "then cancel."
                                )
                                .font(.callout)
                                .foregroundStyle(palette.secondaryInk.color)
                                inlineBlockEditor(session: staleSession)
                            }
                        }
                        rows
                    }
                } else {
                    VStack(alignment: .leading, spacing: theme.blockSpacing) {
                        rows
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    @ViewBuilder
    private func blockRow(
        _ block: Block,
        index: Int,
        blocks: [Block],
        proxy: ScrollViewProxy,
        topLevel: Bool
    ) -> some View {
        let content = blockContent(
            block,
            previous: index > 0 ? blocks[index - 1] : nil,
            proxy: proxy
        )
        if topLevel {
            topLevelItem(block, index: index, content: content)
        } else if case .heading(_, _, let range) = block,
                  let range,
                  headingIDs[range.lowerBound] != nil {
            content
        } else if let range = block.range {
            // Nested IDs used to be `block-<index>`, which repeated in every
            // container and collided with the top level's IDs. A block's
            // source position is unique across the whole document.
            content.id("nested-block-\(range.lowerBound)")
        } else {
            content
        }
    }

    /// The block's view: an inline source editor while it is being edited,
    /// otherwise the rendered projection, with Source Peek attached when
    /// requested.
    private func blockContent(
        _ block: Block,
        previous: Block?,
        proxy: ScrollViewProxy
    ) -> AnyView {
        let content: AnyView
        if let range = block.range,
           let session = editingSession,
           session.range == range {
            content = AnyView(
                inlineBlockEditor(session: session)
            )
        } else {
            content = blockView(
                block,
                previous: previous,
                proxy: proxy
            )
        }
        return sourcePeekContent(content, block: block)
    }

    /// Identifies a top-level block and reports its frame in scroll-content
    /// coordinates. A heading view already carries its scroll ID; adding the
    /// same ID outside it would duplicate it.
    private func topLevelItem(
        _ block: Block,
        index: Int,
        content: AnyView
    ) -> AnyView {
        let anchor = blockAnchor(block, index: index)
        let identified: AnyView
        if case .heading(_, _, let range) = block,
           let range,
           headingIDs[range.lowerBound] != nil {
            identified = content
        } else {
            identified = AnyView(content.id(anchor))
        }
        return AnyView(
            identified.background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: BlockFramesKey.self,
                        value: [
                            anchor: geometry.frame(
                                in: .named(Self.scrollSpace)
                            )
                        ]
                    )
                }
            }
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
        case let .definitionList(list, _):
            content = AnyView(definitionListView(list, proxy: proxy))
        case let .details(details, range):
            content = detailsBlockView(
                details,
                range: range,
                proxy: proxy
            )
        case .tableOfContents:
            content = AnyView(tocView(proxy: proxy))
        case .footnoteDefinition:
            content = AnyView(EmptyView())
        case let .footnotes(section, _):
            content = AnyView(footnotesView(section, proxy: proxy))
        case .htmlBlock:
            content = AnyView(EmptyView())
        }

        let display = lintMarked(content, for: block)
        guard let range = block.range else { return display }
        let actions = RenderedBlockMenu.actions(
            for: block,
            canEditInSource: onEditInSource != nil,
            canSetDetailsOpen: onSetDetailsOpen != nil,
            canEditBlock: canEditBlock
        )
        guard !actions.isEmpty else { return display }
        let menu = display.contextMenu {
            ForEach(actions.indices, id: \.self) { index in
                let action = actions[index]
                Button(action.title) {
                    RenderedBlockMenu.perform(
                        action,
                        range: range,
                        editInSource: onEditInSource,
                        setDetailsOpen: onSetDetailsOpen,
                        editBlock: { range in
                            startBlockEditing(range)
                        },
                        sourcePeek: { range in
                            startSourcePeek(range)
                        }
                    )
                }
            }
        }
        guard let onEditInSource,
              RenderedBlockMenu.doubleClickAction(
                  for: block,
                  canEditInSource: true
              ) != nil else {
            return AnyView(menu)
        }
        return AnyView(
            menu.simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    onEditInSource(range)
                }
            )
        )
    }

    // MARK: - Source projections

    private var canEditBlock: Bool {
        onCommitBlockEdit != nil && !source.isEmpty
    }

    private func blockSlice(_ range: SourceRange) -> String? {
        guard canEditBlock else { return nil }
        return MarkdownBlockProjector.slice(range, in: source)
    }

    private func inlineBlockEditor(
        session: BlockEditingSession
    ) -> some View {
        BlockProjectionEditor(
            title: "Edit Block",
            model: session.model,
            onCancel: { editingSession = nil }
        )
        .id(session.range.lowerBound)
    }

    /// Opens an in-place edit session. The model is created once and stored
    /// in the session, so a reparse that moves the block re-presents the same
    /// draft instead of starting a new editor with the original slice.
    ///
    /// Not private: the E2E probe drives this real entry point, so removing
    /// the `onProjectionStart` call below breaks a check instead of passing
    /// silently.
    func startBlockEditing(_ range: SourceRange) {
        guard let slice = blockSlice(range) else { return }
        onProjectionStart?()
        let model = BlockProjectionEditorModel(
            text: slice,
            commit: { replacement in
                let committed = commitBlock(
                    range,
                    expected: slice,
                    replacement: replacement
                )
                if committed {
                    editingSession = nil
                }
                return committed
            }
        )
        editingSession = BlockEditingSession(
            range: range,
            slice: slice,
            model: model
        )
    }

    /// Opens Source Peek for one block. Not private for the same reason as
    /// `startBlockEditing`: the E2E probe drives the real entry point.
    func startSourcePeek(_ range: SourceRange) {
        guard let slice = blockSlice(range) else { return }
        onProjectionStart?()
        let model = BlockProjectionEditorModel(
            text: slice,
            commit: { replacement in
                let committed = commitBlock(
                    range,
                    expected: slice,
                    replacement: replacement
                )
                if committed {
                    peekSession = nil
                }
                return committed
            }
        )
        peekSession = BlockEditingSession(
            range: range,
            slice: slice,
            model: model
        )
    }

    /// Attaches a transient Source Peek panel to the block when this block is
    /// the requested one. The panel is a sibling presentation, not a mode
    /// change: the document stays Rendered and the source is untouched until
    /// Save.
    private func sourcePeekContent(
        _ content: AnyView,
        block: Block
    ) -> AnyView {
        guard let range = block.range,
              let session = peekSession,
              session.range == range else {
            return content
        }
        return AnyView(
            content.popover(
                isPresented: Binding(
                    get: { peekSession?.range == range },
                    set: { isPresented in
                        if !isPresented { peekSession = nil }
                    }
                ),
                arrowEdge: .bottom
            ) {
                BlockProjectionEditor(
                    title: "Source Peek",
                    model: session.model,
                    onCancel: { peekSession = nil }
                )
                .frame(
                    width: AppTheme.MarkdownChrome.BlockEditor.popoverWidth
                )
                .padding(AppTheme.Spacing.sm)
                .background(AppTheme.MarkdownChrome.PaletteChrome.background)
            }
        )
    }

    private func commitBlock(
        _ range: SourceRange,
        expected: String,
        replacement: String
    ) -> Bool {
        guard let onCommitBlockEdit else { return false }
        return onCommitBlockEdit(range, expected, replacement)
    }

    /// A blockquote whose first text begins with a GitHub alert marker is
    /// presented as a labelled callout. Source bytes are never changed; the
    /// marker is stripped only from this projection.
    private func blockQuoteView(
        _ blocks: [Block],
        proxy: ScrollViewProxy
    ) -> AnyView {
        guard let kind = MarkdownAlertKind.kind(in: blocks) else {
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

        let content = kind.strippingMarker(from: blocks)
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
        let message = lintMessage(
            intersecting: range.lowerBound..<range.upperBound
        )
        return AnyView(
            HStack(alignment: .top, spacing: AppTheme.Spacing.xs) {
                Rectangle()
                    .fill(color)
                    .frame(width: AppTheme.MarkdownChrome.Lint.markerWidth)
                    .frame(maxHeight: .infinity)
                    .accessibilityLabel(
                        severity == .error
                            ? "Markdown error"
                            : "Markdown warning"
                    )
                    .accessibilityValue(message ?? "")
                content
            }
        )
    }

    private func lintMessage(
        intersecting range: Range<Int>
    ) -> String? {
        lintDiagnostics.first { diagnostic in
            diagnostic.range.lowerBound < range.upperBound
                && range.lowerBound < diagnostic.range.upperBound
        }?.message
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
            text(inlines, mathSize: theme.headingSize(level))
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
        if let math = Self.displayMathPayload(inlines) {
            return AnyView(displayMathView(math))
        }
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
            text(inlines, mathSize: theme.bodySize)
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
                text(label, mathSize: theme.bodySize)
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

    /// Terms are semibold; definitions are indented under them. Each item
    /// keeps the source's own line breaks out of the reading surface because
    /// the list structure already carries the grouping.
    private func definitionListView(
        _ list: DefinitionList,
        proxy: ScrollViewProxy
    ) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ForEach(list.items.indices, id: \.self) { index in
                    let item = list.items[index]
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        ForEach(item.terms.indices, id: \.self) { termIndex in
                            text(
                                item.terms[termIndex].inlines,
                                mathSize: theme.bodySize
                            )
                            .fontWeight(.semibold)
                        }
                        ForEach(
                            item.definitions.indices,
                            id: \.self
                        ) { definitionIndex in
                            text(
                                item.definitions[definitionIndex].inlines,
                                mathSize: theme.bodySize
                            )
                            .padding(.leading, AppTheme.Spacing.lg)
                        }
                    }
                }
            }
            // Definition text carries links like any other block; without
            // this they bypass workspace navigation and the external
            // confirmation the rest of the viewer applies.
            .environment(\.openURL, openAction(proxy: proxy))
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

    @ViewBuilder
    private func codeBlockView(_ code: CodeBlock) -> some View {
        if let diagram = DiagramPolicy.source(from: code) {
            MarkdownDiagramView(
                code: code,
                diagram: diagram,
                theme: theme,
                palette: palette,
                highlightQuery: find.isVisible ? find.query : nil
            )
        } else {
            MarkdownCodeBlockView(
                code: code,
                theme: theme,
                palette: palette,
                highlightQuery: find.isVisible ? find.query : nil
            )
        }
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
                            row: 0,
                            column: column,
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
                                row: row + 1,
                                column: column,
                                proxy: proxy
                            )
                        }
                    }
                }
            }
            .padding(AppTheme.Spacing.md)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Table, \(table.header.count) columns, \(table.rows.count) rows"
        )
        .background(palette.tableGround.color)
        .clipShape(
            RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous)
        )
    }

    private func tableCell(
        _ cell: TableCell,
        alignment: Alignment,
        row: Int,
        column: Int,
        proxy: ScrollViewProxy
    ) -> some View {
        text(cell.inlines, mathSize: theme.tableSize)
            .font(theme.uiFont.font(size: theme.tableSize))
            .lineSpacing(theme.codeLineSpacing)
            .foregroundStyle(palette.ink.color)
            .multilineTextAlignment(textAlignment(alignment))
            .frame(maxWidth: .infinity, alignment: alignment)
            .environment(\.openURL, openAction(proxy: proxy))
            .accessibilityValue(
                "Row \(row + 1), column \(column + 1)"
            )
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

    // MARK: - Footnotes

    private func footnotesView(
        _ section: FootnoteSection,
        proxy: ScrollViewProxy
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Rectangle()
                .fill(palette.rule.color)
                .frame(height: AppTheme.BorderWidth.hairline)
            Text("Footnotes")
                .font(theme.uiFont.font(size: theme.captionSize))
                .foregroundStyle(palette.secondaryInk.color)
            ForEach(section.entries, id: \.number) { entry in
                HStack(
                    alignment: .firstTextBaseline,
                    spacing: AppTheme.Spacing.sm
                ) {
                    Text("\(entry.number).")
                        .font(theme.bodyFont.font(size: theme.bodySize))
                        .foregroundStyle(palette.secondaryInk.color)
                    VStack(
                        alignment: .leading,
                        spacing: AppTheme.Spacing.xxs
                    ) {
                        text(entry.inlines, mathSize: theme.bodySize)
                            .font(theme.bodyFont.font(size: theme.bodySize))
                            .foregroundStyle(palette.ink.color)
                            .textSelection(.enabled)
                            .environment(
                                \.openURL,
                                openAction(proxy: proxy)
                            )
                        if !entry.referenceRanges.isEmpty {
                            HStack(spacing: AppTheme.Spacing.sm) {
                                ForEach(
                                    entry.referenceRanges.indices,
                                    id: \.self
                                ) { index in
                                    backLink(
                                        entry: entry,
                                        index: index,
                                        proxy: proxy
                                    )
                                }
                            }
                        }
                    }
                }
                .id("footnote-\(entry.number)")
            }
        }
        .padding(.top, AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func backLink(
        entry: FootnoteEntry,
        index: Int,
        proxy: ScrollViewProxy
    ) -> some View {
        Button {
            scrollToReference(entry.referenceRanges[index], proxy: proxy)
        } label: {
            Text("↩")
                .font(theme.uiFont.font(size: theme.captionSize))
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.link.color)
        .accessibilityLabel(
            "Back to reference \(index + 1) of footnote \(entry.number)"
        )
    }

    /// Scrolls to the top-level block that holds a reference, expanding any
    /// details element on the way in.
    private func scrollToReference(
        _ range: SourceRange,
        proxy: ScrollViewProxy
    ) {
        guard let index = ast.blocks.firstIndex(where: { block in
            block.range?.contains(offset: range.lowerBound) ?? false
        }) else {
            return
        }
        for details in detailsRanges {
            if details.range.lowerBound <= range.lowerBound,
               range.upperBound <= details.range.upperBound {
                expansion[details.index] = true
            }
        }
        let anchor = blockAnchor(ast.blocks[index], index: index)
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(anchor, anchor: .center) }
        }
    }

    // MARK: - Inline text

    func attributed(_ inlines: [Inline]) -> AttributedString {
        var result = AttributedString()
        var styles: [MarkdownInlineHTMLTag] = []
        append(inlines, to: &result, styles: &styles)
        return highlighted(result)
    }

    /// A paragraph's text as a `Text` value, with formulas substituted as
    /// baseline-aligned images.
    ///
    /// `Text` ignores `NSTextAttachment`, so a formula is carried through the
    /// attributed string as an object-replacement run and swapped here for
    /// `Text(Image)`. The image is offset by the formula's descent, which
    /// puts the math baseline on the text baseline.
    private func text(
        _ inlines: [Inline],
        mathSize: CGFloat
    ) -> Text {
        let attributed = attributed(inlines)
        var output = Text("")
        var pending = AttributedString()

        func flush() {
            guard !pending.characters.isEmpty else { return }
            output = Text("\(output)\(Text(pending))")
            pending = AttributedString()
        }

        for run in attributed.runs {
            if let payload = run[MarkdownMathAttribute.self] {
                flush()
                output = Text("\(output)\(mathText(payload, size: mathSize))")
            } else {
                pending.append(AttributedString(attributed[run.range]))
            }
        }
        flush()
        return output
    }

    private func mathText(_ payload: MarkdownMathPayload, size: CGFloat) -> Text {
        switch MarkdownMathRenderer.shared.layout(
            source: payload.source,
            display: payload.display,
            fontSize: size,
            color: palette.ink.nsColor
        ) {
        case let .success(layout):
            return Text(Image(nsImage: layout.image))
                .baselineOffset(-layout.descent)
        case .failure:
            var literal = AttributedString(payload.raw)
            literal.foregroundColor = palette.secondaryInk.color
            return Text(literal)
        }
    }

    @ViewBuilder
    private func displayMathView(_ payload: MarkdownMathPayload) -> some View {
        switch MarkdownMathRenderer.shared.layout(
            source: payload.source,
            display: true,
            fontSize: theme.bodySize,
            color: palette.ink.nsColor
        ) {
        case let .success(layout):
            ViewThatFits(in: .horizontal) {
                Image(nsImage: layout.image)
                    .interpolation(.high)
                Image(nsImage: layout.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel(
                payload.source.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .failure:
            Text(payload.raw)
                .font(theme.codeFont.font(size: theme.codeSize))
                .foregroundStyle(palette.secondaryInk.color)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private static func displayMathPayload(
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

    /// Applies the allowlisted inline HTML styles that are open around a
    /// text run. `mark` uses the palette's warning tint at the standard
    /// border opacity; scripts reuse the footnote scale and offset tokens.
    private func applyInlineHTMLStyles(
        _ styles: [MarkdownInlineHTMLTag],
        to segment: inout AttributedString
    ) {
        for style in styles {
            switch style {
            case .mark:
                segment.backgroundColor = palette.warning.color.opacity(
                    AppTheme.Opacity.borderStrong
                )
            case .underline:
                segment.underlineStyle = .single
            case .superscript:
                segment.font = theme.bodyFont.font(
                    size: theme.bodySize * AppTheme.Reading.footnoteScale
                )
                segment.baselineOffset = AppTheme.Reading.footnoteBaselineOffset
            case .subscriptTag:
                segment.font = theme.bodyFont.font(
                    size: theme.bodySize * AppTheme.Reading.footnoteScale
                )
                segment.baselineOffset = -AppTheme.Reading.footnoteBaselineOffset
            }
        }
    }

    private func append(
        _ inlines: [Inline],
        to result: inout AttributedString,
        styles: inout [MarkdownInlineHTMLTag]
    ) {
        for inline in inlines {
            switch inline {
            case let .text(value, _):
                var segment = AttributedString(value)
                applyInlineHTMLStyles(styles, to: &segment)
                result.append(segment)
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
                append(children, to: &segment, styles: &styles)
                result.append(applying(.emphasized, to: segment))
            case let .strong(children, _):
                var segment = AttributedString()
                append(children, to: &segment, styles: &styles)
                result.append(applying(.stronglyEmphasized, to: segment))
            case let .strikethrough(children, _):
                var container = AttributeContainer()
                container.strikethroughStyle = .single
                var segment = AttributedString()
                append(children, to: &segment, styles: &styles)
                segment.mergeAttributes(container)
                result.append(segment)
            case let .link(destination, _, children, _):
                if let reference = MediaReference.parse(destination) {
                    result.append(mediaSegment(reference))
                    continue
                }
                var segment = AttributedString()
                append(children, to: &segment, styles: &styles)
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
            case let .inlineHTML(raw, _):
                // Only the four allowlisted tags carry meaning; everything
                // else stays hidden raw HTML.
                guard let match = MarkdownInlineHTML.match(raw) else {
                    continue
                }
                if match.isClosing {
                    if let index = styles.lastIndex(of: match.tag) {
                        styles.remove(at: index)
                    }
                } else {
                    styles.append(match.tag)
                }
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
            case let .footnoteReference(reference, _):
                var container = AttributeContainer()
                container.font = theme.bodyFont.font(
                    size: theme.bodySize * AppTheme.Reading.footnoteScale
                )
                container.baselineOffset = AppTheme.Reading
                    .footnoteBaselineOffset
                var segment = AttributedString("\(reference.number)")
                segment.mergeAttributes(container)
                segment.link = Self.footnoteURL(number: reference.number)
                segment.foregroundColor = palette.link.color
                result.append(segment)
            case let .math(source, raw, display, _):
                var segment = AttributedString("\u{FFFC}")
                segment[MarkdownMathAttribute.self] = MarkdownMathPayload(
                    source: source,
                    raw: raw,
                    display: display
                )
                result.append(segment)
            }
        }
    }

    // MARK: - Media references

    private func mediaSegment(_ reference: MediaReference) -> AttributedString {
        var segment = AttributedString()
        if let label = reference.label, !label.isEmpty {
            segment = AttributedString(label)
        } else if let path = reference.path {
            segment = AttributedString(path)
        } else {
            segment = AttributedString(
                reference.kind == .take ? "Take" : "Timecode"
            )
        }
        var prefixed = AttributedString(
            Self.mediaGlyph(reference.kind) + " "
        )
        prefixed.append(segment)
        switch mediaState(for: reference) {
        case .available:
            if let url = reference.url() {
                prefixed.link = url
            }
            prefixed.foregroundColor = palette.link.color
        case .missing:
            prefixed.append(AttributedString(" (missing)"))
            prefixed.foregroundColor = palette.warning.color
        }
        return prefixed
    }

    private func mediaState(
        for reference: MediaReference
    ) -> MediaReferenceState {
        if let mediaReferenceState {
            return mediaReferenceState(reference)
        }
        guard let path = reference.path else { return .available }
        guard let documentURL else { return .missing }
        let root: URL = workspaceRoot
            ?? documentURL.deletingLastPathComponent()
        guard let url = MarkdownSecurity.resolveLocalPath(
            path,
            relativeTo: documentURL,
            root: root
        ) else {
            return .missing
        }
        return FileManager.default.fileExists(atPath: url.path)
            ? .available
            : .missing
    }

    private static func mediaGlyph(_ kind: MediaReference.Kind) -> String {
        switch kind {
        case .take: "▶"
        case .timecode: "⏱"
        }
    }

    // MARK: - Links

    private func openAction(proxy: ScrollViewProxy) -> OpenURLAction {
        OpenURLAction { url in
            if let reference = MediaReference.parse(url.absoluteString) {
                onOpenMedia?(reference)
                return .handled
            }
            if let number = Self.footnoteNumber(from: url) {
                scroll(to: "footnote-\(number)", proxy: proxy)
                return .handled
            }
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

            switch MarkdownLinkActivation.decide(absolute) {
            case .confirmBeforeOpening(let confirmed):
                if let onOpenExternalURL {
                    onOpenExternalURL(confirmed)
                } else {
                    ExternalLinkConfirmation.present(
                        ExternalLinkConfirmation.request(for: confirmed)
                    )
                }
            case .openDirectly(.local):
                onOpenLocalLink?(url.relativeString)
            case .openDirectly, .refused:
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

    static func footnoteURL(number: Int) -> URL? {
        URL(string: "\(footnoteScheme)://\(number)")
    }

    static func footnoteNumber(from url: URL) -> Int? {
        guard url.scheme == footnoteScheme else { return nil }
        return Int(url.host ?? "")
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
    /// The metadata identity currently displayed. The poll runs every two
    /// seconds; a cache hit used to publish the same image and clear the
    /// failure flag each time, invalidating the block for nothing.
    @State private var loadedIdentity: String?
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
            if image != nil || decodeFailed || loadedIdentity != nil {
                image = nil
                decodeFailed = false
                loadedIdentity = nil
            }
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
            if image != nil || decodeFailed || loadedIdentity != nil {
                image = nil
                decodeFailed = false
                loadedIdentity = nil
            }
            return
        }
        // The poll fires every two seconds; an unchanged file must publish
        // nothing, or the rendered block invalidates forever.
        guard identity != loadedIdentity else { return }
        let key = identity as NSString
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            decodeFailed = false
            loadedIdentity = identity
            return
        }

        let decoded: NSImage? = await Task.detached(
            priority: .userInitiated
        ) {
            BoundedImageLoader.image(at: url)
        }.value
        guard !Task.isCancelled else { return }
        loadedIdentity = identity
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
struct MarkdownCodeBlockView: View {
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
            highlightedText = await MarkdownFenceHighlighter.highlight(
                code: code.code,
                languageName: code.language
            )
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

}

/// The rendered viewer's fenced-code highlighter.
///
/// Lexing a large fence on the main actor stalls the render frame, so the
/// lexer runs in a detached task and the attributed result is assembled only
/// after the task is still current. SwiftUI cancels the task when the fence's
/// identity changes, and the cancellation check discards a stale result.
enum MarkdownFenceHighlighter {
    /// `probe` runs inside the detached lex and exists so a regression test
    /// can prove the work is not on the main actor.
    @MainActor
    static func highlight(
        code: String,
        languageName: String?,
        probe: (@Sendable () -> Void)? = nil
    ) async -> AttributedString? {
        guard let language = MarkdownFenceLanguage.language(
            for: languageName
        ), language != .plainText,
           code.utf8.count <= MarkdownLimits.maxHighlightedFenceBytes else {
            return nil
        }
        let snapshot = await Task.detached(priority: .userInitiated) {
            probe?()
            return CodeSyntaxHighlighter.lex(
                text: code,
                language: language,
                revision: 0
            )
        }.value
        guard !Task.isCancelled else { return nil }
        return assemble(code: code, snapshot: snapshot)
    }

    @MainActor
    private static func assemble(
        code: String,
        snapshot: CodeLexSnapshot
    ) -> AttributedString? {
        let ns = code as NSString
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
}

// MARK: - Rendered find bar

private struct RenderedFindBar: View {
    @Bindable var find: RenderedFindController
    let isFocusedPane: Bool
    @FocusState private var fieldFocused: Bool
    @State private var keyMonitor: Any?
    @State private var hostWindow = RenderedFindBarHostWindow()

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
        .background(
            RenderedFindBarWindowProbe { hostWindow.window = $0 }
        )
    }

    /// AppKit matches a lowercase menu equivalent without regard to Shift, so
    /// Cmd+G and Shift+Cmd+G both reach "Find Next". The bar owns both chords
    /// while it is visible, before menu dispatch.
    private func installMonitor() {
        guard keyMonitor == nil else { return }
        let find = find
        let host = hostWindow
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
            // A local monitor sees every window's keys. Without this guard
            // an open find bar in one window swallowed another window's
            // Find Next.
            guard let hostWindow = host.window,
                  event.window === hostWindow,
                  hostWindow.isKeyWindow,
                  self.isFocusedPane,
                  event.charactersIgnoringModifiers?.lowercased() == "g",
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

/// The window a view is hosted in, updated as the view moves between
/// windows. A plain class, not `@State`: the find bar reads it when an event
/// arrives and must not re-render when it changes.
private final class RenderedFindBarHostWindow {
    weak var window: NSWindow?
}

private struct RenderedFindBarWindowProbe: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class ProbeView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
