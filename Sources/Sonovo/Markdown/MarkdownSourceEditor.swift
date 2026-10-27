import AppKit
import Observation
import SonovoCore
import SwiftUI
import UniformTypeIdentifiers

private extension MultiCursorEdit.Operation {
    /// The policy-table entry this batch operation answers to. `.replace` is
    /// the cut path's "replace every selection with nothing".
    var policyOperation: MultiCursorPolicy.Operation {
        switch self {
        case .insert: .typing
        case .deleteBackward: .backspace
        case .deleteForward: .delete
        case .replace: .cut
        case .paste: .plainPaste
        }
    }
}

private extension MarkdownCommandKind {
    /// The policy-table entry a command answers to. Table edits and table
    /// insertion have their own row; a command that merely edits source is a
    /// formatting command.
    var policyOperation: MultiCursorPolicy.Operation {
        switch self {
        case .insertTable, .insertTableRowAbove, .insertTableRowBelow,
             .deleteTableRow, .insertTableColumnLeft, .insertTableColumnRight,
             .deleteTableColumn, .deleteTable, .setTableAlignment,
             .formatTable:
            .tableCommand
        default:
            .formattingCommand
        }
    }
}

/// The TextKit 2 Markdown source editor.
///
/// The view presents the document; it does not own the source, the revision,
/// or the undo stack. Edits flow into `MarkdownDocument.replaceSource`, parsing
/// is debounced through `MarkdownParseService`, and stale results are
/// discarded by revision.
@MainActor
final class MarkdownEditorController: NSObject, NSTextViewDelegate {
    let document: MarkdownDocument
    let textView: MarkdownTextView
    let scrollView: NSScrollView
    let reviewRulerView = ReviewMarkerRulerView()
    /// Secondary carets for the multi-cursor layer. The controller owns the
    /// caret set; the overlay only draws what it is given.
    private(set) var caretOverlay: CaretOverlayView?
    /// The caret set. nil means the editor behaves exactly as before:
    /// one native caret, and no edit is routed through the batch engine.
    private(set) var multiCursorSelection: MultiCursorSelection?
    /// True only for the synchronous window of a batch application. A text
    /// change or selection echo arriving inside it belongs to the batch.
    private var isApplyingBatch = false
    /// Suppresses the echo comparison for the synchronous batch window. The
    /// asynchronous restore never runs inside it.
    private var suppressSelectionEcho = false
    /// Display lines for vertical motion, valid for one buffer and width.
    ///
    /// The key is the synchronised revision and the storage length, not the
    /// text: `String ==` is canonical, so a decomposed source and its
    /// precomposed spelling compare equal while their UTF-16 offsets differ,
    /// and a cached line table would name positions in the wrong buffer.
    private var displayLineCache: (
        revision: UInt64,
        highlighted: UInt64?,
        length: Int,
        font: NSFont?,
        width: CGFloat,
        lines: [CaretDisplayLine]
    )?
    /// The editor's focus as its responder callbacks reported it. While a
    /// responder transfer is in progress the window still names the old
    /// responder, so the callbacks' value is authoritative once it exists.
    private var focusOverride: Bool?
    /// The document revision whose source is loaded into the text view.
    ///
    /// A revision captured just before a batch proves only what the document
    /// holds at that moment, not that the view's buffer belongs to it: an
    /// external update of the same length slips past a length test and the
    /// batch would write over it. Every path that copies the document into
    /// the view, or writes the view back into the document, records the
    /// revision here; the batch refuses when it no longer matches.
    private var synchronizedRevision: UInt64 = 0
    /// Whether a native selection change is a user action in this text view.
    /// The notification carries no cause: a click or drag means the user
    /// took over and must collapse the set, while find-bar navigation is
    /// primary-only and must preserve it. The default reads the window's
    /// first responder; a test can supply the answer without a window.
    var isSelectionChangeUserDriven: () -> Bool = { false }
    /// The pasteboard the clipboard commands read and write. Injectable so a
    /// test never touches the user's real clipboard.
    var clipboard: NSPasteboard = .general

    private final class WeakController: @unchecked Sendable {
        weak var value: MarkdownEditorController?
    }

    private let weakSelf = WeakController()
    private var scrollObserver: NSObjectProtocol?
    private var preferenceObserver: NSObjectProtocol?
    /// Window resign is a collapse surface: the caret set must not survive the
    /// editor leaving the key window.
    private var windowResignObserver: NSObjectProtocol?
    private var visibleHighlightTask: Task<Void, Never>?

    private let parseCoordinator: MarkdownParseCoordinator
    private let parseDebounce: TimeInterval
    private var parseObserverToken: UUID?
    private let registry = MarkdownCommandRegistry()
    private let assetStore = MarkdownAssetStore()
    private(set) var lastCommandError: Error? {
        didSet {
            guard let lastCommandError else { return }
            onCommandError?(String(describing: lastCommandError))
        }
    }
    /// Production surfaces route command and asset failures to the workspace
    /// banner instead of leaving them in an unread property.
    var onCommandError: ((String) -> Void)?

    private var parseTask: Task<Void, Never>?
    private var pendingParseRevision: UInt64?
    private var linkPopover: MarkdownLinkPopoverController?
    private var tablePopover: MarkdownTablePopoverController?
    /// The table the grid popover edits, captured when it opened. Commits
    /// refuse when the document no longer holds this exact block.
    private(set) var tableSnapshot: MarkdownTableSnapshot?
    /// The document revision the snapshot belongs to. A reload or an edit
    /// elsewhere refuses the next commit instead of writing through it.
    private(set) var tableSnapshotRevision: UInt64 = 0
    private(set) var lintDiagnostics: [MarkdownDiagnostic] = []
    /// View-only display modes. They never touch the text or the undo stack.
    var isFocusModeEnabled = false
    var isTypewriterEnabled = false
    private var lineNumberCache: (
        revision: UInt64,
        length: Int,
        starts: [Int]
    )?
    /// The workspace's effective-root generation, captured into action
    /// targets so a project switch refuses a stale popover commit.
    var rootGenerationProvider: () -> UInt64 = { 0 }
    /// Supplies the comment margin's markers. The workspace owns comment
    /// state; the editor asks instead of keeping a second copy that could
    /// drift.
    var reviewMarkerProvider: (() -> [ReviewMarkerRulerView.Marker])?
    var onReviewMarkerSelected: ((UUID) -> Void)?
    /// Reports the viewport's reading anchor after a scroll. The split view
    /// uses it to follow the source pane; nil elsewhere.
    var onVisibleAnchorChange: ((SourceReadingAnchor) -> Void)?
    /// Reports that this editor became the editing surface, so a
    /// two-document split can route commands to its pane.
    var onFocus: (() -> Void)?
    /// Routes a link the source link popover opens, using the workspace's
    /// routing so Source and Rendered cannot disagree.
    var onOpenLocalLink: ((String) -> Void)?
    var onOpenMediaLink: ((MediaReference) -> Void)?
    /// A wiki target is not a path; the workspace resolves it by name.
    var onOpenWikiLink: ((WikiLink) -> Void)?
    /// The document state when the current input-method composition began.
    private var compositionBaseline: CompositionBaseline?
    /// The action name for the edit currently being applied through the
    /// text view, so the document records the command's undo label.
    private var actionNameOverride: String?

    private struct CompositionBaseline {
        let revision: UInt64
        let source: String
    }

    /// An input-method composition in flight. The preimage is the text the
    /// composition started from; `span` is the primary span it replaces, in
    /// preimage offsets. The first marked-text update names the span through
    /// its pre-update selection; a later explicit replacement range overrides
    /// it. Later updates do not move the span: their pre-update selection
    /// tracks the marked text itself, not the span it replaces.
    private struct CompositionTracker {
        let preimage: String
        var span: Range<Int>?
    }
    private var compositionTracker: CompositionTracker?
    private var composingForMultiCursor: Bool {
        compositionTracker != nil
    }
    private var suppressSync = false
    private var pendingCommands: [QueuedCommand] = []
    /// A find-bar seed waiting for the view to gain a window.
    private var pendingFindSeed: (query: String, offset: Int)?
    /// A mount restore waiting for layout. An explicit navigation clears it.
    private var pendingReadingAnchor: SourceReadingAnchor?
    /// A reading anchor to reapply when an external reload replaces the
    /// whole source. Captured before the replacement, consumed by the next
    /// sync, and cleared by an explicit navigation.
    private var pendingSourceReplacementAnchor: SourceReadingAnchor?
    private(set) var lastOutput: MarkdownParseOutput?
    private(set) var lastHighlightedRevision: UInt64?
    /// Test hooks fired at the exact milestones a latency probe measures: a
    /// parse publication, and the end of the highlight pass that applies it.
    /// Polling the published properties cannot tell a fast chain from one
    /// whose two steps fell inside the same polling interval.
    var onParsePublished: ((UInt64) -> Void)?
    var onHighlightApplied: ((UInt64) -> Void)?

    private struct QueuedCommand {
        let documentID: UUID
        let revision: UInt64
        let selection: Range<Int>
        let action: @MainActor () -> Void
    }

    init(
        document: MarkdownDocument,
        parseCoordinator: MarkdownParseCoordinator,
        parseDebounce: TimeInterval
    ) {
        self.document = document
        self.parseCoordinator = parseCoordinator
        self.parseDebounce = parseDebounce
        self.textView = MarkdownTextView(usingTextLayoutManager: true)
        self.scrollView = NSScrollView()
        super.init()
        weakSelf.value = self
        isSelectionChangeUserDriven = { [weak self] in
            guard let self else { return false }
            return self.textView.window?.firstResponder === self.textView
        }

        configure(textView)
        configureScrollView()
        textView.onPlainClick = { [weak self] in
            self?.adoptSingleCursor()
        }
        textView.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.focusOverride = focused
            self.caretOverlay?.setFocused(focused)
            // MC-03 also hides the secondary selection backgrounds when the
            // editor is not first responder; they are text attributes, so
            // hiding them is another decoration pass.
            self.refreshMultiCursorDecorations()
        }
        textView.onPasteImage = { [weak self] data, fileExtension in
            self?.insertImageAsset(data, fileExtension: fileExtension) ?? false
        }
        textView.onSmartSelectAll = { [weak self] in
            self?.smartSelectAll() ?? false
        }
        textView.onEscapeSelection = { [weak self] in
            self?.collapseSmartSelection() ?? false
        }
        textView.onMultiCursorEscape = { [weak self] in
            guard let self, self.multiCursorSelection != nil else {
                return false
            }
            self.adoptSingleCursor()
            return true
        }
        textView.onSmartPaste = { [weak self] in
            self?.smartPaste() ?? false
        }
        textView.onInsertText = { [weak self] text, range in
            self?.handleTyping(text, replacementRange: range) ?? false
        }
        textView.onMarkedText = { [weak self] selectionBefore, replacement in
            self?.noteCompositionUpdate(
                selectionBefore: selectionBefore,
                replacementRange: replacement
            )
        }
        textView.onCompositionEnd = { [weak self] range in
            self?.finishCompositionIfNeeded(explicitRange: range)
        }
        textView.onMultiCursorPaste = { [weak self] in
            self?.pasteMultiCursor() ?? false
        }
        textView.onMultiCursorPlainPaste = { [weak self] in
            self?.pasteMultiCursor(plainTextOnly: true) ?? false
        }
        textView.onMultiCursorCopy = { [weak self] in
            self?.copyMultiCursor() ?? false
        }
        textView.onMultiCursorCut = { [weak self] in
            self?.cutMultiCursor() ?? false
        }
        textView.onCommandClick = { [weak self] point in
            self?.toggleCaret(at: point) ?? false
        }
        textView.delegate = self
        reviewRulerView.clientView = textView
        reviewRulerView.scrollView = scrollView
        reviewRulerView.lineTop = { [weak self] offset in
            self?.lineTop(offset: offset)
        }
        reviewRulerView.onSelect = { [weak self] id in
            self?.onReviewMarkerSelected?(id)
        }
        reviewRulerView.visibleLines = { [weak self] in
            self?.textView.visibleCodeLines() ?? []
        }
        reviewRulerView.lineNumberProvider = { [weak self] offset in
            self?.lineNumber(at: offset)
        }
        reviewRulerView.showsLineNumbers = Preferences.markdownLineNumbers
        textView.string = document.source
        synchronizedRevision = document.revision
        applyBaseAttributesOnly()
        parseObserverToken = parseCoordinator.addObserver(
            for: document.id
        ) { [weak self] state in
            self?.handleParseState(state)
        }
        // A coordinator that already parsed this revision (the editor was
        // recreated for a mode switch) publishes nothing for a repeat
        // request, so the new observer must read the current state once.
        handleParseState(parseCoordinator.state(for: document.id))
        isFocusModeEnabled = Preferences.markdownFocusMode
        isTypewriterEnabled = Preferences.markdownTypewriter
        observeDocument()
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .sonovoEditorPreferencesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyEditorPreferences()
            }
        }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Notification is not Sendable; carry the window's number and
            // compare it on the main actor instead.
            let number = (notification.object as? NSWindow)?.windowNumber
            MainActor.assumeIsolated {
                guard let self, let number,
                      self.textView.window?.windowNumber == number,
                      self.multiCursorSelection != nil else { return }
                self.resetMultiCursor()
            }
        }
    }

    /// Called when the view is attached to a window hierarchy.
    func attach() {
        installScrollObserver()
        syncFromDocument()
        refreshReviewMarkers()
    }

    isolated deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
        }
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
        }
        detach()
    }

    /// Stops consuming parse publications for this document.
    func detach() {
        tablePopover?.close()
        tablePopover = nil
        tableSnapshot = nil
        if let parseObserverToken {
            parseCoordinator.removeObserver(parseObserverToken, for: document.id)
            self.parseObserverToken = nil
        }
        parseTask?.cancel()
        parseTask = nil
        visibleHighlightTask?.cancel()
        visibleHighlightTask = nil
    }

    /// Applies a Settings change to an open editor: the wrap mode and font
    /// size take effect without reopening the document.
    private func applyEditorPreferences() {
        let wrap = Preferences.wrapLines
        textView.isHorizontallyResizable = !wrap
        textView.autoresizingMask = wrap ? [.width] : []
        if let container = textView.textContainer {
            container.widthTracksTextView = wrap
            container.containerSize = NSSize(
                width: wrap
                    ? scrollView.contentSize.width
                    : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        isFocusModeEnabled = Preferences.markdownFocusMode
        isTypewriterEnabled = Preferences.markdownTypewriter
        reviewRulerView.showsLineNumbers = Preferences.markdownLineNumbers
        refreshReviewMarkers()
        applyBaseAttributesOnly()
        scheduleVisibleHighlight()
    }

    private func configureScrollView() {
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        textView.frame = scrollView.contentView.bounds
        textView.minSize = NSSize(
            width: AppTheme.Editor.minimumTextSize,
            height: AppTheme.Editor.minimumTextSize
        )
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        let wrap = Preferences.wrapLines
        textView.isHorizontallyResizable = !wrap
        textView.autoresizingMask = wrap ? [.width] : []
        textView.textContainer?.containerSize = NSSize(
            width: wrap
                ? scrollView.contentSize.width
                : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = wrap
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = false
        scrollView.verticalRulerView = reviewRulerView
    }

    /// Recomputes the margin markers and shows the gutter only while at least
    /// one thread is anchored. Called after comment edits, source edits, and
    /// mount.
    func refreshReviewMarkers() {
        let markers = reviewMarkerProvider?() ?? []
        reviewRulerView.commentMarkers = markers
        let show = reviewRulerView.showsLineNumbers
            || markers.contains(where: \.anchored)
        if scrollView.rulersVisible != show {
            scrollView.rulersVisible = show
        }
        reviewRulerView.needsDisplay = true
    }

    private func installScrollObserver() {
        guard scrollObserver == nil else { return }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        let box = weakSelf
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard let controller = box.value else { return }
                controller.reviewRulerView.needsDisplay = true
                controller.scheduleVisibleHighlight()
                if let anchor = controller.readingAnchor() {
                    controller.onVisibleAnchorChange?(anchor)
                }
            }
        }
    }

    private func scheduleVisibleHighlight() {
        guard let output = lastOutput else { return }
        visibleHighlightTask?.cancel()
        visibleHighlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled, let self else { return }
            self.applyHighlight(
                output,
                decorations: self.currentDecorations
            )
        }
    }

    /// The cell the caret is in, when the source is a valid table. The
    /// selection must be collapsed: a multi-cell selection has no single
    /// cell to highlight.
    private var tableCellRange: Range<Int>? {
        let selection = textView.selectedRange()
        guard selection.length == 0,
              let table = MarkdownTableScanner.table(
                  at: selection.location,
                  in: textView.string
              ),
              table.isValid else {
            return nil
        }
        for row in [table.header] + table.body {
            if let cell = row.cells.first(where: {
                selection.location >= $0.segmentRange.lowerBound
                    && selection.location <= $0.segmentRange.upperBound
            }) {
                let lower = cell.segmentRange.lowerBound
                let upper = cell.segmentRange.upperBound
                return lower..<upper
            }
        }
        return nil
    }

    /// The decoration layers that are independent of the parse output.
    ///
    /// MC-03: the selection background hides while the editor is not first
    /// responder or a composition is in flight. `selectionsVisible` carries
    /// the composition case, where the background has to be cleared before
    /// the marked text exists; focus is read from the responder record.
    private var currentDecorations: MarkdownDecorationSet {
        decorations(selectionsVisible: true, recomputingSemantics: true)
    }

    /// The last computed caret-independent layers. Cached because the cell
    /// lookup is a whole-document table scan: recomputing them per character
    /// made the batch path scale with document size instead of with the
    /// caret count.
    private var cachedSemanticDecorations: MarkdownDecorationSet?

    private func decorations(
        selectionsVisible: Bool,
        recomputingSemantics: Bool = false
    ) -> MarkdownDecorationSet {
        var decorations = recomputingSemantics
            ? computeSemanticDecorations()
            : cachedSemanticDecorations ?? computeSemanticDecorations()
        if let model = multiCursorSelection,
           selectionsVisible,
           editorIsFocused {
            decorations.selection = MultiCursorDecoration.selections(
                for: model,
                color: AppTheme.MultiCursor.selectionColor
            )
        }
        return decorations
    }

    /// Recomputes and caches focus dimming, the caret's table cell, and lint
    /// underlines. A pass that reuses the cache lets the cell layer lag by
    /// the batch's length delta until the next full pass; the deferred
    /// viewport pass follows a batch within a frame and refreshes it.
    private func computeSemanticDecorations() -> MarkdownDecorationSet {
        var decorations = MarkdownDecorationSet()
        if isFocusModeEnabled, let output = lastOutput {
            decorations.focus = MarkdownFocus.decorations(
                sourceLength: (textView.string as NSString).length,
                caret: textView.selectedRange().location,
                blocks: output.ast.blocks,
                dim: NSColor(AppTheme.MarkdownChrome.Focus.dim)
            )
        }
        if let range = tableCellRange {
            decorations.cell = [
                MarkdownDecoration(
                    layer: .cell,
                    range: NSRange(
                        location: range.lowerBound,
                        length: range.upperBound - range.lowerBound
                    ),
                    attributes: [
                        .backgroundColor: NSColor(
                            AppTheme.MarkdownChrome.TableCell.highlight
                        )
                    ]
                )
            ]
        }
        decorations.lint = lintDiagnostics.map { diagnostic in
            MarkdownDecoration(
                layer: .lint,
                range: NSRange(
                    location: diagnostic.range.lowerBound,
                    length: diagnostic.range.upperBound
                        - diagnostic.range.lowerBound
                ),
                attributes: [
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: NSColor(
                        diagnostic.severity == .error
                            ? AppTheme.MarkdownChrome.Lint.error
                            : AppTheme.MarkdownChrome.Lint.warning
                    )
                ]
            )
        }
        cachedSemanticDecorations = decorations
        return decorations
    }

    /// The editor's focus. The responder callbacks record a transfer the
    /// window has not completed yet; a windowless editor (tests, the probe)
    /// has no responder to ask and paints as focused.
    private var editorIsFocused: Bool {
        if let focusOverride { return focusOverride }
        guard let window = textView.window else { return true }
        return window.firstResponder === textView
    }

    /// Shows the diagnostics from an explicit "Check Markdown" run. An edit
    /// clears them immediately; they are never stale last-run counts.
    func setLintDiagnostics(_ diagnostics: [MarkdownDiagnostic]) {
        lintDiagnostics = diagnostics
        scheduleVisibleHighlight()
    }

    private func clearLintDiagnostics() {
        guard !lintDiagnostics.isEmpty else { return }
        lintDiagnostics = []
        scheduleVisibleHighlight()
    }

    /// The fixed paste chain. A conversion replaces the selection in one
    /// undoable edit; plain content returns false so AppKit pastes it.
    func smartPaste() -> Bool {
        guard !textView.hasMarkedText() else { return false }
        let pasteboard = NSPasteboard.general
        var flavors: [MarkdownPasteInput.Flavor] = []
        if let url = pasteboard.string(forType: .URL) {
            flavors.append(.url(url))
        }
        if let text = pasteboard.string(forType: .string) {
            flavors.append(.text(text))
        }
        if let html = pasteboard.string(forType: .html) {
            flavors.append(.html(html))
        }
        guard !flavors.isEmpty else { return false }

        let selection = Range(textView.selectedRange()) ?? 0..<0
        let ns = textView.string as NSString
        guard selection.upperBound <= ns.length else { return false }
        let selectionText = ns.substring(
            with: NSRange(
                location: selection.lowerBound,
                length: selection.upperBound - selection.lowerBound
            )
        )
        let input = MarkdownPasteInput(
            flavors: flavors,
            selectionText: selectionText,
            isInsideFence: MarkdownTypingPolicy.isInsideFence(
                textView.string,
                at: selection.lowerBound
            ),
            documentSource: textView.string
        )
        guard case let .insert(range, replacement, newSelection) =
            MarkdownPasteConverter.plan(input: input, selection: selection)
        else {
            return false
        }
        let newSource = ns.replacingCharacters(
            in: NSRange(
                location: range.lowerBound,
                length: range.upperBound - range.lowerBound
            ),
            with: replacement
        )
        return apply(
            MarkdownCommandResult(
                source: newSource,
                selection: newSelection,
                actionName: "Paste",
                previousSource: textView.string
            )
        )
    }

    /// Commands the palette may offer for the current context.
    func availableCommands() -> [MarkdownCommandKind] {
        let context = commandContext()
        return MarkdownCommandCatalog.paletteEntries {
            registry.isAvailable($0, in: context)
        }.map(\.command)
    }

    /// Cmd+A expands to the next enclosing container. Selection-only: no
    /// undo entry is created. With more than one caret the policy collapses
    /// to the primary first, then runs.
    func smartSelectAll() -> Bool {
        if multiCursorSelection != nil {
            guard multiCursorPolicy(.smartSelectAll) == .collapse else {
                // The table's one other sensible value is refuse; either way
                // a single-caret walk must not run over a live caret set.
                NSSound.beep()
                return true
            }
            adoptSingleCursor()
        }
        guard let output = lastOutput, output.revision == document.revision
        else { return false }
        let selection = Range(textView.selectedRange()) ?? 0..<0
        guard let next = MarkdownSmartSelect.next(
            source: textView.string,
            selection: selection,
            ast: output.ast
        ) else {
            return false
        }
        textView.setSelectedRange(
            NSRange(location: next.lowerBound, length: next.count)
        )
        return true
    }

    /// Escape collapses a smart selection to a caret at its start.
    func collapseSmartSelection() -> Bool {
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return false }
        textView.setSelectedRange(
            NSRange(location: selection.location, length: 0)
        )
        return true
    }

    /// Selects the next or previous diagnostic, wrapping around.
    func goToDiagnostic(backwards: Bool) {
        guard !lintDiagnostics.isEmpty else {
            NSSound.beep()
            return
        }
        let sorted = lintDiagnostics.sorted {
            $0.range.lowerBound < $1.range.lowerBound
        }
        let caret = textView.selectedRange().location
        let index: Int
        if backwards {
            index = sorted.lastIndex {
                $0.range.upperBound <= caret
            } ?? (sorted.count - 1)
        } else {
            index = sorted.firstIndex {
                $0.range.lowerBound > caret
            } ?? 0
        }
        select(range: sorted[index].range)
    }

    /// The range highlighting may touch: the visible text plus a margin.
    /// Without a laid-out window this is the whole document.
    private func affectedRange() -> NSRange {
        let length = textView.string.utf16.count
        let full = NSRange(location: 0, length: length)
        guard length > 0 else { return full }

        // TextKit 2 knows the laid-out viewport. This works before the view is
        // in a window, unlike `visibleRect`.
        if let layout = textView.textLayoutManager,
           let content = layout.textContentManager {
            layout.textViewportLayoutController.layoutViewport()
            if let viewport = layout.textViewportLayoutController.viewportRange {
                let start = content.offset(
                    from: content.documentRange.location,
                    to: viewport.location
                )
                let end = content.offset(
                    from: content.documentRange.location,
                    to: viewport.endLocation
                )
                let margin = AppTheme.Editor.visibleRangeMargin
                let lower = max(0, min(start, end) - margin)
                let upper = min(length, max(start, end) + margin)
                if upper > lower {
                    return NSRange(location: lower, length: upper - lower)
                }
            }
        }

        // The clip view's bounds are the visible rect in the document view's
        // coordinate system.
        let visible = scrollView.contentView.bounds
        guard !visible.isEmpty else { return full }

        let top = textView.characterIndexForInsertion(
            at: NSPoint(x: visible.minX, y: visible.minY)
        )
        let bottom = textView.characterIndexForInsertion(
            at: NSPoint(x: visible.maxX, y: visible.maxY)
        )
        let margin = AppTheme.Editor.visibleRangeMargin
        let lower = max(0, min(top, bottom) - margin)
        let upper = min(length, max(top, bottom) + margin)
        guard upper > lower else { return full }
        return NSRange(location: lower, length: upper - lower)
    }

    // MARK: - View configuration

    private func configure(_ view: NSTextView) {
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isContinuousSpellCheckingEnabled = true
        view.isGrammarCheckingEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        // The card behind the editor owns the surface color; a second
        // background here would paint a square rectangle inside the card.
        view.drawsBackground = false
        view.textContainerInset = NSSize(
            width: AppTheme.Reading.sourceInsetHorizontal,
            height: AppTheme.Reading.sourceInsetVertical
        )
        // Resizing and width-tracking are owned by `configureScrollView`.
        view.textContainer?.lineFragmentPadding = AppTheme.Editor.lineFragmentPadding
        view.isEditable = !document.isReadOnly
        view.typingAttributes = baseAttributes
        view.setAccessibilityLabel("Markdown source")
        view.setAccessibilityRole(.textArea)

        let overlay = CaretOverlayView(textView: view)
        view.addSubview(overlay)
        caretOverlay = overlay
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = AppTheme.Reading.sourceLineHeightMultiple
        paragraph.paragraphSpacing = AppTheme.Reading.sourceParagraphSpacing
        // Source is code-shaped text: monospaced, wide leading, and a
        // smaller paragraph gap so consecutive lines stay together.
        return [
            .font: NSFont.monospacedSystemFont(
                ofSize: Preferences.editorFontSize,
                weight: .regular
            ),
            .foregroundColor: NSColor(AppTheme.Palette.label),
            .paragraphStyle: paragraph
        ]
    }

    private func applyBaseAttributesOnly() {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)
        storage.endEditing()
        textView.typingAttributes = baseAttributes
    }

    // MARK: - Document binding

    /// Copies document state into the text view. Used after undo, reload, or a
    /// mode switch.
    func syncFromDocument() {
        textView.isEditable = !document.isReadOnly
        refreshReviewMarkers()
        if textView.hasMarkedText() {
            // A document update that cannot be applied mid-composition must
            // still be remembered, so the commit does not overwrite it.
            recordCompositionBaselineIfNeeded()
            return
        }

        let selected = textView.selectedRange()
        // The length test is O(1) and settles every edit that changed the
        // length; only a same-length replacement reaches the exact code-unit
        // comparison, which costs ~90 ms per megabyte when it runs.
        let textLength = textView.textStorage?.length ?? 0
        if textLength == document.sourceUTF16Count,
           (textView.string as NSString).isEqual(to: document.source) {
            // The view already holds this revision, so a batch computed on it
            // is safe.
            synchronizedRevision = document.revision
            restoreSelection(selected)
            // Initial attachment copies the source in `init`, so the strings
            // are already equal and this is the only place that can start the
            // first parse. Without it an existing document stays unhighlighted
            // until its first edit.
            if lastOutput?.revision != document.revision,
               pendingParseRevision != document.revision {
                scheduleParse(immediate: true)
            }
            return
        }

        resetTextToDocument()
        restoreSelection(selected)
        if let anchor = pendingSourceReplacementAnchor {
            pendingSourceReplacementAnchor = nil
            restoreReadingAnchor(anchor)
        }
        scheduleParse(immediate: true)
    }

    /// Copies the document source into the view without recording an edit.
    private func resetTextToDocument() {
        // Diagnostics describe the replaced text; keeping them would let the
        // next highlight paint ranges from the old source and let problem
        // navigation jump to them.
        lintDiagnostics = []
        // The caret set names offsets in the replaced text.
        resetMultiCursor()
        compositionTracker = nil
        suppressSync = true
        textView.string = document.source
        synchronizedRevision = document.revision
        applyBaseAttributesOnly()
        suppressSync = false
    }

    /// Restores the selection without republishing it. This runs from
    /// `updateNSView`; `setSelectedRange` posts a selection notification on
    /// every call, and a notification raised inside the update path is how a
    /// SwiftUI representable re-enters itself. The document selection is
    /// observable, so it is written only when it differs.
    private func restoreSelection(_ selected: NSRange) {
        let length = (textView.string as NSString).length
        let location = min(max(0, selected.location), length)
        let upper = min(length, location + max(0, selected.length))
        let range = NSRange(location: location, length: upper - location)
        if textView.selectedRange() != range {
            textView.setSelectedRange(range)
        }
        if let swiftRange = Range(range), document.selection != swiftRange {
            document.selection = swiftRange
        }
    }

    private func observeDocument() {
        withObservationTracking {
            _ = document.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncFromDocument()
                self.observeDocument()
            }
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !suppressSync else { return }

        // A read-only document's text view should never accept an edit, but
        // commands and undo can still reach this path. Revert rather than
        // letting the visible text diverge from the saved source.
        guard !document.isReadOnly else {
            resetTextToDocument()
            lastCommandError = DocumentError.readOnly
            return
        }

        // Never mutate the document while a composition is in flight, but
        // remember what the composition was based on.
        if textView.hasMarkedText() {
            recordCompositionBaselineIfNeeded()
            return
        }
        finishCompositionIfNeeded(explicitRange: nil)
        if let baseline = compositionBaseline {
            compositionBaseline = nil
            if document.revision != baseline.revision
                || document.source != baseline.source {
                // The document changed while the composition was in flight
                // (an external reload or adoption). Writing the stale editor
                // buffer composed on top of the old text would silently
                // discard that update.
                resetTextToDocument()
                lastCommandError = DocumentError.staleCompletion
                return
            }
        }

        // A native edit on a stale buffer is the single-caret form of the
        // overwrite the batch refuses. Without this record a keystroke typed
        // before the editor synced an external update would write the old
        // text back over it. Rebuild from the document; the keystroke is the
        // one that loses.
        guard synchronizedRevision == document.revision else {
            resetTextToDocument()
            lastCommandError = DocumentError.staleCompletion
            return
        }

        // A length mismatch proves the text differs; exact code-unit
        // comparison is reserved for a same-length replacement.
        let textLength = textView.textStorage?.length ?? 0
        if textLength != document.sourceUTF16Count
            || !(textView.string as NSString).isEqual(to: document.source) {
            do {
                try document.replaceSource(
                    textView.string,
                    actionName: actionNameOverride ?? "Edit"
                )
            } catch {
                lastCommandError = error
                resetTextToDocument()
                return
            }
        }
        // The view and the document agree on this revision, whether the
        // write-back ran or the text was already identical.
        synchronizedRevision = document.revision
        if let range = Range(textView.selectedRange()) {
            document.selection = range
        }

        clearLintDiagnostics()
        scheduleParse()
        flushPendingCommands()
        refreshReviewMarkers()
        keepCaretNearTypewriterLine()
    }

    /// Records the state the current composition started from, once.
    ///
    /// The revision is the one the editor buffer represents, not the
    /// document's current revision. When an external update has landed since
    /// the last sync, the buffer still holds the older text; recording the
    /// newer revision would make the commit look current and let it overwrite
    /// that update. The commit then sees the mismatch and resets instead.
    private func recordCompositionBaselineIfNeeded() {
        guard compositionBaseline == nil else { return }
        compositionBaseline = CompositionBaseline(
            revision: synchronizedRevision,
            source: document.source
        )
    }

    func textDidBeginEditing(_ notification: Notification) {
        onFocus?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // With a caret set live, a native selection change is one of three
        // things: an echo of our own write (suppressed above), a pointer
        // gesture by the user, or a navigation another surface performed —
        // Find, review markers, a reading anchor, Edit in Source. A pointer
        // gesture collapses the set. Navigation is primary-only: the set
        // survives and its primary follows the selection, because otherwise
        // the next edit would land at the old primary while the user looks at
        // a different caret. The notification carries no cause, so Find
        // brackets its call (see `MarkdownTextView.navigationDepth`).
        if !suppressSelectionEcho,
           !composingForMultiCursor,
           multiCursorSelection != nil,
           let native = Range(textView.selectedRange()) {
            let isPointer = isSelectionChangeUserDriven()
                && textView.navigationDepth == 0
            if isPointer, native != multiCursorSelection?.primaryRange {
                adoptSingleCursor()
            } else if !isPointer {
                // The table names navigation primary-only; any other outcome
                // for it leaves the set alone rather than guessing.
                switch multiCursorPolicy(.find) {
                case .primaryOnly:
                    movePrimary(to: native)
                case .collapse:
                    adoptSingleCursor()
                case .refuse, .batch:
                    break
                }
            }
        }
        if let range = Range(textView.selectedRange()),
           document.selection != range {
            document.selection = range
        }
        scheduleVisibleHighlight()
        keepCaretNearTypewriterLine()
    }

    // The choke point: with more than one caret, any AppKit-initiated text
    // change that is not the batch itself is refused before the first
    // storage mutation. A route the plan forgot fails closed here instead of
    // editing only the primary. An input-method composition is the one
    // exception: its edits belong to the primary, and the terminal commit is
    // translated for the secondaries in `finishCompositionIfNeeded`.
    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard !isApplyingBatch,
              !composingForMultiCursor,
              !textView.hasMarkedText(),
              let model = multiCursorSelection,
              model.count > 1 else { return true }
        return false
    }

    func textView(
        _ textView: NSTextView,
        shouldChangeTextInRanges affectedRanges: [NSValue],
        replacementStrings: [String]?
    ) -> Bool {
        guard !isApplyingBatch,
              !composingForMultiCursor,
              !textView.hasMarkedText(),
              let model = multiCursorSelection,
              model.count > 1 else { return true }
        return false
    }

    // MARK: - Multi-cursor

    /// The one-outcome policy every caret-set surface consults. Injectable so
    /// a test can prove a handler reads the table instead of hard-coding its
    /// current values.
    var multiCursorPolicy: (MultiCursorPolicy.Operation)
        -> MultiCursorPolicy.Outcome = { $0.outcome }

    /// The batch entry point's gate: only the table's `batch` outcome may run
    /// here. Every other outcome stops with the standard beep — `.collapse`
    /// would have to re-run the operation natively, which the caller owns.
    /// Returns true when the caller must stop.
    private func gateBatch(_ operation: MultiCursorPolicy.Operation) -> Bool {
        guard multiCursorSelection != nil else { return false }
        guard multiCursorPolicy(operation) != .batch else { return false }
        NSSound.beep()
        return true
    }

    /// The gate for operations this path cannot batch. Returns true when the
    /// caller must stop; nil means proceed with one native caret (`.collapse`
    /// adopted the primary) or with the set intact (`.primaryOnly`).
    private func gateNonBatch(
        _ operation: MultiCursorPolicy.Operation
    ) -> Bool? {
        guard multiCursorSelection != nil else { return nil }
        switch multiCursorPolicy(operation) {
        case .collapse:
            adoptSingleCursor()
            return nil
        case .primaryOnly:
            return nil
        case .refuse:
            NSSound.beep()
            return true
        case .batch:
            // This path has no batch implementation. A table entry promising
            // one is a wiring bug; refuse rather than silently editing the
            // primary and leaving the other carets behind.
            assertionFailure("\(operation) has no batch implementation here")
            NSSound.beep()
            return true
        }
    }

    /// Adopts a caret set. One caret routes nothing through the batch engine;
    /// two or more make every supported edit a batch. The native selection
    /// always follows the primary, including the one-caret case (a placement
    /// command that finds a single occurrence still selects it). Placement
    /// gestures and tests use this entry point.
    func adoptMultiCursor(_ selection: MultiCursorSelection) {
        multiCursorSelection = selection.count > 1 ? selection : nil
        let primary = selection.primaryRange
        let native = NSRange(location: primary.lowerBound, length: primary.count)
        suppressSelectionEcho = true
        textView.setSelectedRange(native)
        suppressSelectionEcho = false
        // Placement can land on an occurrence several screens away (Cmd+D
        // wrapping to the top of a long document).
        textView.scrollRangeToVisible(native)
        refreshMultiCursorVisuals()
    }

    /// The user took over the native selection; multi-cursor mode ends.
    func adoptSingleCursor() {
        guard multiCursorSelection != nil else { return }
        multiCursorSelection = nil
        caretOverlay?.clear()
        refreshMultiCursorDecorations()
    }

    /// Programmatic navigation moved the native selection. The caret set
    /// survives, and its primary follows so the next edit lands where the
    /// user sees the caret; a secondary the new primary collides with is
    /// dropped.
    private func movePrimary(to range: Range<Int>) {
        guard let model = multiCursorSelection,
              range != model.primaryRange,
              range.lowerBound >= 0,
              range.lowerBound <= range.upperBound else {
            return
        }
        let caret = MultiCursorSelection.Caret(
            anchor: range.lowerBound,
            active: range.upperBound
        )
        guard let updated = try? model.movingPrimary(
            to: caret,
            source: textView.string
        ) else { return }
        multiCursorSelection = updated.count > 1 ? updated : nil
        refreshMultiCursorVisuals()
    }

    /// Collapses multi-cursor mode without touching text or selection.
    func resetMultiCursor() {
        guard multiCursorSelection != nil else { return }
        multiCursorSelection = nil
        caretOverlay?.clear()
        refreshMultiCursorDecorations()
    }

    // MARK: - Placement

    /// Cmd+click: toggles a caret at the click point and makes it primary.
    /// The click is consumed once it has been considered, so AppKit never
    /// moves the native selection behind the caret set. A read-only,
    /// rendered, or composing editor lets the click through untouched.
    func toggleCaret(at point: NSPoint) -> Bool {
        guard document.mode == .source,
              !document.isReadOnly,
              !textView.hasMarkedText() else {
            return false
        }
        let source = textView.string
        let length = (source as NSString).length
        let index = min(
            max(0, textView.characterIndexForInsertion(at: point)),
            length
        )
        do {
            let native = Range(textView.selectedRange()) ?? 0..<0
            let base: MultiCursorSelection
            if let existing = multiCursorSelection {
                base = existing
            } else {
                base = try MultiCursorSelection(
                    [
                        MultiCursorSelection.Caret(
                            anchor: min(native.lowerBound, length),
                            active: min(native.upperBound, length)
                        )
                    ],
                    primary: 0,
                    source: source
                )
            }
            adoptMultiCursor(
                try base.adding(anchor: index, active: index, source: source)
            )
        } catch {
            // A grapheme split or the caret cap: the gesture is refused, but
            // it still must not fall through to AppKit's selection handling.
            NSSound.beep()
        }
        return true
    }

    // MARK: - Input-method composition

    /// Records the primary span a composition replaces. Only a multi-caret
    /// editor translates anything, so a single caret never pays for a
    /// tracker. The first update's pre-event selection is the span; a later
    /// explicit replacement range overrides it. Later updates without an
    /// explicit range keep the original span, because their pre-event
    /// selection tracks the marked text itself.
    private func noteCompositionUpdate(
        selectionBefore: NSRange,
        replacementRange: NSRange
    ) {
        // The first marked-text update is the only synchronous signal that a
        // composition started: AppKit posts no text-change notification for
        // marked text, so `textDidChange` never sees the in-flight state and
        // cannot record the baseline. Record it here, before the multi-caret
        // guard, because a single-caret composition needs the same
        // protection against committing over an external update.
        recordCompositionBaselineIfNeeded()
        guard multiCursorSelection != nil else { return }
        let length = (textView.string as NSString).length
        func valid(_ range: NSRange) -> Range<Int>? {
            guard range.location != NSNotFound,
                  range.location >= 0,
                  range.length >= 0,
                  range.location <= length - range.length else {
                return nil
            }
            return range.location..<(range.location + range.length)
        }
        if compositionTracker == nil {
            compositionTracker = CompositionTracker(
                preimage: textView.string,
                span: valid(replacementRange) ?? valid(selectionBefore)
            )
            // MC-03: the selection background hides while a composition is in
            // flight. Attribute passes are refused once marked text exists,
            // so clear it now, before AppKit installs the composition.
            refreshMultiCursorDecorations(selectionsVisible: false)
        } else if let explicit = valid(replacementRange) {
            compositionTracker?.span = explicit
        }
    }

    /// Ends a composition once AppKit has cleared its marked text. The
    /// primary is wherever the native selection landed; every secondary
    /// translates by the span the composition actually replaced. A span the
    /// model cannot map (a grapheme split, a collision) collapses the set to
    /// the primary rather than risking corruption.
    private func finishCompositionIfNeeded(explicitRange: NSRange?) {
        guard var tracker = compositionTracker, !textView.hasMarkedText()
        else {
            return
        }
        compositionTracker = nil
        guard let model = multiCursorSelection, model.count > 1 else { return }
        let after = textView.string
        // Exact code-unit equality: composing a precomposed "é" over a
        // decomposed "e" + U+0301 makes Swift's canonical `==` true while the
        // UTF-16 offsets after the replacement shift, so the secondaries must
        // still translate.
        if (after as NSString).isEqual(to: tracker.preimage) {
            // The text is unchanged, but the native selection moved to the
            // end of the commit; the model primary must follow, or the next
            // keystroke edits the old range.
            if let range = Range(textView.selectedRange()),
               range != model.primaryRange,
               let updated = try? model.movingPrimary(
                   to: MultiCursorSelection.Caret(
                       anchor: range.lowerBound,
                       active: range.upperBound
                   ),
                   source: after
               ) {
                multiCursorSelection = updated.count > 1 ? updated : nil
            }
            refreshMultiCursorVisuals()
            return
        }
        // An explicit range on the commit itself outranks whatever the
        // marked-text updates implied.
        if let explicitRange,
           explicitRange.location != NSNotFound,
           explicitRange.location >= 0,
           explicitRange.length >= 0 {
            let preimageLength = (tracker.preimage as NSString).length
            if explicitRange.location
                <= preimageLength - explicitRange.length {
                let start = explicitRange.location
                tracker.span = start..<(start + explicitRange.length)
            }
        }
        let length = (after as NSString).length
        let selection = textView.selectedRange()
        guard selection.location != NSNotFound,
              selection.location >= 0,
              selection.length >= 0,
              selection.location <= length - selection.length else {
            adoptSingleCursor()
            return
        }
        let newPrimary = MultiCursorSelection.Caret(
            anchor: selection.location,
            active: selection.location + selection.length
        )
        let (replaced, inserted) = replacedSpan(
            from: tracker.preimage,
            to: after,
            hinted: tracker.span
        )
        do {
            let translated = try model.translated(
                replacing: replaced,
                with: inserted,
                primary: newPrimary,
                source: after
            )
            multiCursorSelection = translated.count > 1 ? translated : nil
            refreshMultiCursorVisuals()
        } catch {
            adoptSingleCursor()
        }
    }

    /// The span a composition actually replaced. The input method's own
    /// report is authoritative when it fits the observed text; otherwise the
    /// common prefix and suffix of preimage and postimage name the changed
    /// middle.
    private func replacedSpan(
        from preimage: String,
        to postimage: String,
        hinted: Range<Int>?
    ) -> (replaced: Range<Int>, inserted: Range<Int>) {
        let old = Array(preimage.utf16)
        let new = Array(postimage.utf16)
        if let hinted,
           hinted.lowerBound >= 0,
           hinted.upperBound <= old.count {
            let insertedLength = new.count - (old.count - hinted.count)
            let insertedEnd = hinted.lowerBound + insertedLength
            if insertedLength >= 0,
               insertedEnd <= new.count,
               Array(new[0..<hinted.lowerBound])
                == Array(old[0..<hinted.lowerBound]),
               Array(new[insertedEnd...])
                == Array(old[hinted.upperBound...]) {
                return (hinted, hinted.lowerBound..<insertedEnd)
            }
        }
        var prefix = 0
        while prefix < old.count,
              prefix < new.count,
              old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix,
              suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        return (
            prefix..<(old.count - suffix),
            prefix..<(new.count - suffix)
        )
    }

    // MARK: - Movement

    /// One keyboard motion with more than one caret. Selection-only: no
    /// text change, no undo entry.
    private struct MultiCursorMotion {
        let vertical: CaretMovement.Vertical?
        let direction: CaretMovement.Direction
        let unit: CaretMovement.Unit
        let extending: Bool

        init?(selector: Selector) {
            switch selector {
            case #selector(NSResponder.moveLeft(_:)):
                self.init(direction: .backward, unit: .grapheme, extending: false)
            case #selector(NSResponder.moveRight(_:)):
                self.init(direction: .forward, unit: .grapheme, extending: false)
            case #selector(NSResponder.moveLeftAndModifySelection(_:)):
                self.init(direction: .backward, unit: .grapheme, extending: true)
            case #selector(NSResponder.moveRightAndModifySelection(_:)):
                self.init(direction: .forward, unit: .grapheme, extending: true)
            case #selector(NSResponder.moveWordLeft(_:)),
                 #selector(NSResponder.moveWordBackward(_:)):
                self.init(direction: .backward, unit: .word, extending: false)
            case #selector(NSResponder.moveWordRight(_:)),
                 #selector(NSResponder.moveWordForward(_:)):
                self.init(direction: .forward, unit: .word, extending: false)
            case #selector(NSResponder.moveWordLeftAndModifySelection(_:)),
                 #selector(NSResponder.moveWordBackwardAndModifySelection(_:)):
                self.init(direction: .backward, unit: .word, extending: true)
            case #selector(NSResponder.moveWordRightAndModifySelection(_:)),
                 #selector(NSResponder.moveWordForwardAndModifySelection(_:)):
                self.init(direction: .forward, unit: .word, extending: true)
            case #selector(NSResponder.moveToBeginningOfLine(_:)):
                self.init(direction: .backward, unit: .line, extending: false)
            case #selector(NSResponder.moveToEndOfLine(_:)):
                self.init(direction: .forward, unit: .line, extending: false)
            case #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)):
                self.init(direction: .backward, unit: .line, extending: true)
            case #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)):
                self.init(direction: .forward, unit: .line, extending: true)
            case #selector(NSResponder.moveToBeginningOfDocument(_:)):
                self.init(direction: .backward, unit: .document, extending: false)
            case #selector(NSResponder.moveToEndOfDocument(_:)):
                self.init(direction: .forward, unit: .document, extending: false)
            case #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)):
                self.init(direction: .backward, unit: .document, extending: true)
            case #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:)):
                self.init(direction: .forward, unit: .document, extending: true)
            case #selector(NSResponder.moveUp(_:)):
                self.init(vertical: .up, extending: false)
            case #selector(NSResponder.moveDown(_:)):
                self.init(vertical: .down, extending: false)
            case #selector(NSResponder.moveUpAndModifySelection(_:)):
                self.init(vertical: .up, extending: true)
            case #selector(NSResponder.moveDownAndModifySelection(_:)):
                self.init(vertical: .down, extending: true)
            default:
                return nil
            }
        }

        private init(
            vertical: CaretMovement.Vertical? = nil,
            direction: CaretMovement.Direction = .forward,
            unit: CaretMovement.Unit = .grapheme,
            extending: Bool
        ) {
            self.vertical = vertical
            self.direction = direction
            self.unit = unit
            self.extending = extending
        }
    }

    private func applyMotion(_ motion: MultiCursorMotion) -> Bool {
        guard let model = multiCursorSelection else { return false }
        let moved: MultiCursorSelection
        do {
            if let vertical = motion.vertical {
                moved = try CaretMovement.vertical(
                    model,
                    in: textView.string,
                    direction: vertical,
                    extending: motion.extending,
                    lines: lineProvider()
                )
            } else {
                moved = try CaretMovement.horizontal(
                    model,
                    in: textView.string,
                    direction: motion.direction,
                    unit: motion.unit,
                    extending: motion.extending
                )
            }
        } catch {
            return true
        }
        multiCursorSelection = moved.count > 1 ? moved : nil
        suppressSelectionEcho = true
        let primary = moved.primaryRange
        let native = NSRange(location: primary.lowerBound, length: primary.count)
        textView.setSelectedRange(native)
        suppressSelectionEcho = false
        // Consuming the key bypasses AppKit's own scroll-into-view; a caret
        // moved several screens away must still be revealed.
        textView.scrollRangeToVisible(native)
        refreshMultiCursorVisuals()
        return true
    }

    /// Display lines are cached for one buffer, font, and width; a resize, a
    /// font change, or an edit rebuilds them from TextKit. The font belongs in
    /// the key because it changes wrapping at a fixed container width, and
    /// the revision because equality of text is not equality of offsets.
    private func lineProvider() -> TextKitLineProvider {
        let revision = synchronizedRevision
        // Syntax highlighting changes heading and inline fonts without an
        // edit, so the revision alone cannot say the layout is unchanged.
        // The highlighted revision is part of the key: a table built before
        // the pass is rebuilt once after it.
        let highlighted = lastHighlightedRevision
        let length = textView.textStorage?.length ?? 0
        let font = textView.font
        let width = textView.textContainer?.containerSize.width
            ?? textView.bounds.width
        if let cache = displayLineCache,
           cache.revision == revision,
           cache.highlighted == highlighted,
           cache.length == length,
           cache.font == font,
           cache.width == width {
            return TextKitLineProvider(lines: cache.lines)
        }
        let provider = TextKitLineProvider(textView: textView)
        displayLineCache = (
            revision,
            highlighted,
            length,
            font,
            width,
            provider.lines
        )
        return provider
    }

    @discardableResult
    func applyMultiCursor(_ operation: MultiCursorEdit.Operation) -> Bool {
        guard let model = multiCursorSelection, model.count > 1 else {
            return false
        }
        guard !gateBatch(operation.policyOperation) else { return true }
        guard !document.isReadOnly else {
            lastCommandError = DocumentError.readOnly
            return true
        }
        guard !isApplyingBatch else { return true }
        // The view's buffer must belong to the document revision the batch
        // will be applied to. An external update of equal length changes the
        // revision without changing any length, so only this recorded value
        // catches it.
        guard synchronizedRevision == document.revision,
              textView.textStorage?.length == document.sourceUTF16Count else {
            resetTextToDocument()
            lastCommandError = DocumentError.staleCompletion
            return true
        }
        let sourceRevision = document.revision
        let sourceLength = textView.textStorage?.length ?? 0
        // The guards above prove the view holds this document revision's
        // text at the recorded length; the document's copy is native, while
        // bridging the view's string once costs every offset conversion
        // inside the engine ~3 ms per megabyte per caret.
        switch MultiCursorEdit.apply(
            operation,
            to: document.source,
            selection: model
        ) {
        case .failure(let failure):
            NSSound.beep()
            lastCommandError = failure
            return true
        case .success(let output):
            guard output.changed else {
                // The replacements are textually a no-op but still collapse
                // selections to carets; the native selection must follow the
                // model, or the user sees a selection that typing ignores.
                adoptMultiCursor(output.selection)
                return true
            }
            guard output.source.utf8.count
                <= DocumentHistoryLimits.maxReplacementBytes else {
                NSSound.beep()
                lastCommandError = DocumentError.editTooLarge
                return true
            }
            // The engine is pure and synchronous, so nothing can edit the
            // storage or the document inside it. These O(1) invariants catch
            // a reentrant change exactly where the old whole-source
            // comparisons did, without their grapheme walk (~90 ms per
            // megabyte).
            guard document.revision == sourceRevision,
                  synchronizedRevision == sourceRevision,
                  document.sourceUTF16Count == sourceLength,
                  textView.textStorage?.length == sourceLength else {
                // The storage or the document changed behind the batch.
                // Rebuild from the document instead of writing an edit
                // computed on stale text.
                resetTextToDocument()
                lastCommandError = DocumentError.staleCompletion
                return true
            }
            applyBatch(output)
            return true
        }
    }

    /// Applies one batch inside the synchronous window: one storage edit over
    /// the span the replacements cover, the model primary, the native
    /// selection, one change notification, and one document revision. The
    /// suppression flags never outlive this call, so the asynchronous document
    /// sync still uses the echo comparison.
    private func applyBatch(_ output: MultiCursorEdit.Output) {
        guard let storage = textView.textStorage else { return }
        isApplyingBatch = true
        suppressSelectionEcho = true
        applyBatchReplacements(output.replacements, to: storage)
        // One caret after the batch means multi-cursor mode is over; keeping a
        // non-nil set would leave Return, Tab and formatting refused against a
        // stale two-caret model.
        multiCursorSelection = output.selection.count > 1
            ? output.selection
            : nil
        let primary = output.selection.primaryRange
        textView.setSelectedRange(
            NSRange(location: primary.lowerBound, length: primary.count)
        )
        actionNameOverride = output.actionName
        textView.didChangeText()
        actionNameOverride = nil
        suppressSelectionEcho = false
        isApplyingBatch = false
        refreshMultiCursorVisuals()
    }

    /// Applies every replacement as one storage edit over the span they
    /// cover. Editing the storage once per caret moves the text after that
    /// caret once per caret — with 100 carets early in a 1 MB document that
    /// is a hundred megabyte-scale moves per keystroke. One span replacement
    /// moves the tail once; the span's own attributes are carried from the
    /// pre-edit text, and the highlight pass repaints the syntax anyway.
    private func applyBatchReplacements(
        _ replacements: [MultiCursorEdit.Replacement],
        to storage: NSTextStorage
    ) {
        guard let highest = replacements.first,
              let lowest = replacements.last,
              lowest.range.lowerBound <= highest.range.upperBound else {
            return
        }
        let span = NSRange(
            location: lowest.range.lowerBound,
            length: highest.range.upperBound - lowest.range.lowerBound
        )
        // Build the new span once from untouched slices and payloads.
        // Replacing inside a mutable copy per caret shifted the copy's tail
        // at every step: 100 carets spread across a large span moved the
        // span's contents a hundred times.
        let built = NSMutableAttributedString()
        var cursor = span.location
        for replacement in replacements.reversed() {
            if replacement.range.lowerBound > cursor {
                built.append(
                    storage.attributedSubstring(
                        from: NSRange(
                            location: cursor,
                            length: replacement.range.lowerBound - cursor
                        )
                    )
                )
            }
            built.append(
                NSAttributedString(
                    string: replacement.text,
                    attributes: attributesForInsertion(
                        at: replacement.range.lowerBound,
                        in: storage
                    )
                )
            )
            cursor = replacement.range.upperBound
        }
        if cursor < span.upperBound {
            built.append(
                storage.attributedSubstring(
                    from: NSRange(
                        location: cursor,
                        length: span.upperBound - cursor
                    )
                )
            )
        }
        storage.replaceCharacters(in: span, with: built)
    }

    /// The attributes text inserted at `offset` inherits: those of the
    /// character it replaces or precedes, or the last character's at the end
    /// of the document.
    private func attributesForInsertion(
        at offset: Int,
        in storage: NSTextStorage
    ) -> [NSAttributedString.Key: Any] {
        guard storage.length > 0 else { return baseAttributes }
        let index = min(max(offset, 0), storage.length - 1)
        return storage.attributes(at: index, effectiveRange: nil)
    }

    private func refreshMultiCursorVisuals() {
        guard let model = multiCursorSelection else {
            caretOverlay?.clear()
            refreshMultiCursorDecorations()
            return
        }
        caretOverlay?.show(
            model.carets,
            primaryIndex: model.primaryIndex,
            composing: textView.hasMarkedText()
        )
        refreshMultiCursorDecorations()
    }

    private func refreshMultiCursorDecorations(
        selectionsVisible: Bool = true
    ) {
        let decorations = decorations(selectionsVisible: selectionsVisible)
        guard let output = lastOutput else {
            // An editable buffer beyond the parse limit has no output; the
            // selection backgrounds must still paint, or placement and batch
            // replacement would run with nothing visible.
            applyDecorationsWithoutSyntax(decorations)
            return
        }
        applyHighlight(output, decorations: decorations)
    }

    /// Paints the semantic layers with no syntax pass. Used when parsing is
    /// disabled for an oversized buffer; the compositor still needs its
    /// decoration layers applied over base attributes.
    private func applyDecorationsWithoutSyntax(
        _ decorations: MarkdownDecorationSet
    ) {
        guard !textView.hasMarkedText(), let storage = textView.textStorage else {
            return
        }
        let manager = document.undoManager
        let wasEnabled = manager.isUndoRegistrationEnabled
        if wasEnabled {
            manager.disableUndoRegistration()
        }
        defer {
            if wasEnabled {
                manager.enableUndoRegistration()
            }
        }
        MarkdownDecorationCompositor.apply(
            syntax: { _ in },
            decorations: decorations,
            to: storage,
            affectedRange: affectedRange(),
            baseAttributes: baseAttributes
        )
        textView.typingAttributes = baseAttributes
    }

    /// Plain-text paste only. An image or rich payload is refused: the policy
    /// table gives those surfaces exactly one outcome, and it is not a batch.
    /// `plainTextOnly` is the Paste as Plain Text command: the payload's
    /// string is used whatever else it carries.
    private func pasteMultiCursor(plainTextOnly: Bool = false) -> Bool {
        guard let model = multiCursorSelection, model.count > 1 else {
            return false
        }
        // A composition owns the next edit. Marked text has already rewritten
        // storage, so the model's ranges name the pre-composition buffer; a
        // batch would fail its length guard and reset the editor, discarding
        // the composition. The native paste path replaces the marked text
        // correctly, so leave this paste to it.
        guard !textView.hasMarkedText(), !composingForMultiCursor else {
            return false
        }
        let pasteboard = clipboard
        let types = pasteboard.types ?? []
        let operation: MultiCursorPolicy.Operation
        // The same classification the native handler uses: an image file URL
        // pastes an image even when the pasteboard also carries a string
        // fallback, so it must not be batched as plain text.
        if plainTextOnly {
            operation = .plainPaste
        } else if textView.isImagePasteboard(pasteboard) {
            operation = .imagePaste
        } else if types.contains(.html) {
            operation = .smartPaste
        } else {
            operation = .plainPaste
        }
        switch multiCursorPolicy(operation) {
        case .refuse:
            NSSound.beep()
            return true
        case .batch:
            break
        case .collapse, .primaryOnly:
            // No paste surface has either outcome in the table.
            return true
        }
        guard let text = pasteboard.string(forType: .string) else {
            NSSound.beep()
            return true
        }
        return applyMultiCursor(.paste(text))
    }

    /// The concatenation of every non-empty selection, in caret order. A
    /// zero-length caret contributes nothing.
    func multiCursorCopyText() -> String? {
        // Marked text has already rewritten the storage, so the model's
        // ranges still name the pre-composition buffer and extracting them
        // would raise an NSRangeException. During composition the native
        // primary selection is the only coherent selection: let the native
        // copy path handle it.
        guard !textView.hasMarkedText(), !composingForMultiCursor else {
            return nil
        }
        guard let model = multiCursorSelection, model.count > 1 else {
            return nil
        }
        let ns = textView.string as NSString
        var pieces: [String] = []
        for caret in model.carets where !caret.range.isEmpty {
            // A range outside the current storage means the model describes a
            // different source; a partial concatenation would be wrong.
            guard caret.range.lowerBound >= 0,
                  caret.range.upperBound <= ns.length else {
                return nil
            }
            pieces.append(
                ns.substring(
                    with: NSRange(
                        location: caret.range.lowerBound,
                        length: caret.range.count
                    )
                )
            )
        }
        guard !pieces.isEmpty else { return nil }
        return pieces.joined()
    }

    private func copyMultiCursor() -> Bool {
        // The table names copy a batch: one concatenated clipboard write.
        // Consulting it here keeps the clipboard path honest even if the
        // table's verdict changes.
        guard multiCursorPolicy(.copy) == .batch else {
            NSSound.beep()
            return true
        }
        guard let text = multiCursorCopyText() else { return false }
        let pasteboard = clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    private func cutMultiCursor() -> Bool {
        guard let model = multiCursorSelection, model.count > 1,
              model.carets.contains(where: { !$0.range.isEmpty }) else {
            return false
        }
        guard copyMultiCursor() else { return false }
        // Replacing each selection with nothing leaves zero-length carets
        // untouched; that is the cut every caret expects.
        return applyMultiCursor(.replace(""))
    }

    /// Keeps the caret's visual line near 40% of the viewport. A line already
    /// within the jitter window does not move, and Reduce Motion falls back
    /// to the minimal scroll instead of re-centering.
    func keepCaretNearTypewriterLine() {
        guard isTypewriterEnabled, !textView.hasMarkedText() else { return }
        let caret = textView.selectedRange().location
        // The caret may be offscreen after a programmatic move; lay its line
        // out before measuring it.
        textView.scrollRangeToVisible(NSRange(location: caret, length: 0))
        guard let line = textView.visibleCodeLines()
            .last(where: { $0.documentOffset <= caret }) else {
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            textView.scrollRangeToVisible(
                NSRange(location: caret, length: 0)
            )
            return
        }
        let visible = scrollView.contentView.bounds
        guard let target = MarkdownTypewriter.scrollTarget(
            viewportMinY: visible.minY,
            viewportHeight: visible.height,
            caretLineTop: line.rect.minY
        ) else {
            return
        }
        let maximum = max(0, textView.bounds.height - visible.height)
        let y = min(max(0, target), maximum)
        scrollView.contentView.scroll(
            to: NSPoint(x: visible.origin.x, y: y)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        reviewRulerView.needsDisplay = true
    }

    /// The 1-based source line for a UTF-16 offset. The newline index is
    /// rebuilt once per document revision, not once per ruler draw.
    func lineNumber(at offset: Int) -> Int {
        let revision = document.revision
        let length = (textView.string as NSString).length
        let starts: [Int]
        if let cache = lineNumberCache,
           cache.revision == revision,
           cache.length == length {
            starts = cache.starts
        } else {
            var built: [Int] = [0]
            let ns = textView.string as NSString
            if ns.length > 0 {
                for index in 0..<ns.length
                where ns.character(at: index) == 0x0A {
                    built.append(index + 1)
                }
            }
            lineNumberCache = (revision, length, built)
            starts = built
        }
        var low = 0
        var high = starts.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= offset {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found + 1
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        document.undoManager
    }

    func textView(_ view: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !view.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Return is a refuse surface with more than one caret: list
            // continuation and table row insertion both edit one paragraph
            // around the primary, and the policy allows neither outcome.
            if let stop = gateNonBatch(.listReturn) {
                return stop
            }
            let selection = Range(view.selectedRange()) ?? 0..<0
            if let event = NSApp.currentEvent,
               event.modifierFlags.contains(.command) {
                guard MarkdownTableScanner.table(
                    at: selection.lowerBound,
                    in: view.string
                ) != nil else {
                    return false
                }
                let above = event.modifierFlags.contains(.shift)
                _ = perform(
                    above ? .insertTableRowAbove : .insertTableRowBelow
                )
                return true
            }
            return handleListReturn(in: view)
        }

        let selection = Range(view.selectedRange()) ?? 0..<0
        if let model = multiCursorSelection, model.count > 1 {
            switch commandSelector {
            case #selector(NSResponder.deleteBackward(_:)):
                return applyMultiCursor(.deleteBackward)
            case #selector(NSResponder.deleteForward(_:)):
                return applyMultiCursor(.deleteForward)
            case #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertBacktab(_:)):
                // A caret inside a table navigates cells; anywhere else Tab
                // indents. They are separate policy rows, so the table's own
                // entry is consulted when the caret is in a table.
                let operation: MultiCursorPolicy.Operation =
                    MarkdownTableScanner.table(
                        at: selection.lowerBound,
                        in: view.string
                    ) != nil
                    ? .tableCellTab
                    : .tabIndent
                if let stop = gateNonBatch(operation) {
                    return stop
                }
            default:
                break
            }
            if let motion = MultiCursorMotion(selector: commandSelector) {
                return applyMotion(motion)
            }
        }
        let plan: MarkdownEditPlan
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            plan = MarkdownTypingPolicy.tab(
                source: view.string,
                selection: selection,
                backwards: false
            )
        case #selector(NSResponder.insertBacktab(_:)):
            plan = MarkdownTypingPolicy.tab(
                source: view.string,
                selection: selection,
                backwards: true
            )
        case #selector(NSResponder.deleteBackward(_:)):
            plan = MarkdownTypingPolicy.backspace(
                source: view.string,
                selection: selection
            )
        case #selector(NSResponder.deleteForward(_:)):
            plan = MarkdownTypingPolicy.deleteForward(
                source: view.string,
                selection: selection
            )
        default:
            return false
        }
        return apply(plan, in: view)
    }

    /// Apply a pure typing plan in one edit/undo group. A refused plan makes
    /// no change and beeps; notApplicable lets AppKit handle the key.
    private func apply(_ plan: MarkdownEditPlan, in view: NSTextView) -> Bool {
        switch plan.outcome {
        case .notApplicable:
            return false
        case .refused:
            NSSound.beep()
            return true
        case .handled:
            if let range = plan.range {
                let nsRange = NSRange(
                    location: range.lowerBound,
                    length: range.upperBound - range.lowerBound
                )
                guard view.shouldChangeText(
                    in: nsRange,
                    replacementString: plan.replacement
                ) else {
                    return true
                }
                view.textStorage?.replaceCharacters(
                    in: nsRange,
                    with: plan.replacement
                )
            }
            if let selection = plan.selection {
                let length = (view.string as NSString).length
                let location = min(selection.lowerBound, length)
                let selected = min(
                    selection.upperBound - selection.lowerBound,
                    length - location
                )
                view.setSelectedRange(
                    NSRange(location: location, length: selected)
                )
            }
            // A selection-only plan is navigation, not an edit: it must not
            // post a text-change notification or touch undo.
            if plan.range != nil {
                view.didChangeText()
            }
            return true
        }
    }

    /// The auto-pair entry point for ordinary typing. Marked text and command
    /// chords never reach the policy; AppKit handles those insertions.
    private func handleTyping(
        _ inserted: String,
        replacementRange: NSRange
    ) -> Bool {
        // A commit can arrive with the marked text already cleared; the
        // tracker still owns it, and the batch must not insert at every
        // caret.
        guard !textView.hasMarkedText(), !composingForMultiCursor else {
            return false
        }
        if let model = multiCursorSelection, model.count > 1 {
            if replacementRange.location != NSNotFound {
                let primary = NSRange(
                    location: model.primaryRange.lowerBound,
                    length: model.primaryRange.count
                )
                guard replacementRange == primary else {
                    NSSound.beep()
                    return true
                }
            }
            return applyMultiCursor(.insert(inserted))
        }
        let selection: Range<Int>
        if replacementRange.location == NSNotFound {
            selection = Range(textView.selectedRange()) ?? 0..<0
        } else {
            selection = Range(replacementRange) ?? 0..<0
        }
        let plan = MarkdownTypingPolicy.typing(
            source: textView.string,
            selection: selection,
            inserted: inserted,
            chordModifierHeld: typingChordModifierHeld
        )
        return apply(plan, in: textView)
    }

    private var typingChordModifierHeld: Bool {
        // Only the event being dispatched can say whether a chord modifier
        // is held. `NSEvent.modifierFlags` reports the flags of the last
        // event at any time, so a programmatic insert (paste, IME commit, a
        // test) would inherit whatever modifiers the previous event used and
        // skip pairing unpredictably.
        guard let flags = NSApp.currentEvent?.modifierFlags else {
            return false
        }
        return !flags.intersection([.command, .control, .option]).isEmpty
    }

    // MARK: - Table grid

    /// Opens the inline table grid when the caret is inside a table.
    func presentTablePopover() {
        // The grid edits one cell at a time, and its Tab navigation is a
        // refuse surface under the policy; the popover never opens with more
        // than one caret.
        guard multiCursorSelection == nil else {
            NSSound.beep()
            return
        }
        guard !document.isReadOnly else {
            lastCommandError = DocumentError.readOnly
            return
        }
        guard let window = textView.window else { return }
        let selection = Range(textView.selectedRange()) ?? 0..<0
        guard let snapshot = beginTableEditing(at: selection.lowerBound)
        else {
            lastCommandError = NSError(
                domain: "Sonovo.TableGrid",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Place the caret in a table to edit it.",
                ]
            )
            return
        }
        let cell = snapshot.cell(row: 0, column: 0).map {
            $0.range.lowerBound..<$0.range.upperBound
        } ?? snapshot.blockRange
        let nsRange = NSRange(
            location: cell.lowerBound,
            length: cell.count
        )
        let screenRect = textView.firstRect(
            forCharacterRange: nsRange,
            actualRange: nil
        )
        var viewRect = textView.convert(
            window.convertFromScreen(screenRect),
            from: nil
        )
        if viewRect.isEmpty {
            viewRect = NSRect(
                x: viewRect.midX,
                y: viewRect.midY,
                width: AppTheme.MarkdownChrome.Popover.anchorSize,
                height: AppTheme.MarkdownChrome.Popover.anchorSize
            )
        }
        let controller = tablePopover ?? MarkdownTablePopoverController()
        tablePopover = controller
        controller.show(
            snapshot: snapshot,
            relativeTo: viewRect,
            of: textView,
            onSetCell: { [weak self] row, column, text in
                self?.commitTableCell(
                    row: row,
                    column: column,
                    text: text
                ) ?? .refused("The table editor closed.")
            },
            onCommand: { [weak self] command, row, column in
                self?.performTableCommand(
                    command,
                    row: row,
                    column: column
                ) ?? .refused("The table editor closed.")
            },
            onReload: { [weak self] in
                self?.reloadTableSnapshot()
                    ?? .refused("The table editor closed.")
            },
            onClose: { [weak self] in
                self?.tablePopover = nil
                self?.tableSnapshot = nil
            }
        )
    }

    /// Captures the table at `offset` for editing. Exposed so tests exercise
    /// exactly what the popover does without mounting a window.
    @discardableResult
    func beginTableEditing(at offset: Int) -> MarkdownTableSnapshot? {
        guard let snapshot = MarkdownTableGrid.snapshot(
            at: offset,
            in: textView.string
        ) else {
            tableSnapshot = nil
            return nil
        }
        tableSnapshot = snapshot
        tableSnapshotRevision = document.revision
        return snapshot
    }

    func commitTableCell(
        row: Int,
        column: Int,
        text: String
    ) -> MarkdownTableGridOutcome {
        guard let snapshot = tableSnapshot else {
            return .refused("Open the table editor first.")
        }
        guard prepareTableCommit() else {
            return .refused(
                "The document changed since this table editor opened. "
                    + "Reload it and try again."
            )
        }
        do {
            let edit = try MarkdownTableGrid.setContent(
                text,
                row: row,
                column: column,
                in: snapshot,
                source: textView.string
            )
            return applyTableGridEdit(edit)
        } catch {
            return .refused(Self.tableGridMessage(error))
        }
    }

    func performTableCommand(
        _ command: MarkdownTableCommand,
        row: Int,
        column: Int
    ) -> MarkdownTableGridOutcome {
        guard let snapshot = tableSnapshot else {
            return .refused("Open the table editor first.")
        }
        guard prepareTableCommit() else {
            return .refused(
                "The document changed since this table editor opened. "
                    + "Reload it and try again."
            )
        }
        do {
            let edit = try MarkdownTableGrid.perform(
                command,
                row: row,
                column: column,
                in: snapshot,
                source: textView.string
            )
            return applyTableGridEdit(edit)
        } catch {
            return .refused(Self.tableGridMessage(error))
        }
    }

    func reloadTableSnapshot() -> MarkdownTableGridOutcome {
        guard let snapshot = tableSnapshot else {
            return .refused("Open the table editor first.")
        }
        if let relocated = MarkdownTableGrid.relocate(
            snapshot,
            in: textView.string
        ) {
            tableSnapshot = relocated
            // The relocation was computed against the current revision;
            // leaving the old revision here made every later commit refuse
            // after an unrelated edit.
            tableSnapshotRevision = document.revision
            return .updated(relocated)
        }
        return .refused(
            "The table changed. Close the editor and open it again."
        )
    }

    private func applyTableGridEdit(
        _ edit: MarkdownTableGridEdit
    ) -> MarkdownTableGridOutcome {
        let result = MarkdownCommandResult(
            source: edit.source,
            selection: edit.selection,
            actionName: edit.actionName,
            previousSource: textView.string
        )
        guard apply(result) else {
            return .refused("The change could not be applied.")
        }
        guard let updated = MarkdownTableGrid.snapshot(
            at: edit.blockRange.lowerBound,
            in: textView.string
        ) else {
            return .refused("The table could not be read back.")
        }
        tableSnapshot = updated
        tableSnapshotRevision = document.revision
        lastCommandError = nil
        return .updated(updated)
    }

    /// A commit must belong to the exact document revision the grid saw.
    private func prepareTableCommit() -> Bool {
        guard document.revision == tableSnapshotRevision else {
            return false
        }
        if textView.string != document.source {
            syncFromDocument()
        }
        return true
    }

    private static func tableGridMessage(_ error: Error) -> String {
        switch error {
        case MarkdownTableGridError.staleTable:
            return "The table changed since this editor opened. "
                + "Reload it and try again."
        case MarkdownTableGridError.unknownCell:
            return "That cell is not authored in the source. "
                + "Add a column to give every row the cell."
        case let MarkdownTableGridError.refused(reason):
            switch reason {
            case .headerRow:
                return "The header row cannot be deleted."
            case .lastRow:
                return "The table must keep at least one body row."
            case .lastColumn:
                return "The table must keep at least one column."
            case .malformedTable:
                return "The table is malformed."
            }
        case MarkdownTableGridError.invalidTable:
            return "The table could not be read."
        case MarkdownTableGridError.notApplicable:
            return "That command does not apply here."
        case MarkdownTableGridError.noTable:
            return "Place the caret in a table to edit it."
        default:
            return String(describing: error)
        }
    }

    // MARK: - Link popover

    /// Opens the link popover over the link at the caret. With no link there,
    /// it falls back to inserting one.
    func presentLinkPopover() {
        // A link popover anchors to one range; the policy names the link
        // popover a collapse surface, so consult it rather than deciding here.
        if multiCursorSelection != nil {
            switch multiCursorPolicy(.linkPopover) {
            case .collapse:
                adoptSingleCursor()
            case .refuse:
                NSSound.beep()
                return
            case .primaryOnly, .batch:
                break
            }
        }
        guard !textView.hasMarkedText(),
              let output = lastOutput else {
            _ = perform(.insertLink(destination: ""))
            return
        }
        let selection = Range(textView.selectedRange()) ?? 0..<0
        guard let target = MarkdownLinkEditor.target(
            at: selection.lowerBound,
            in: output.ast,
            source: textView.string
        ) else {
            _ = perform(.insertLink(destination: ""))
            return
        }
        let nsRange = NSRange(
            location: target.range.lowerBound,
            length: target.range.upperBound - target.range.lowerBound
        )
        let expectedSlice = (textView.string as NSString)
            .substring(with: nsRange)
        let actionTarget = MarkdownActionTarget(
            documentID: document.id,
            identityGeneration: document.identityGeneration,
            sourceRevision: document.revision,
            range: target.range,
            expectedSlice: expectedSlice,
            rootGeneration: rootGenerationProvider()
        )
        guard let window = textView.window else { return }
        let screenRect = textView.firstRect(
            forCharacterRange: nsRange,
            actualRange: nil
        )
        var viewRect = textView.convert(
            window.convertFromScreen(screenRect),
            from: nil
        )
        if viewRect.isEmpty {
            viewRect = NSRect(
                x: viewRect.midX,
                y: viewRect.midY,
                width: AppTheme.MarkdownChrome.Popover.anchorSize,
                height: AppTheme.MarkdownChrome.Popover.anchorSize
            )
        }

        let controller = linkPopover ?? MarkdownLinkPopoverController()
        linkPopover = controller
        controller.show(
            target: target,
            headings: output.headings.headings,
            relativeTo: viewRect,
            of: textView,
            onCommit: { [weak self, weak controller] values in
                self?.commitLink(values, target: target, action: actionTarget)
                controller?.close()
            },
            onRemove: { [weak self, weak controller] in
                self?.removeLink(target: target, action: actionTarget)
                controller?.close()
            },
            onCopy: { destination in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    destination,
                    forType: .string
                )
            },
            onOpen: { [weak self] destination in
                self?.openLinkDestination(destination)
            },
            onOpenWiki: { [weak self, weak controller] link in
                controller?.close()
                self?.onOpenWikiLink?(link)
            },
            onOpenDefinition: { [weak self, weak controller] in
                guard let range = target.definitionRange else { return }
                self?.select(range: range)
                controller?.close()
            }
        )
    }

    /// Routes the source popover's Open action through the same decision
    /// model as the rendered viewer: external links confirm, local paths and
    /// `sonovo:` media links use the workspace routing, and a fragment
    /// reveals its heading in Source.
    func openLinkDestination(_ destination: String) {
        switch MarkdownLinkActivation.decide(destination) {
        case .confirmBeforeOpening(let url):
            ExternalLinkConfirmation.present(
                ExternalLinkConfirmation.request(for: url)
            )
        case .openDirectly(.local):
            onOpenLocalLink?(destination)
        case .openDirectly(.media):
            if let reference = MediaReference.parse(destination) {
                onOpenMediaLink?(reference)
            }
        case .openDirectly(.fragment):
            revealFragment(destination)
        case .openDirectly(.external), .openDirectly(.mailto):
            // `decide` maps both to `confirmBeforeOpening`; this arm keeps
            // the switch exhaustive without a second route.
            break
        case .refused:
            break
        }
    }

    private func revealFragment(_ destination: String) {
        let trimmed = destination.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.hasPrefix("#") else { return }
        let raw = String(trimmed.dropFirst())
        let fragment = raw.removingPercentEncoding ?? raw
        guard !fragment.isEmpty,
              let entry = lastOutput?.headings.heading(forFragment: fragment),
              let range = entry.range else {
            return
        }
        select(range: range.lowerBound..<range.upperBound)
    }

    private func commitLink(
        _ values: MarkdownLinkValues,
        target: MarkdownLinkTarget,
        action: MarkdownActionTarget
    ) {
        guard action.isCurrent(in: commandContext()) else {
            lastCommandError = MarkdownCommandError.staleTarget
            return
        }
        do {
            let result = try MarkdownLinkEditor.commit(
                values,
                to: target,
                source: textView.string,
                selection: Range(textView.selectedRange()) ?? 0..<0
            )
            _ = apply(result)
        } catch {
            lastCommandError = error
        }
    }

    private func removeLink(
        target: MarkdownLinkTarget,
        action: MarkdownActionTarget
    ) {
        guard action.isCurrent(in: commandContext()) else {
            lastCommandError = MarkdownCommandError.staleTarget
            return
        }
        let ns = textView.string as NSString
        let newSource = ns.replacingCharacters(
            in: NSRange(
                location: target.range.lowerBound,
                length: target.range.upperBound - target.range.lowerBound
            ),
            with: ""
        )
        let caret = min(
            target.range.lowerBound,
            (newSource as NSString).length
        )
        _ = apply(
            MarkdownCommandResult(
                source: newSource,
                selection: caret..<caret,
                actionName: "Remove Link",
                previousSource: textView.string
            )
        )
    }

    private func commandContext(
        target: MarkdownActionTarget? = nil
    ) -> MarkdownCommandContext {
        MarkdownCommandContext(
            source: textView.string,
            selection: Range(textView.selectedRange()) ?? 0..<0,
            isReadOnly: document.isReadOnly,
            hasMarkedText: textView.hasMarkedText(),
            mode: document.mode,
            documentID: document.id,
            identityGeneration: document.identityGeneration,
            sourceRevision: document.revision,
            rootGeneration: rootGenerationProvider(),
            target: target
        )
    }

    /// Commits the raw frontmatter text over exactly the range the panel
    /// opened on. A stale target refuses before any edit.
    func commitFrontmatter(range: Range<Int>, text: String) {
        let ns = textView.string as NSString
        guard range.lowerBound >= 0,
              range.upperBound <= ns.length else {
            lastCommandError = MarkdownCommandError.staleTarget
            return
        }
        let expectedSlice = ns.substring(
            with: NSRange(
                location: range.lowerBound,
                length: range.upperBound - range.lowerBound
            )
        )
        let target = MarkdownActionTarget(
            documentID: document.id,
            identityGeneration: document.identityGeneration,
            sourceRevision: document.revision,
            range: range,
            expectedSlice: expectedSlice,
            rootGeneration: rootGenerationProvider()
        )
        performCommand { [weak self] in
            guard let self else { return }
            do {
                let result = try self.registry.apply(
                    .replaceFrontmatter(range: range, text: text),
                    to: self.commandContext(target: target)
                )
                _ = self.apply(result)
                self.lastCommandError = nil
            } catch {
                self.lastCommandError = error
            }
        }
    }

    // MARK: - Commands and IME affinity

    // MARK: - Reading anchor

    /// The visible reading anchor: the line at the viewport's top edge, how
    /// many points of it are above that edge, and the selection.
    func readingAnchor() -> SourceReadingAnchor? {
        let ns = textView.string as NSString
        guard ns.length > 0 else { return nil }
        let visible = scrollView.contentView.bounds
        guard visible.height > 0 else { return nil }
        let point = NSPoint(
            x: textView.textContainerOrigin.x,
            y: visible.minY
        )
        let index = textView.characterIndexForInsertion(at: point)
        let clamped = min(max(index, 0), ns.length - 1)
        let lineRange = ns.lineRange(
            for: NSRange(location: clamped, length: 0)
        )
        guard let top = lineTop(offset: lineRange.location) else {
            return nil
        }
        return SourceReadingAnchor(
            lineOffset: lineRange.location,
            viewportOffset: Double(visible.minY - top),
            selection: Range(textView.selectedRange())
        )
    }

    /// Scrolls the source pane so the line containing `offset` sits at the
    /// top edge. Split scroll sync uses this; it changes no text, selection,
    /// or undo entry.
    func scrollToSourceOffset(_ offset: Int) {
        let ns = textView.string as NSString
        guard ns.length > 0 else { return }
        let clamped = min(max(offset, 0), ns.length - 1)
        // Lay out the line first; `lineTop` reads the fragment geometry.
        textView.scrollRangeToVisible(
            NSRange(location: clamped, length: min(1, ns.length - clamped))
        )
        guard let top = lineTop(offset: clamped) else { return }
        let visible = scrollView.contentView.bounds
        let maximum = max(0, textView.bounds.height - visible.height)
        let target = min(max(0, top), maximum)
        scrollView.contentView.scroll(
            to: NSPoint(x: visible.origin.x, y: target)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Restores an anchor once the view has a window and a viewport. A later
    /// explicit navigation (`select`, find-bar seeding) clears it, so a
    /// deferred mount restore can never overwrite where the user just went.
    func restoreReadingAnchorWhenMounted(_ anchor: SourceReadingAnchor) {
        pendingReadingAnchor = anchor
        schedulePendingReadingAnchor(attempt: 0)
    }

    private func schedulePendingReadingAnchor(attempt: Int) {
        guard pendingReadingAnchor != nil else { return }
        guard textView.window != nil,
              scrollView.contentView.bounds.height > 0 else {
            guard attempt < 6 else {
                pendingReadingAnchor = nil
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                self?.schedulePendingReadingAnchor(attempt: attempt + 1)
            }
            return
        }
        guard let anchor = pendingReadingAnchor else { return }
        pendingReadingAnchor = nil
        restoreReadingAnchor(anchor)
    }

    /// Reapplies a captured reading anchor after an external reload replaces
    /// the source. If the new text is already in the view, the anchor is
    /// restored now; otherwise the next `syncFromDocument` consumes it.
    func restoreReadingAnchorAfterSourceReplacement(
        _ anchor: SourceReadingAnchor
    ) {
        if textView.string == document.source {
            pendingSourceReplacementAnchor = nil
            restoreReadingAnchor(anchor)
        } else {
            pendingSourceReplacementAnchor = anchor
        }
    }

    /// Restores an anchor without changing the document or its undo history.
    /// `scrollRangeToVisible` forces TextKit to lay out the line; the viewport
    /// is then adjusted by the recorded offset and clamped to the document.
    func restoreReadingAnchor(_ anchor: SourceReadingAnchor) {
        guard let start = ReadingAnchorResolver.sourceLineStart(
            for: anchor,
            in: textView.string
        ) else {
            return
        }
        let ns = textView.string as NSString
        if let selection = anchor.selection {
            let location = min(max(selection.lowerBound, 0), ns.length)
            let upper = min(max(location, selection.upperBound), ns.length)
            textView.setSelectedRange(
                NSRange(location: location, length: upper - location)
            )
        }
        textView.scrollRangeToVisible(
            NSRange(location: start, length: min(1, ns.length - start))
        )
        // An anchor at or past the end of the document names the final empty
        // line, which has no fragment of its own: its position is simply the
        // document's bottom.
        let desired: CGFloat
        if start < ns.length, let top = lineTop(offset: start) {
            desired = max(0, top + CGFloat(anchor.viewportOffset))
        } else if start >= ns.length {
            desired = .greatestFiniteMagnitude
        } else {
            return
        }
        // TextKit refines the document height as the newly revealed viewport
        // is laid out, so a scroll clamped to the current bottom can finish
        // short of — or past — the settled end. Re-evaluate against the
        // settled height; two passes reach it and the third bounds a layout
        // that keeps reporting a new height.
        for _ in 0..<3 {
            let available = max(
                0,
                textView.bounds.height
                    - scrollView.contentView.bounds.height
            )
            let target = min(desired, available)
            scrollView.contentView.scroll(
                to: NSPoint(
                    x: scrollView.contentView.bounds.origin.x,
                    y: target
                )
            )
            textView.layoutSubtreeIfNeeded()
            let settledAvailable = max(
                0,
                textView.bounds.height
                    - scrollView.contentView.bounds.height
            )
            if min(desired, settledAvailable) == target {
                break
            }
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The view-space y of the line fragment that starts at `offset`.
    private func lineTop(offset: Int) -> CGFloat? {
        guard let layout = textView.textLayoutManager,
              let content = layout.textContentManager else {
            return nil
        }
        layout.textViewportLayoutController.layoutViewport()
        guard let location = content.location(
            content.documentRange.location,
            offsetBy: offset
        ), let fragment = layout.textLayoutFragment(for: location) else {
            return nil
        }
        return fragment.layoutFragmentFrame.minY
            + textView.textContainerOrigin.y
    }

    // MARK: - Find bar seeding

    /// Shows the source find bar seeded with `query`, with the occurrence at
    /// `offset` selected. The text finder reads the search string from the
    /// selection, so the view must be mounted before the actions run.
    func seedFindBar(with query: String, at offset: Int) {
        guard !query.isEmpty else { return }
        pendingReadingAnchor = nil
        pendingSourceReplacementAnchor = nil
        pendingFindSeed = (query, offset)
        schedulePendingFindSeed(attempt: 0)
    }

    private func schedulePendingFindSeed(attempt: Int) {
        guard let pending = pendingFindSeed else { return }
        guard textView.window != nil else {
            guard attempt < 6 else {
                pendingFindSeed = nil
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                self?.schedulePendingFindSeed(attempt: attempt + 1)
            }
            return
        }
        pendingFindSeed = nil
        applyFindSeed(pending)
    }

    private func applyFindSeed(_ pending: (query: String, offset: Int)) {
        let ns = textView.string as NSString
        guard pending.offset >= 0, pending.offset <= ns.length else {
            return
        }
        let length = min(
            (pending.query as NSString).length,
            ns.length - pending.offset
        )
        guard length > 0 else { return }
        // Seeding the find bar is primary-only navigation: it moves the
        // native selection to the match, keeps every caret, and moves the
        // model primary with it.
        suppressSelectionEcho = true
        textView.setSelectedRange(
            NSRange(location: pending.offset, length: length)
        )
        suppressSelectionEcho = false
        movePrimary(to: pending.offset..<(pending.offset + length))
        textView.window?.makeFirstResponder(textView)
        // The standard text-finder actions, not a second finder: the bar owns
        // its own state and the Find menu keeps working on it.
        let set = NSMenuItem()
        set.tag = NSTextFinder.Action.setSearchString.rawValue
        textView.performTextFinderAction(set)
        let show = NSMenuItem()
        show.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(show)
    }

    /// Select an exact UTF-16 range and reveal it. Used by Edit in Source;
    /// this changes no bytes and creates no undo entry.
    func select(range: Range<Int>) {
        pendingReadingAnchor = nil
        pendingSourceReplacementAnchor = nil
        let length = (textView.string as NSString).length
        guard range.lowerBound >= 0,
              range.upperBound <= length,
              range.lowerBound <= range.upperBound else {
            return
        }
        let nsRange = NSRange(
            location: range.lowerBound,
            length: range.upperBound - range.lowerBound
        )
        // Navigation is primary-only: it keeps the caret set, and its primary
        // follows the selection so the next edit lands where the user sees
        // the caret.
        suppressSelectionEcho = true
        textView.setSelectedRange(nsRange)
        suppressSelectionEcho = false
        movePrimary(to: range)
        textView.scrollRangeToVisible(nsRange)
        textView.window?.makeFirstResponder(textView)
    }

    /// Executes one registered command through the text view, so the edit
    /// participates in the document's undo stack.
    @discardableResult
    func perform(_ command: MarkdownCommandKind) -> Bool {
        // Every command that edits source is a refuse surface with more than
        // one caret; only the two placement commands are allowed, and they
        // edit no source at all. The choke point covers AppKit's edit routes;
        // this covers the explicit ones (menus, palette, key equivalents).
        if command != .addNextOccurrence,
           command != .selectAllOccurrences,
           gateNonBatch(command.policyOperation) == true {
            return false
        }
        var succeeded = false
        performCommand { [weak self] in
            guard let self else { return }
            do {
                let context = MarkdownCommandContext(
                    source: self.textView.string,
                    selection: Range(self.textView.selectedRange()) ?? 0..<0,
                    isReadOnly: self.document.isReadOnly,
                    hasMarkedText: self.textView.hasMarkedText(),
                    mode: self.document.mode,
                    carets: self.multiCursorSelection
                )
                let result = try self.registry.apply(command, to: context)
                succeeded = self.apply(result)
                self.lastCommandError = nil
            } catch {
                self.lastCommandError = error
            }
        }
        return succeeded
    }

    /// Sets the authored `open` default of the details block enclosing
    /// `offset`, through the same registry and undo stack as a source-mode
    /// command. The offset is explicit because a rendered-viewer menu action
    /// is not tied to the source selection.
    @discardableResult
    func setDetailsOpenDefault(open: Bool, at offset: Int) -> Bool {
        guard !document.isReadOnly else { return false }
        var succeeded = false
        performCommand { [weak self] in
            guard let self else { return }
            do {
                let context = MarkdownCommandContext(
                    source: self.textView.string,
                    selection: offset..<offset,
                    isReadOnly: self.document.isReadOnly,
                    hasMarkedText: self.textView.hasMarkedText()
                )
                let result = try self.registry.apply(
                    .setDetailsOpen(open),
                    to: context
                )
                succeeded = self.apply(result)
                self.lastCommandError = nil
            } catch {
                self.lastCommandError = error
            }
        }
        return succeeded
    }

    func title(for command: MarkdownCommandKind) -> String {
        registry.title(for: command)
    }

    func setSpellChecking(_ enabled: Bool) {
        textView.isContinuousSpellCheckingEnabled = enabled
    }

    /// Copies image data into the document's asset folder and inserts a
    /// relative link. Returns false and leaves the document untouched on any
    /// failure.
    @discardableResult
    func insertImageAsset(_ data: Data, fileExtension: String) -> Bool {
        guard !document.isReadOnly else {
            lastCommandError = DocumentError.readOnly
            return false
        }
        guard document.mode == .source else {
            // The insert command is unavailable in rendered mode; writing the
            // asset first would leave an orphan with no link.
            return false
        }
        guard !textView.hasMarkedText() else {
            // Do not write an asset for a command that cannot be applied yet.
            return false
        }
        guard let documentURL = document.fileURL else {
            lastCommandError = MarkdownAssetError.untitledDocument
            return false
        }
        do {
            let stored = try assetStore.storeWithStatus(
                imageData: data,
                fileExtension: fileExtension,
                relativeTo: documentURL,
                workspaceRoot: documentURL.deletingLastPathComponent()
            )
            let inserted = perform(
                .insertImage(destination: stored.path, alt: "image")
            )
            if !inserted, stored.created {
                // The link was not inserted; do not leave the new file
                // behind.
                let assetURL = documentURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(stored.path)
                try? FileManager.default.removeItem(at: assetURL)
            }
            return inserted
        } catch {
            lastCommandError = error
            return false
        }
    }

    private func apply(_ result: MarkdownCommandResult) -> Bool {
        // A command that changes nothing must not register an undo step; an
        // idempotent formatter run would otherwise fill the history with
        // no-ops. The caret still moves to the command's selection; a
        // placement command replaces the whole caret set instead.
        if result.source == textView.string {
            if let carets = result.carets {
                adoptMultiCursor(carets)
                return true
            }
            let nsSource = textView.string as NSString
            let location = min(result.selection.lowerBound, nsSource.length)
            let length = min(
                result.selection.upperBound - result.selection.lowerBound,
                nsSource.length - location
            )
            textView.setSelectedRange(
                NSRange(location: location, length: length)
            )
            return true
        }
        let old = textView.string as NSString
        let new = result.source as NSString
        let newRange = result.changedRange
        guard newRange.lowerBound >= 0,
              newRange.upperBound >= newRange.lowerBound,
              newRange.upperBound <= new.length else {
            return false
        }

        let suffixLength = new.length - newRange.upperBound
        let oldUpper = old.length - suffixLength
        guard oldUpper >= newRange.lowerBound,
              oldUpper <= old.length else {
            return false
        }

        let oldRange = NSRange(
            location: newRange.lowerBound,
            length: oldUpper - newRange.lowerBound
        )
        let replacement = new.substring(
            with: NSRange(
                location: newRange.lowerBound,
                length: newRange.upperBound - newRange.lowerBound
            )
        )
        guard textView.shouldChangeText(in: oldRange, replacementString: replacement) else {
            return false
        }

        textView.textStorage?.replaceCharacters(in: oldRange, with: replacement)
        let nsSource = textView.string as NSString
        let location = min(result.selection.lowerBound, nsSource.length)
        let length = min(
            result.selection.upperBound - result.selection.lowerBound,
            nsSource.length - location
        )
        textView.setSelectedRange(NSRange(location: location, length: length))
        // `didChangeText()` synchronously runs `textDidChange`, which records
        // the edit on the document. Carry the command's action name into
        // that record so undo names the formatting, not "Edit".
        actionNameOverride = result.actionName
        textView.didChangeText()
        actionNameOverride = nil
        return true
    }

    /// Runs a source command, or queues it until composition ends.
    func performCommand(_ action: @escaping @MainActor () -> Void) {
        if textView.hasMarkedText() {
            pendingCommands.append(
                QueuedCommand(
                    documentID: document.id,
                    revision: document.revision,
                    selection: document.selection ?? 0..<0,
                    action: action
                )
            )
            return
        }
        action()
    }

    /// Applies queued commands only when document, revision, and selection all
    /// still match.
    func flushPendingCommands() {
        guard !textView.hasMarkedText() else { return }
        let commands = pendingCommands
        pendingCommands.removeAll()

        for command in commands {
            guard command.documentID == document.id,
                  command.revision == document.revision,
                  command.selection == (document.selection ?? 0..<0) else {
                continue
            }
            command.action()
        }
    }

    var queuedCommandCount: Int { pendingCommands.count }

    // MARK: - Parsing and highlighting

    func scheduleParse(immediate: Bool = false) {
        parseTask?.cancel()

        // Above the editable threshold the document is presented as plain
        // source. Parsing it only to color ranges would build a second
        // document-sized AST, which is the cost the size policy exists to
        // avoid.
        guard !document.isLarge else {
            parseTask = nil
            pendingParseRevision = nil
            lastOutput = nil
            applyBaseAttributesOnly()
            return
        }

        let revision = document.revision
        let source = textView.string
        let delay = immediate ? 0 : parseDebounce
        pendingParseRevision = revision

        // The debounce is input scheduling, not parse ownership: after it
        // elapses the document-owned coordinator does the work and publishes
        // to every consumer.
        parseTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }
            guard !Task.isCancelled, let self else { return }
            if self.pendingParseRevision == revision {
                self.pendingParseRevision = nil
            }
            self.parseCoordinator.request(
                documentID: self.document.id,
                identityGeneration: self.document.identityGeneration,
                revision: revision,
                source: source
            )
        }
    }

    /// Applies a publication from the document-owned parse state.
    private func handleParseState(_ state: MarkdownParseState) {
        switch state {
        case .ready(let output):
            guard output.documentID == document.id else { return }
            lastOutput = output
            onParsePublished?(output.revision)
            document.setNestingLimit(false)
            applyHighlight(output, decorations: currentDecorations)
        case .refused(let reason, _):
            if reason == .nestingLimit {
                document.setNestingLimit(true)
            }
        case .idle, .parsing:
            break
        }
    }

    /// Applies semantic attributes without touching text or undo history.
    ///
    /// Syntax, lint, cell highlight, and focus dimming go through one
    /// compositor pass so no layer erases another.
    func applyHighlight(
        _ output: MarkdownParseOutput,
        decorations: MarkdownDecorationSet = .empty
    ) {
        // A delayed viewport task can outlive the document or revision it
        // captured. Applying it would paint stale ranges over edited text.
        guard output.documentID == document.id,
              output.revision == document.revision else {
            return
        }
        // Never touch attributes while an input method composition is in
        // flight; the marked text can change without a document revision.
        guard !textView.hasMarkedText() else { return }
        guard let storage = textView.textStorage else { return }

        let manager = document.undoManager
        let wasEnabled = manager.isUndoRegistrationEnabled
        if wasEnabled {
            manager.disableUndoRegistration()
        }
        defer {
            if wasEnabled {
                manager.enableUndoRegistration()
            }
        }

        lastOutput = output
        let affected = affectedRange()
        MarkdownDecorationCompositor.apply(
            syntax: { storage in
                MarkdownHighlighter(affectedRange: affected).apply(
                    ast: output.ast,
                    to: storage
                )
            },
            decorations: decorations,
            to: storage,
            affectedRange: affected,
            baseAttributes: baseAttributes
        )

        textView.typingAttributes = baseAttributes
        lastHighlightedRevision = output.revision
        onHighlightApplied?(output.revision)
    }

    // MARK: - List continuation

    private func handleListReturn(in view: NSTextView) -> Bool {
        let string = view.string as NSString
        let selection = view.selectedRange()
        guard selection.length == 0 else { return false }

        guard !FenceContext.isInsideFence(
            view.string,
            at: selection.location
        ) else {
            return false
        }

        let lineRange = string.lineRange(
            for: NSRange(location: selection.location, length: 0)
        )
        var line = string.substring(with: lineRange)
        if line.hasSuffix("\n") { line.removeLast() }
        if line.hasSuffix("\r") { line.removeLast() }

        // A thematic break (`- - -`, `* * *`) is not a list item.
        guard !isThematicBreak(line) else { return false }
        // Four or more leading spaces are indented code unless an enclosing
        // list item is deep enough to own the line.
        let indentation = leadingIndentWidth(line)
        if indentation >= 4,
           !hasEnclosingListItem(
               above: lineRange.location,
               in: string,
               indent: indentation
           ) {
            return false
        }

        guard let parsed = ListLine.parse(line) else { return false }

        let markerStart = lineRange.location
        let markerLength = parsed.markerLength

        // A list marker only continues a list when the caret is after it.
        guard selection.location >= markerStart + markerLength else {
            return false
        }

        if parsed.content.trimmingCharacters(in: .whitespaces).isEmpty {
            // Return on an empty item exits the list.
            let removeRange = NSRange(
                location: markerStart,
                length: min(markerLength, string.length - markerStart)
            )
            guard view.shouldChangeText(in: removeRange, replacementString: "") else {
                return true
            }
            view.textStorage?.replaceCharacters(in: removeRange, with: "")
            view.didChangeText()
            return true
        }

        let insertion = "\n" + parsed.continuationMarker
        guard view.shouldChangeText(in: selection, replacementString: insertion) else {
            return true
        }
        view.textStorage?.replaceCharacters(in: selection, with: insertion)
        view.setSelectedRange(
            NSRange(
                location: selection.location + (insertion as NSString).length,
                length: 0
            )
        )
        view.didChangeText()
        return true
    }

    /// The width of the leading whitespace, counting a tab as four columns.
    private func leadingIndentWidth(_ line: String) -> Int {
        columnWidth(String(line.prefix(while: { $0 == " " || $0 == "\t" })))
    }

    /// Whether `line` is a CommonMark thematic break (`- - -`, `* * *`,
    /// `___` and their longer forms).
    private func isThematicBreak(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first,
              first == "-" || first == "*" || first == "_" else {
            return false
        }
        var count = 0
        for character in trimmed {
            if character == first {
                count += 1
            } else if character != " " && character != "\t" {
                return false
            }
        }
        return count >= 3
    }

    /// Whether the nearest non-blank line above `location` is a list item
    /// whose content column is at most `indent`. Such a line can contain
    /// further-indented content; without it, the indented line is code.
    private func hasEnclosingListItem(
        above location: Int,
        in string: NSString,
        indent: Int
    ) -> Bool {
        var lineStart = location
        while lineStart > 0 {
            let previous = string.lineRange(
                for: NSRange(location: lineStart - 1, length: 0)
            )
            let previousEnd = min(NSMaxRange(previous), string.length)
            var text = string.substring(
                with: NSRange(
                    location: previous.location,
                    length: max(0, previousEnd - previous.location)
                )
            )
            if text.hasSuffix("\n") { text.removeLast() }
            if text.hasSuffix("\r") { text.removeLast() }
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let parsed = ListLine.parse(text) else { return false }
                // `markerLength` already includes the leading indent. Measure
                // the matched prefix once, counting a tab as four columns.
                let prefix = (text as NSString).substring(
                    with: NSRange(location: 0, length: parsed.markerLength)
                )
                let contentColumn = columnWidth(prefix)
                // Four columns past the item's content column is indented
                // code, even though it is indented enough for the item.
                return contentColumn <= indent && indent - contentColumn < 4
            }
            lineStart = previous.location
        }
        return false
    }
}

// MARK: - Text view

/// An NSTextView that accepts pasted and dropped images through the controller.
final class MarkdownTextView: NSTextView {
    var onPasteImage: ((Data, String) -> Bool)?
    /// Returns true when the controller consumed the whole-document select.
    var onSmartSelectAll: (() -> Bool)?
    var onSmartPaste: (() -> Bool)?
    /// Returns true when the controller handled the insertion as an auto-pair
    /// or a skip-over; AppKit then inserts nothing.
    var onInsertText: ((String, NSRange) -> Bool)?
    /// Returns true when the controller consumed a multi-caret paste, copy,
    /// or cut. Each returns false when the editor is in single-caret mode.
    var onMultiCursorPaste: (() -> Bool)?
    /// Paste as Plain Text: the same batch path, ignoring rich payloads.
    var onMultiCursorPlainPaste: (() -> Bool)?
    var onMultiCursorCopy: (() -> Bool)?
    var onMultiCursorCut: (() -> Bool)?
    /// Handles a Command-click at a view-space point. Returns true when the
    /// controller placed or refused a caret, so AppKit's own selection
    /// handling never runs behind the caret set.
    var onCommandClick: ((NSPoint) -> Bool)?
    /// Called for a click AppKit is about to handle as an ordinary selection
    /// gesture, before the native selection moves. A plain click always
    /// returns to one caret — including a click on the primary's existing
    /// position, where AppKit sends no selection-change notification and the
    /// change-driven collapse would never run.
    var onPlainClick: (() -> Void)?
    /// Reports the view gaining or losing first responder. The caret overlay
    /// hides when the view is not focused, and a focus change within one key
    /// window changes no selection, frame, or scroll position, so its own
    /// observers cannot see it.
    var onFocusChange: ((Bool) -> Void)?
    /// Reports an input-method marked-text update before AppKit mutates the
    /// storage: the selection before the update and the replacement range
    /// the input method named.
    var onMarkedText: ((NSRange, NSRange) -> Void)?
    /// Reports an insertion completed. A composition ends here when AppKit
    /// cleared its marked text without a text change; the replacement range
    /// is the one the input method named for the commit.
    var onCompositionEnd: ((NSRange) -> Void)?
    /// Returns true when the controller collapsed a smart selection.
    var onEscapeSelection: (() -> Bool)?
    /// Returns true when Escape collapsed the multi-caret set.
    var onMultiCursorEscape: (() -> Bool)?
    /// Depth of Find navigation this view is performing. A selection change
    /// inside it is primary-only: it preserves the caret set, where a pointer
    /// gesture collapses it. The change notification carries no cause, so the
    /// initiator has to bracket the call.
    private(set) var navigationDepth = 0
    private var dragHasImage = false

    /// Runs `body` as a navigation: a selection change inside it is
    /// primary-only even while this view is first responder. The Find
    /// overrides below bracket their calls; a test can drive the same path.
    func performNavigation<T>(_ body: () -> T) -> T {
        navigationDepth += 1
        defer { navigationDepth -= 1 }
        return body()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func performFindPanelAction(_ sender: Any?) {
        performNavigation { super.performFindPanelAction(sender) }
    }

    override func performTextFinderAction(_ sender: Any?) {
        performNavigation { super.performTextFinderAction(sender) }
    }

    override func selectAll(_ sender: Any?) {
        if onSmartSelectAll?() == true { return }
        super.selectAll(sender)
    }

    override func mouseDown(with event: NSEvent) {
        // Command-click places or toggles a caret before AppKit moves the
        // native selection; the controller decides whether the gesture
        // applies at all.
        if event.modifierFlags.contains(.command),
           let onCommandClick,
           onCommandClick(convert(event.locationInWindow, from: nil)) {
            return
        }
        // Any other click is the user taking over the selection: one caret
        // from here on, even when the click lands on the primary's own
        // position and AppKit reports no change.
        onPlainClick?()
        super.mouseDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if onMultiCursorEscape?() == true { return }
        if onEscapeSelection?() == true { return }
        super.cancelOperation(sender)
    }

    override func paste(_ sender: Any?) {
        if onMultiCursorPaste?() == true { return }
        if handleImage(from: NSPasteboard.general) { return }
        if onSmartPaste?() == true { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if onMultiCursorPlainPaste?() == true { return }
        super.pasteAsPlainText(sender)
    }

    override func copy(_ sender: Any?) {
        if onMultiCursorCopy?() == true { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        if onMultiCursorCut?() == true { return }
        super.cut(sender)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let text = string as? String,
           onInsertText?(text, replacementRange) == true {
            return
        }
        super.insertText(string, replacementRange: replacementRange)
        onCompositionEnd?(replacementRange)
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        onMarkedText?(self.selectedRange(), replacementRange)
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Insert at the drop point, not at the previous selection.
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        setSelectedRange(NSRange(location: index, length: 0))
        if handleImage(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Probe once per drag session, not on every movement update.
        dragHasImage = isImagePasteboard(sender.draggingPasteboard)
        if dragHasImage { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if dragHasImage { return .copy }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragHasImage = false
        super.draggingExited(sender)
    }

    func isImagePasteboard(_ pasteboard: NSPasteboard) -> Bool {
        // Type metadata only: `data(forType:)` copies the whole payload, and
        // drag tracking runs on every movement update.
        let types = pasteboard.types ?? []
        if types.contains(.png) || types.contains(.tiff) {
            return true
        }
        return fileURLs(from: pasteboard).contains { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else {
                return false
            }
            return type.conforms(to: .image)
        }
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
    }

    private func handleImage(from pasteboard: NSPasteboard) -> Bool {
        guard let handler = onPasteImage else { return false }

        // AppKit materializes a pasteboard payload before this code sees it;
        // there is no incremental pasteboard reader. The cap therefore
        // applies to what is processed and written, not to the copy the
        // pasteboard already owns.
        if let png = pasteboard.data(forType: .png) {
            guard png.count <= MediaLimits.maxImageBytes else { return false }
            return handler(png, "png")
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = BoundedImageLoader.pngData(from: tiff) {
            return handler(png, "png")
        }
        if let url = fileURLs(from: pasteboard).first(where: { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else {
                return false
            }
            return type.conforms(to: .image)
        }),
           let png = BoundedImageLoader.pngData(at: url) {
            // The bytes are PNG regardless of the source file's extension.
            return handler(png, "png")
        }
        return false
    }

    /// The viewport's rendered visual lines, in view coordinates. Shared by
    /// the line-number ruler and typewriter mode, so a coordinate fix cannot
    /// drift between them.
    func visibleCodeLines() -> [CodeLineLayout] {
        guard let layout = textLayoutManager,
              let content = layout.textContentManager else {
            return []
        }
        let inset = textContainerInset
        let visible = visibleRect
        layout.textViewportLayoutController.layoutViewport()
        let viewportStart = layout.textViewportLayoutController
            .viewportRange?.location
        var lines: [CodeLineLayout] = []
        layout.enumerateTextLayoutFragments(
            from: viewportStart,
            options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds
                let lineRect = NSRect(
                    x: frame.minX + inset.width + bounds.minX,
                    y: frame.minY + inset.height + bounds.minY,
                    width: bounds.width,
                    height: bounds.height
                )
                if lineRect.minY > visible.maxY {
                    return false
                }
                guard lineRect.maxY >= visible.minY else {
                    continue
                }
                let fragmentStart = content.offset(
                    from: content.documentRange.location,
                    to: fragment.rangeInElement.location
                )
                lines.append(
                    CodeLineLayout(
                        documentOffset: fragmentStart
                            + line.characterRange.location,
                        rect: lineRect,
                        text: line.attributedString.string
                    )
                )
            }
            return true
        }
        return lines
    }
}

// MARK: - Focus and typewriter

/// Focus-mode decorations: everything outside the block containing the caret
/// is dimmed. The compositor clips these ranges to the visible range and the
/// lint layer still wins on its own keys.
enum MarkdownFocus {
    static func decorations(
        sourceLength: Int,
        caret: Int,
        blocks: [Block],
        dim: NSColor
    ) -> [MarkdownDecoration] {
        guard sourceLength >= 0,
              caret >= 0,
              caret <= sourceLength,
              let block = blocks.first(where: { block in
                  guard let range = block.range else { return false }
                  return range.lowerBound <= caret
                      && caret <= range.upperBound
              }),
              let range = block.range else {
            return []
        }
        var decorations: [MarkdownDecoration] = []
        if range.lowerBound > 0 {
            decorations.append(
                MarkdownDecoration(
                    layer: .focus,
                    range: NSRange(
                        location: 0,
                        length: min(range.lowerBound, sourceLength)
                    ),
                    attributes: [.foregroundColor: dim]
                )
            )
        }
        if range.upperBound < sourceLength {
            decorations.append(
                MarkdownDecoration(
                    layer: .focus,
                    range: NSRange(
                        location: range.upperBound,
                        length: sourceLength - range.upperBound
                    ),
                    attributes: [.foregroundColor: dim]
                )
            )
        }
        return decorations
    }
}

/// Typewriter scroll arithmetic. Returning nil keeps the viewport still when
/// the caret is already near the target, so typing does not jitter.
enum MarkdownTypewriter {
    static func scrollTarget(
        viewportMinY: CGFloat,
        viewportHeight: CGFloat,
        caretLineTop: CGFloat,
        jitter: CGFloat = AppTheme.MarkdownChrome.Typewriter.jitter,
        centerFraction: CGFloat =
            AppTheme.MarkdownChrome.Typewriter.centerFraction
    ) -> CGFloat? {
        guard viewportHeight > 0 else { return nil }
        let target = viewportMinY + viewportHeight * centerFraction
        let delta = caretLineTop - target
        guard abs(delta) > jitter else { return nil }
        return viewportMinY + delta
    }
}

// MARK: - Formatting toolbar

/// The editor's formatting controls. Buttons call the same registry as the
/// menus and key equivalents; menus keep the infrequent commands out of the
/// way instead of stringing every heading and list onto the toolbar.
struct MarkdownFormattingToolbar: View {
    let controller: MarkdownEditorController

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            BarIconButton(systemName: "bold", help: "Bold") {
                controller.perform(.toggleStrong)
            }
            BarIconButton(systemName: "italic", help: "Italic") {
                controller.perform(.toggleEmphasis)
            }
            BarIconButton(systemName: "strikethrough", help: "Strikethrough") {
                controller.perform(.toggleStrikethrough)
            }
            BarIconButton(systemName: "curlybraces", help: "Inline Code") {
                controller.perform(.toggleInlineCode)
            }
            inlineExtrasMenu

            toolbarDivider

            headingMenu
            BarIconButton(systemName: "text.quote", help: "Block Quote") {
                controller.perform(.toggleBlockQuote)
            }
            listMenu

            toolbarDivider

            insertMenu
        }
    }

    private var inlineExtrasMenu: some View {
        Menu {
            Button("Highlight") {
                controller.perform(.toggleHighlight)
            }
            Button("Underline") {
                controller.perform(.toggleUnderline)
            }
            Button("Superscript") {
                controller.perform(.toggleSuperscript)
            }
            Button("Subscript") {
                controller.perform(.toggleSubscript)
            }
        } label: {
            toolbarIcon("textformat")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Highlight and Script")
        .accessibilityLabel("Highlight and Script")
    }

    private var headingMenu: some View {
        Menu {
            ForEach(1...6, id: \.self) { level in
                Button("Heading \(level)") {
                    controller.perform(.toggleHeading(level: level))
                }
            }
        } label: {
            toolbarIcon("textformat.size")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Heading")
        .accessibilityLabel("Heading")
    }

    private var listMenu: some View {
        Menu {
            Button("Bullet List") {
                controller.perform(.toggleList(kind: .bullet))
            }
            Button("Numbered List") {
                controller.perform(.toggleList(kind: .ordered))
            }
            Button("Task List") {
                controller.perform(.toggleList(kind: .task))
            }
        } label: {
            toolbarIcon("list.bullet")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("List")
        .accessibilityLabel("List")
    }

    private var insertMenu: some View {
        Menu {
            Button("Link") {
                controller.perform(.insertLink(destination: ""))
            }
            Button("Image") {
                controller.perform(.insertImage(destination: "", alt: "image"))
            }
            Button("Wiki Link") {
                controller.perform(.insertWikiLink(target: "", alias: nil))
            }
            Button("Details") {
                controller.perform(.insertDetails(summary: "Details"))
            }
            Button("Table of Contents") {
                controller.perform(.insertTOC)
            }
            Divider()
            Button("Table") {
                controller.perform(.insertTable(rows: 2, columns: 2))
            }
            Button("Edit Table…") {
                controller.presentTablePopover()
            }
            Divider()
            Button("Code Block") {
                controller.perform(.insertCodeFence)
            }
            Button("Horizontal Rule") {
                controller.perform(.insertRule)
            }
        } label: {
            toolbarIcon("text.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Insert")
        .accessibilityLabel("Insert")
    }

    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
            .frame(
                width: AppTheme.ControlSize.medium,
                height: AppTheme.ControlSize.regular
            )
            .contentShape(Rectangle())
    }

    private var toolbarDivider: some View {
        Divider()
            .frame(height: AppTheme.Size.toolbarDividerHeight)
    }
}

// MARK: - Fenced code context

/// Detects whether an offset sits inside a fenced code block.
///
/// The list-continuation path must not rewrite a line that merely looks like
/// a list item inside a fence. A live parse can be debounced, so this scans
/// the source directly.
private enum FenceContext {
    static func isInsideFence(_ source: String, at offset: Int) -> Bool {
        let ns = source as NSString
        guard offset > 0 else { return false }

        var lineStart = 0
        var fence: (character: Character, length: Int, containerIndent: Int)?
        let limit = min(offset, ns.length)

        while lineStart < limit {
            let lineRange = ns.lineRange(
                for: NSRange(location: lineStart, length: 0)
            )
            let lineEnd = min(NSMaxRange(lineRange), ns.length)
            var line = ns.substring(
                with: NSRange(location: lineStart, length: lineEnd - lineStart)
            )
            if line.hasSuffix("\n") { line.removeLast() }
            if line.hasSuffix("\r") { line.removeLast() }
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            // A fence marker may be indented at most three spaces; four
            // spaces makes it indented code content, not a delimiter.
            let indentation = line.prefix(while: { $0 == " " }).count
            let canBeFence = line.first != "\t" && indentation < 4

            if let active = fence {
                // A fenced block inside a container (a list item) ends when
                // the container does: a non-blank line indented less than
                // the fence's own container prefix closes it.
                let indentation = leadingWidth(line)
                if !trimmed.isEmpty, indentation < active.containerIndent {
                    fence = nil
                    if canBeFence, let opened = openingFence(line, trimmed) {
                        fence = opened
                    }
                } else if canBeFence, closesFence(
                    trimmed,
                    character: active.character,
                    minimumLength: active.length
                ) {
                    fence = nil
                }
            } else if canBeFence, let opened = openingFence(line, trimmed) {
                fence = opened
            }

            lineStart = lineEnd
        }

        return fence != nil
    }

    /// The width of the leading whitespace, counting a tab as four columns.
    private static func leadingWidth(_ line: String) -> Int {
        columnWidth(String(line.prefix(while: { $0 == " " || $0 == "\t" })))
    }

    /// Recognizes a fence that follows one or more list markers, such as
    /// `- ```swift`, which is still a fenced code block inside the item.
    ///
    /// `containerIndent` is the column where the fence's content begins; a
    /// later line indented less than that has left the containing block.
    private static func openingFence(
        _ line: String,
        _ trimmed: Substring
    ) -> (character: Character, length: Int, containerIndent: Int)? {
        var rest = trimmed
        var sawListContainer = false
        while true {
            if let first = rest.first,
               first == "-" || first == "+" || first == "*" {
                let after = rest.dropFirst()
                if after.first == " " || after.first == "\t" {
                    sawListContainer = true
                    rest = after.drop(while: { $0 == " " || $0 == "\t" })
                    continue
                }
            }

            var probe = rest.startIndex
            var digits = 0
            while probe < rest.endIndex, rest[probe].isNumber, digits < 10 {
                digits += 1
                probe = rest.index(after: probe)
            }
            if digits >= 1, digits <= 9, probe < rest.endIndex,
               rest[probe] == "." || rest[probe] == ")" {
                let after = rest.index(after: probe)
                if after == rest.endIndex
                    || rest[after] == " " || rest[after] == "\t" {
                    sawListContainer = true
                    rest = rest[after...].drop(while: {
                        $0 == " " || $0 == "\t"
                    })
                    continue
                }
            }
            break
        }

        guard let first = rest.first, first == "`" || first == "~" else {
            return nil
        }
        var length = 0
        for character in rest {
            guard character == first else { break }
            length += 1
        }
        guard length >= 3,
              !(first == "`" && rest.dropFirst(length).contains("`")) else {
            return nil
        }
        // Only a list container makes indentation a scope requirement. A
        // top-level fence may be indented up to three spaces without turning
        // that indentation into a container: unindented content lines are
        // still inside the fence.
        let containerIndent: Int
        if sawListContainer {
            containerIndent = columnWidth(
                String(line[line.startIndex..<rest.startIndex])
            )
        } else {
            containerIndent = 0
        }
        return (first, length, containerIndent)
    }

    private static func closesFence(
        _ trimmed: Substring,
        character: Character,
        minimumLength: Int
    ) -> Bool {
        var length = 0
        for candidate in trimmed {
            guard candidate == character else { break }
            length += 1
        }
        guard length >= minimumLength else { return false }
        return trimmed.dropFirst(length).allSatisfy { $0 == " " || $0 == "\t" }
    }
}

// MARK: - List line parsing

/// Display columns of a prefix: a tab advances to the next four-column tab
/// stop, every other character one column.
private func columnWidth(_ text: String) -> Int {
    var width = 0
    for character in text {
        if character == "\t" {
            width = (width / 4 + 1) * 4
        } else {
            width += 1
        }
    }
    return width
}

private struct ListLine {
    let indent: String
    let marker: String
    let number: Int?
    let delimiter: String
    let taskPrefix: String?
    let content: String
    let markerLength: Int

    var continuationMarker: String {
        var text = indent
        if let number {
            // The parser accepts at most nine digits; do not generate a
            // tenth and make the next Return stop recognizing the item.
            text += "\(min(number + 1, 999_999_999))\(delimiter) "
        } else {
            text += "\(marker) "
        }
        if let taskPrefix {
            text += taskPrefix.replacingOccurrences(of: "[x]", with: "[ ]")
                .replacingOccurrences(of: "[X]", with: "[ ]")
        }
        return text
    }

    static func parse(_ line: String) -> ListLine? {
        // CommonMark allows at most nine digits in an ordered marker. A
        // longer number is not a list marker, and parsing it as one overflowed
        // `number + 1` on Return.
        let pattern = #"^([ \t]*)([-*+]|[0-9]{1,9}[.)])([ \t]+|$)(\[[ xX]\](?:[ \t]+|$))?"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let ns = line as NSString
        guard let match = expression.firstMatch(
            in: line,
            range: NSRange(location: 0, length: ns.length)
        ) else {
            return nil
        }

        let indent = ns.substring(with: match.range(at: 1))
        let markerToken = ns.substring(with: match.range(at: 2))
        let task = match.range(at: 4).location != NSNotFound
            ? ns.substring(with: match.range(at: 4))
            : nil
        let markerLength = match.range.length
        let content = ns.substring(
            with: NSRange(
                location: markerLength,
                length: ns.length - markerLength
            )
        )

        let number: Int?
        let delimiter: String
        if let last = markerToken.last, last == "." || last == ")" {
            number = Int(markerToken.dropLast())
            delimiter = String(last)
        } else {
            number = nil
            delimiter = ""
        }

        return ListLine(
            indent: indent,
            marker: markerToken,
            number: number,
            delimiter: delimiter,
            taskPrefix: task,
            content: content,
            markerLength: markerLength
        )
    }
}

// MARK: - Highlighting

private struct MarkdownHighlighter {
    let affectedRange: NSRange

    private let textColor = NSColor(AppTheme.Palette.label)
    private let secondary = NSColor(AppTheme.Palette.secondaryLabel)
    private let tertiary = NSColor(AppTheme.Palette.tertiaryLabel)
    private let accent = NSColor(AppTheme.Palette.info)
    private let codeBackground = NSColor(AppTheme.Palette.card)
    private var baseSize: CGFloat { Preferences.editorFontSize }

    func apply(ast: SonovoAST, to storage: NSTextStorage) {
        walk(ast.blocks, storage: storage)
    }

    private func walk(_ blocks: [Block], storage: NSTextStorage) {
        for block in blocks {
            if let range = block.range {
                let nsRange = NSRange(
                    location: range.lowerBound,
                    length: range.length
                )
                if NSIntersectionRange(nsRange, affectedRange).length == 0 {
                    continue
                }
            }

            switch block {
            case let .heading(level, inlines, range):
                let font = headingFont(level)
                if let range {
                    add(.font, font, range, storage)
                    add(.foregroundColor, textColor, range, storage)
                    tintHeadingMarker(range, storage)
                }
                applyInlines(inlines, base: font, bold: true, italic: false, storage)
            case let .paragraph(inlines, _):
                applyInlines(
                    inlines,
                    base: bodyFont,
                    bold: false,
                    italic: false,
                    storage
                )
            case let .blockQuote(children, range):
                if let range {
                    tintBlockQuoteMarkers(range, storage)
                }
                walk(children, storage: storage)
            case let .list(list, _):
                for item in list.items {
                    if let range = item.range {
                        tintListMarker(range, storage)
                    }
                    walk(item.blocks, storage: storage)
                }
            case let .codeBlock(_, range):
                if let range {
                    add(
                        .font,
                        NSFont.monospacedSystemFont(
                            ofSize: Preferences.editorFontSize,
                            weight: .regular
                        ),
                        range,
                        storage
                    )
                    add(.backgroundColor, codeBackground, range, storage)
                }
            case let .table(table, _):
                for cell in table.header { applyInlines(cell.inlines, base: bodyFont, bold: false, italic: false, storage) }
                for row in table.rows {
                    for cell in row { applyInlines(cell.inlines, base: bodyFont, bold: false, italic: false, storage) }
                }
            case let .definitionList(list, _):
                for item in list.items {
                    for term in item.terms {
                        applyInlines(
                            term.inlines,
                            base: bodyFont,
                            bold: true,
                            italic: false,
                            storage
                        )
                    }
                    for definition in item.definitions {
                        applyInlines(
                            definition.inlines,
                            base: bodyFont,
                            bold: false,
                            italic: false,
                            storage
                        )
                    }
                }
            case let .details(details, _):
                applyInlines(details.summary, base: bodyFont, bold: false, italic: false, storage)
                walk(details.blocks, storage: storage)
            default:
                continue
            }
        }
    }

    private var bodyFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
    }

    /// Syntax markers recede so the content, not the punctuation, carries the
    /// page. Heading `#` runs and list bullets are structural, not prose.
    private func tintHeadingMarker(
        _ range: SourceRange,
        _ storage: NSTextStorage
    ) {
        let ns = storage.string as NSString
        let end = min(range.upperBound, ns.length)
        var index = range.lowerBound
        while index < end, isSpace(ns.character(at: index)) { index += 1 }
        var hashes = 0
        while index < end, ns.character(at: index) == 0x23 {
            hashes += 1
            index += 1
        }
        guard hashes > 0 else { return }
        while index < end, isSpace(ns.character(at: index)) { index += 1 }
        add(
            .foregroundColor,
            tertiary,
            nsRange: NSRange(
                location: range.lowerBound,
                length: index - range.lowerBound
            ),
            storage
        )
    }

    private func tintListMarker(
        _ range: SourceRange,
        _ storage: NSTextStorage
    ) {
        let ns = storage.string as NSString
        let end = min(range.upperBound, ns.length)
        var index = range.lowerBound
        while index < end, isSpace(ns.character(at: index)) { index += 1 }
        let start = index
        if index < end, "-+*".utf16.contains(ns.character(at: index)) {
            index += 1
        } else {
            while index < end,
                  ns.character(at: index) >= 0x30,
                  ns.character(at: index) <= 0x39 {
                index += 1
            }
            guard index > start, index < end else { return }
            let delimiter = ns.character(at: index)
            guard delimiter == 0x2E || delimiter == 0x29 else { return }
            index += 1
        }
        while index < end, isSpace(ns.character(at: index)) { index += 1 }
        add(
            .foregroundColor,
            tertiary,
            nsRange: NSRange(location: start, length: index - start),
            storage
        )
    }

    private func tintBlockQuoteMarkers(
        _ range: SourceRange,
        _ storage: NSTextStorage
    ) {
        let ns = storage.string as NSString
        let end = min(range.upperBound, ns.length)
        var lineStart = range.lowerBound
        while lineStart < end, lineStart < ns.length {
            let lineRange = ns.lineRange(
                for: NSRange(location: lineStart, length: 0)
            )
            let lineEnd = min(NSMaxRange(lineRange), end)
            var index = lineStart
            while index < lineEnd, isSpace(ns.character(at: index)) {
                index += 1
            }
            if index < lineEnd, ns.character(at: index) == 0x3E {
                var markerEnd = index + 1
                if markerEnd < lineEnd, isSpace(ns.character(at: markerEnd)) {
                    markerEnd += 1
                }
                add(
                    .foregroundColor,
                    tertiary,
                    nsRange: NSRange(
                        location: index,
                        length: markerEnd - index
                    ),
                    storage
                )
            }
            guard lineEnd > lineStart else { break }
            lineStart = lineEnd
        }
    }

    private func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    private func applyInlines(
        _ inlines: [Inline],
        base: NSFont,
        bold: Bool,
        italic: Bool,
        _ storage: NSTextStorage
    ) {
        for inline in inlines {
            switch inline {
            case let .text(_, range):
                if let range {
                    add(.font, font(base: base, bold: bold, italic: italic), range, storage)
                    add(.foregroundColor, textColor, range, storage)
                }
            case let .emphasis(children, range):
                if let range { add(.font, font(base: base, bold: bold, italic: true), range, storage) }
                applyInlines(children, base: base, bold: bold, italic: true, storage)
            case let .strong(children, range):
                if let range { add(.font, font(base: base, bold: true, italic: italic), range, storage) }
                applyInlines(children, base: base, bold: true, italic: italic, storage)
            case let .strikethrough(children, range):
                if let range {
                    add(.strikethroughStyle, NSUnderlineStyle.single.rawValue, range, storage)
                }
                applyInlines(children, base: base, bold: bold, italic: italic, storage)
            case let .inlineCode(_, range):
                if let range {
                    add(
                        .font,
                        NSFont.monospacedSystemFont(
                            ofSize: baseSize,
                            weight: .regular
                        ),
                        range,
                        storage
                    )
                    add(.backgroundColor, codeBackground, range, storage)
                }
            case let .link(_, _, children, range):
                // Color the children first; the link's accent then applies
                // over the whole label instead of being overwritten by the
                // child text color.
                applyInlines(children, base: base, bold: bold, italic: italic, storage)
                if let range {
                    add(.foregroundColor, accent, range, storage)
                    add(.underlineStyle, NSUnderlineStyle.single.rawValue, range, storage)
                }
            case let .image(_, _, _, range):
                if let range { add(.foregroundColor, secondary, range, storage) }
            case let .inlineHTML(_, range):
                if let range { add(.foregroundColor, tertiary, range, storage) }
            case let .wikiLink(_, range):
                if let range {
                    add(.foregroundColor, accent, range, storage)
                    add(.underlineStyle, NSUnderlineStyle.single.rawValue, range, storage)
                }
            case let .footnoteReference(_, range):
                if let range {
                    add(.foregroundColor, accent, range, storage)
                    add(.underlineStyle, NSUnderlineStyle.single.rawValue, range, storage)
                }
            case let .math(_, _, _, range):
                if let range { add(.foregroundColor, secondary, range, storage) }
            case .softBreak, .lineBreak:
                continue
            }
        }
    }

    private func headingFont(_ level: Int) -> NSFont {
        NSFont.monospacedSystemFont(
            ofSize: AppTheme.Reading.sourceHeadingSize(level),
            weight: level <= 2 ? .bold : .semibold
        )
    }

    private func font(base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        guard !traits.isEmpty else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: traits)
    }

    private func add(
        _ key: NSAttributedString.Key,
        _ value: Any,
        _ range: SourceRange,
        _ storage: NSTextStorage
    ) {
        let nsRange = NSRange(
            location: range.lowerBound,
            length: range.length
        )
        guard nsRange.location >= 0,
              nsRange.length > 0,
              nsRange.location + nsRange.length <= storage.length else {
            return
        }
        let intersection = NSIntersectionRange(nsRange, affectedRange)
        guard intersection.length > 0 else { return }
        storage.addAttribute(key, value: value, range: intersection)
    }

    /// Adds an attribute for a marker range that has no `SourceRange`
    /// position of its own (it is a slice of an already-mapped block).
    private func add(
        _ key: NSAttributedString.Key,
        _ value: Any,
        nsRange: NSRange,
        _ storage: NSTextStorage
    ) {
        guard nsRange.location >= 0,
              nsRange.length > 0,
              NSMaxRange(nsRange) <= storage.length else {
            return
        }
        let intersection = NSIntersectionRange(nsRange, affectedRange)
        guard intersection.length > 0 else { return }
        storage.addAttribute(key, value: value, range: intersection)
    }
}

// MARK: - SwiftUI wrapper

struct MarkdownSourceEditor: NSViewRepresentable {
    let document: MarkdownDocument
    var cache: MarkdownEditorCache?
    var parseCoordinator: MarkdownParseCoordinator?
    /// Applied once, after the view is attached and laid out.
    var readingAnchor: SourceReadingAnchor?
    /// A source offset the split view wants revealed after a rendered scroll.
    var scrollTargetOffset: Binding<Int?>?
    var onVisibleAnchorChange: ((SourceReadingAnchor) -> Void)?
    var onFocus: (() -> Void)?
    var onOpenLocalLink: ((String) -> Void)?
    var onOpenMediaLink: ((MediaReference) -> Void)?
    /// A wiki target is not a path; the workspace resolves it by name.
    var onOpenWikiLink: ((WikiLink) -> Void)?

    init(
        document: MarkdownDocument,
        cache: MarkdownEditorCache? = nil,
        parseCoordinator: MarkdownParseCoordinator? = nil,
        readingAnchor: SourceReadingAnchor? = nil,
        scrollTargetOffset: Binding<Int?>? = nil,
        onVisibleAnchorChange: ((SourceReadingAnchor) -> Void)? = nil,
        onFocus: (() -> Void)? = nil,
        onOpenLocalLink: ((String) -> Void)? = nil,
        onOpenMediaLink: ((MediaReference) -> Void)? = nil,
        onOpenWikiLink: ((WikiLink) -> Void)? = nil
    ) {
        self.document = document
        self.cache = cache
        self.parseCoordinator = parseCoordinator
        self.readingAnchor = readingAnchor
        self.scrollTargetOffset = scrollTargetOffset
        self.onVisibleAnchorChange = onVisibleAnchorChange
        self.onFocus = onFocus
        self.onOpenLocalLink = onOpenLocalLink
        self.onOpenMediaLink = onOpenMediaLink
        self.onOpenWikiLink = onOpenWikiLink
    }

    final class Coordinator {
        var lastScrollTarget: Int?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let entry = resolvedCache.entry(
            for: document,
            parseCoordinator: resolvedCoordinator
        )
        if entry.scrollView.superview != nil {
            entry.scrollView.removeFromSuperview()
        }
        entry.controller.attach()
        entry.controller.onVisibleAnchorChange = onVisibleAnchorChange
        entry.controller.onFocus = onFocus
        entry.controller.onOpenLocalLink = onOpenLocalLink
        entry.controller.onOpenMediaLink = onOpenMediaLink
        entry.controller.onOpenWikiLink = onOpenWikiLink
        if let anchor = readingAnchor {
            entry.controller.restoreReadingAnchorWhenMounted(anchor)
        }
        return entry.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let entry = resolvedCache.entry(
            for: document,
            parseCoordinator: resolvedCoordinator
        )
        // The representable is given a document identity at the call site,
        // so a different document should have produced a new scroll view.
        // Never sync a controller into a view it does not own.
        guard nsView === entry.scrollView else { return }
        entry.controller.syncFromDocument()
        entry.controller.onVisibleAnchorChange = onVisibleAnchorChange
        entry.controller.onFocus = onFocus
        entry.controller.onOpenLocalLink = onOpenLocalLink
        entry.controller.onOpenMediaLink = onOpenMediaLink
        entry.controller.onOpenWikiLink = onOpenWikiLink
        guard let binding = scrollTargetOffset else { return }
        guard let target = binding.wrappedValue else {
            context.coordinator.lastScrollTarget = nil
            return
        }
        guard target != context.coordinator.lastScrollTarget else { return }
        context.coordinator.lastScrollTarget = target
        entry.controller.scrollToSourceOffset(target)
        DispatchQueue.main.async {
            if binding.wrappedValue == target {
                binding.wrappedValue = nil
            }
        }
    }

    private var resolvedCache: MarkdownEditorCache {
        cache ?? .shared
    }

    private var resolvedCoordinator: MarkdownParseCoordinator {
        if let parseCoordinator { return parseCoordinator }
        return MarkdownSourceEditor.sharedCoordinator
    }

    private static let sharedCoordinator = MarkdownParseCoordinator(
        service: MarkdownParseService()
    )
}
