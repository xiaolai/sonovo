import SwiftUI

struct LeadingToolbarView: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            BarIconButton(systemName: "sidebar.leading", help: "Toggle Sidebar") {
                state.columnVisibility = state.columnVisibility == .detailOnly ? .all : .detailOnly
            }

            Picker("Navigator", selection: $state.navigatorMode) {
                ForEach(NavigatorMode.allCases) { mode in
                    Image(systemName: mode.icon)
                        .accessibilityLabel(mode.label)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 76)
            .help("Navigator")

            Rectangle()
                .fill(Color.appSeparator)
                .frame(width: 1, height: 16)

            BarIconButton(
                systemName: state.isPlaying ? "pause.fill" : "play.fill",
                help: state.isPlaying ? "Pause preview" : "Preview",
                tint: .green
            ) {
                state.togglePlayback()
            }

            BarIconButton(systemName: "stop.fill", help: "Stop") {
                state.isPlaying = false
            }

            BarIconButton(systemName: "chevron.left", help: "Back") { }
                .disabled(true)

            BarIconButton(systemName: "chevron.right", help: "Forward") { }
                .disabled(true)
        }
        .frame(height: 28)
    }
}

struct TitleToolbarView: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                Text("\(state.production.title) — \(state.production.episode)")
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Circle()
                        .fill(state.isPlaying ? Color.accentColor : Color.green)
                        .frame(width: 5, height: 5)
                    Text(state.activityText)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .fixedSize()

            Button {
                state.newTake()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Request a new take")

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
        }
        .frame(height: 30)
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

struct TrailingToolbarView: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 6) {
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
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Terminal")

            Menu {
                Toggle("Show Tab Bar", isOn: $state.showTabBar)
                Toggle("Show Breadcrumbs", isOn: $state.showBreadcrumbs)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Editor Options")

            Picker("Review Mode", selection: $state.editorMode) {
                ForEach(EditorMode.allCases) { mode in
                    Image(systemName: mode.icon)
                        .accessibilityLabel(mode.label)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 94)
            .disabled(!state.canUseReviewModes)
            .help("Review mode")

            BarIconButton(
                systemName: "sidebar.right",
                help: state.inspectorVisible ? "Hide Inspector" : "Show Inspector",
                isSelected: state.inspectorVisible
            ) {
                state.inspectorVisible.toggle()
            }
        }
        .frame(height: 28)
    }
}
