import SwiftUI
import SonovoDomainTypes

/// Embedded terminal commands.
@MainActor
package struct TerminalCommands: Commands {
    package let state: any TerminalPaneContext
    package init(state: any TerminalPaneContext) { self.state = state }
    @Environment(\.openWindow) private var openWindow

    package var body: some Commands {
        CommandMenu("Terminal") {
            Button("Manage Sessions…") {
                openWindow(id: "sessions")
            }

            Divider()

            Button("Toggle Terminal") {
                state.terminalPresentation =
                    state.terminalPresentation == .hidden ? .split : .hidden
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

            Picker("Dock", selection: Binding(get: { state.terminalDock }, set: { state.terminalDock = $0 })) {
                ForEach(TerminalDock.allCases) { dock in
                    Text(dock.label).tag(dock)
                }
            }

            Divider()

            Button("Hide Terminal") {
                state.terminalPresentation = .hidden
            }
            .disabled(state.terminalPresentation == .hidden)

            Button("Restart Shell") {
                NotificationCenter.default.post(
                    name: .sonovoRestartTerminal,
                    object: nil
                )
            }
        }
    }
}
