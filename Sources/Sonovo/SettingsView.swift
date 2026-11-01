import SonovoFeatureAPI
import SonovoWorkspaceHost
import SonovoDesignSystem
import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case editor
    case reading
    case audio
    case terminal
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .editor: "Editor"
        case .reading: "Reading"
        case .audio: "Audio"
        case .terminal: "Terminal"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .editor: "textformat"
        case .reading: "text.book.closed"
        case .audio: "waveform"
        case .terminal: "terminal"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Bindable var state: AppState

    @AppStorage("sonovo.appearance") private var appearance = "system"
    @AppStorage("sonovo.canvasInset") private var canvasInset = AppTheme.Canvas.comfortableInset
    @AppStorage("sonovo.canvasRadius") private var canvasRadius = AppTheme.Canvas.roundedRadius

    @State private var selectedSection = "appearance"
    @AppStorage("sonovo.theme") private var theme = "Standard"
    @AppStorage("sonovo.foregroundIntensity") private var foregroundIntensity =
        AppTheme.Preferences.foregroundIntensityDefault
    @AppStorage("sonovo.backgroundIntensity") private var backgroundIntensity =
        AppTheme.Preferences.backgroundIntensityDefault

    @AppStorage("sonovo.editorFontSize") private var editorFontSize =
        AppTheme.Preferences.editorFontSizeDefault
    @AppStorage(FontPreferences.readingFaceKey)
    private var readingFace = ReadingFace.theme.rawValue
    @AppStorage(FontPreferences.chineseFaceKey)
    private var readingChineseFace = FontPreferences.defaultChineseFace
    @AppStorage(FontPreferences.codeFamilyKey)
    private var codeFontFamily = ""
    @State private var nerdFontFamilies: [String] = []

    var body: some View {
        NavigationSplitView {
            List(navigationItems, selection: $selectedSection) { section in
                Label(section.label, systemImage: section.icon)
                    .tag(section.id)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(SidebarMaterialBackground())
            .navigationSplitViewColumnWidth(
                AppTheme.Layout.settingsSidebarWidth
            )
            .toolbar(removing: .sidebarToggle)
        } detail: {
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
        .task {
            nerdFontFamilies = NerdFonts.installedFamilies
        }
        .onChange(of: editorFontSize) { _, _ in
            postEditorPreferenceChange()
        }
    }

    /// Editors read the size and wrap mode when they build attributes. Tell
    /// the live ones so an open document updates without reopening.
    private func postEditorPreferenceChange() {
        NotificationCenter.default.post(
            name: .sonovoEditorPreferencesChanged,
            object: nil
        )
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
        if let page = state.liveProject.featureSessions.settings.first(where: { $0.slot == "page" && $0.sectionID == selectedSection }) {
            page.makeView()
        } else {
        switch selectedSection {
        case "general":
            generalPane
        case "appearance":
            appearancePane
        case "editor":
            editorPane
        case "reading":
            Text("Settings unavailable.")
        case "audio":
            audioPane
        case "terminal":
            Text("Settings unavailable.")
        case "about":
            aboutPane
        default:
            Text("Settings unavailable.")
        }
        }
    }

    private var navigationItems: [SettingsNavigationItem] {
        var items = SettingsSection.allCases.map { SettingsNavigationItem(id: $0.id, label: $0.label, icon: $0.icon) }
        let known = Set(items.map(\.id))
        var inserted = Set<String>()
        for pane in state.liveProject.featureSessions.settings where pane.slot == "page" && !known.contains(pane.sectionID) && inserted.insert(pane.sectionID).inserted {
            items.insert(SettingsNavigationItem(id: pane.sectionID, label: pane.title, icon: pane.icon), at: max(0, items.count - 1))
        }
        return items
    }
    @ViewBuilder private func featureSettings(slot: String) -> some View {
        ForEach(state.liveProject.featureSessions.settings.filter { $0.slot == slot }, id: \.id) { $0.makeView() }
    }

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            paneHeader(
                title: "About",
                detail: "What this app is, and what it is not."
            )

            HStack(spacing: AppTheme.Spacing.md) {
                Image(
                    nsImage: NSApp.applicationIconImage
                        ?? NSWorkspace.shared.icon(for: .application)
                )
                .resizable()
                .interpolation(.high)
                .frame(
                    width: AppTheme.Size.settingsAboutIconSize,
                    height: AppTheme.Size.settingsAboutIconSize
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Sonovo")
                        .font(
                            .system(
                                size: AppTheme.TypeScale.xxl,
                                weight: .semibold
                            )
                        )
                    Text("Version \(AppVersion.current)")
                        .font(.system(size: AppTheme.TypeScale.xs))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsGroup {
                SettingsRow {
                    Text("A personal macOS tool for my own use.")
                    Text(
                        "Not intended for anyone else to build, install, "
                            + "or depend on. There is no support, "
                            + "compatibility guarantee, or contribution "
                            + "process."
                    )
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                }
            }
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
                    Toggle("Restore open tabs", isOn: $state.restoreTabs)
                    Text("Reopen the file tabs from your last session.")
                }
                SettingsRow {
                    Toggle("Reopen last production", isOn: $state.reopenLast)
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

    /// A persisted size is untrusted. Clamp before converting it for display;
    /// an out-of-range double would trap in `Int(_:)`.
    private var editorFontSizePoints: Int {
        Int(Preferences.clampedEditorFontSize(editorFontSize).rounded())
    }

    /// Persisted values can be out of range (an older build, a hand-edited
    /// defaults file). The control edits and displays only a clamped value,
    /// so the same number reaches the editor that the label shows.
    private var editorFontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(Preferences.clampedEditorFontSize(editorFontSize)) },
            set: {
                editorFontSize = Double(
                    Preferences.clampedEditorFontSize(CGFloat($0))
                )
            }
        )
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
                            value: editorFontSizeBinding,
                            in: AppTheme.Preferences.editorFontSizeRange,
                            step: AppTheme.Preferences.editorFontSizeStep
                        ) {
                            Text("\(editorFontSizePoints) pt")
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                }
                SettingsRow {
                    Toggle("Show breadcrumbs", isOn: $state.showBreadcrumbs)
                    Text("Show the path to the current asset above the editor.")
                }
                featureSettings(slot: "editor.leading")




                SettingsRow {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        HStack {
                            Text("Reading typeface")
                            Spacer()
                            Picker("", selection: readingFaceSelection) {
                                ForEach(ReadingFace.installed) { face in
                                    Text(face.displayName).tag(face.rawValue)
                                }
                            }
                            .labelsHidden()
                            .accessibilityLabel("Reading typeface")
                            .frame(
                                width: AppTheme.Layout.settingsPickerWidth
                            )
                        }
                        Text(
                            "Overrides the theme's Latin face for body and "
                                + "headings. Follow theme keeps New York for "
                                + "Paper and Charter for Book and Editorial."
                        )
                        .font(.system(size: AppTheme.TypeScale.xs))
                        .foregroundStyle(.secondary)
                    }
                }
                SettingsRow {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        HStack {
                            Text("Chinese reading face")
                            Spacer()
                            Picker("", selection: chineseFaceSelection) {
                                ForEach(ChineseFace.installed) { face in
                                    Text(face.displayName).tag(face.fontName)
                                }
                            }
                            .labelsHidden()
                            .accessibilityLabel("Chinese reading face")
                            .frame(
                                width: AppTheme.Layout.settingsPickerWidth
                            )
                        }
                        Text(
                            "PingFang 简体 is the default. Each family ships "
                                + "in Simplified and Traditional cuts."
                        )
                        .font(.system(size: AppTheme.TypeScale.xs))
                        .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsGroup {
                SettingsRow {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        HStack {
                            Text("Code font")
                            Spacer()
                            Picker("", selection: $codeFontFamily) {
                                Text("System Mono (SF Mono)").tag("")
                                ForEach(nerdFontOptions, id: \.self) {
                                    family in
                                    Text(
                                        family == NerdFonts.recommendedFamily
                                            ? "\(family) (Recommended)"
                                            : family
                                    )
                                    .tag(family)
                                }
                            }
                            .labelsHidden()
                            .accessibilityLabel("Code font")
                            .frame(
                                width: AppTheme.Layout.settingsPickerWidth
                            )
                        }
                        if !codeFontFamily.isEmpty,
                           !AppFonts.isInstalled(codeFontFamily) {
                            Text(
                                "That font is not installed; the editor "
                                    + "falls back to system mono."
                            )
                            .font(.system(size: AppTheme.TypeScale.xs))
                            .foregroundStyle(AppTheme.Palette.warning)
                        }
                        NerdFontHelp()
                    }
                }
                featureSettings(slot: "editor.trailing")


            }
        }
    }

    private var audioPane: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            paneHeader(
                title: "Audio",
                detail: "Playback defaults for voice and music."
            )

            SettingsGroup {
                featureSettings(slot: "audio.device")
                SettingsRow {
                    Toggle("Follow playhead", isOn: $state.followPlayhead)
                    Text("Keep the selected transcript line aligned with playback.")
                }
                SettingsRow {
                    Toggle(
                        "Show captions by default",
                        isOn: $state.showCaptions
                    )
                    Text("Display the current transcript line over the video stage.")
                }
            }
        }
    }



    // MARK: - Terminal settings


    private var readingFaceSelection: Binding<String> {
        Binding(
            get: {
                ReadingFace(rawValue: readingFace)?.available.rawValue
                    ?? ReadingFace.theme.rawValue
            },
            set: { readingFace = $0 }
        )
    }

    private var chineseFaceSelection: Binding<String> {
        Binding(
            get: {
                ChineseFace.valid(fontName: readingChineseFace)
                    ?? FontPreferences.defaultChineseFace
            },
            set: { readingChineseFace = $0 }
        )
    }

    private var nerdFontOptions: [String] {
        var options = nerdFontFamilies
        if !codeFontFamily.isEmpty,
           !options.contains(codeFontFamily) {
            options.insert(codeFontFamily, at: 0)
        }
        return options
    }

























    private func paneHeader(title: String, detail: String) -> some View {
        SettingsPaneHeader(title: title, detail: detail)
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
                            .strokeBorder(Color.accentColor, lineWidth: AppTheme.BorderWidth.thick)
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

/// Installed font families with a monospaced member. Ghostty accepts a family
/// name, not a file path, so the picker offers only families the system can
/// resolve.

private struct SettingsNavigationItem: Identifiable { let id: String; let label: String; let icon: String }
