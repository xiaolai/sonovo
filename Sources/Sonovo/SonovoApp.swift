import AppKit
import SwiftUI

@main
struct SonovoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()
    @AppStorage("sonovo.appearance") private var appearance = "system"
    @AppStorage("sonovo.theme") private var theme = "Standard"
    @AppStorage("sonovo.foregroundIntensity") private var foregroundIntensity =
        AppTheme.Preferences.foregroundIntensityDefault
    @AppStorage("sonovo.backgroundIntensity") private var backgroundIntensity =
        AppTheme.Preferences.backgroundIntensityDefault

    var body: some Scene {
        // One window, one AppState. A WindowGroup would give every window the
        // same cached AppKit editor and terminal views, which cannot be
        // mounted in two windows at once.
        Window("Sonovo", id: "main") {
            MainWindow(state: state)
                .environment(state)
                .environment(\.workspaceTheme, workspaceTheme)
                .tint(workspaceTheme.accent)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: AppTheme.Layout.windowMinWidth, minHeight: AppTheme.Layout.windowMinHeight)
                .background(WindowChromeConfigurator())
        }
        .defaultSize(
            width: AppTheme.Layout.windowDefaultWidth,
            height: AppTheme.Layout.windowDefaultHeight
        )
        // The automatic launch behavior only presents a scene that was
        // restored; a cold install therefore opened no window until a second
        // reopen event. The main window is the app's only working surface.
        .defaultLaunchBehavior(.presented)
        .windowToolbarStyle(.unified)
        .commands {
            DocumentCommands(state: state)
            MarkdownCommands(state: state)
            SubtitleCommands(state: state)
            Model3DCommands(state: state)
            TerminalCommands(state: state)
            ProjectCommands(state: state)
        }

        Settings {
            SettingsView(state: state)
                .environment(state)
                .background(WindowChromeConfigurator())
        }
    }

    /// Themes are a named accent plus a canvas wash. The intensity sliders
    /// persist and scale the wash; the accent also tints standard controls.
    private var workspaceTheme: WorkspaceTheme {
        let base: Color
        switch theme {
        case "Slate":
            base = AppTheme.Palette.slateAccent
        case "Ember":
            base = AppTheme.Palette.emberAccent
        default:
            base = Color.accentColor
        }
        return WorkspaceTheme(
            accent: AppTheme.blendedAccent(
                base,
                fraction: foregroundIntensity * 0.18
            ),
            wash: base,
            backgroundIntensity: backgroundIntensity
        )
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        switch ProcessInfo.processInfo.environment["SONOVO_APPEARANCE"] {
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        default:
            break
        }

        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        NSApp.activate(ignoringOtherApps: true)

        // AppKit can rebuild a column's titlebar background when the window
        // becomes key or finishes a live resize, which brings its hairline
        // back. Reapply the chrome after those transitions.
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didEndLiveResizeNotification
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(refreshWindowChrome(_:)),
                name: name,
                object: nil
            )
        }

        DispatchQueue.main.async {
            for window in NSApp.windows {
                configureWindowChrome(window)
            }
        }
    }

    @objc private func refreshWindowChrome(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        applyToolbarChrome(window)
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            applyToolbarChrome(window)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        GhosttyAppController.shared.setFocus(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        GhosttyAppController.shared.setFocus(false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Runs only after the quit is approved. Doing this earlier would stop
    /// watchers and terminate terminals even when a save decision cancels the
    /// quit.
    func applicationWillTerminate(_ notification: Notification) {
        AppStateRegistry.active?.prepareForTermination()
    }

    private var terminationPending = false

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let state = AppStateRegistry.active,
              state.hasDirtyDocuments else {
            return .terminateNow
        }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true

        // Every project is flushed, active first. A pending save decision
        // cancels the quit and leaves the failing project active; the user
        // resolves it and quits again. No project is left unwatched or
        // half-saved by this path.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let allowed = await state.flushAllBeforeClose()
            self.terminationPending = false
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }
}


private func configureWindowChrome(_ window: NSWindow) {
    applyToolbarChrome(window)
    // SwiftUI can install the toolbar after the window first appears; the
    // separator returns unless the setting is applied once it exists.
    DispatchQueue.main.async { [weak window] in
        guard let window else { return }
        applyToolbarChrome(window)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak window] in
        guard let window else { return }
        applyToolbarChrome(window)
    }
}



private func applyToolbarChrome(_ window: NSWindow) {
    window.titlebarSeparatorStyle = .none
    window.toolbar?.showsBaselineSeparator = false
    hideTitlebarHairlines(in: window.contentView?.superview)
}

/// macOS 26 keeps a half-point separator layer inside each split column's
/// titlebar background, even with `titlebarSeparatorStyle = .none`. Hiding
/// those thin solid layers removes the line; the titlebar material, glass,
/// and controls are untouched. Matching is structural and fails closed.
private func hideTitlebarHairlines(in view: NSView?) {
    guard let view else { return }
    if String(describing: type(of: view)) == "NSTitlebarBackgroundView" {
        hideHairlineLayers(in: view.layer)
    }
    for subview in view.subviews {
        hideTitlebarHairlines(in: subview)
    }
}

private func hideHairlineLayers(in layer: CALayer?) {
    guard let layer else { return }
    if layer.frame.height > 0,
       layer.frame.height <= 1,
       layer.backgroundColor != nil {
        layer.isHidden = true
    }
    for sublayer in layer.sublayers ?? [] {
        hideHairlineLayers(in: sublayer)
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configureWindowChrome(window)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window {
                configureWindowChrome(window)
            }
        }
    }
}
