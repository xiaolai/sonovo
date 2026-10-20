import AppKit
import SwiftUI

@main
struct SonovoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()
    @AppStorage("sonovo.appearance") private var appearance = "system"

    var body: some Scene {
        // One window, one AppState. A WindowGroup would give every window the
        // same cached AppKit editor and terminal views, which cannot be
        // mounted in two windows at once.
        Window("Sonovo", id: "main") {
            MainWindow(state: state)
                .environment(state)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: AppTheme.Layout.windowMinWidth, minHeight: AppTheme.Layout.windowMinHeight)
                .background(WindowChromeConfigurator())
        }
        .defaultSize(
            width: AppTheme.Layout.windowDefaultWidth,
            height: AppTheme.Layout.windowDefaultHeight
        )
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    Task { await state.saveSelectedDocument() }
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!state.canSaveSelectedDocument)
                Button("Save As…") {
                    Task { await state.markdown.saveSelectedAs() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(
                    state.selectedTab?.kind != .script
                        || state.terminalPresentation == .full
                )
            }
            CommandGroup(after: .newItem) {
                Button("New Take") { state.newTake() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            SidebarCommands()
            CommandGroup(after: .sidebar) {
                Button("Toggle Inspector") { state.inspectorVisible.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
            CommandMenu("Markdown") {
                Button("New Document") {
                    state.showMarkdownWorkspace()
                    state.markdown.newDocument()
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                Button("Open…") {
                    state.showMarkdownWorkspace()
                    state.markdown.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("Open Folder…") {
                    state.showMarkdownWorkspace()
                    state.markdown.presentOpenFolderPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Toggle Source/Rendered") { state.markdown.toggleMode() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Group {
                    Button("Bold") { state.markdown.performSelected(.toggleStrong) }
                    Button("Italic") { state.markdown.performSelected(.toggleEmphasis) }
                    Button("Inline Code") { state.markdown.performSelected(.toggleInlineCode) }
                    Button("Strikethrough") { state.markdown.performSelected(.toggleStrikethrough) }
                    Menu("Heading") {
                        ForEach(1...6, id: \.self) { level in
                            Button("Heading \(level)") {
                                state.markdown.performSelected(.toggleHeading(level: level))
                            }
                        }
                    }
                    Button("Block Quote") { state.markdown.performSelected(.toggleBlockQuote) }
                    Menu("List") {
                        Button("Bullet") { state.markdown.performSelected(.toggleList(kind: .bullet)) }
                        Button("Numbered") { state.markdown.performSelected(.toggleList(kind: .ordered)) }
                        Button("Task") { state.markdown.performSelected(.toggleList(kind: .task)) }
                    }
                    Button("Insert Link") {
                        state.markdown.performSelected(.insertLink(destination: ""))
                    }
                    Button("Insert Wiki Link") {
                        state.markdown.performSelected(.insertWikiLink(target: "", alias: nil))
                    }
                    Button("Insert Details") {
                        state.markdown.performSelected(.insertDetails(summary: "Details"))
                    }
                    Button("Insert TOC") { state.markdown.performSelected(.insertTOC) }
                }
                .disabled(!canFormatMarkdown)
            }

            CommandMenu("Subtitles") {
                Button("Show Subtitle Editor") {
                    state.showSubtitleWorkspace()
                }
                Button(
                    state.subtitles.previewMode == .collapsed
                        ? "Show Video"
                        : "Hide Video"
                ) {
                    state.subtitles.togglePreviewMode()
                }
                Button("Open Subtitle…") {
                    state.showSubtitleWorkspace()
                    state.subtitles.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .option])
                Button("Open Media…") {
                    state.showSubtitleWorkspace()
                    guard let document = state.subtitles.selectedDocument else {
                        return
                    }
                    state.subtitles.presentOpenMediaPanel(for: document)
                }
                .disabled(state.subtitles.selectedDocument == nil)
                Divider()
                Button("Close Document") {
                    Task { await state.subtitles.closeSelected() }
                }
                .disabled(state.subtitles.selectedDocument == nil)
            }

            CommandMenu("Terminal") {
                Button("Toggle Terminal") {
                    state.terminalPresentation = state.terminalPresentation == .hidden ? .split : .hidden
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

                Picker("Dock", selection: $state.terminalDock) {
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
                    NotificationCenter.default.post(name: .sonovoRestartTerminal, object: nil)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(state)
                .background(WindowChromeConfigurator())
        }
    }

    /// Formatting commands act on the visible, editable Markdown source
    /// editor. With another tab selected they would modify a hidden document.
    private var canFormatMarkdown: Bool {
        state.selectedAssetID == "script-md"
            && state.terminalPresentation != .full
            && state.markdown.selectedDocument?.mode == .source
            && state.markdown.selectedDocument?.isReadOnly == false
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        switch ProcessInfo.processInfo.environment["SONOVO_APPEARANCE"] {
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        default:
            break
        }

        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            for window in NSApp.windows {
                configureWindowChrome(window)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private var terminationPending = false

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        let subtitles = SubtitleWorkspaceRegistry.active
        let markdown = MarkdownWorkspaceRegistry.active
        let subtitleDirty = subtitles?.hasDirtyDocuments ?? false
        let markdownDirty = markdown?.hasDirtyDocuments ?? false
        guard subtitleDirty || markdownDirty else {
            return .terminateNow
        }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Subtitle documents always have a path: flush them first, and
            // refuse the quit outright if one cannot be saved. There is no
            // second unsaved-changes decision for them.
            if let subtitles, subtitles.hasDirtyDocuments {
                let saved = await subtitles.flushAllForTermination()
                guard saved else {
                    self.terminationPending = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }

            guard let markdown, markdown.hasDirtyDocuments else {
                self.terminationPending = false
                sender.reply(toApplicationShouldTerminate: true)
                return
            }

            let canTerminate = await markdown.flushAllForTermination()
            if canTerminate {
                self.terminationPending = false
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            guard markdown.pendingClose != nil else {
                // The flush failed without a decision to ask about; there is
                // nothing left to wait for.
                self.terminationPending = false
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            // A document needs a decision. Reply only after the user answers
            // the close alert, so Save or Discard can resume the quit instead
            // of cancelling it silently.
            markdown.onTerminationResolved = { [weak self] allowed in
                guard let self else { return }
                self.terminationPending = false
                sender.reply(toApplicationShouldTerminate: allowed)
            }
        }
        return .terminateLater
    }
}


private func configureWindowChrome(_ window: NSWindow) {
    window.titlebarSeparatorStyle = .none
    window.toolbar?.showsBaselineSeparator = false
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configureWindowChrome(window)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window {
                configureWindowChrome(window)
            }
        }
    }
}
