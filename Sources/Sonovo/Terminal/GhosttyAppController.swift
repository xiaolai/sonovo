// Adapted from Calyx's GhosttyAppController (MIT).
// The runtime callback shape, resource lookup, and clipboard bridge follow
// https://github.com/yuuichieguchi/Calyx and the libghostty C API.

@preconcurrency import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.sonovo.Sonovo", category: "Ghostty")

@MainActor
final class GhosttyAppController {
    static let shared = GhosttyAppController()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private(set) var isReady = false
    private var currentThemeIsDark = false
    private let surfaces = NSHashTable<GhosttyTerminalView>.weakObjects()

    private init() {
        applyGhosttyResources()

        guard GhosttyFFI.initialize() else {
            logger.error("ghostty_init failed")
            return
        }

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        currentThemeIsDark = isDark

        guard let configuration = makeConfig(isDark: isDark) else {
            logger.error("Ghostty configuration failed")
            return
        }
        config = configuration

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: sonovoGhosttyWakeup,
            action_cb: sonovoGhosttyAction,
            read_clipboard_cb: sonovoGhosttyReadClipboard,
            confirm_read_clipboard_cb: sonovoGhosttyConfirmReadClipboard,
            write_clipboard_cb: sonovoGhosttyWriteClipboard,
            close_surface_cb: sonovoGhosttyCloseSurface
        )

        guard let newApp = GhosttyFFI.appNew(&runtime, config: configuration) else {
            logger.error("ghostty_app_new failed")
            return
        }

        app = newApp
        isReady = true
        GhosttyFFI.appSetFocus(newApp, focused: NSApp.isActive)
        logger.info("Ghostty ready: \(GhosttyProbe.version, privacy: .public)")
    }

    isolated deinit {
        if let app {
            GhosttyFFI.appFree(app)
        }
        if let config {
            GhosttyFFI.configFree(config)
        }
    }

    func tick() {
        guard let app else { return }
        GhosttyFFI.appTick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        GhosttyFFI.appSetFocus(app, focused: focused)
    }

    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let app else { return }
        GhosttyFFI.appSetColorScheme(app, scheme: scheme)
    }

    func register(_ view: GhosttyTerminalView) {
        surfaces.add(view)
    }

    func applyTheme(isDark: Bool) {
        guard currentThemeIsDark != isDark, let app else { return }
        guard let newConfig = makeConfig(isDark: isDark) else {
            logger.warning("Ghostty theme reload failed")
            return
        }

        let previous = config
        config = newConfig
        currentThemeIsDark = isDark

        GhosttyFFI.appUpdateConfig(app, config: newConfig)
        for view in surfaces.allObjects {
            guard let surface = view.surface else { continue }
            GhosttyFFI.surfaceUpdateConfig(surface, config: newConfig)
        }
        // The app and surfaces have taken the new configuration; the old
        // opaque allocation is no longer referenced. `withExtendedLifetime`
        // kept it alive but never freed it, leaking one config per theme
        // change.
        if let previous {
            GhosttyFFI.configFree(previous)
        }
    }

    /// Rebuilds the configuration after a terminal preference changed. New
    /// surfaces use the new font and shell; existing surfaces take the font
    /// immediately (their shell process is already running).
    func reloadTerminalPreferences() {
        guard let app else { return }
        guard let newConfig = makeConfig(isDark: currentThemeIsDark) else {
            logger.warning("Ghostty preference reload failed")
            return
        }
        let previous = config
        config = newConfig
        GhosttyFFI.appUpdateConfig(app, config: newConfig)
        for view in surfaces.allObjects {
            guard let surface = view.surface else { continue }
            GhosttyFFI.surfaceUpdateConfig(surface, config: newConfig)
        }
        if let previous {
            GhosttyFFI.configFree(previous)
        }
    }

    private func applyGhosttyResources() {
        guard let resources = Bundle.module.url(forResource: "ghostty", withExtension: nil) else {
            logger.error("Bundled Ghostty resources not found")
            return
        }

        let shellIntegration = resources.appendingPathComponent("shell-integration")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: shellIntegration.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            logger.error("Ghostty resources are incomplete")
            return
        }

        setenv("GHOSTTY_RESOURCES_DIR", resources.path, 1)

        // Ghostty derives the shell's TERMINFO from the resources directory,
        // but only when it sees one; without it the child inherits whatever
        // TERMINFO the launching process had, and a `/dev/null` there makes
        // every shell in the terminal fail to load a database. Set the value
        // here as well so it cannot depend on that derivation.
        if let terminfo = Bundle.module.url(
            forResource: "terminfo",
            withExtension: nil
        ) {
            setenv("TERMINFO", terminfo.path, 1)
        } else {
            logger.error("Bundled terminfo database not found")
        }
    }

    private func makeConfig(isDark: Bool) -> ghostty_config_t? {
        guard let config = GhosttyFFI.configNew() else { return nil }

        GhosttyFFI.configLoadDefaultFiles(config)
        GhosttyFFI.configLoadRecursiveFiles(config)

        // User choices from Settings override the defaults but sit before
        // the bundled color theme, which only sets colors.
        if let overrides = TerminalPreferences.overrideConfigURL() {
            GhosttyFFI.configLoadFile(config, path: overrides.path)
        }

        let themeName = isDark ? "dark" : "light"
        if let themeURL = Bundle.module.url(
            forResource: themeName,
            withExtension: "conf",
            subdirectory: "ghostty-themes"
        ) {
            GhosttyFFI.configLoadFile(config, path: themeURL.path)
        } else {
            logger.warning("Ghostty \(themeName, privacy: .public) theme not found")
        }

        GhosttyFFI.configFinalize(config)

        let diagnostics = GhosttyFFI.configDiagnosticsCount(config)
        for index in 0..<diagnostics {
            let diagnostic = GhosttyFFI.configGetDiagnostic(config, index: index)
            if let message = diagnostic.message {
                logger.warning("Ghostty config: \(String(cString: message), privacy: .public)")
            }
        }

        return config
    }
}

// MARK: - Runtime callbacks

private func sonovoGhosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    nonisolated(unsafe) let pointer = userdata
    DispatchQueue.main.async {
        let controller = Unmanaged<GhosttyAppController>.fromOpaque(pointer).takeUnretainedValue()
        controller.tick()
    }
}

private func sonovoGhosttyAction(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    guard let app else { return false }
    nonisolated(unsafe) let safeApp = app
    let safeTarget = target
    let safeAction = action
    return MainActor.assumeIsolated {
        GhosttyActionRouter.handle(app: safeApp, target: safeTarget, action: safeAction)
    }
}

private func sonovoGhosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    guard let userdata else { return false }
    nonisolated(unsafe) let pointer = userdata
    nonisolated(unsafe) let safeState = state
    return MainActor.assumeIsolated {
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(pointer).takeUnretainedValue()
        guard let surface = view.surface else { return false }
        let pasteboard = clipboard(for: location)
        let text = pasteboard.string(forType: .string) ?? ""
        text.withCString { cString in
            GhosttyFFI.surfaceCompleteClipboardRequest(surface, data: cString, state: safeState, confirmed: false)
        }
        return true
    }
}

private func sonovoGhosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    guard let userdata, let string else { return }
    nonisolated(unsafe) let pointer = userdata
    nonisolated(unsafe) let safeState = state
    let contents = String(cString: string)
    MainActor.assumeIsolated {
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(pointer).takeUnretainedValue()
        guard view.surface != nil else { return }
        // Clipboard reads are exfiltration: never approve one silently.
        let allowed = confirmClipboardAccess(
            title: "Allow the terminal to read the clipboard?",
            detail: "A program running in the terminal requested the "
                + "clipboard contents."
        )
        // The modal loop can close the view and free its surface. Re-read
        // it afterwards instead of completing against the stale pointer;
        // a surface that is gone has no request left to complete.
        guard let surface = view.surface else { return }
        // Ghostty re-prompts when a denial is completed with
        // `confirmed: false`; the reference app completes every confirmation
        // with empty contents and `confirmed: true` instead.
        let response = allowed ? contents : ""
        response.withCString { cString in
            GhosttyFFI.surfaceCompleteClipboardRequest(
                surface,
                data: cString,
                state: safeState,
                confirmed: true
            )
        }
    }
}

private func sonovoGhosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ contents: UnsafePointer<ghostty_clipboard_content_s>?,
    _ contentsLength: Int,
    _ confirm: Bool
) {
    guard let contents, contentsLength > 0 else { return }

    var value: String?
    for index in 0..<contentsLength {
        let entry = contents[index]
        guard let data = entry.data else { continue }
        if let mime = entry.mime, String(cString: mime) == "text/plain" {
            value = String(cString: data)
            break
        }
    }
    if value == nil, let data = contents[0].data {
        value = String(cString: data)
    }
    guard let value else { return }

    MainActor.assumeIsolated {
        if confirm,
           !confirmClipboardAccess(
               title: "Allow the terminal to replace the clipboard?",
               detail: "A program running in the terminal wants to write "
                   + "to the clipboard."
           ) {
            return
        }
        let pasteboard = clipboard(for: location)
        _ = pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

/// A modal confirmation for a terminal clipboard request. The request is
/// denied unless the user explicitly allows it.
@MainActor
private func confirmClipboardAccess(title: String, detail: String) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: "Allow")
    alert.addButton(withTitle: "Deny")
    return alert.runModal() == .alertFirstButtonReturn
}

private func sonovoGhosttyCloseSurface(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {
    guard let userdata else { return }
    nonisolated(unsafe) let pointer = userdata
    MainActor.assumeIsolated {
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(pointer).takeUnretainedValue()
        view.handleCloseRequest(processAlive: processAlive)
    }
}

private func clipboard(for location: ghostty_clipboard_e) -> NSPasteboard {
    if location == GHOSTTY_CLIPBOARD_SELECTION {
        return NSPasteboard(name: NSPasteboard.Name("com.sonovo.selection"))
    }
    return .general
}

// MARK: - Actions

@MainActor
enum GhosttyActionRouter {
    static func handle(
        app: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let view = surfaceView(from: target),
               let title = action.action.set_title.title {
                view.updateTitle(String(cString: title))
            }
            return true

        case GHOSTTY_ACTION_PWD:
            if let view = surfaceView(from: target),
               let pwd = action.action.pwd.pwd {
                view.updateWorkingDirectory(String(cString: pwd))
            }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            surfaceView(from: target)?.updateCursorShape(action.action.mouse_shape)
            return true

        case GHOSTTY_ACTION_RENDER:
            surfaceView(from: target)?.needsDisplay = true
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            surfaceView(from: target)?.updateCellSize(
                width: action.action.cell_size.width,
                height: action.action.cell_size.height
            )
            return true

        case GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_SCROLLBAR:
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            guard let pointer = action.action.open_url.url,
                  let url = URL(string: String(cString: pointer)),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return true
            }
            NSWorkspace.shared.open(url)
            return true

        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true

        case GHOSTTY_ACTION_QUIT:
            NSApp.terminate(nil)
            return true

        case GHOSTTY_ACTION_NEW_TAB:
            surfaceView(from: target)?.onNewTabRequested?()
            return true

        case GHOSTTY_ACTION_CLOSE_TAB, GHOSTTY_ACTION_CLOSE_WINDOW:
            surfaceView(from: target)?.handleCloseRequest(processAlive: true)
            return true

        default:
            return false
        }
    }

    private static func surfaceView(from target: ghostty_target_s) -> GhosttyTerminalView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let userdata = GhosttyFFI.surfaceUserdata(surface) else {
            return nil
        }
        return Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
    }
}
