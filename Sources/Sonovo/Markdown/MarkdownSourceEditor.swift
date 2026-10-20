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

    private final class WeakController: @unchecked Sendable {
        weak var value: MarkdownEditorController?
    }

    private let weakSelf = WeakController()
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?
    private var visibleHighlightTask: Task<Void, Never>?

    private let parseService: MarkdownParseService
    private let parseDebounce: TimeInterval
    private let registry = MarkdownCommandRegistry()
    private let assetStore = MarkdownAssetStore()
    private(set) var lastCommandError: Error?

    private var parseTask: Task<Void, Never>?
    private var pendingParseRevision: UInt64?
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
        parseService: MarkdownParseService,
        parseDebounce: TimeInterval
    ) {
        self.document = document
        self.parseService = parseService
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
        textView.delegate = self
        textView.string = document.source
        applyBaseAttributesOnly()
        observeDocument()
    }

    /// Called when the view is attached to a window hierarchy.
    func attach() {
        installScrollObserver()
        syncFromDocument()
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
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
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
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
                box.value?.scheduleVisibleHighlight()
            }
        }
    }

    private func scheduleVisibleHighlight() {
        guard let output = lastOutput else { return }
        visibleHighlightTask?.cancel()
        visibleHighlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled, let self else { return }
            self.applyHighlight(output)
        }
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
            width: AppTheme.Editor.textInset,
            height: AppTheme.Editor.textInset
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
        paragraph.lineHeightMultiple = AppTheme.Editor.lineHeightMultiple
        paragraph.paragraphSpacing = AppTheme.Editor.paragraphSpacing
        return [
            .font: NSFont.systemFont(ofSize: AppTheme.TypeScale.md),
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
        scheduleParse(immediate: true)
    }

    /// Copies the document source into the view without recording an edit.
    private func resetTextToDocument() {
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

        if let range = NSRange(location: location, length: upper - location).toRange() {
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
            if document.source != baseline.source {
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
        if let range = textView.selectedRange().toRange() {
            document.selection = range
        }

        scheduleParse()
        flushPendingCommands()
    }

    /// Records the document state the current composition started from, once.
    private func recordCompositionBaselineIfNeeded() {
        guard compositionBaseline == nil else { return }
        compositionBaseline = CompositionBaseline(
            revision: document.revision,
            source: document.source
        )
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if let range = textView.selectedRange().toRange() {
            document.selection = range
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        document.undoManager
    }

    func textView(_ view: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        guard !view.hasMarkedText() else { return false }
        return handleListReturn(in: view)
    }

    // MARK: - Commands and IME affinity

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
                    selection: self.textView.selectedRange().toRange() ?? 0..<0,
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

        let documentID = document.id
        let revision = document.revision
        let source = textView.string
        let delay = immediate ? 0 : parseDebounce
        pendingParseRevision = revision

        parseTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }
            guard !Task.isCancelled, let self else { return }

            let output = await self.parseService.parse(
                MarkdownParseInput(
                    documentID: documentID,
                    revision: revision,
                    source: source
                )
            )
            guard !Task.isCancelled else { return }

            // The request is settled whether or not the service produced a
            // result. Clear the pending marker so a dropped request (backlog
            // pressure) can be retried by the next sync, but never clear a
            // newer request's marker.
            if self.pendingParseRevision == revision {
                self.pendingParseRevision = nil
            }
            guard let output, output.revision == self.document.revision else {
                return
            }

            self.lastOutput = output
            self.applyHighlight(output)
        }
    }

    /// Applies semantic attributes without touching text or undo history.
    func applyHighlight(_ output: MarkdownParseOutput) {
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

        let affected = affectedRange()
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: affected)
        MarkdownHighlighter(affectedRange: affected).apply(
            ast: output.ast,
            to: storage
        )
        storage.endEditing()

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
        var width = 0
        for character in line {
            if character == " " {
                width += 1
            } else if character == "\t" {
                width += 4
            } else {
                break
            }
        }
        return width
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
                let contentColumn = leadingIndentWidth(parsed.indent)
                    + parsed.markerLength
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
    private var dragHasImage = false

    override func paste(_ sender: Any?) {
        if handleImage(from: NSPasteboard.general) { return }
        super.paste(sender)
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
        if pasteboard.data(forType: .png) != nil
            || pasteboard.data(forType: .tiff) != nil {
            return true
        }
        // Drag tracking must not decode image data; type metadata is enough.
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

        if let png = pasteboard.data(forType: .png) {
            return handler(png, "png")
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let representation = NSBitmapImageRep(data: tiff),
           let png = representation.representation(using: .png, properties: [:]) {
            return handler(png, "png")
        }
        if let url = fileURLs(from: pasteboard).first(where: { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else {
                return false
            }
            return type.conforms(to: .image)
        }),
           let image = NSImage(contentsOf: url),
           let tiff = image.tiffRepresentation,
           let representation = NSBitmapImageRep(data: tiff),
           let png = representation.representation(using: .png, properties: [:]) {
            // The bytes are PNG regardless of the source file's extension.
            return handler(png, "png")
        }
        return false
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
        var width = 0
        for character in line {
            if character == " " {
                width += 1
            } else if character == "\t" {
                width += 4
            } else {
                break
            }
        }
        return width
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
        while true {
            if let first = rest.first,
               first == "-" || first == "+" || first == "*" {
                let after = rest.dropFirst()
                if after.first == " " || after.first == "\t" {
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
        // Include any list markers consumed above: for `- ``` the fence's
        // content column is 2, not 0.
        let containerIndent = line.distance(
            from: line.startIndex,
            to: trimmed.startIndex
        ) + trimmed.distance(from: trimmed.startIndex, to: rest.startIndex)
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
        let pattern = #"^([ \t]*)([-*+]|[0-9]{1,9}[.)])([ \t]+)(\[[ xX]\](?:[ \t]+|$))?"#
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
    private let accent = NSColor(AppTheme.Palette.generating)
    private let codeBackground = NSColor(AppTheme.Palette.card)
    private let baseSize = AppTheme.TypeScale.md

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
                }
                applyInlines(inlines, base: font, bold: true, italic: false, storage)
            case let .paragraph(inlines, _):
                applyInlines(
                    inlines,
                    base: NSFont.systemFont(ofSize: baseSize),
                    bold: false,
                    italic: false,
                    storage
                )
            case let .blockQuote(children, _):
                walk(children, storage: storage)
            case let .list(list, _):
                for item in list.items {
                    walk(item.blocks, storage: storage)
                }
            case let .codeBlock(_, range):
                if let range {
                    add(
                        .font,
                        NSFont.monospacedSystemFont(
                            ofSize: AppTheme.TypeScale.md,
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
            case let .details(details, _):
                applyInlines(details.summary, base: bodyFont, bold: false, italic: false, storage)
                walk(details.blocks, storage: storage)
            default:
                continue
            }
        }
    }

    private var bodyFont: NSFont {
        NSFont.systemFont(ofSize: baseSize)
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
            case .softBreak, .lineBreak:
                continue
            }
        }
    }

    private func headingFont(_ level: Int) -> NSFont {
        let size: CGFloat
        switch level {
        case 1: size = AppTheme.TypeScale.displaySmall
        case 2: size = AppTheme.TypeScale.titleLarge
        case 3: size = AppTheme.TypeScale.title
        case 4: size = AppTheme.TypeScale.xl
        case 5: size = AppTheme.TypeScale.lg
        default: size = AppTheme.TypeScale.md
        }
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    private func font(base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        if bold {
            let size = base.pointSize
            var font = NSFont.systemFont(ofSize: size, weight: .semibold)
            if italic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            return font
        }
        if italic {
            return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        }
        return base
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
}

// MARK: - SwiftUI wrapper

struct MarkdownSourceEditor: NSViewRepresentable {
    let document: MarkdownDocument
    var cache: MarkdownEditorCache?
    var parseService: MarkdownParseService?

    init(
        document: MarkdownDocument,
        cache: MarkdownEditorCache? = nil,
        parseService: MarkdownParseService? = nil
    ) {
        self.document = document
        self.cache = cache
        self.parseService = parseService
    }

    func makeNSView(context: Context) -> NSScrollView {
        let entry = resolvedCache.entry(
            for: document,
            parseService: resolvedParseService
        )
        if entry.scrollView.superview != nil {
            entry.scrollView.removeFromSuperview()
        }
        entry.controller.attach()
        return entry.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let entry = resolvedCache.entry(
            for: document,
            parseService: resolvedParseService
        )
        // The representable is given a document identity at the call site,
        // so a different document should have produced a new scroll view.
        // Never sync a controller into a view it does not own.
        guard nsView === entry.scrollView else { return }
        entry.controller.syncFromDocument()
    }

    private var resolvedCache: MarkdownEditorCache {
        cache ?? .shared
    }

    private var resolvedParseService: MarkdownParseService {
        if let parseService { return parseService }
        return MarkdownSourceEditor.sharedParseService
    }

    private static let sharedParseService = MarkdownParseService()
}
