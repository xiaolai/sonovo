import AppKit
import SwiftUI

@main
struct SonovoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()
    @AppStorage("sonovo.appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup("Sonovo") {
            MainWindow(state: state)
                .environment(state)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Take") { state.newTake() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Inspector") { state.inspectorVisible.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
            CommandMenu("Terminal") {
                Button("Toggle Terminal") {
                    state.terminalPresentation = state.terminalPresentation == .hidden ? .split : .hidden
                }
                .keyboardShortcut("`", modifiers: [.control])

                Button("Terminal in Split") {
                    state.terminalPresentation = .split
                }

                Button("Terminal Full Pane") {
                    state.terminalPresentation = .full
                }

                Divider()

                Button("New Terminal Tab") {
                    state.terminalSessions.addSession()
                    state.terminalPresentation = .split
                }
                .keyboardShortcut("t", modifiers: [.command])

                Divider()

                Picker("Dock", selection: $state.terminalDock) {
                    Text("Automatic").tag(TerminalDock.automatic)
                    Text("Right").tag(TerminalDock.right)
                    Text("Bottom").tag(TerminalDock.bottom)
                }

                Divider()

                Button("Hide Terminal") {
                    state.terminalPresentation = .hidden
                }
                .disabled(state.terminalPresentation == .hidden)

                Button("Restart Shell") {
                    NotificationCenter.default.post(name: .sonovoRestartTerminal, object: nil)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(state)
        }
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

        if let icon = NSImage(contentsOfFile: "dev-docs/icon-artifacts/AppIcon.png") {
            NSApp.applicationIconImage = icon
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
