import AppKit
import Foundation
import Observation
import SonovoCore

/// Editor preferences the code surface reads. Stored in UserDefaults so a
/// setting applies to every open code document immediately.
struct CodeEditorSettings: Equatable, Sendable {
    private var storedTabWidth: Int

    /// Always inside `AppTheme.Code.tabWidthRange`. Clamping here rather than
    /// at each read keeps a value from UserDefaults or a direct caller from
    /// reaching the repeated-string allocation in indentation arithmetic.
    var tabWidth: Int {
        get { storedTabWidth }
        set { storedTabWidth = AppTheme.Code.clampedTabWidth(newValue) }
    }

    var usesTabs = false
    var wrapsLines = false

    static let tabWidthKey = "sonovo.codeTabWidth"
    static let usesTabsKey = "sonovo.codeUsesTabs"
    static let wrapLinesKey = "sonovo.codeWrapLines"

    init(
        tabWidth: Int = AppTheme.Code.tabWidthDefault,
        usesTabs: Bool = false,
        wrapsLines: Bool = false
    ) {
        storedTabWidth = AppTheme.Code.clampedTabWidth(tabWidth)
        self.usesTabs = usesTabs
        self.wrapsLines = wrapsLines
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let storedWidth = defaults.integer(forKey: tabWidthKey)
        return CodeEditorSettings(
            tabWidth: storedWidth > 0
                ? storedWidth
                : AppTheme.Code.tabWidthDefault,
            usesTabs: defaults.bool(forKey: usesTabsKey),
            wrapsLines: defaults.bool(forKey: wrapLinesKey)
        )
    }
}

/// One retained TextKit 2 surface per open code document.
///
/// The document owns the source and the undo stack. The controller projects
/// that state, schedules lexing off the main actor, and never applies a
/// snapshot from a superseded revision.
@MainActor
@Observable
final class CodeEditorController: NSObject, NSTextViewDelegate {
    let document: CodeDocument
    let textView: CodeTextView
    let scrollView: NSScrollView
    let rulerView: CodeLineNumberRulerView

    private(set) var cursorLine = 1
    private(set) var cursorColumn = 1
    private(set) var selectionLength = 0
    private(set) var symbolName: String?
    /// Diagnostic count of detached symbol scans. A cache hit must not bump
    /// it; cursor movement inside one revision reuses the completed scan.
    private(set) var symbolScanCount = 0
    private(set) var highlightSnapshot: CodeLexSnapshot?
    private(set) var lastCommandError: Error?

    private var settings: CodeEditorSettings
    private var highlightTask: Task<Void, Never>?
    private var visibleHighlightTask: Task<Void, Never>?
    private var pendingLine: Int?
    private var compositionBaseline: String?
    private var suppressSync = false
    private var scrollObserver: NSObjectProtocol?
    private var symbolTask: Task<Void, Never>?
    /// The language the current snapshot was lexed with. Save As can change
    /// the language without changing the revision or the text.
    var highlightLanguage: CodeLanguage? { highlightSnapshot?.language }

    private struct SymbolCache {
        let revision: UInt64
        let language: CodeLanguage
        let symbols: [CodeSymbol]
    }

    private var symbolCache: SymbolCache?
    private struct SymbolScan {
        let revision: UInt64
        let language: CodeLanguage
        let task: Task<[CodeSymbol], Never>
    }
    private var sharedSymbolScan: SymbolScan?

    private final class WeakController: @unchecked Sendable {
        weak var value: CodeEditorController?
    }

    init(document: CodeDocument, settings: CodeEditorSettings) {
        self.document = document
        self.settings = settings
        self.textView = CodeTextView(usingTextLayoutManager: true)
        self.scrollView = NSScrollView()
        self.rulerView = CodeLineNumberRulerView()
        super.init()
        configure(textView)
        configureScrollView()
        textView.delegate = self
        textView.string = document.source
        textView.editorUsesTabs = settings.usesTabs
        textView.editorTabWidth = settings.tabWidth
        rulerView.clientView = textView
        rulerView.scrollView = scrollView
        rulerView.lineNumberProvider = { [weak self] offset in
            self?.highlightSnapshot?.lineNumber(at: offset)
        }
        applyBaseAttributesOnly()
        observeDocument()
    }

    isolated deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    // MARK: - Configuration

    private func configure(_ view: NSTextView) {
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(
            width: AppTheme.Code.contentInsetHorizontal,
            height: AppTheme.Code.contentInsetVertical
        )
        view.textContainer?.lineFragmentPadding = AppTheme.Editor.lineFragmentPadding
        view.isEditable = document.isEditable
        view.typingAttributes = baseAttributes
        view.setAccessibilityLabel("Code editor")
        view.setAccessibilityRole(.textArea)
        view.setAccessibilityHelp(
            "Source text. Line numbers are in the gutter."
        )
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
        applyWrapping()
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.verticalRulerView = rulerView
        rulerView.ruleThickness = AppTheme.Code.lineNumberWidth
        rulerView.clientView = textView
    }

    private func applyWrapping() {
        let wraps = settings.wrapsLines
        textView.isHorizontallyResizable = !wraps
        textView.autoresizingMask = wraps ? [.width] : []
        textView.textContainer?.widthTracksTextView = wraps
        if wraps {
            textView.textContainer?.containerSize = NSSize(
                width: scrollView.contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
        } else {
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        scrollView.hasHorizontalScroller = !wraps
    }

    func updateSettings(_ settings: CodeEditorSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        textView.editorUsesTabs = settings.usesTabs
        textView.editorTabWidth = settings.tabWidth
        applyWrapping()
        applyBaseAttributesOnly()
        scheduleHighlight(editedLine: nil, immediate: true)
    }

    private var baseFont: NSFont {
        NSFont.monospacedSystemFont(
            ofSize: AppTheme.Code.fontSize,
            weight: .regular
        )
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = AppTheme.Code.lineHeightMultiple
        let spaceWidth = (" " as NSString).size(
            withAttributes: [.font: baseFont]
        ).width
        paragraph.defaultTabInterval = spaceWidth
            * CGFloat(max(1, settings.tabWidth))
        paragraph.tabStops = []
        return [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
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

    // MARK: - Lifecycle

    func attach() {
        installObservers()
        syncFromDocument()
        // The first attach copies the source in `init`, so the strings are
        // already equal and nothing else would start the first lex. Without
        // this, an existing document stays unhighlighted until it is edited.
        scheduleHighlight(editedLine: nil, immediate: true)
        textView.updateIndentGuideFont(baseFont)
        textView.needsDisplay = true
    }

    private func installObservers() {
        guard scrollObserver == nil else { return }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        let box = WeakController()
        box.value = self
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { _ in
            Task { @MainActor in
                box.value?.rulerView.needsDisplay = true
                box.value?.textView.needsDisplay = true
                box.value?.scheduleVisibleHighlight()
            }
        }
    }

    // MARK: - Document binding

    func syncFromDocument() {
        textView.isEditable = document.isEditable
        if textView.hasMarkedText() {
            // Capture the state the composition started from once; a
            // document update during composition must not replace it, or the
            // commit would overwrite that update.
            if compositionBaseline == nil {
                compositionBaseline = document.source
            }
            return
        }
        let selected = textView.selectedRange()
        if Self.differs(textView.string, document.source) {
            suppressSync = true
            textView.string = document.source
            applyBaseAttributesOnly()
            suppressSync = false
            scheduleHighlight(editedLine: nil, immediate: true)
        }
        if highlightLanguage != document.language {
            // Save As can change the language without changing the text.
            scheduleHighlight(editedLine: nil, immediate: true)
        }
        restoreSelection(selected)
        updateCursorState()
    }

    /// Byte equality, not `String` equality: two canonically equivalent
    /// strings can have different UTF-8 bytes, and the document's exact bytes
    /// are what get saved. `==` would treat them as the same text and skip
    /// the update.
    private static func differs(_ lhs: String, _ rhs: String) -> Bool {
        !lhs.utf8.elementsEqual(rhs.utf8)
    }

    /// Restores the selection without republishing it. This runs from
    /// `updateNSView`; `setSelectedRange` posts a selection notification on
    /// every call, SwiftUI observes it and re-enters the update, and the
    /// document never finishes opening — an endless transaction at full CPU.
    /// The document selection is observable too, so it is written only when
    /// it actually differs.
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
            _ = document.isEditable
            _ = document.language
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncFromDocument()
                self.observeDocument()
            }
        }
    }

    // MARK: - NSTextViewDelegate

    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        pendingLine = highlightSnapshot?.lineNumber(
            at: affectedCharRange.location
        ).advanced(by: -1)
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !suppressSync else { return }
        guard document.isEditable else {
            suppressSync = true
            textView.string = document.source
            applyBaseAttributesOnly()
            suppressSync = false
            lastCommandError = CodeDocumentError.readOnly
            return
        }
        if textView.hasMarkedText() {
            if compositionBaseline == nil {
                compositionBaseline = document.source
            }
            return
        }
        if let baseline = compositionBaseline {
            compositionBaseline = nil
            if Self.differs(document.source, baseline) {
                // The document moved while the composition was in flight.
                syncFromDocument()
                lastCommandError = CodeDocumentError.staleCompletion
                return
            }
        }
        if Self.differs(textView.string, document.source) {
            do {
                try document.replaceSource(textView.string)
            } catch {
                lastCommandError = error
                syncFromDocument()
                return
            }
        }
        if let swiftRange = Range(textView.selectedRange()),
           document.selection != swiftRange {
            document.selection = swiftRange
        }
        scheduleHighlight(editedLine: pendingLine)
        pendingLine = nil
        updateCursorState()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        selectionDidMove()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        document.undoManager
    }

    private func selectionDidMove() {
        if let swiftRange = Range(textView.selectedRange()),
           document.selection != swiftRange {
            document.selection = swiftRange
        }
        updateCursorState()
        refreshBracketHighlight()
    }

    private func updateCursorState() {
        let ns = textView.string as NSString
        let location = min(textView.selectedRange().location, ns.length)
        let line: Int
        if let snapshot = highlightSnapshot,
           snapshot.revision == document.revision {
            line = snapshot.lineNumber(at: location)
        } else {
            line = ns.substring(to: location)
                .components(separatedBy: "\n").count
        }
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        // The status bar reads these; republishing an unchanged value from the
        // update path would invalidate it for nothing.
        let newLine = max(1, line)
        let newColumn = max(1, location - lineRange.location + 1)
        let newSelectionLength = textView.selectedRange().length
        if cursorLine != newLine {
            cursorLine = newLine
        }
        if cursorColumn != newColumn {
            cursorColumn = newColumn
        }
        if selectionLength != newSelectionLength {
            selectionLength = newSelectionLength
        }
        refreshSymbol()
    }

    // MARK: - Highlighting

    /// Schedules a lexing pass. The previous snapshot is kept as the
    /// checkpoint base; a stale result is discarded by revision.
    func scheduleHighlight(editedLine: Int?, immediate: Bool = false) {
        highlightTask?.cancel()
        // A viewport-only repaint needs no relex.
        if editedLine == nil, let snapshot = highlightSnapshot,
           snapshot.revision == document.revision,
           highlightLanguage == document.language {
            applyHighlight(snapshot)
            return
        }

        let revision = document.revision
        let text = textView.string
        let language = document.language
        let previous = highlightSnapshot
        let line = editedLine
        highlightTask = Task { @MainActor [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { return }
            }
            let worker = Task.detached(priority: .userInitiated) {
                if let previous, let line {
                    return CodeSyntaxHighlighter.relex(
                        previous: previous,
                        text: text,
                        language: language,
                        revision: revision,
                        editedLine: line
                    )
                }
                return CodeSyntaxHighlighter.lex(
                    text: text,
                    language: language,
                    revision: revision
                )
            }
            let snapshot = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            guard self.document.revision == snapshot.revision,
                  self.document.language == snapshot.language else { return }
            self.highlightSnapshot = snapshot
            self.applyHighlight(snapshot)
            self.updateCursorState()
        }
    }

    private func scheduleVisibleHighlight() {
        guard let snapshot = highlightSnapshot,
              snapshot.revision == document.revision,
              snapshot.language == document.language else { return }
        visibleHighlightTask?.cancel()
        visibleHighlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self else { return }
            self.applyHighlight(snapshot)
        }
    }

    /// Applies token colors, the current-line tint, and bracket marks to the
    /// visible range. Attributes never touch text or undo history.
    func applyHighlight(_ snapshot: CodeLexSnapshot) {
        guard snapshot.revision == document.revision else { return }
        guard snapshot.language == document.language else { return }
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
        let highContrast = NSWorkspace.shared
            .accessibilityDisplayShouldIncreaseContrast
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: affected)
        for token in snapshot.tokens(intersecting: affected) {
            let role = Self.role(for: token.kind)
            storage.addAttribute(
                .foregroundColor,
                value: AppTheme.Syntax.resolvedColor(
                    for: role,
                    highContrast: highContrast
                ),
                range: token.range
            )
            if highContrast, AppTheme.Syntax.isBoldInHighContrast(role) {
                storage.addAttribute(
                    .font,
                    value: NSFontManager.shared.convert(
                        baseFont,
                        toHaveTrait: .boldFontMask
                    ),
                    range: token.range
                )
            }
        }

        if let lineRange = currentLineRange(in: snapshot) {
            storage.addAttribute(
                .backgroundColor,
                value: NSColor.labelColor.withAlphaComponent(
                    AppTheme.Code.currentLineOpacity
                ),
                range: NSIntersectionRange(lineRange, affected)
            )
        }

        for range in currentBracketRanges() {
            storage.addAttribute(
                .backgroundColor,
                value: NSColor.controlAccentColor.withAlphaComponent(
                    AppTheme.Code.bracketOpacity
                ),
                range: NSIntersectionRange(range, affected)
            )
        }
        storage.endEditing()

        textView.typingAttributes = baseAttributes
        rulerView.needsDisplay = true
    }

    nonisolated static func role(for kind: CodeTokenKind) -> AppTheme.SyntaxRole {
        switch kind {
        case .keyword: .keyword
        case .typeName: .typeName
        case .string: .string
        case .comment: .comment
        case .number: .number
        case .function: .function
        case .property: .property
        case .punctuation: .punctuation
        case .identifier: .identifier
        case .markup: .markup
        }
    }

    private func currentLineRange(in snapshot: CodeLexSnapshot) -> NSRange? {
        let location = textView.selectedRange().location
        let line = snapshot.lineNumber(at: location)
        return snapshot.range(ofLine: line)
    }

    /// The visible range plus a margin, using the TextKit 2 viewport. Before
    /// layout exists this is the whole document.
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
                let margin = AppTheme.Code.viewportMargin
                let lower = max(0, min(start, end) - margin)
                let upper = min(length, max(start, end) + margin)
                if upper > lower {
                    return NSRange(location: lower, length: upper - lower)
                }
            }
        }
        return full
    }

    // MARK: - Brackets

    private func refreshBracketHighlight() {
        if let snapshot = highlightSnapshot {
            applyHighlight(snapshot)
        }
    }

    /// Matches the bracket at or next to the caret. The scan is bounded so a
    /// pathological file cannot stall the main actor.
    private func currentBracketRanges() -> [NSRange] {
        let ns = textView.string as NSString
        guard ns.length > 0 else { return [] }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return [] }
        let location = min(selection.location, ns.length)
        var bracketIndex: Int?
        var bracket: unichar = 0
        for candidate in [location, location - 1] {
            guard candidate >= 0, candidate < ns.length else { continue }
            let unit = ns.character(at: candidate)
            if Self.openingBrackets.contains(unit)
                || Self.closingBrackets.contains(unit) {
                bracketIndex = candidate
                bracket = unit
                break
            }
        }
        guard let bracketIndex else { return [] }
        guard let match = findMatch(
            for: bracket,
            at: bracketIndex,
            in: ns
        ) else { return [] }
        return [
            NSRange(location: bracketIndex, length: 1),
            NSRange(location: match, length: 1)
        ]
    }

    private static let openingBrackets: Set<unichar> = [0x28, 0x5B, 0x7B]
    private static let closingBrackets: Set<unichar> = [0x29, 0x5D, 0x7D]

    private func findMatch(
        for bracket: unichar,
        at index: Int,
        in ns: NSString
    ) -> Int? {
        // The lexer is the authority on strings and comments. Only use it
        // when it describes the text on screen.
        let snapshot: CodeLexSnapshot? = {
            guard let snapshot = highlightSnapshot,
                  snapshot.revision == document.revision,
                  snapshot.language == document.language else {
                return nil
            }
            return snapshot
        }()
        func isLiteral(_ offset: Int) -> Bool {
            guard let kind = snapshot?.tokenKind(at: offset) else {
                return false
            }
            return kind == .string || kind == .comment
        }
        if isLiteral(index) { return nil }
        let isOpening = Self.openingBrackets.contains(bracket)
        let paired: unichar
        switch bracket {
        case 0x28: paired = 0x29
        case 0x29: paired = 0x28
        case 0x5B: paired = 0x5D
        case 0x5D: paired = 0x5B
        case 0x7B: paired = 0x7D
        case 0x7D: paired = 0x7B
        default: return nil
        }
        let limit = 200_000
        var depth = 0
        var cursor = index
        while cursor >= 0, cursor < ns.length {
            if isLiteral(cursor) {
                cursor += isOpening ? 1 : -1
                continue
            }
            let unit = ns.character(at: cursor)
            if unit == bracket {
                depth += 1
            } else if unit == paired {
                depth -= 1
                if depth == 0 {
                    return cursor
                }
            }
            if abs(cursor - index) > limit { return nil }
            cursor += isOpening ? 1 : -1
        }
        return nil
    }

    // MARK: - Navigation

    func goToLine(_ line: Int) {
        let ns = textView.string as NSString
        var currentLine = 1
        var location = 0
        while currentLine < line, location < ns.length {
            let range = ns.lineRange(
                for: NSRange(location: location, length: 0)
            )
            location = NSMaxRange(range)
            currentLine += 1
        }
        selectAndReveal(NSRange(location: min(location, ns.length), length: 0))
    }

    func goToOffset(_ offset: Int, length: Int = 0) {
        let ns = textView.string as NSString
        let location = min(max(0, offset), ns.length)
        let selected = min(max(0, length), ns.length - location)
        selectAndReveal(
            NSRange(location: location, length: selected)
        )
    }

    private func selectAndReveal(_ range: NSRange) {
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        if range.length > 0 {
            textView.showFindIndicator(for: range)
        }
        selectionDidMove()
    }

    /// Literal find, used by the find bar and by the M1 measurement. Case
    /// insensitive by default.
    func find(
        _ query: String,
        caseSensitive: Bool = false
    ) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = textView.string as NSString
        var results: [NSRange] = []
        var searchStart = 0
        let options: NSString.CompareOptions = caseSensitive
            ? []
            : [.caseInsensitive]
        while searchStart < ns.length {
            let found = ns.range(
                of: query,
                options: options,
                range: NSRange(
                    location: searchStart,
                    length: ns.length - searchStart
                )
            )
            guard found.location != NSNotFound else { break }
            results.append(found)
            searchStart = found.location + max(1, found.length)
            if results.count >= CodeLimits.searchResultLimit { break }
        }
        return results
    }

    func showFindBar() {
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        textView.performFindPanelAction(item)
    }

    // MARK: - Symbols

    /// The outline scan for the current revision, when the controller has
    /// already produced one. The symbol sheet reuses it instead of running a
    /// second full lex.
    func cachedSymbols() -> [CodeSymbol]? {
        guard let cache = symbolCache,
              cache.revision == document.revision,
              cache.language == document.language else {
            return nil
        }
        return cache.symbols
    }

    /// The outline for the current revision. The viewer's symbol sheet and
    /// the breadcrumb share one scan instead of running a full lex each.
    func symbolsForCurrentRevision() async -> [CodeSymbol]? {
        let language = document.language
        guard language.supportsOutline else { return nil }
        let revision = document.revision
        if let cache = symbolCache,
           cache.revision == revision,
           cache.language == language {
            return cache.symbols
        }
        let task: Task<[CodeSymbol], Never>
        if let shared = sharedSymbolScan,
           shared.revision == revision,
           shared.language == language {
            task = shared.task
        } else {
            let source = textView.string
            symbolScanCount += 1
            task = Task.detached(priority: .utility) {
                CodeSymbolIndex.symbols(in: source, language: language)
            }
            sharedSymbolScan = SymbolScan(
                revision: revision,
                language: language,
                task: task
            )
        }
        let symbols = await task.value
        if sharedSymbolScan?.revision == revision,
           sharedSymbolScan?.language == language {
            sharedSymbolScan = nil
        }
        guard document.revision == revision,
              document.language == language else {
            return nil
        }
        symbolCache = SymbolCache(
            revision: revision,
            language: language,
            symbols: symbols
        )
        return symbols
    }

    private func refreshSymbol() {
        symbolTask?.cancel()
        let language = document.language
        guard language.supportsOutline else {
            symbolCache = nil
            if symbolName != nil {
                symbolName = nil
            }
            return
        }
        let revision = document.revision
        let line = cursorLine
        // Cursor movement inside one revision reuses the scan; only the
        // lookup changes.
        if let cache = symbolCache,
           cache.revision == revision,
           cache.language == language {
            let name = CodeSymbolIndex.symbol(at: line, in: cache.symbols)?.name
            if symbolName != name {
                symbolName = name
            }
            return
        }
        symbolTask = Task { @MainActor [weak self] in
            // Wait for the cursor to settle; moving through a line should
            // not launch a symbol scan per keystroke.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            guard let symbols = await self.symbolsForCurrentRevision() else {
                return
            }
            guard !Task.isCancelled else { return }
            let name = CodeSymbolIndex.symbol(
                at: line,
                in: symbols
            )?.name
            if self.symbolName != name {
                self.symbolName = name
            }
        }
    }

    func dismissCommandError() {
        lastCommandError = nil
    }

    // MARK: - Accessibility

    var accessibilityStatus: String {
        var pieces = [
            "Line \(cursorLine), column \(cursorColumn)"
        ]
        if selectionLength > 0 {
            pieces.append("\(selectionLength) characters selected")
        }
        if let readOnly = document.readOnlyReason {
            pieces.append(readOnly.explanation)
        }
        pieces.append(encodingLabel)
        return pieces.joined(separator: ". ")
    }

    var encodingLabel: String {
        document.hasBOM ? "UTF-8 BOM" : "UTF-8"
    }

    var lineEndingLabel: String {
        document.lineEnding == .crlf ? "CRLF" : "LF"
    }

    var indentationLabel: String {
        settings.usesTabs
            ? "Tabs, width \(settings.tabWidth)"
            : "Spaces, width \(settings.tabWidth)"
    }
}

// MARK: - Text view

/// One visible line: its document offset, its rect in the text view, and its
/// rendered text. The gutter and the indent guides share this iterator so a
/// coordinate fix cannot drift between them.
struct CodeLineLayout {
    let documentOffset: Int
    let rect: NSRect
    let text: String
}

/// The code surface. Indent guides are drawn by the view; token colors and
/// the current-line tint are attributes applied by the controller.
final class CodeTextView: NSTextView {
    private var indentGuideFont = NSFont.monospacedSystemFont(
        ofSize: AppTheme.Code.fontSize,
        weight: .regular
    )
    var editorUsesTabs = false
    /// Always inside `AppTheme.Code.tabWidthRange`; the indent-guide and
    /// tab-insertion paths rely on a bounded width.
    var editorTabWidth: Int {
        get { storedTabWidth }
        set { storedTabWidth = AppTheme.Code.clampedTabWidth(newValue) }
    }
    private var storedTabWidth = AppTheme.Code.tabWidthDefault

    func updateIndentGuideFont(_ font: NSFont) {
        indentGuideFont = font
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawIndentGuides()
    }

    /// The viewport's rendered lines, bounded to the visible rect.
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

    private func drawIndentGuides() {
        let spaceWidth = (" " as NSString).size(
            withAttributes: [.font: indentGuideFont]
        ).width
        guard spaceWidth > 0 else { return }
        let tabWidth = AppTheme.Code.clampedTabWidth(editorTabWidth)
        let guideColor = NSColor.tertiaryLabelColor.withAlphaComponent(
            AppTheme.Opacity.border
        )

        for line in visibleCodeLines() {
            var columns = 0
            for character in line.text {
                if character == " " {
                    columns += 1
                } else if character == "\t" {
                    columns += tabWidth - (columns % tabWidth)
                } else {
                    break
                }
            }
            guard columns > 0 else { continue }
            guideColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = AppTheme.Code.indentGuideWidth
            var column = 1
            while column <= columns {
                let x = line.rect.minX + CGFloat(column) * spaceWidth
                path.move(to: NSPoint(x: x, y: line.rect.minY))
                path.line(to: NSPoint(x: x, y: line.rect.maxY))
                column += 1
            }
            path.stroke()
        }
    }

    /// Tab inserts the configured indentation instead of a literal tab in a
    /// spaces document. Selection replacement still goes through the normal
    /// edit path.
    override func insertTab(_ sender: Any?) {
        guard !editorUsesTabs else {
            insertText("\t", replacementRange: selectedRange())
            return
        }
        insertText(
            String(
                repeating: " ",
                count: AppTheme.Code.clampedTabWidth(editorTabWidth)
            ),
            replacementRange: selectedRange()
        )
    }

    override func insertBacktab(_ sender: Any?) {
        // Outdent one level of leading whitespace on the current line.
        let ns = string as NSString
        let selection = selectedRange()
        let lineRange = ns.lineRange(
            for: NSRange(location: selection.location, length: 0)
        )
        let width = AppTheme.Code.clampedTabWidth(editorTabWidth)
        var removable = 0
        var removedWidth = 0
        while lineRange.location + removable < ns.length,
              removedWidth < width {
            let unit = ns.character(at: lineRange.location + removable)
            if unit == 0x20 {
                removedWidth += 1
                removable += 1
            } else if unit == 0x09 {
                removedWidth += width - (removedWidth % width)
                removable += 1
            } else {
                break
            }
        }
        guard removable > 0,
              shouldChangeText(
                  in: NSRange(location: lineRange.location, length: removable),
                  replacementString: ""
              ) else {
            return
        }
        textStorage?.replaceCharacters(
            in: NSRange(location: lineRange.location, length: removable),
            with: ""
        )
        didChangeText()
    }
}

// MARK: - Line number ruler

/// The gutter. It draws only the visible line fragments, so a 50k-line file
/// costs the viewport, not the file.
final class CodeLineNumberRulerView: NSRulerView {
    var lineNumberProvider: ((Int) -> Int?)?
    private var numberAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(
                ofSize: AppTheme.Code.lineNumberFontSize,
                weight: .regular
            ),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
    }

    init() {
        super.init(scrollView: nil, orientation: .verticalRuler)
        ruleThickness = AppTheme.Code.lineNumberWidth
        setAccessibilityRole(.ruler)
        setAccessibilityLabel("Line numbers")
        setAccessibilityHelp("Shows the line number for each visible line.")
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? CodeTextView else {
            return
        }

        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: bounds.maxX, y: bounds.minY))
        divider.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY))
        divider.lineWidth = AppTheme.BorderWidth.hairline
        divider.stroke()

        var lastNumber: Int?
        for line in textView.visibleCodeLines() {
            let number = lineNumberProvider?(line.documentOffset) ?? 1
            // A wrapped logical line has several visual fragments; the
            // gutter numbers the logical line once.
            guard number != lastNumber else {
                continue
            }
            lastNumber = number
            let text = "\(number)" as NSString
            let size = text.size(withAttributes: numberAttributes)
            let origin = convert(line.rect.origin, from: textView)
            let y = origin.y + (line.rect.height - size.height) / 2
            let x = ruleThickness - AppTheme.Code.lineNumberInset
                - size.width
            text.draw(
                at: NSPoint(x: max(0, x), y: y),
                withAttributes: numberAttributes
            )
        }
    }
}
