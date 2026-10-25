import SwiftUI

/// One editor presentation mode. Three independent toolbar buttons keep the
/// glass button shape consistent with the terminal, options, and inspector
/// controls; a segmented picker draws a second, wider container inside the
/// toolbar's own container.
struct ViewModeButton: View {
    @Bindable var state: AppState
    let mode: EditorMode

    private var isSelected: Bool {
        state.editorMode == mode
    }

    var body: some View {
        Button {
            state.editorMode = mode
        } label: {
            Label(mode.label, systemImage: mode.icon)
                .labelStyle(.iconOnly)
                .foregroundStyle(
                    isSelected ? Color.accentColor : Color.primary
                )
        }
        .disabled(!state.canUseMediaModes)
        .help(mode.label)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One on/off control for the editor chrome. It lives beside the project
/// switcher, not among the terminal and inspector tools.
struct EditorChromeToggle: View {
    @Binding var isOn: Bool
    let icon: String
    let title: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
        }
        .help(isOn ? "Hide \(title)" : "Show \(title)")
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct TerminalMenu: View {
    @Bindable var state: AppState

    var body: some View {
        Menu {
            Picker("Terminal", selection: $state.terminalPresentation) {
                Text("Hidden").tag(TerminalPresentation.hidden)
                Text("Split").tag(TerminalPresentation.split)
                Text("Full").tag(TerminalPresentation.full)
            }

            Picker("Dock", selection: $state.terminalDock) {
                Text("Automatic").tag(TerminalDock.automatic)
                Text("Right").tag(TerminalDock.right)
                Text("Bottom").tag(TerminalDock.bottom)
            }

            Divider()

            Button("New Terminal Tab") {
                revealTerminalIfNeeded()
                state.terminalSessions.addSession()
            }

            Button("Reattach Sessions") {
                revealTerminalIfNeeded()
                state.terminalSessions.restoreTmuxSessions()
            }

            Button("Restart Shell") {
                NotificationCenter.default.post(
                    name: .sonovoRestartTerminal,
                    object: nil
                )
            }
            .disabled(state.terminalSessions.selectedSession == nil)
        } label: {
            Label("Terminal", systemImage: "terminal")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .help("Terminal")
        .accessibilityLabel("Terminal")
    }

    /// A tab added to a hidden terminal is invisible; every terminal action
    /// from this menu first brings the pane on screen.
    private func revealTerminalIfNeeded() {
        if state.terminalPresentation == .hidden {
            state.terminalPresentation = .split
        }
    }
}

struct InspectorButton: View {
    @Bindable var state: AppState

    var body: some View {
        Button {
            state.inspectorVisible.toggle()
        } label: {
            Label("Inspector", systemImage: "sidebar.right")
                .labelStyle(.iconOnly)
        }
        .help(state.inspectorVisible ? "Hide Inspector" : "Show Inspector")
        .accessibilityLabel(
            state.inspectorVisible ? "Hide Inspector" : "Show Inspector"
        )
    }
}
