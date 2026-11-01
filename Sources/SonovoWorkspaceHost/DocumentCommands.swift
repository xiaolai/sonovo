import SonovoDomainTypes
import AppKit
import SwiftUI

/// Document-level menu commands: saving, new takes, sidebar, inspector.
@MainActor
package struct DocumentCommands: Commands {
    package init(state: AppState) { self.state = state }
    @Bindable var state: AppState

    package var body: some Commands {
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
                if !state.performEditorCommand(.find) {
                    state.columnVisibility = .all
                    state.focusSidebarFilter &+= 1
                }
            }
            .keyboardShortcut("f", modifiers: [.command])
            Button("Find Next") { state.performEditorCommand(.findNext) }
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(!state.canPerformEditorCommand(.findNext))
            Button("Find Previous") { state.performEditorCommand(.findPrevious) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!state.canPerformEditorCommand(.findPrevious))
            Button("Replace…") { state.performEditorCommand(.replace) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(!state.canPerformEditorCommand(.replace))
            Button("Replace All") { state.performEditorCommand(.replaceAll) }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(!state.canPerformEditorCommand(.replaceAll))
        }
    }

}
