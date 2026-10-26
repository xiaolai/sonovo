import AppKit
import Observation
import SonovoCore
import SwiftUI
import UniformTypeIdentifiers

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

    private final class WeakController: @unchecked Sendable {
        weak var value: MarkdownEditorController?
    }

    private let weakSelf = WeakController()
    private var scrollObserver: NSObjectProtocol?
    private var preferenceObserver: NSObjectProtocol?
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

        configure(textView)
        configureScrollView()
        textView.onPasteImage = { [weak self] data, fileExtension in
            self?.insertImageAsset(data, fileExtension: fileExtension) ?? false
        }
        textView.onSmartSelectAll = { [weak self] in
            self?.smartSelectAll() ?? false
        }
        textView.onEscapeSelection = { [weak self] in
            self?.collapseSmartSelection() ?? false
        }
        textView.onSmartPaste = { [weak self] in
            self?.smartPaste() ?? false
        }
        textView.onInsertText = { [weak self] text, range in
            self?.handleTyping(text, replacementRange: range) ?? false
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
    private var currentDecorations: MarkdownDecorationSet {
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
        return decorations
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
    /// undo entry is created.
    func smartSelectAll() -> Bool {
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
        guard textView.string != document.source else {
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
        suppressSync = true
        textView.string = document.source
        applyBaseAttributesOnly()
        suppressSync = false
    }

    private func restoreSelection(_ selected: NSRange) {
        let length = (textView.string as NSString).length
        let location = min(max(0, selected.location), length)
        let upper = min(length, location + max(0, selected.length))
        textView.setSelectedRange(NSRange(location: location, length: upper - location))

        if let range = Range(NSRange(location: location, length: upper - location)) {
            document.selection = range
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

        if textView.string != document.source {
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
        if let range = Range(textView.selectedRange()) {
            document.selection = range
        }

        clearLintDiagnostics()
        scheduleParse()
        flushPendingCommands()
        refreshReviewMarkers()
        keepCaretNearTypewriterLine()
    }

    /// Records the document state the current composition started from, once.
    private func recordCompositionBaselineIfNeeded() {
        guard compositionBaseline == nil else { return }
        compositionBaseline = CompositionBaseline(
            revision: document.revision,
            source: document.source
        )
    }

    func textDidBeginEditing(_ notification: Notification) {
        onFocus?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if let range = Range(textView.selectedRange()) {
            document.selection = range
        }
        scheduleVisibleHighlight()
        keepCaretNearTypewriterLine()
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
        guard !textView.hasMarkedText() else { return false }
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
        textView.setSelectedRange(
            NSRange(location: pending.offset, length: length)
        )
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
        textView.setSelectedRange(nsRange)
        textView.scrollRangeToVisible(nsRange)
        textView.window?.makeFirstResponder(textView)
    }

    /// Executes one registered command through the text view, so the edit
    /// participates in the document's undo stack.
    @discardableResult
    func perform(_ command: MarkdownCommandKind) -> Bool {
        var succeeded = false
        performCommand { [weak self] in
            guard let self else { return }
            do {
                let context = MarkdownCommandContext(
                    source: self.textView.string,
                    selection: Range(self.textView.selectedRange()) ?? 0..<0,
                    isReadOnly: self.document.isReadOnly,
                    hasMarkedText: self.textView.hasMarkedText(),
                    mode: self.document.mode
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
        // no-ops. The caret still moves to the command's selection.
        if result.source == textView.string {
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
    /// Returns true when the controller collapsed a smart selection.
    var onEscapeSelection: (() -> Bool)?
    private var dragHasImage = false

    override func selectAll(_ sender: Any?) {
        if onSmartSelectAll?() == true { return }
        super.selectAll(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if onEscapeSelection?() == true { return }
        super.cancelOperation(sender)
    }

    override func paste(_ sender: Any?) {
        if handleImage(from: NSPasteboard.general) { return }
        if onSmartPaste?() == true { return }
        super.paste(sender)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let text = string as? String,
           onInsertText?(text, replacementRange) == true {
            return
        }
        super.insertText(string, replacementRange: replacementRange)
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

    private func isImagePasteboard(_ pasteboard: NSPasteboard) -> Bool {
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
