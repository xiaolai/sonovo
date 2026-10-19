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
            Button {
                state.newTake()
            } label: {
                Image(systemName: "plus")
                    .frame(width: AppTheme.Size.addIcon, height: AppTheme.Size.addIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Request a new take")
            .accessibilityLabel("Request a new take")

            Menu {
                previewQualityButton("1080p")
                previewQualityButton("720p")
                previewQualityButton("4K")
            } label: {
                Label(state.previewQuality, systemImage: "play.rectangle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Preview quality")
            .accessibilityLabel("Preview quality")

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

            Picker("Review Mode", selection: $state.editorMode) {
                ForEach(EditorMode.allCases) { mode in
                    Image(systemName: mode.icon)
                        .accessibilityLabel(mode.label)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: AppTheme.Size.reviewModePickerWidth)
            .disabled(!state.canUseReviewModes)
            .help("Review mode")
            .accessibilityLabel("Review mode")

            BarIconButton(
                systemName: "sidebar.right",
                help: state.inspectorVisible ? "Hide Inspector" : "Show Inspector",
                isSelected: state.inspectorVisible
            ) {
                state.inspectorVisible.toggle()
            }
        }
    }

    private func previewQualityButton(_ quality: String) -> some View {
        Button {
            state.previewQuality = quality
        } label: {
            if state.previewQuality == quality {
                Label(quality, systemImage: "checkmark")
            } else {
                Text(quality)
            }
        }
    }
}
