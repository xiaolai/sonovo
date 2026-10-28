import AppKit
import Observation
import SonovoCore
import SwiftUI

/// The TextKit 2 subtitle source editor.
///
/// The document owns the source, revision, and undo stack. This controller is
/// a projection: edits flow into `SubtitleDocument.replaceSource`, and external
/// reloads are copied back without recording an edit.
@MainActor
final class SubtitleSourceEditorController: NSObject, NSTextViewDelegate {
    let document: SubtitleDocument
    let textView: NSTextView
    let scrollView: NSScrollView

    private final class WeakBox: @unchecked Sendable {
        weak var value: SubtitleSourceEditorController?
    }

    private let box = WeakBox()
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?
    nonisolated(unsafe) private var preferenceObserver: NSObjectProtocol?
    private var highlightTask: Task<Void, Never>?
    private var highlightGeneration: UInt64 = 0
    private var highlightImmediate = false
    private var suppressSync = false
    private var compositionBaseline: (revision: UInt64, source: String)?
    private var didAttach = false

    init(document: SubtitleDocument) {
        self.document = document
        self.textView = NSTextView(usingTextLayoutManager: true)
        self.scrollView = NSScrollView()
        super.init()
        box.value = self

        configureTextView()
        configureScrollView()
        textView.delegate = self
        textView.string = document.source
        applyBaseAttributesOnly()
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

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
        }
    }

    func attach() {
        guard !didAttach else {
            syncFromDocument()
            return
        }
        didAttach = true
        installScrollObserver()
        syncFromDocument()
    }

    // MARK: - Configuration

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
    }

    /// Applies a Settings change without reopening the document.
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
        applyBaseAttributesOnly()
        scheduleHighlight()
    }

    private func configureTextView() {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(
            width: AppTheme.Reading.sourceInsetHorizontal,
            height: AppTheme.Reading.sourceInsetVertical
        )
        textView.textContainer?.lineFragmentPadding = AppTheme.Editor.lineFragmentPadding
        textView.isEditable = !document.isReadOnly
        textView.typingAttributes = baseAttributes
        textView.setAccessibilityLabel("Subtitle source")
        textView.setAccessibilityRole(.textArea)
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = AppTheme.Reading.sourceLineHeightMultiple
        paragraph.paragraphSpacing = AppTheme.Reading.sourceParagraphSpacing
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
        let manager = document.undoManager
        let wasEnabled = manager.isUndoRegistrationEnabled
        if wasEnabled { manager.disableUndoRegistration() }
        defer { if wasEnabled { manager.enableUndoRegistration() } }

        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)
        storage.endEditing()
        textView.typingAttributes = baseAttributes
    }

    // MARK: - Document binding

    func syncFromDocument() {
        textView.isEditable = !document.isReadOnly
        guard !textView.hasMarkedText() else {
            recordCompositionBaseline()
            return
        }
        if textView.string != document.source {
            let selected = textView.selectedRange()
            resetTextToDocument()
            restoreSelection(selected)
        }
        scheduleHighlight(immediate: true)
    }

    private func resetTextToDocument() {
        suppressSync = true
        textView.string = document.source
        applyBaseAttributesOnly()
        suppressSync = false
    }

    /// Restores the selection without reposting it: this runs from the update
    /// path, and `setSelectedRange` posts a selection notification on every
    /// call, which re-enters a SwiftUI representable that observes it.
    private func restoreSelection(_ selected: NSRange) {
        let length = (textView.string as NSString).length
        let location = min(max(0, selected.location), length)
        let upper = min(length, location + max(0, selected.length))
        let range = NSRange(location: location, length: upper - location)
        if textView.selectedRange() != range {
            textView.setSelectedRange(range)
        }
    }

    private func observeDocument() {
        withObservationTracking {
            _ = document.revision
            _ = document.parsedRevision
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

        guard !document.isReadOnly else {
            resetTextToDocument()
            return
        }

        // Never mutate the document while an input method composition is in
        // flight; remember what it was composing over.
        if textView.hasMarkedText() {
            recordCompositionBaseline()
            return
        }
        if let baseline = compositionBaseline {
            compositionBaseline = nil
            if document.revision != baseline.revision
                || document.source != baseline.source {
                // An external reload changed the file mid-composition.
                resetTextToDocument()
                return
            }
        }

        if textView.string != document.source {
            do {
                try document.replaceSource(textView.string, actionName: "Edit")
            } catch {
                resetTextToDocument()
                return
            }
        }
        scheduleHighlight()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        document.undoManager
    }

    private func recordCompositionBaseline() {
        guard compositionBaseline == nil else { return }
        compositionBaseline = (
            revision: document.revision,
            source: document.source
        )
    }

    // MARK: - Highlighting

    private func installScrollObserver() {
        guard scrollObserver == nil else { return }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        let box = box
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { _ in
            Task { @MainActor in
                box.value?.scheduleHighlight()
            }
        }
    }

    /// Coalesces scroll-and-edit repaints. Replacing the task on every call
    /// meant a stream of bounds notifications faster than the 24 ms delay
    /// starved the highlight; one runner takes the newest generation.
    private func scheduleHighlight(immediate: Bool = false) {
        highlightGeneration &+= 1
        if immediate { highlightImmediate = true }
        guard highlightTask == nil else { return }
        highlightTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let generation = self.highlightGeneration
                let skipDelay = self.highlightImmediate
                self.highlightImmediate = false
                if !skipDelay {
                    try? await Task.sleep(for: .milliseconds(24))
                }
                guard !Task.isCancelled else { return }
                if generation != self.highlightGeneration { continue }
                self.applyHighlight()
                if generation == self.highlightGeneration { break }
            }
            self?.highlightTask = nil
        }
    }

    private func applyHighlight() {
        guard document.parsedRevision == document.revision,
              !textView.hasMarkedText(),
              let storage = textView.textStorage else {
            return
        }
        let affected = affectedRange()
        guard affected.length > 0 else { return }

        let manager = document.undoManager
        let wasEnabled = manager.isUndoRegistrationEnabled
        if wasEnabled { manager.disableUndoRegistration() }
        defer { if wasEnabled { manager.enableUndoRegistration() } }

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: affected)
        SubtitleHighlighter(
            format: document.format,
            parsed: document.parsed,
            affectedRange: affected,
            text: textView.string
        ).apply(to: storage)
        storage.endEditing()
        textView.typingAttributes = baseAttributes
    }

    /// The range highlighting may touch: the visible text plus a margin.
    private func affectedRange() -> NSRange {
        let length = (textView.string as NSString).length
        let full = NSRange(location: 0, length: length)
        guard length > 0 else { return full }

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
}

/// Paints cue structure quietly and leaves the words at full strength.
struct SubtitleHighlighter {
    let format: SubtitleFormat
    let parsed: SubtitleParseResult
    let affectedRange: NSRange
    let text: String

    func apply(to storage: NSTextStorage) {
        let ns = text as NSString
        let muted = NSColor(AppTheme.Palette.secondaryLabel)
        let tagColor = NSColor(AppTheme.Palette.info)
            .withAlphaComponent(AppTheme.Opacity.heavy)

        for cue in cues(intersecting: affectedRange) {
            if format.isASSFamily {
                let prefix = NSRange(
                    location: cue.blockRange.lowerBound,
                    length: max(
                        0,
                        cue.textRange.lowerBound - cue.blockRange.lowerBound
                    )
                )
                set(muted, on: prefix, storage: storage)
                for tag in assTags(in: cue.textRange, ns: ns) {
                    set(tagColor, on: tag, storage: storage)
                }
            } else {
                if let timing = cue.timingLineRange {
                    set(muted, on: nsRange(timing), storage: storage)
                }
                if let identifier = cue.identifier {
                    let length = (identifier as NSString).length
                    let range = NSRange(
                        location: cue.blockRange.lowerBound,
                        length: length
                    )
                    set(muted, on: range, storage: storage)
                }
            }
        }

        highlightMetadataLines(in: ns, storage: storage, muted: muted)
    }

    private func cues(intersecting range: NSRange) -> [SubtitleCue] {
        let lower = range.location
        let upper = NSMaxRange(range)
        var result: [SubtitleCue] = []
        for cue in parsed.cues {
            if cue.blockRange.upperBound <= lower { continue }
            if cue.blockRange.lowerBound >= upper { break }
            result.append(cue)
        }
        return result
    }

    private func assTags(
        in range: Range<Int>,
        ns: NSString
    ) -> [NSRange] {
        var tags: [NSRange] = []
        var index = range.lowerBound
        let openBrace: unichar = 0x7B
        let closeBrace: unichar = 0x7D
        while index < range.upperBound {
            if ns.character(at: index) == openBrace {
                var end = index + 1
                while end < range.upperBound,
                      ns.character(at: end) != closeBrace {
                    end += 1
                }
                if end < range.upperBound {
                    tags.append(NSRange(
                        location: index,
                        length: end - index + 1
                    ))
                }
                index = end + 1
            } else {
                index += 1
            }
        }
        return tags
    }

    private func highlightMetadataLines(
        in ns: NSString,
        storage: NSTextStorage,
        muted: NSColor
    ) {
        let affectedLines = ns.lineRange(for: affectedRange)
        let start = affectedLines.location
        // The visible window can begin inside a section. Reading the state
        // from the text before it keeps ASS dialogue from being muted when
        // the `[Events]` header has scrolled out of view.
        var section = format.isASSFamily
            ? assSection(before: start, ns: ns)
            : ""
        var inNoteBlock = format == .vtt
            ? vttNoteBlockState(before: start, ns: ns)
            : false
        var lineStart = start
        let limit = NSMaxRange(affectedLines)
        while lineStart < limit, lineStart < ns.length {
            let lineRange = ns.lineRange(
                for: NSRange(location: lineStart, length: 0)
            )
            let raw = ns.substring(with: lineRange)
            let trimmed = raw.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let upper = trimmed.uppercased()
            let blank = trimmed.isEmpty

            if format == .vtt {
                if inNoteBlock {
                    set(muted, on: lineRange, storage: storage)
                    if blank { inNoteBlock = false }
                } else if trimmed == "WEBVTT"
                    || trimmed.hasPrefix("WEBVTT ") {
                    set(muted, on: lineRange, storage: storage)
                } else if isVTTBlockKeyword(trimmed) {
                    set(muted, on: lineRange, storage: storage)
                    inNoteBlock = true
                }
            } else if format.isASSFamily {
                if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                    section = upper
                    set(muted, on: lineRange, storage: storage)
                } else if section != "[EVENTS]" {
                    if !blank {
                        set(muted, on: lineRange, storage: storage)
                    }
                } else if upper.hasPrefix("FORMAT:") {
                    set(muted, on: lineRange, storage: storage)
                }
            }
            lineStart = NSMaxRange(lineRange)
        }
    }

    /// The last ASS section header before `offset`, or "" when the range
    /// starts before any header.
    private func assSection(before offset: Int, ns: NSString) -> String {
        var probe = offset
        while probe > 0 {
            let lineRange = ns.lineRange(
                for: NSRange(location: probe - 1, length: 0)
            )
            let line = ns.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = line.uppercased()
            if upper.hasPrefix("["), upper.hasSuffix("]") {
                return upper
            }
            guard lineRange.location > 0 else { break }
            probe = lineRange.location
        }
        return ""
    }

    /// Whether `offset` falls inside a WebVTT NOTE/STYLE/REGION block. A
    /// blank line ends the block, so a blank line between the keyword and
    /// the window means the window is ordinary cue content.
    private func vttNoteBlockState(before offset: Int, ns: NSString) -> Bool {
        var probe = offset
        while probe > 0 {
            let lineRange = ns.lineRange(
                for: NSRange(location: probe - 1, length: 0)
            )
            let line = ns.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { return false }
            if isVTTBlockKeyword(line) { return true }
            guard lineRange.location > 0 else { break }
            probe = lineRange.location
        }
        return false
    }

    /// WebVTT block keywords are uppercase and need a following boundary.
    /// `Note this carefully` is cue text, not a NOTE block.
    private func isVTTBlockKeyword(_ text: String) -> Bool {
        for keyword in ["NOTE", "STYLE", "REGION"] {
            if text == keyword
                || text.hasPrefix(keyword + " ")
                || text.hasPrefix(keyword + "\t") {
                return true
            }
        }
        return false
    }

    private func set(
        _ color: NSColor,
        on range: NSRange,
        storage: NSTextStorage
    ) {
        let clipped = NSIntersectionRange(range, affectedRange)
        guard clipped.length > 0,
              clipped.location >= 0,
              NSMaxRange(clipped) <= storage.length else {
            return
        }
        storage.addAttribute(
            .foregroundColor,
            value: color,
            range: clipped
        )
    }

    private func nsRange(_ range: Range<Int>) -> NSRange {
        NSRange(location: range.lowerBound, length: range.count)
    }
}

struct SubtitleSourceEditor: NSViewRepresentable {
    let controller: SubtitleSourceEditorController

    func makeNSView(context: Context) -> NSScrollView {
        controller.attach()
        return controller.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        controller.attach()
    }
}
