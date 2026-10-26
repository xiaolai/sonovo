import AppKit
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
            Button("Filter Navigator") {
                state.columnVisibility = .all
                state.focusSidebarFilter &+= 1
            }
            Button("Toggle Inspector") { state.inspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Last Used Tab") {
                state.liveProject.toggleLastUsedTab()
            }
            .keyboardShortcut(KeyEquivalent("\t"), modifiers: [.control])
            .disabled(state.liveProject.openTabs.count < 2)
            Button("Next Tab") {
                state.liveProject.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(state.liveProject.openTabs.count < 2)
            Button("Previous Tab") {
                state.liveProject.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(state.liveProject.openTabs.count < 2)
        }
        CommandGroup(after: .pasteboard) {
            // Bypasses the smart-paste chain entirely: the pasteboard's plain
            // string is inserted exactly, even when it carries HTML.
            Button("Paste as Plain Text") {
                NSApp.sendAction(
                    #selector(NSTextView.pasteAsPlainText(_:)),
                    to: nil,
                    from: nil
                )
            }
            .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            Button("Find") {
                if isRenderedModeSelected {
                    state.markdown.showRenderedFind()
                } else if canFind {
                    performFind(.showFindPanel)
                } else {
                    state.columnVisibility = .all
                    state.focusSidebarFilter &+= 1
                }
            }
            .keyboardShortcut("f", modifiers: [.command])
            Button("Find Next") {
                if isRenderedModeSelected {
                    state.markdown.stepRenderedFind(1)
                } else {
                    performFind(.next)
                }
            }
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(!canFind && !isRenderedModeSelected)
            Button("Find Previous") {
                if isRenderedModeSelected {
                    state.markdown.stepRenderedFind(-1)
                } else {
                    performFind(.previous)
                }
            }
            // The bar itself resolves Cmd+G / Shift+Cmd+G: AppKit ignores the
            // Shift flag when matching a lowercase equivalent, so both menu
            // items would otherwise resolve to Find Next.
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!canFind && !isRenderedModeSelected)
            Button("Replace…") { performTextFinder(.showReplaceInterface) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(!canReplace)
            Button("Replace All") { performFind(.replaceAll) }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(!canReplace)
        }
    }

    /// The selected Markdown source text view, if it is the surface Find
    /// should act on. Retained per-document text views make a key-window
    /// lookup unsafe; resolve through the workspace instead.
    private var markdownTextView: NSTextView? {
        guard state.selectedTab?.kind == .script,
              state.terminalPresentation != .full else {
            return nil
        }
        return state.markdown.sourceFindTarget()?.textView
    }

    private var canFind: Bool {
        markdownTextView != nil
    }

    /// The reading view owns Find when the document is rendered; the source
    /// editor keeps the native bar.
    private var isRenderedModeSelected: Bool {
        state.selectedTab?.kind == .script
            && state.terminalPresentation != .full
            && state.markdown.selectedDocument?.mode == .rendered
    }

    private var canReplace: Bool {
        guard let document = state.markdown.selectedDocument else {
            return false
        }
        return markdownTextView != nil && !document.isReadOnly
    }

    private func performFind(_ action: NSFindPanelAction) {
        guard let textView = markdownTextView else { return }
        // A menu action can run while SwiftUI still owns focus. Give the
        // editor focus first, then show the bar after the menu finishes
        // tracking so it is not dismissed by the menu teardown.
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        DispatchQueue.main.async {
            textView.performFindPanelAction(item)
        }
    }

    /// The find bar's replace controls live on NSTextFinderAction;
    /// NSFindPanelAction has no replace-panel case.
    private func performTextFinder(_ action: NSTextFinder.Action) {
        guard let textView = markdownTextView else { return }
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = action.rawValue
        DispatchQueue.main.async {
            textView.performTextFinderAction(item)
        }
    }
}

/// Media editing commands. Undo and redo deliberately use separate shortcuts
/// from the text editors so a media command can never consume a text undo.
@MainActor
struct MediaCommands: Commands {
    @Bindable var state: AppState

    var body: some Commands {
        CommandMenu("Media") {
            if state.isRecordingAudio {
                Button("Stop Recording") {
                    state.stopAudioRecording()
                }
            } else {
                Button("Record Audio…") {
                    Task { await state.startAudioRecording() }
                }
                .disabled(!state.canStartAudioRecording)
            }

            Divider()

            Button("Trim to Selection") {
                state.trimMediaSelection()
            }
            .disabled(!state.canTrimMediaSelection)

            Button("Delete Selection") {
                state.deleteMediaSelection()
            }
            .disabled(!state.canDeleteMediaSelection)

            Button("Reset Edit") {
                state.resetMediaEdit()
            }
            .disabled(!state.canResetMediaEdit)

            Divider()

            Button("Undo Media Edit") {
                state.undoMediaEdit()
            }
            .keyboardShortcut("z", modifiers: [.command, .option])
            .disabled(!state.canUndoMediaEdit)

            Button("Redo Media Edit") {
                state.redoMediaEdit()
            }
            .keyboardShortcut(
                "z",
                modifiers: [.command, .option, .shift]
            )
            .disabled(!state.canRedoMediaEdit)

            Divider()

            Button("Save Take") {
                Task { await state.saveMediaTake() }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(!state.canSaveMediaTake)

            Button("Replace Original…") {
                state.requestReplaceMediaOriginal()
            }
            .disabled(!state.canReplaceMediaOriginal)
        }
    }
}

/// Markdown document and formatting commands.
@MainActor
struct MarkdownCommands: Commands {    @Bindable var state: AppState

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
            Button("Export as HTML…") {
                state.markdown.exportSelected(as: .html)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!isMarkdownVisible)
            Button("Export as PDF…") {
                state.markdown.exportSelected(as: .pdf)
            }
            .disabled(!isMarkdownVisible)
            Divider()
            Group {
                Button("Bold") {
                    state.markdown.performSelected(.toggleStrong)
                }
                .keyboardShortcut("b", modifiers: [.command])
                Button("Italic") {
                    state.markdown.performSelected(.toggleEmphasis)
                }
                .keyboardShortcut("i", modifiers: [.command])
                Button("Inline Code") {
                    state.markdown.performSelected(.toggleInlineCode)
                }
                .keyboardShortcut("e", modifiers: [.command])
                Button("Strikethrough") {
                    state.markdown.performSelected(.toggleStrikethrough)
                }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Highlight") {
                    state.markdown.performSelected(.toggleHighlight)
                }
                Button("Underline") {
                    state.markdown.performSelected(.toggleUnderline)
                }
                Button("Superscript") {
                    state.markdown.performSelected(.toggleSuperscript)
                }
                Button("Subscript") {
                    state.markdown.performSelected(.toggleSubscript)
                }
                Menu("Heading") {
                    ForEach(1...6, id: \.self) { level in
                        Button("Heading \(level)") {
                            state.markdown.performSelected(
                                .toggleHeading(level: level)
                            )
                        }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(level)")),
                            modifiers: [.command, .option]
                        )
                    }
                }
                Button("Block Quote") {
                    state.markdown.performSelected(.toggleBlockQuote)
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                Menu("List") {
                    Button("Bullet") {
                        state.markdown.performSelected(
                            .toggleList(kind: .bullet)
                        )
                    }
                    .keyboardShortcut("8", modifiers: [.command, .shift])
                    Button("Numbered") {
                        state.markdown.performSelected(
                            .toggleList(kind: .ordered)
                        )
                    }
                    .keyboardShortcut("7", modifiers: [.command, .shift])
                    Button("Task") {
                        state.markdown.performSelected(
                            .toggleList(kind: .task)
                        )
                    }
                    .keyboardShortcut("9", modifiers: [.command, .shift])
                }
                Button("Insert Link") {
                    state.markdown.presentLinkPopoverOnSelected()
                }
                .keyboardShortcut("k", modifiers: [.command])
                Button("Insert Wiki Link") {
                    state.markdown.performSelected(
                        .insertWikiLink(target: "", alias: nil)
                    )
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Insert Details") {
                    state.markdown.performSelected(
                        .insertDetails(summary: "Details")
                    )
                }
                Button("Insert TOC") {
                    state.markdown.performSelected(.insertTOC)
                }
                Menu("Table") {
                    Button("Insert Table") {
                        state.markdown.performSelected(
                            .insertTable(rows: 2, columns: 2)
                        )
                    }
                    Divider()
                    Button("Insert Row Above") {
                        state.markdown.performSelected(
                            .insertTableRowAbove
                        )
                    }
                    Button("Insert Row Below") {
                        state.markdown.performSelected(
                            .insertTableRowBelow
                        )
                    }
                    Button("Delete Row") {
                        state.markdown.performSelected(.deleteTableRow)
                    }
                    Divider()
                    Button("Insert Column Left") {
                        state.markdown.performSelected(
                            .insertTableColumnLeft
                        )
                    }
                    Button("Insert Column Right") {
                        state.markdown.performSelected(
                            .insertTableColumnRight
                        )
                    }
                    Button("Delete Column") {
                        state.markdown.performSelected(.deleteTableColumn)
                    }
                    Divider()
                    Menu("Align Column") {
                        Button("None") {
                            state.markdown.performSelected(
                                .setTableAlignment(.none)
                            )
                        }
                        Button("Left") {
                            state.markdown.performSelected(
                                .setTableAlignment(.left)
                            )
                        }
                        Button("Center") {
                            state.markdown.performSelected(
                                .setTableAlignment(.center)
                            )
                        }
                        Button("Right") {
                            state.markdown.performSelected(
                                .setTableAlignment(.right)
                            )
                        }
                    }
                    Button("Format Table") {
                        state.markdown.performSelected(.formatTable)
                    }
                    Divider()
                    Button("Delete Table") {
                        state.markdown.performSelected(.deleteTable)
                    }
                }
                Menu("Lines") {
                    Button("Move Up") {
                        state.markdown.performSelected(.lineUp)
                    }
                    Button("Move Down") {
                        state.markdown.performSelected(.lineDown)
                    }
                    Button("Duplicate") {
                        state.markdown.performSelected(.duplicateLine)
                    }
                    Button("Delete") {
                        state.markdown.performSelected(.deleteLine)
                    }
                    Button("Join") {
                        state.markdown.performSelected(.joinLines)
                    }
                    Divider()
                    Button("Remove Blank Lines") {
                        state.markdown.performSelected(.removeBlankLines)
                    }
                    Button("Collapse Blank Lines") {
                        state.markdown.performSelected(.collapseBlankLines)
                    }
                    Button("Remove Trailing Spaces") {
                        state.markdown.performSelected(.trimTrailingSpaces)
                    }
                    Divider()
                    Button("Sort Ascending") {
                        state.markdown.performSelected(.sortLinesAscending)
                    }
                    Button("Sort Descending") {
                        state.markdown.performSelected(.sortLinesDescending)
                    }
                    Divider()
                    Button("Uppercase") {
                        state.markdown.performSelected(.uppercase)
                    }
                    Button("Lowercase") {
                        state.markdown.performSelected(.lowercase)
                    }
                    Button("Title Case") {
                        state.markdown.performSelected(.titleCase)
                    }
                    Button("Toggle Case") {
                        state.markdown.performSelected(.toggleCase)
                    }
                }
                Menu("Text") {
                    Button("Format CJK Spacing") {
                        state.markdown.performSelected(.formatCJK)
                    }
                }
            }
            .disabled(!canFormatMarkdown)
            Divider()
            Button("Check Markdown") {
                state.markdown.checkSelectedMarkdown()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(!isMarkdownVisible)
            Button("Next Problem") {
                state.markdown.goToNextProblem()
            }
            .keyboardShortcut(KeyEquivalent("\u{F705}"), modifiers: [])
            .disabled(!isMarkdownVisible)
            Button("Previous Problem") {
                state.markdown.goToPreviousProblem()
            }
            .keyboardShortcut(KeyEquivalent("\u{F705}"), modifiers: [.shift])
            .disabled(!isMarkdownVisible)
            Button("Command Palette") {
                state.markdown.togglePalette()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!isMarkdownVisible)
            Button("Quick Open…") {
                state.markdown.isQuickOpenVisible = true
            }
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(!isMarkdownVisible)
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
            && state.markdown.selectedDocument?.isSourceOnly == false
            && isSourceEditorFocused
    }

    /// The focused surface decides ownership. A terminal, find field, or
    /// popover must not receive a Markdown formatting action even when a
    /// Markdown tab is selected.
    private var isSourceEditorFocused: Bool {
        guard let document = state.markdown.selectedDocument else {
            return false
        }
        guard let responder = NSApp.keyWindow?.firstResponder as? NSTextView
        else {
            return false
        }
        return responder === state.markdown.controller(for: document).textView
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
                state.revealSubtitleDocument(document)
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
                state.revealModelDocument(document)
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

/// Project timeline commands. The timeline stays optional: it never replaces
/// source playback for ordinary media tabs.
@MainActor
struct TimelineCommands: Commands {
    @Bindable var state: AppState

    private var timeline: TimelineDocument? {
        state.liveProject.timelines.document
    }

    var body: some Commands {
        CommandMenu("Timeline") {
            Button("New Timeline") {
                state.newTimeline()
            }
            .disabled(state.liveProject.isDemo)
            Divider()
            Button("Save Timeline") {
                state.liveProject.timelines.save()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(timeline?.hasUnsavedChanges != true)
            Button("Undo Timeline Edit") {
                _ = timeline?.undo()
            }
            .keyboardShortcut("z", modifiers: [.command, .option])
            .disabled(timeline?.canUndo != true)
            Button("Redo Timeline Edit") {
                _ = timeline?.redo()
            }
            .keyboardShortcut(
                "z",
                modifiers: [.command, .option, .shift]
            )
            .disabled(timeline?.canRedo != true)
        }
    }
}

/// Embedded terminal commands.
@MainActor
struct TerminalCommands: Commands {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Terminal") {
            Button("Manage Sessions…") {
                openWindow(id: "sessions")
            }

            Divider()

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
