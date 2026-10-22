import SwiftUI

/// Document-level menu commands: saving, new takes, sidebar, inspector.
@MainActor
struct DocumentCommands: Commands {
    @Bindable var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                Task { await state.saveSelectedDocument() }
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!state.canSaveSelectedDocument)
            Button("Save As…") {
                Task { await state.saveSelectedDocumentAs() }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!state.canSaveSelectedDocumentAs)
        }
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") { state.inspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}

/// Markdown document and formatting commands.
@MainActor
struct MarkdownCommands: Commands {
    @Bindable var state: AppState

    var body: some Commands {
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
                .disabled(!isMarkdownVisible)
            Divider()
            Group {
                Button("Bold") {
                    state.markdown.performSelected(.toggleStrong)
                }
                Button("Italic") {
                    state.markdown.performSelected(.toggleEmphasis)
                }
                Button("Inline Code") {
                    state.markdown.performSelected(.toggleInlineCode)
                }
                Button("Strikethrough") {
                    state.markdown.performSelected(.toggleStrikethrough)
                }
                Menu("Heading") {
                    ForEach(1...6, id: \.self) { level in
                        Button("Heading \(level)") {
                            state.markdown.performSelected(
                                .toggleHeading(level: level)
                            )
                        }
                    }
                }
                Button("Block Quote") {
                    state.markdown.performSelected(.toggleBlockQuote)
                }
                Menu("List") {
                    Button("Bullet") {
                        state.markdown.performSelected(
                            .toggleList(kind: .bullet)
                        )
                    }
                    Button("Numbered") {
                        state.markdown.performSelected(
                            .toggleList(kind: .ordered)
                        )
                    }
                    Button("Task") {
                        state.markdown.performSelected(
                            .toggleList(kind: .task)
                        )
                    }
                }
                Button("Insert Link") {
                    state.markdown.performSelected(
                        .insertLink(destination: "")
                    )
                }
                Button("Insert Wiki Link") {
                    state.markdown.performSelected(
                        .insertWikiLink(target: "", alias: nil)
                    )
                }
                Button("Insert Details") {
                    state.markdown.performSelected(
                        .insertDetails(summary: "Details")
                    )
                }
                Button("Insert TOC") {
                    state.markdown.performSelected(.insertTOC)
                }
            }
            .disabled(!canFormatMarkdown)
        }
    }

    /// Mode switching changes the document the selected tab is showing; it
    /// must not act on a hidden workspace behind another tab or the terminal.
    private var isMarkdownVisible: Bool {
        state.selectedTab?.kind == .script
            && state.terminalPresentation != .full
    }

    /// Formatting commands act on the visible, editable Markdown source
    /// editor. With another tab selected they would modify a hidden document.
    private var canFormatMarkdown: Bool {
        state.selectedTab?.kind == .script
            && state.terminalPresentation != .full
            && state.markdown.selectedDocument?.mode == .source
            && state.markdown.selectedDocument?.isReadOnly == false
    }
}

/// Subtitle editor commands.
@MainActor
struct SubtitleCommands: Commands {
    @Bindable var state: AppState

    var body: some Commands {
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
                // Capture the document before revealing the workspace; the
                // reveal can select a different subtitle tab.
                guard let document = state.subtitles.selectedDocument else {
                    return
                }
                state.showSubtitleWorkspace()
                state.subtitles.presentOpenMediaPanel(for: document)
            }
            .disabled(state.subtitles.selectedDocument == nil)
            Divider()
            Button("Close Document") {
                Task { await state.subtitles.closeSelected() }
            }
            .disabled(state.subtitles.selectedDocument == nil)
        }
    }
}

/// 3D viewer commands.
@MainActor
struct Model3DCommands: Commands {
    @Bindable var state: AppState

    var body: some Commands {
        CommandMenu("3D") {
            Button("Show 3D Viewer") {
                state.showModel3DWorkspace()
            }
            Button("Open Model…") {
                state.showModel3DWorkspace()
                state.models.presentOpenPanel()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Button("Reload Model") {
                state.models.reloadSelected()
            }
            .disabled(state.models.selectedDocument == nil)
            Button("Convert with Blender…") {
                // The reveal can change the selected model tab; convert the
                // one the enabled state was evaluated against.
                guard let document = state.models.selectedDocument else {
                    return
                }
                state.showModel3DWorkspace()
                state.models.convert(document)
            }
            .disabled(
                state.models.selectedDocument?
                    .format.canConvertWithBlender != true
                    || state.models.blenderInstallation == nil
            )
            Divider()
            Button("Close Model") {
                Task { await state.models.closeSelected() }
            }
            .disabled(state.models.selectedDocument == nil)
        }
    }
}

/// Embedded terminal commands.
@MainActor
struct TerminalCommands: Commands {
    @Bindable var state: AppState

    var body: some Commands {
        CommandMenu("Terminal") {
            Button("Toggle Terminal") {
                state.terminalPresentation =
                    state.terminalPresentation == .hidden ? .split : .hidden
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
                NotificationCenter.default.post(
                    name: .sonovoRestartTerminal,
                    object: nil
                )
            }
        }
    }
}
