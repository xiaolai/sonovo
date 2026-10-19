import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case editor
    case audio
    case terminal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .editor: "Editor"
        case .audio: "Audio"
        case .terminal: "Terminal"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .editor: "textformat"
        case .audio: "waveform"
        case .terminal: "terminal"
        }
    }
}

struct SettingsView: View {
    @AppStorage("sonovo.appearance") private var appearance = "system"

    @State private var selectedSection: SettingsSection = .appearance
    @State private var foregroundIntensity = 0.48
    @State private var backgroundIntensity = 0.34
    @State private var theme = "Standard"

    @AppStorage("sonovo.restoreTabs") private var restoreTabs = true
    @AppStorage("sonovo.confirmClose") private var confirmClose = true
    @AppStorage("sonovo.reopenLast") private var reopenLast = true
    @AppStorage("sonovo.editorFontSize") private var editorFontSize = 13.0
    @AppStorage("sonovo.showBreadcrumbs") private var showBreadcrumbs = true
    @AppStorage("sonovo.markdownRendered") private var markdownRendered = true
    @AppStorage("sonovo.wrapLines") private var wrapLines = true
    @AppStorage("sonovo.audioDevice") private var audioDevice = "System Default"
    @AppStorage("sonovo.sampleRate") private var sampleRate = "48 kHz"
    @AppStorage("sonovo.followPlayhead") private var followPlayhead = true
    @AppStorage("sonovo.captionsDefault") private var captionsDefault = true
    @AppStorage("sonovo.shell") private var shell = "/bin/zsh"
    @AppStorage("sonovo.terminalFont") private var terminalFont = "SF Mono 12"
    @AppStorage("sonovo.loginShell") private var loginShell = true

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.label, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(.bar)
            .frame(width: 184)

            Divider()

            ScrollView {
                detailPane
                    .padding(AppTheme.Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 720, height: 500)
        .navigationTitle("Settings")
        .preferredColorScheme(preferredColorScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selectedSection {
        case .general:
            generalPane
        case .appearance:
            appearancePane
        case .editor:
            editorPane
        case .audio:
            audioPane
        case .terminal:
            terminalPane
        }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            paneHeader(
                title: "General",
                detail: "How Sonovo opens and restores productions."
            )

            SettingsGroup {
                SettingsRow {
                    Toggle("Restore open tabs", isOn: $restoreTabs)
                    Text("Reopen the tabs and splits from your last session.")
                }
                Hairline()
                SettingsRow {
                    Toggle("Confirm before closing", isOn: $confirmClose)
                    Text("Ask before closing a production with unsaved changes.")
                }
                Hairline()
                SettingsRow {
                    Toggle("Reopen last production", isOn: $reopenLast)
                    Text("Open the most recent production at launch.")
                }
            }
        }
    }

    private var appearancePane: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            paneHeader(
                title: "Appearance",
                detail: "Choose how Sonovo looks. The theme tints the whole workspace."
            )

            HStack(spacing: AppTheme.Spacing.md) {
                AppearanceCard(mode: .system, isSelected: appearance == "system") {
                    appearance = "system"
                }
                AppearanceCard(mode: .light, isSelected: appearance == "light") {
                    appearance = "light"
                }
                AppearanceCard(mode: .dark, isSelected: appearance == "dark") {
                    appearance = "dark"
                }
            }

            SettingsGroup {
                SettingsRow {
                    HStack {
                        Text("Theme")
                        Spacer()
                        Menu {
                            Button("Standard") { theme = "Standard" }
                            Button("Slate") { theme = "Slate" }
                            Button("Ember") { theme = "Ember" }
                        } label: {
                            HStack(spacing: 4) {
                                Text(theme)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                Hairline()
                SettingsRow {
                    HStack(spacing: AppTheme.Spacing.md) {
                        Text("Foreground")
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $foregroundIntensity, in: 0...1)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.35 + foregroundIntensity * 0.55))
                            .frame(width: 26, height: 16)
                    }
                }
                Hairline()
                SettingsRow {
                    HStack(spacing: AppTheme.Spacing.md) {
                        Text("Background")
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $backgroundIntensity, in: 0...1)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.15 + backgroundIntensity * 0.5))
                            .frame(width: 26, height: 16)
                    }
                }
            }

            Text("Themes are derived from a base palette. Individual colors stay editable per workspace.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(.tertiary)
        }
    }

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            paneHeader(
                title: "Editor",
                detail: "Text, Markdown, and tab behavior."
            )

            SettingsGroup {
                SettingsRow {
                    HStack {
                        Text("Font size")
                        Spacer()
                        Stepper(value: $editorFontSize, in: 11...18, step: 1) {
                            Text("\(Int(editorFontSize)) pt")
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                }
                Hairline()
                SettingsRow {
                    Toggle("Show breadcrumbs", isOn: $showBreadcrumbs)
                    Text("Show the path to the current asset above the editor.")
                }
                Hairline()
                SettingsRow {
                    Toggle("Open Markdown rendered", isOn: $markdownRendered)
                    Text("Start in the rendered document view instead of source.")
                }
                Hairline()
                SettingsRow {
                    Toggle("Wrap long lines", isOn: $wrapLines)
                    Text("Wrap source lines to the width of the editor.")
                }
            }
        }
    }

    private var audioPane: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            paneHeader(
                title: "Audio",
                detail: "Playback and review defaults for voice and music."
            )

            SettingsGroup {
                SettingsRow {
                    HStack {
                        Text("Output device")
                        Spacer()
                        Picker("", selection: $audioDevice) {
                            Text("System Default").tag("System Default")
                            Text("Mac Studio Speakers").tag("Mac Studio Speakers")
                            Text("AirPods").tag("AirPods")
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                }
                Hairline()
                SettingsRow {
                    HStack {
                        Text("Sample rate")
                        Spacer()
                        Picker("", selection: $sampleRate) {
                            Text("48 kHz").tag("48 kHz")
                            Text("44.1 kHz").tag("44.1 kHz")
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }
                Hairline()
                SettingsRow {
                    Toggle("Follow playhead", isOn: $followPlayhead)
                    Text("Keep the selected transcript line aligned with playback.")
                }
                Hairline()
                SettingsRow {
                    Toggle("Show captions by default", isOn: $captionsDefault)
                    Text("Display the current transcript line over the video stage.")
                }
            }
        }
    }

    private var terminalPane: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            paneHeader(
                title: "Terminal",
                detail: "The terminal is the studio's back door. Hidden until opened."
            )

            SettingsGroup {
                SettingsRow {
                    HStack {
                        Text("Shell")
                        Spacer()
                        Picker("", selection: $shell) {
                            Text("zsh").tag("/bin/zsh")
                            Text("bash").tag("/bin/bash")
                            Text("fish").tag("/opt/homebrew/bin/fish")
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                }
                Hairline()
                SettingsRow {
                    HStack {
                        Text("Font")
                        Spacer()
                        Picker("", selection: $terminalFont) {
                            Text("SF Mono 12").tag("SF Mono 12")
                            Text("Menlo 12").tag("Menlo 12")
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                }
                Hairline()
                SettingsRow {
                    Toggle("Use login shell", isOn: $loginShell)
                    Text("Start the terminal as a login shell so your profile is loaded.")
                }
            }
        }
    }

    private func paneHeader(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
            Text(detail)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }
}

private struct SettingsRow<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            content
        }
        .font(.system(size: AppTheme.FontSize.sm))
        .padding(.vertical, AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AppearanceCard: View {
    enum Mode: String {
        case system
        case light
        case dark

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    let mode: Mode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: AppTheme.Spacing.xs) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))

                    preview
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
                        .padding(5)

                    if isSelected {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    } else {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                            .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
                    }
                }
                .frame(height: 92)

                Text(mode.title)
                    .font(.system(size: AppTheme.FontSize.xs, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.title) appearance")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var preview: some View {
        switch mode {
        case .system:
            HStack(spacing: 0) {
                MiniWindow(isDark: false)
                Rectangle()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: 1)
                MiniWindow(isDark: true)
            }
        case .light:
            MiniWindow(isDark: false)
        case .dark:
            MiniWindow(isDark: true)
        }
    }
}

private struct MiniWindow: View {
    let isDark: Bool

    var body: some View {
        let background = isDark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0.96, green: 0.96, blue: 0.97)
        let sidebar = isDark ? Color(red: 0.15, green: 0.15, blue: 0.16) : Color(red: 0.91, green: 0.91, blue: 0.92)
        let content = isDark ? Color(red: 0.08, green: 0.08, blue: 0.09) : Color.white
        let line = isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)

        return ZStack {
            background

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 26)
                content
            }

            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    Circle().fill(Color(red: 0.93, green: 0.42, blue: 0.38)).frame(width: 3, height: 3)
                    Circle().fill(Color(red: 0.96, green: 0.73, blue: 0.30)).frame(width: 3, height: 3)
                    Circle().fill(Color(red: 0.36, green: 0.78, blue: 0.39)).frame(width: 3, height: 3)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .frame(height: 8)
                .background(background)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(line)
                    .frame(width: 26, height: 2)
                RoundedRectangle(cornerRadius: 1)
                    .fill(line)
                    .frame(width: 18, height: 2)
                RoundedRectangle(cornerRadius: 1)
                    .fill(line)
                    .frame(width: 22, height: 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 32)
            .padding(.top, 14)
        }
    }
}
