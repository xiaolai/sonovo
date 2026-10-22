import SwiftUI

struct LeadingToolbarView: View {
    @Bindable var state: AppState

    var body: some View {
        Picker("Navigator", selection: $state.navigatorMode) {
            ForEach(NavigatorMode.allCases) { mode in
                Image(systemName: mode.icon)
                    .accessibilityLabel(mode.label)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: AppTheme.Size.navigatorPickerWidth)
        .help("Navigator")
        .accessibilityLabel("Navigator")
    }
}

struct TrailingToolbarView: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: AppTheme.Spacing.s6) {
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
                    state.terminalSessions.addSession()
                }

                Button("Reattach Sessions") {
                    state.terminalSessions.restoreTmuxSessions()
                }

                Button("Restart Shell") {
                    NotificationCenter.default.post(name: .sonovoRestartTerminal, object: nil)
                }
            } label: {
                Image(systemName: "terminal")
                    .frame(width: AppTheme.Size.menuIcon, height: AppTheme.Size.menuIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Terminal")
            .accessibilityLabel("Terminal")

            Menu {
                Toggle("Show Tab Bar", isOn: $state.showTabBar)
                Toggle("Show Breadcrumbs", isOn: $state.showBreadcrumbs)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: AppTheme.Size.menuIcon, height: AppTheme.Size.menuIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Editor Options")
            .accessibilityLabel("Editor Options")

            Picker("Mode", selection: $state.editorMode) {
                ForEach(EditorMode.allCases) { mode in
                    Image(systemName: mode.icon)
                        .accessibilityLabel(mode.label)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: AppTheme.Size.mediaModePickerWidth)
            .disabled(!state.canUseMediaModes)
            .help("View mode")
            .accessibilityLabel("View mode")

        }
    }
}
