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

    @State private var selectedSection: SettingsSection = .appearance
    @AppStorage("sonovo.theme") private var theme = "Standard"
    @AppStorage("sonovo.foregroundIntensity") private var foregroundIntensity =
        AppTheme.Preferences.foregroundIntensityDefault
    @AppStorage("sonovo.backgroundIntensity") private var backgroundIntensity =
        AppTheme.Preferences.backgroundIntensityDefault

    @AppStorage("sonovo.editorFontSize") private var editorFontSize =
        AppTheme.Preferences.editorFontSizeDefault
    @AppStorage("sonovo.markdownRendered") private var markdownRendered = true
    @AppStorage("sonovo.wrapLines") private var wrapLines = true
    @AppStorage("sonovo.codeTabWidth") private var codeTabWidth =
        AppTheme.Code.tabWidthDefault
    @AppStorage("sonovo.codeUsesTabs") private var codeUsesTabs = false
    @AppStorage("sonovo.codeWrapLines") private var codeWrapLines = false
    @AppStorage("sonovo.audioDevice") private var audioDevice = ""
    @AppStorage("sonovo.shell") private var shell = ""
    @AppStorage("sonovo.terminalFont") private var terminalFont = "SF Mono 12"
    @AppStorage("sonovo.loginShell") private var loginShell = true
    @AppStorage("sonovo.terminals.tmux") private var terminalTmux = true
    @State private var outputDevices: [AudioOutputDevice] = []
    @State private var editingCustomShell = false
    @State private var customShellDraft = ""
    @State private var customShellError: String?
    @State private var tmuxVersion: String?

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.label, systemImage: section.icon)
                    .tag(section)
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
            outputDevices = AudioOutputDevices.all()
        }
        .task {
            guard tmuxVersion == nil else { return }
            tmuxVersion = await Task.detached {
                LiveTmux.shared.version()
            }.value
        }
        .onChange(of: editorFontSize) { _, _ in
            postEditorPreferenceChange()
        }
        .onChange(of: wrapLines) { _, _ in
            postEditorPreferenceChange()
        }
        .onChange(of: terminalFont) { _, _ in
            GhosttyAppController.shared.reloadTerminalPreferences()
        }
        .onChange(of: shell) { _, _ in
            GhosttyAppController.shared.reloadTerminalPreferences()
        }
        .onChange(of: loginShell) { _, _ in
            GhosttyAppController.shared.reloadTerminalPreferences()
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
        switch selectedSection {
        case .general:
            generalPane
        case .appearance:
            appearancePane
        case .editor:
            editorPane
        case .reading:
            ReadingSettingsPane()
        case .audio:
            audioPane
        case .terminal:
            terminalPane
        case .about:
            aboutPane
        }
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

    private var codeTabWidthBinding: Binding<Int> {
        Binding(
            get: { AppTheme.Code.clampedTabWidth(codeTabWidth) },
            set: { codeTabWidth = AppTheme.Code.clampedTabWidth($0) }
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
                SettingsRow {
                    Toggle("Open Markdown rendered", isOn: $markdownRendered)
                    Text("Start in the rendered document view instead of source.")
                }
                SettingsRow {
                    Toggle("Wrap long lines", isOn: $wrapLines)
                    Text("Wrap source lines to the width of the editor.")
                }
            }

            SettingsGroup {
                SettingsRow {
                    HStack {
                        Text("Code tab width")
                        Spacer()
                        Stepper(
                            value: codeTabWidthBinding,
                            in: AppTheme.Code.tabWidthRange
                        ) {
                            Text("\(codeTabWidthBinding.wrappedValue)")
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                }
                SettingsRow {
                    Toggle("Insert tabs in code", isOn: $codeUsesTabs)
                    Text(
                        "Use tab characters instead of spaces when Tab is "
                            + "pressed in the code editor."
                    )
                }
                SettingsRow {
                    Toggle("Wrap code lines", isOn: $codeWrapLines)
                    Text(
                        "Wrap long code lines instead of scrolling "
                            + "horizontally."
                    )
                }
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
                SettingsRow {
                    HStack {
                        Text("Output device")
                        Spacer()
                        Picker("", selection: $audioDevice) {
                            Text("System Default").tag("")
                            ForEach(outputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                            if !audioDevice.isEmpty,
                               !outputDevices.contains(where: {
                                   $0.id == audioDevice
                               }) {
                                Text("Unavailable device")
                                    .tag(audioDevice)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Output device")
                        .frame(width: AppTheme.Layout.settingsPickerWidth)
                    }
                }
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
                        Picker("", selection: shellSelection) {
                            Text("System Default").tag("")
                            ForEach(TerminalShell.available()) { option in
                                Text(option.title).tag(option.path)
                            }
                            Text("Other…").tag(Self.customShellTag)
                        }
                        .labelsHidden()
                        .accessibilityLabel("Shell")
                        .frame(width: AppTheme.Layout.settingsPickerNarrowWidth)
                    }
                    Text("Starts \(Preferences.effectiveShell).")
                }
                if showsCustomShellRow {
                    SettingsRow {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.s6) {
                            HStack {
                                TextField(
                                    "/opt/homebrew/bin/zsh",
                                    text: $customShellDraft
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(
                                    maxWidth: AppTheme.Layout
                                        .settingsCustomShellWidth
                                )
                                Button("Use") { applyCustomShell() }
                            }
                            if let customShellError {
                                Text(customShellError)
                                    .font(.system(size: AppTheme.TypeScale.xs))
                                    .foregroundStyle(AppTheme.Palette.warning)
                            } else {
                                Text("An absolute path to an executable shell.")
                                    .font(.system(size: AppTheme.TypeScale.xs))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if Preferences.shellIsMissing {
                    SettingsRow {
                        Text(
                            "The selected shell is missing; the terminal "
                                + "uses \(TerminalShell.accountShell)."
                        )
                        .font(.system(size: AppTheme.TypeScale.xs))
                        .foregroundStyle(AppTheme.Palette.warning)
                    }
                }
                SettingsRow {
                    HStack {
                        Text("Font")
                        Spacer()
                        Picker("", selection: terminalFontFamily) {
                            ForEach(terminalFontFamilies, id: \.self) {
                                family in
                                Text(family).tag(family)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Terminal font")
                        .frame(width: AppTheme.Layout.settingsPickerTinyWidth)
                    }
                }
                SettingsRow {
                    HStack {
                        Text("Size")
                        Spacer()
                        Picker("", selection: terminalFontSize) {
                            ForEach(terminalFontSizes, id: \.self) { size in
                                Text("\(formatFontSize(size)) pt")
                                    .tag(size)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Terminal font size")
                        .frame(width: AppTheme.Layout.settingsPickerTinyWidth)
                    }
                }
                SettingsRow {
                    Toggle("Use login shell", isOn: $loginShell)
                    Text(
                        "On: reads zshenv, zprofile, zshrc, and zlogin. "
                            + "Off: skips zprofile and zlogin, so PATH "
                            + "setup there is not loaded."
                    )
                }
                SettingsRow {
                    Toggle("Keep terminals in tmux", isOn: $terminalTmux)
                    Text(
                        "Sessions outlive Sonovo and can be reattached "
                            + "over SSH. New tabs use tmux; existing tabs "
                            + "keep their mode."
                    )
                    if !LiveTmux.shared.isAvailable {
                        Text(
                            "tmux was not found. Install it with Homebrew "
                                + "to enable persistent sessions."
                        )
                        .foregroundStyle(AppTheme.Palette.warning)
                    }
                }
                SettingsRow {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.s6) {
                        HStack {
                            Text("Diagnostics")
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    diagnosticsText,
                                    forType: .string
                                )
                            }
                        }
                        Text(diagnosticsText)
                            .font(
                                .system(
                                    size: AppTheme.TypeScale.xs,
                                    design: .monospaced
                                )
                            )
                            .textSelection(.enabled)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Terminal settings

    private static let customShellTag = "__custom__"

    private var terminalFontParts: (family: String, size: Double) {
        TerminalPreferences.parsedFont(from: terminalFont)
            ?? ("SF Mono", 12)
    }

    private var terminalFontFamilies: [String] {
        var families = ["SF Mono", "Menlo"]
        let current = terminalFontParts.family
        if !families.contains(current) {
            families.append(current)
        }
        return families
    }

    private var terminalFontSizes: [Double] {
        let range = AppTheme.Preferences.terminalFontSizeRange
        var sizes = Array(
            stride(
                from: range.lowerBound,
                through: range.upperBound,
                by: AppTheme.Preferences.terminalFontSizeStep
            )
        )
        let current = terminalFontParts.size
        if !sizes.contains(current) {
            sizes.append(current)
            sizes.sort()
        }
        return sizes
    }

    private var terminalFontFamily: Binding<String> {
        Binding(
            get: { terminalFontParts.family },
            set: { family in
                terminalFont = "\(family) \(formatFontSize(terminalFontParts.size))"
            }
        )
    }

    private var terminalFontSize: Binding<Double> {
        Binding(
            get: {
                let range = AppTheme.Preferences.terminalFontSizeRange
                return min(
                    max(terminalFontParts.size, range.lowerBound),
                    range.upperBound
                )
            },
            set: { size in
                terminalFont =
                    "\(terminalFontParts.family) \(formatFontSize(size))"
            }
        )
    }

    private func formatFontSize(_ size: Double) -> String {
        size.rounded() == size
            ? String(Int(size))
            : String(format: "%.1f", size)
    }

    private var shellIsKnown: Bool {
        shell.isEmpty
            || TerminalShell.available().contains { $0.path == shell }
    }

    private var showsCustomShellRow: Bool {
        editingCustomShell || !shellIsKnown
    }

    private var shellSelection: Binding<String> {
        Binding(
            get: {
                shellIsKnown && !editingCustomShell
                    ? shell
                    : Self.customShellTag
            },
            set: { value in
                if value == Self.customShellTag {
                    editingCustomShell = true
                    if customShellDraft.isEmpty {
                        customShellDraft = shell
                    }
                } else {
                    editingCustomShell = false
                    customShellError = nil
                    shell = value
                }
            }
        )
    }

    private func applyCustomShell() {
        let path = customShellDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard path.hasPrefix("/") else {
            customShellError = "Enter an absolute path."
            return
        }
        guard TerminalShell.isUsable(path) else {
            customShellError = "No executable shell at that path."
            return
        }
        customShellError = nil
        shell = path
    }

    private var diagnosticsText: String {
        var lines: [String] = []
        let resolved = Preferences.effectiveShell
        if shell.isEmpty {
            lines.append("shell: \(resolved) (system default)")
        } else if TerminalShell.isUsable(shell) {
            lines.append("shell: \(resolved)")
        } else {
            lines.append(
                "shell: \(resolved) (configured \(shell) missing)"
            )
        }
        lines.append("login shell: \(loginShell ? "on" : "off")")
        let tmux = LiveTmux.shared
        if let path = tmux.executablePath {
            let version = tmuxVersion.map { " (\($0))" } ?? ""
            lines.append("tmux: \(path)\(version)")
        } else {
            lines.append("tmux: not found")
        }
        if let terminfo = Bundle.module.url(
            forResource: "terminfo",
            withExtension: nil
        ) {
            lines.append("terminfo: \(terminfo.path)")
        } else {
            lines.append("terminfo: missing")
        }
        lines.append(
            "attach: "
                + TmuxCommands.attachShellCommand(name: "<session>")
        )
        return lines.joined(separator: "\n")
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
