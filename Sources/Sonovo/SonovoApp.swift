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
            MediaCommands(state: state)
            TimelineCommands(state: state)
            TerminalCommands(state: state)
            ProjectCommands(state: state)
        }

        Window("Sonovo Sessions", id: "sessions") {
            TmuxSessionsWindow(model: state.sessionsWindow)
                .environment(state)
                .tint(workspaceTheme.accent)
                .preferredColorScheme(preferredColorScheme)
                .background(WindowChromeConfigurator())
        }
        .defaultSize(
            width: AppTheme.Layout.sessionsDefaultWidth,
            height: AppTheme.Layout.sessionsDefaultHeight
        )
        .windowToolbarStyle(.unified)

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
                fraction: foregroundIntensity * AppTheme.Preferences.accentBlendFactor
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

        #if SONOVO_E2E_PROBE
        E2EProbe.run()
        #endif

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

    private enum TmuxQuitDecision {
        case keepRunning
        case endSessions
        case cancel
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let state = AppStateRegistry.active else {
            return .terminateNow
        }
        if !terminationPending,
           !state.hasDirtyDocuments,
           state.attachedTmuxSessionCount == 0 {
            return .terminateNow
        }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Saves settle first: a cancelled quit must not have ended any
            // session already. The tmux decision is therefore the last
            // prompt before the quit actually proceeds.
            let allowed = await state.flushAllBeforeClose()
            guard allowed else {
                self.terminationPending = false
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            if state.attachedTmuxSessionCount > 0 {
                #if SONOVO_E2E_PROBE
                // The probe quits itself; a modal would hang automation.
                #else
                switch self.askAboutTmuxSessions(
                    count: state.attachedTmuxSessionCount
                ) {
                case .cancel:
                    self.terminationPending = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                case .keepRunning:
                    break
                case .endSessions:
                    await state.endAllAttachedTmuxSessions()
                }
                #endif
            }
            self.terminationPending = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func askAboutTmuxSessions(count: Int) -> TmuxQuitDecision {
        let alert = NSAlert()
        alert.messageText = count == 1
            ? "End the tmux session?"
            : "End \(count) tmux sessions?"
        alert.informativeText =
            "They keep running after Sonovo quits unless you end them."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "End Sessions")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[2].keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .keepRunning
        case .alertSecondButtonReturn:
            return .endSessions
        default:
            return .cancel
        }
    }
}


@MainActor
private func configureWindowChrome(_ window: NSWindow) {
    applyToolbarChrome(window)
}

@MainActor
private func applyToolbarChrome(_ window: NSWindow) {
    window.titlebarSeparatorStyle = .none
    hideTitlebarHairlines(in: window.contentView?.superview)
}

/// macOS 26 keeps a half-point separator layer inside each split column's
/// titlebar background, even with `titlebarSeparatorStyle = .none`. Hiding
/// those thin solid layers removes the line; the titlebar material, glass,
/// and controls are untouched. Matching is structural and fails closed.
@MainActor
private func hideTitlebarHairlines(in view: NSView?) {
    guard let view else { return }
    if isTitlebarBackgroundView(view) {
        hideHairlineLayers(in: view.layer, minimumWidth: view.bounds.width)
    }
    for subview in view.subviews {
        hideTitlebarHairlines(in: subview)
    }
}

/// The AppKit internal view that hosts the titlebar material. Isolated here
/// so the implementation-name fallback is one small, replaceable check.
@MainActor
private func isTitlebarBackgroundView(_ view: NSView) -> Bool {
    String(describing: type(of: view)) == "NSTitlebarBackgroundView"
}

@MainActor
private func hideHairlineLayers(
    in layer: CALayer?,
    minimumWidth: CGFloat
) {
    guard let layer, minimumWidth > 0 else { return }
    // Only a layer spanning at least half the titlebar can be the separator.
    // Button and control borders are narrow and must not be hidden.
    // token-exempt: titlebar layer threshold
    if layer.frame.height > 0,
       layer.frame.height <= 1,
       layer.backgroundColor != nil,
       layer.frame.width >= minimumWidth * 0.5 { // token-exempt: titlebar layer threshold
        layer.isHidden = true
    }
    for sublayer in layer.sublayers ?? [] {
        hideHairlineLayers(in: sublayer, minimumWidth: minimumWidth)
    }
}

struct WindowChromeConfigurator: NSViewRepresentable {
    /// Applies the chrome once per window/toolbar identity. SwiftUI calls
    /// `updateNSView` for every environment change; the old code scheduled two
    /// window-tree walks on each one. The identity check makes all but the
    /// first pass free.
    @MainActor
    final class Coordinator {
        weak var view: NSView?
        private weak var appliedWindow: NSWindow?
        private var appliedToolbar: ObjectIdentifier?
        private var applyScheduled = false
        /// Test seam: production applies the real chrome.
        var applyChrome: @MainActor (NSWindow) -> Void = configureWindowChrome

        func schedule(_ view: NSView) {
            self.view = view
            guard !isCurrent(window: view.window) else { return }
            guard !applyScheduled else { return }
            applyScheduled = true
            Task { @MainActor [weak self] in
                self?.apply(retryWithoutWindow: true)
            }
        }

        private func isCurrent(window: NSWindow?) -> Bool {
            guard let window else { return false }
            return appliedWindow === window
                && appliedToolbar
                    == window.toolbar.map(ObjectIdentifier.init)
        }

        private func apply(retryWithoutWindow: Bool) {
            applyScheduled = false
            guard let window = view?.window else {
                guard retryWithoutWindow else { return }
                applyScheduled = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    self?.apply(retryWithoutWindow: false)
                }
                return
            }
            let toolbar = window.toolbar.map(ObjectIdentifier.init)
            guard appliedWindow !== window
                || appliedToolbar != toolbar else {
                return
            }
            applyChrome(window)
            appliedWindow = window
            appliedToolbar = toolbar
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.schedule(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.schedule(view)
    }
}
