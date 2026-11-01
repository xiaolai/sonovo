import AppKit
import SwiftUI
import SonovoDesignSystem

struct TerminalSettingsPane: View {
    @AppStorage("sonovo.shell") private var shell = ""
    @AppStorage("sonovo.terminalFont") private var terminalFont = "SF Mono 12"
    @AppStorage("sonovo.loginShell") private var loginShell = true
    @AppStorage(TerminalPreferences.tmuxKey) private var terminalTmux = false
    @State private var terminalFontCatalog: [String] = []
    @State private var editingCustomShell = false
    @State private var customShellDraft = ""
    @State private var customShellError: String?
    @State private var tmuxVersion: String?

    var body: some View {
        terminalPane
            .task { terminalFontCatalog = TerminalFontCatalog.monospacedFamilies() }
            .task {
                guard tmuxVersion == nil else { return }
                tmuxVersion = await Task.detached { LiveTmux.shared.version() }.value
            }
            .onChange(of: terminalFont) { _, _ in GhosttyAppController.shared.reloadTerminalPreferences() }
            .onChange(of: shell) { _, _ in GhosttyAppController.shared.reloadTerminalPreferences() }
            .onChange(of: loginShell) { _, _ in GhosttyAppController.shared.reloadTerminalPreferences() }
    }
    private var terminalPane: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            SettingsPaneHeader(
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
                        .frame(width: AppTheme.Layout.settingsPickerWidth)
                    }
                }
                SettingsRow {
                    NerdFontHelp()
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
                        "Off by default. Sessions outlive Sonovo and can be "
                            + "reattached over SSH. New tabs use tmux when "
                            + "enabled; existing tabs keep their mode."
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

    private static let customShellTag = "__custom__"


    private var terminalFontParts: (family: String, size: Double) {
        TerminalPreferences.parsedFont(from: terminalFont)
            ?? ("SF Mono", 12)
    }

    private var terminalFontFamilies: [String] {
        let preferred = ["SF Mono", "Menlo", "Monaco"]
        let installed = terminalFontCatalog.isEmpty
            ? preferred
            : terminalFontCatalog
        var families = preferred.filter { installed.contains($0) }
            + installed.filter { !preferred.contains($0) }
        let current = terminalFontParts.family
        if !families.contains(current) {
            families.insert(current, at: 0)
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
        if let terminfo = TerminalResources.bundle?.url(
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
}

private enum TerminalFontCatalog {
    static func monospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let members = manager.availableMembers(
                ofFontFamily: family
            ) else {
                return false
            }
            return members.contains { member in
                guard let name = member.first as? String,
                      let font = NSFont(name: name, size: AppTheme.TypeScale.body) else {
                    return false
                }
                return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
            }
        }
        .sorted()
    }
}
