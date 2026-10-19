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
    @AppStorage("sonovo.canvasInset") private var canvasInset = AppTheme.Canvas.comfortableInset
    @AppStorage("sonovo.canvasRadius") private var canvasRadius = AppTheme.Canvas.roundedRadius

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
        HStack(spacing: AppTheme.Spacing.zero) {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.label, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(SidebarMaterialBackground())
            .frame(width: AppTheme.Layout.settingsSidebarWidth)

            ScrollView {
                detailPane
                    .padding(AppTheme.Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.appWindow)
        }
        .frame(width: AppTheme.Layout.settingsWidth, height: AppTheme.Layout.settingsHeight)
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
                SettingsRow {
                    Toggle("Confirm before closing", isOn: $confirmClose)
                    Text("Ask before closing a production with unsaved changes.")
                }
                SettingsRow {
                    Toggle("Reopen last production", isOn: $reopenLast)
                    Text("Open the most recent production at launch.")
                }
            }

            Text("Sonovo \(AppVersion.current)")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.tertiary)
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
                            HStack(spacing: AppTheme.Spacing.xs) {
                                Text(theme)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: AppTheme.TypeScale.micro, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                SettingsRow {
                    HStack(spacing: AppTheme.Spacing.md) {
                        Text("Foreground")
                            .frame(width: AppTheme.Layout.settingsRowLabelWidth, alignment: .leading)
                        Slider(value: $foregroundIntensity, in: AppTheme.Preferences.unitRange)
                            .accessibilityLabel("Foreground intensity")
                        RoundedRectangle(cornerRadius: AppTheme.Radius.micro)
                            .fill(
                                Color.accentColor.opacity(
                                    AppTheme.Opacity.settingsForegroundBase
                                        + foregroundIntensity * AppTheme.Opacity.settingsForegroundRange
                                )
                            )
                            .frame(width: AppTheme.Size.settingsSwatchWidth, height: AppTheme.Size.settingsSwatchHeight)
                    }
                }
                SettingsRow {
                    HStack(spacing: AppTheme.Spacing.md) {
                        Text("Background")
                            .frame(width: AppTheme.Layout.settingsRowLabelWidth, alignment: .leading)
                        Slider(value: $backgroundIntensity, in: AppTheme.Preferences.unitRange)
                            .accessibilityLabel("Background intensity")
                        RoundedRectangle(cornerRadius: AppTheme.Radius.micro)
                            .fill(
                                Color.accentColor.opacity(
                                    AppTheme.Opacity.settingsBackgroundBase
                                        + backgroundIntensity * AppTheme.Opacity.settingsBackgroundRange
                                )
                            )
                            .frame(width: AppTheme.Size.settingsSwatchWidth, height: AppTheme.Size.settingsSwatchHeight)
                    }
                }
            }

            SettingsGroup {
                SettingsRow {
                    HStack {
                        Text("Canvas breathing room")
                        Spacer()
                        Picker("Canvas breathing room", selection: $canvasInset) {
                            Text("Compact").tag(AppTheme.Canvas.compactInset)
                            Text("Comfortable").tag(AppTheme.Canvas.comfortableInset)
                            Text("Spacious").tag(AppTheme.Canvas.spaciousInset)
                        }
                        .labelsHidden()
                        .frame(width: AppTheme.Layout.settingsPickerWidth)
                        .accessibilityLabel("Canvas breathing room")
                    }
                }
                SettingsRow {
                    HStack {
                        Text("Canvas corners")
                        Spacer()
                        Picker("Canvas corners", selection: $canvasRadius) {
                            Text("Square").tag(AppTheme.Canvas.squareRadius)
                            Text("Rounded").tag(AppTheme.Canvas.roundedRadius)
                            Text("Extra rounded").tag(AppTheme.Canvas.extraRadius)
                        }
                        .labelsHidden()
                        .frame(width: AppTheme.Layout.settingsPickerWidth)
                        .accessibilityLabel("Canvas corners")
                    }
                }
            }

            Text("Spacing adds breathing room between the editor canvas and its surrounding chrome. Corners use the same radius as the cards. In dark appearance the workspace shares one surface, so the canvas edge is intentionally quiet.")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.tertiary)

            Text("Themes are derived from a base palette. Individual colors stay editable per workspace.")
                .font(.system(size: AppTheme.TypeScale.xs))
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
                        Stepper(
                            value: $editorFontSize,
                            in: AppTheme.Preferences.editorFontSizeRange,
                            step: AppTheme.Preferences.editorFontSizeStep
                        ) {
                            Text("\(Int(editorFontSize)) pt")
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                }
                SettingsRow {
                    Toggle("Show breadcrumbs", isOn: $showBreadcrumbs)
                    Text("Show the path to the current asset above the editor.")
                }
                SettingsRow {
                    Toggle("Open Markdown rendered", isOn: $markdownRendered)
                    Text("Start in the rendered document view instead of source.")
                }
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
                        .accessibilityLabel("Output device")
                        .frame(width: AppTheme.Layout.settingsPickerWidth)
                    }
                }
                SettingsRow {
                    HStack {
                        Text("Sample rate")
                        Spacer()
                        Picker("", selection: $sampleRate) {
                            Text("48 kHz").tag("48 kHz")
                            Text("44.1 kHz").tag("44.1 kHz")
                        }
                        .labelsHidden()
                        .accessibilityLabel("Sample rate")
                        .frame(width: AppTheme.Layout.settingsPickerCompactWidth)
                    }
                }
                SettingsRow {
                    Toggle("Follow playhead", isOn: $followPlayhead)
                    Text("Keep the selected transcript line aligned with playback.")
                }
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
                        .accessibilityLabel("Shell")
                        .frame(width: AppTheme.Layout.settingsPickerNarrowWidth)
                    }
                }
                SettingsRow {
                    HStack {
                        Text("Font")
                        Spacer()
                        Picker("", selection: $terminalFont) {
                            Text("SF Mono 12").tag("SF Mono 12")
                            Text("Menlo 12").tag("Menlo 12")
                        }
                        .labelsHidden()
                        .accessibilityLabel("Terminal font")
                        .frame(width: AppTheme.Layout.settingsPickerTinyWidth)
                    }
                }
                SettingsRow {
                    Toggle("Use login shell", isOn: $loginShell)
                    Text("Start the terminal as a login shell so your profile is loaded.")
                }
            }
        }
    }

    private func paneHeader(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title)
                .font(.system(size: AppTheme.TypeScale.xl, weight: .semibold))
            Text(detail)
                .font(.system(size: AppTheme.TypeScale.sm))
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
        VStack(spacing: AppTheme.Spacing.zero) {
            content
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                .fill(Color.appCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
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
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s3) {
            content
        }
        .font(.system(size: AppTheme.TypeScale.sm))
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
                    RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                        .fill(Color.appWindow)

                    preview
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
                        .padding(AppTheme.Spacing.s5)

                    if isSelected {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    } else {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                            .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
                    }
                }
                .frame(height: AppTheme.Size.settingsPreviewHeight)

                Text(mode.title)
                    .font(.system(size: AppTheme.TypeScale.xs, weight: isSelected ? .semibold : .regular))
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
            HStack(spacing: AppTheme.Spacing.zero) {
                MiniWindow(isDark: false)
                Rectangle()
                    .fill(AppTheme.Palette.black.opacity(AppTheme.Opacity.border))
                    .frame(width: AppTheme.BorderWidth.thin)
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
        let background = isDark
            ? AppTheme.Palette.MiniWindow.darkBackground
            : AppTheme.Palette.MiniWindow.lightBackground
        let sidebar = isDark
            ? AppTheme.Palette.MiniWindow.darkSidebar
            : AppTheme.Palette.MiniWindow.lightSidebar
        let content = isDark
            ? AppTheme.Palette.MiniWindow.darkContent
            : AppTheme.Palette.MiniWindow.lightContent
        let line = isDark ? AppTheme.Palette.white.opacity(AppTheme.Opacity.soft) : AppTheme.Palette.black.opacity(AppTheme.Opacity.faint)

        return ZStack {
            background

            HStack(spacing: AppTheme.Spacing.zero) {
                sidebar
                    .frame(width: AppTheme.Size.miniWindowSidebar)
                content
            }

            VStack(spacing: AppTheme.Spacing.zero) {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Circle()
                        .fill(AppTheme.Palette.MiniWindow.trafficRed)
                        .frame(width: AppTheme.Size.miniWindowTrafficDot, height: AppTheme.Size.miniWindowTrafficDot)
                    Circle()
                        .fill(AppTheme.Palette.MiniWindow.trafficYellow)
                        .frame(width: AppTheme.Size.miniWindowTrafficDot, height: AppTheme.Size.miniWindowTrafficDot)
                    Circle()
                        .fill(AppTheme.Palette.MiniWindow.trafficGreen)
                        .frame(width: AppTheme.Size.miniWindowTrafficDot, height: AppTheme.Size.miniWindowTrafficDot)
                    Spacer()
                }
                .padding(.horizontal, AppTheme.Spacing.xs)
                .frame(height: AppTheme.Size.miniWindowTitlebarHeight)
                .background(background)

                Spacer()
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                RoundedRectangle(cornerRadius: AppTheme.Radius.line)
                    .fill(line)
                    .frame(width: AppTheme.Size.miniWindowLineLong, height: AppTheme.Size.miniWindowLineHeight)
                RoundedRectangle(cornerRadius: AppTheme.Radius.line)
                    .fill(line)
                    .frame(width: AppTheme.Size.miniWindowLineShort, height: AppTheme.Size.miniWindowLineHeight)
                RoundedRectangle(cornerRadius: AppTheme.Radius.line)
                    .fill(line)
                    .frame(width: AppTheme.Size.miniWindowLineMedium, height: AppTheme.Size.miniWindowLineHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, AppTheme.Spacing.xxl)
            .padding(.top, AppTheme.Spacing.s14)
        }
    }
}
