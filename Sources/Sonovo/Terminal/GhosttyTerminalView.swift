// A minimal libghostty surface host for Sonovo.
// The surface lifecycle, Metal layer, event plumbing, and IME shape are
// adapted from Calyx (MIT), Copyright (c) 2025 Yuuichi Eguchi.
// Ghostty itself is MIT; see THIRD_PARTY_NOTICES.md.

@preconcurrency import AppKit
import GhosttyKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.sonovo.Sonovo", category: "Terminal")

@MainActor
final class GhosttyTerminalView: NSView, @preconcurrency NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    private(set) var title = ""
    private(set) var workingDirectory: String?

    var onCloseRequested: (() -> Void)?
    var onNewTabRequested: (() -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onWorkingDirectoryChanged: ((String) -> Void)?

    private var didInitialize = false
    private var wantsInitialization = false
    private var needsInitialRefresh = true
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var cellSize = NSSize.zero

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let metalLayer = GhosttyMetalLayer()
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer = metalLayer
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        if let surface {
            GhosttyFFI.surfaceFree(surface)
        }
    }

    // MARK: - Surface lifecycle

    func initializeIfNeeded() {
        guard !didInitialize, window != nil else {
            wantsInitialization = true
            return
        }
        guard frame.width > 0, frame.height > 0 else {
            wantsInitialization = true
            return
        }
        guard let app = GhosttyAppController.shared.app else {
            logger.error("Ghostty app is not ready")
            return
        }

        didInitialize = true
        wantsInitialization = false

        GhosttyAppController.shared.applyTheme(isDark: isDarkAppearance)

        var config = GhosttyFFI.surfaceConfigNew()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos = ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        )
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? 2)
        config.font_size = 13
        config.context = GHOSTTY_SURFACE_CONTEXT_TAB

        guard let newSurface = GhosttyFFI.surfaceNew(app, config: &config) else {
            logger.error("ghostty_surface_new failed")
            didInitialize = false
            return
        }

        surface = newSurface
        GhosttyAppController.shared.register(self)
        GhosttyFFI.surfaceSetContentScale(newSurface, xScale: config.scale_factor, yScale: config.scale_factor)
        updateSurfaceSize()
        setColorSchemeForAppearance()
        GhosttyFFI.surfaceSetFocus(newSurface, focused: window?.firstResponder === self)
        GhosttyFFI.surfaceRefresh(newSurface)
    }

    func shutdown() {
        onCloseRequested = nil
        if let surface {
            GhosttyFFI.surfaceFree(surface)
        }
        surface = nil
        didInitialize = false
        removeFromSuperview()
    }

    func restart() {
        if let surface {
            GhosttyFFI.surfaceFree(surface)
        }
        surface = nil
        didInitialize = false
        needsInitialRefresh = true
        wantsInitialization = true
        initializeIfNeeded()
    }

    func focus() {
        window?.makeFirstResponder(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()

        if wantsInitialization {
            initializeIfNeeded()
        }
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()

        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let backing = convertToBacking(frame)
        GhosttyFFI.surfaceSetContentScale(
            surface,
            xScale: backing.width / frame.width,
            yScale: backing.height / frame.height
        )
        updateSurfaceSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        if wantsInitialization, newSize.width > 0, newSize.height > 0 {
            initializeIfNeeded()
        }
        updateSurfaceSize()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        GhosttyAppController.shared.applyTheme(isDark: isDarkAppearance)
        setColorSchemeForAppearance()
    }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func updateSurfaceSize() {
        guard let surface, frame.width > 0, frame.height > 0 else { return }

        let backing = convertToBacking(frame).size
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.drawableSize = backing
        }
        GhosttyFFI.surfaceSetSize(
            surface,
            width: UInt32(backing.width),
            height: UInt32(backing.height)
        )

        if needsInitialRefresh {
            needsInitialRefresh = false
            GhosttyFFI.surfaceRefresh(surface)
        }
    }

    private func setColorSchemeForAppearance() {
        guard let surface else { return }
        GhosttyFFI.surfaceSetColorScheme(
            surface,
            scheme: isDarkAppearance ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        )
    }

    // MARK: - Ghostty actions

    func updateTitle(_ title: String) {
        self.title = title
        onTitleChanged?(title)
    }

    func updateWorkingDirectory(_ path: String) {
        workingDirectory = path
        onWorkingDirectoryChanged?(path)
    }

    func updateCellSize(width: UInt32, height: UInt32) {
        cellSize = NSSize(width: CGFloat(width), height: CGFloat(height))
    }

    func updateCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            NSCursor.iBeam.set()
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            NSCursor.pointingHand.set()
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            NSCursor.crosshair.set()
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
            NSCursor.operationNotAllowed.set()
        case GHOSTTY_MOUSE_SHAPE_GRAB:
            NSCursor.openHand.set()
        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            NSCursor.closedHand.set()
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE:
            NSCursor.resizeLeftRight.set()
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE:
            NSCursor.resizeUpDown.set()
        default:
            NSCursor.arrow.set()
        }
    }

    func handleCloseRequest(processAlive: Bool) {
        onCloseRequested?()
    }

    @discardableResult
    func performAction(_ name: String) -> Bool {
        guard let surface else { return false }
        let length = name.utf8CString.count
        guard length > 1 else { return false }
        return name.withCString { pointer in
            GhosttyFFI.surfaceBindingAction(surface, action: pointer, len: UInt(length - 1))
        }
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let surface {
            GhosttyFFI.surfaceSetFocus(surface, focused: true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let surface {
            GhosttyFFI.surfaceSetFocus(surface, focused: false)
        }
        return resigned
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard surface != nil else {
            interpretKeyEvents([event])
            return
        }

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let hadMarkedText = markedText.length > 0
        interpretKeyEvents([event])
        syncPreedit(clearIfNeeded: hadMarkedText)

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            for text in accumulated {
                _ = sendKey(
                    action,
                    event: event,
                    text: text,
                    composing: markedText.length > 0
                )
            }
        } else {
            _ = sendKey(
                action,
                event: event,
                text: EventTranslator.ghosttyCharacters(from: event),
                composing: markedText.length > 0 || hadMarkedText
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = sendKey(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard surface != nil, !hasMarkedText() else { return }

        let modifier: UInt32
        switch event.keyCode {
        case 0x39: modifier = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: modifier = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: modifier = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: modifier = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: modifier = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        let action: ghostty_input_action_e = (mods.rawValue & modifier) != 0
            ? GHOSTTY_ACTION_PRESS
            : GHOSTTY_ACTION_RELEASE
        _ = sendKey(action, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, let surface else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "," {
            openSonovoSettings()
            return true
        }

        if flags == .command {
            switch event.charactersIgnoringModifiers ?? "" {
            case "c":
                _ = performAction("copy_to_clipboard")
                return true
            case "v":
                _ = performAction("paste_from_clipboard")
                return true
            case "a":
                _ = performAction("select_all")
                return true
            default:
                break
            }
        }

        guard event.modifierFlags.contains(.command) else { return false }

        var keyEvent = EventTranslator.translateKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
        let characters = event.characters ?? ""
        let matches = characters.withCString { pointer -> Bool in
            keyEvent.text = pointer
            return GhosttyFFI.surfaceKeyIsBinding(surface, event: keyEvent)
        }

        if matches {
            keyDown(with: event)
            return true
        }
        return false
    }

    @discardableResult
    private func sendKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }

        var keyEvent = EventTranslator.translateKeyEvent(event, action: action)
        keyEvent.composing = composing

        if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
            return text.withCString { pointer in
                keyEvent.text = pointer
                return GhosttyFFI.surfaceKey(surface, event: keyEvent)
            }
        }

        return GhosttyFFI.surfaceKey(surface, event: keyEvent)
    }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        NSRange(location: 0, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: attributed)
        case let plain as String:
            markedText = NSMutableAttributedString(string: plain)
        default:
            return
        }

        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        guard let surface else { return .zero }

        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        GhosttyFFI.surfaceIMEPoint(surface, x: &x, y: &y, width: &width, height: &height)

        let rect = NSRect(
            x: x,
            y: frame.height - y,
            width: max(width, cellSize.width),
            height: max(height, cellSize.height)
        )
        let windowRect = convert(rect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }

        let text: String
        switch string {
        case let attributed as NSAttributedString:
            text = attributed.string
        case let plain as String:
            text = plain
        default:
            return
        }

        unmarkText()

        if var accumulated = keyTextAccumulator {
            accumulated.append(text)
            keyTextAccumulator = accumulated
            return
        }

        guard let surface else { return }
        let length = text.utf8CString.count
        guard length > 1 else { return }
        text.withCString { pointer in
            GhosttyFFI.surfaceText(surface, text: pointer, len: UInt(length - 1))
        }
    }

    override func doCommand(by selector: Selector) {
        // The key event is forwarded after interpretKeyEvents; swallowing the
        // selector prevents NSBeep for terminal keys AppKit does not know.
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let text = markedText.string
            let length = text.utf8CString.count
            text.withCString { pointer in
                GhosttyFFI.surfacePreedit(surface, text: pointer, len: UInt(length - 1))
            }
        } else if clearIfNeeded {
            GhosttyFFI.surfacePreedit(surface, text: nil, len: 0)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let surface else { return }
        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        _ = GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: mods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        _ = GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: mods)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        if GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT, mods: mods) {
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        if GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT, mods: mods) {
            return
        }
        super.rightMouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseEntered(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard NSEvent.pressedMouseButtons == 0, let surface else { return }
        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        GhosttyFFI.surfaceMousePos(surface, x: -1, y: -1, mods: mods)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let mods = EventTranslator.translateScrollMods(event)
        GhosttyFFI.surfaceMouseScroll(
            surface,
            x: event.scrollingDeltaX,
            y: event.scrollingDeltaY,
            mods: mods
        )
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mods = EventTranslator.translateModifiers(event.modifierFlags)
        GhosttyFFI.surfaceMousePos(
            surface,
            x: point.x,
            y: frame.height - point.y,
            mods: mods
        )
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(
            NSTrackingArea(
                rect: frame,
                options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
                owner: self,
                userInfo: nil
            )
        )
    }

    // MARK: - Menu actions

    @IBAction func copy(_ sender: Any?) {
        _ = performAction("copy_to_clipboard")
    }

    @IBAction func paste(_ sender: Any?) {
        _ = performAction("paste_from_clipboard")
    }

    @IBAction override func selectAll(_ sender: Any?) {
        _ = performAction("select_all")
    }
}

@MainActor
struct GhosttyTerminalViewRepresentable: NSViewRepresentable {
    let isActive: Bool
    let restartToken: Int
    let focusToken: Int
    let onClose: () -> Void
    let onTitleChanged: (String) -> Void
    let onWorkingDirectoryChanged: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> GhosttyTerminalView {
        let view = GhosttyTerminalView(frame: .zero)
        view.onCloseRequested = onClose
        view.onTitleChanged = onTitleChanged
        view.onWorkingDirectoryChanged = onWorkingDirectoryChanged
        return view
    }

    func updateNSView(_ view: GhosttyTerminalView, context: Context) {
        view.onCloseRequested = onClose
        view.onTitleChanged = onTitleChanged
        view.onWorkingDirectoryChanged = onWorkingDirectoryChanged

        if isActive {
            view.initializeIfNeeded()
        }

        if context.coordinator.lastRestartToken != restartToken {
            context.coordinator.lastRestartToken = restartToken
            view.restart()
        }

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            view.focus()
        }
    }

    final class Coordinator {
        var lastRestartToken = 0
        var lastFocusToken = 0
    }
}
