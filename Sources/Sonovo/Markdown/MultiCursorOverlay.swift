import AppKit
import SonovoCore

/// Caret geometry for the source editor, in the text view's coordinates.
///
/// `enumerateTextSegments` is the source of truth. `firstRect` displaces
/// insertion points for right-aligned RTL fragments by the fragment origin,
/// and `NSTextLineFragment.locationForCharacter` returns the line origin for
/// the second character of a wrapped line on macOS 27; the MC-00 probe
/// measured both, so neither is used here.
@MainActor
enum CaretGeometry {
    static func rect(
        at offset: Int,
        upstream: Bool,
        in view: NSTextView
    ) -> NSRect? {
        guard let layout = view.textLayoutManager,
              let content = layout.textContentManager,
              let start = content.location(
                  content.documentRange.location,
                  offsetBy: offset
              ) else { return nil }
        // Lay out the caret's own character, not the whole document: one
        // offscreen secondary caret used to force full-document layout on the
        // main thread. The caller filters by viewport first, so the line the
        // caret names is normally laid out already; this covers the rest.
        if let end = content.location(start, offsetBy: 1),
           let line = NSTextRange(location: start, end: end) {
            layout.ensureLayout(for: line)
        }
        let range = NSTextRange(location: start)
        var options: NSTextLayoutManager.SegmentOptions = [.rangeNotRequired]
        if upstream { options.insert(.upstreamAffinity) }
        var found: CGRect?
        layout.enumerateTextSegments(
            in: range,
            type: .selection,
            options: options
        ) { _, rect, _, _ in
            found = rect
            return false
        }
        guard let found else { return nil }
        let inset = view.textContainerInset
        return NSRect(
            x: inset.width + found.minX,
            y: inset.height + found.minY,
            width: max(found.width, AppTheme.MultiCursor.caretWidth),
            height: found.height
        )
    }
}

/// Secondary selections as background decorations. The primary selection is
/// native, so it is never painted here.
enum MultiCursorDecoration {
    static func selections(
        for selection: MultiCursorSelection,
        color: NSColor
    ) -> [MarkdownDecoration] {
        selection.carets.enumerated().compactMap { index, caret in
            guard index != selection.primaryIndex,
                  !caret.range.isEmpty else { return nil }
            return MarkdownDecoration(
                layer: .selection,
                range: NSRange(
                    location: caret.range.lowerBound,
                    length: caret.range.count
                ),
                attributes: [.backgroundColor: color]
            )
        }
    }
}

/// Draws secondary carets above the text view. The primary caret stays
/// native. The view never hit-tests, so clicks and drags belong to the text
/// view underneath it.
@MainActor
final class CaretOverlayView: NSView {
    private weak var textView: NSTextView?
    private var secondary: [MultiCursorSelection.Caret] = []
    private var composing = false
    /// The text view's focus state as reported by its responder callbacks.
    /// A first-responder change within one key window moves no selection,
    /// frame, or scroll position, so the overlay's own observers cannot see
    /// it; the text view reports it instead. Falls back to the window's
    /// current responder until the first report arrives.
    private var focused: Bool?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: textView.bounds)
        autoresizingMask = [.width, .height]
        isHidden = true
        // The overlay is paint, not content: AX keeps exposing the text
        // view's one native selection (the primary), and no second element
        // may appear beside it.
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installObservers()
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    /// Shows every caret except the primary one. The overlay hides itself
    /// while a composition is in flight and while the editor is not the
    /// first responder.
    func show(
        _ carets: [MultiCursorSelection.Caret],
        primaryIndex: Int,
        composing: Bool
    ) {
        secondary = carets.enumerated().compactMap { index, caret in
            index == primaryIndex ? nil : caret
        }
        self.composing = composing
        refresh()
    }

    func clear() {
        secondary = []
        composing = false
        refresh()
    }

    /// Records the text view gaining or losing first responder and repaints
    /// visibility. The callback fires while AppKit is still completing the
    /// responder transfer, so the value is kept rather than re-derived from
    /// the window.
    func setFocused(_ isFocused: Bool) {
        focused = isFocused
        refresh()
    }

    /// Whether any secondary caret is still painted. A collapse must leave
    /// the overlay empty, not merely stop feeding it.
    var isEmpty: Bool { secondary.isEmpty }

    private func installObservers() {
        NotificationCenter.default.removeObserver(self)
        guard let textView else { return }
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(changed),
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        center.addObserver(
            self,
            selector: #selector(changed),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            center.addObserver(
                self,
                selector: #selector(changed),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
        }
        if let window = textView.window {
            center.addObserver(
                self,
                selector: #selector(changed),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(changed),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
        }
    }

    @objc private func changed() {
        refresh()
    }

    private func refresh() {
        guard let textView, !secondary.isEmpty else {
            isHidden = true
            return
        }
        let composingNow = composing || textView.hasMarkedText()
        let isFocused = focused
            ?? (textView.window?.firstResponder === textView)
        isHidden = composingNow || !isFocused
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, let textView, !secondary.isEmpty else { return }
        let layout = textView.textLayoutManager
        let content = layout?.textContentManager
        let viewport = layout?.textViewportLayoutController.viewportRange
        AppTheme.MultiCursor.caretColor.setFill()
        for caret in secondary {
            // Resolving geometry for a caret outside the laid-out viewport
            // forces layout of text nobody sees. The clip view posts bounds
            // changes, so a caret that scrolls into view repaints next frame.
            if let content, let viewport,
               let location = content.location(
                   content.documentRange.location,
                   offsetBy: caret.active
               ),
               !viewport.contains(location),
               location.compare(viewport.endLocation) != .orderedSame {
                continue
            }
            guard let rect = CaretGeometry.rect(
                at: caret.active,
                upstream: false,
                in: textView
            ), rect.intersects(dirtyRect) else { continue }
            NSBezierPath(rect: rect).fill()
        }
    }
}
