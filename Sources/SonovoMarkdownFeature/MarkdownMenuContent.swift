import AppKit
import SwiftUI
import SonovoFeatureAPI

@MainActor
struct MarkdownMenuContent: View {
    let workspace: MarkdownWorkspace
    let context: FeatureMenuContext

    var body: some View {
        Group {
            Button("New Document") { context.perform("builtin.markdown.new-document") }
            .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Open…") { context.perform("builtin.markdown.open") }
            .keyboardShortcut("o", modifiers: [.command])
            Button("Open Folder…") { context.perform("builtin.markdown.open-folder") }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Toggle Source/Rendered") { context.perform("builtin.markdown.toggle-source-rendered") }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!isMarkdownVisible)
            Divider()
            Button("Export as HTML…") { context.perform("builtin.markdown.export-as-html") }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!isMarkdownVisible)
            Button("Export as PDF…") { context.perform("builtin.markdown.export-as-pdf") }
            .disabled(!isMarkdownVisible)
            Divider()
            Group {
                Button("Bold") { context.perform("builtin.markdown.bold") }
                .keyboardShortcut("b", modifiers: [.command])
                Button("Italic") { context.perform("builtin.markdown.italic") }
                .keyboardShortcut("i", modifiers: [.command])
                Button("Inline Code") { context.perform("builtin.markdown.inline-code") }
                .keyboardShortcut("e", modifiers: [.command])
                Button("Strikethrough") { context.perform("builtin.markdown.strikethrough") }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Highlight") { context.perform("builtin.markdown.highlight") }
                Button("Underline") { context.perform("builtin.markdown.underline") }
                Button("Superscript") { context.perform("builtin.markdown.superscript") }
                Button("Subscript") { context.perform("builtin.markdown.subscript") }
                Menu("Heading") {
                    ForEach(1...6, id: \.self) { level in
                        Button("Heading \(level)") { context.perform("builtin.markdown.heading.\(level)") }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(level)")),
                            modifiers: [.command, .option]
                        )
                    }
                }
                Button("Block Quote") { context.perform("builtin.markdown.block-quote") }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                Menu("List") {
                    Button("Bullet") { context.perform("builtin.markdown.bullet") }
                    .keyboardShortcut("8", modifiers: [.command, .shift])
                    Button("Numbered") { context.perform("builtin.markdown.numbered") }
                    .keyboardShortcut("7", modifiers: [.command, .shift])
                    Button("Task") { context.perform("builtin.markdown.task") }
                    .keyboardShortcut("9", modifiers: [.command, .shift])
                }
                Button("Insert Link") { context.perform("builtin.markdown.insert-link") }
                .keyboardShortcut("k", modifiers: [.command])
                Button("Insert Wiki Link") { context.perform("builtin.markdown.insert-wiki-link") }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Insert Details") { context.perform("builtin.markdown.insert-details") }
                Button("Insert TOC") { context.perform("builtin.markdown.insert-toc") }
                Menu("Table") {
                    Button("Insert Table") { context.perform("builtin.markdown.insert-table") }
                    Divider()
                    Button("Insert Row Above") { context.perform("builtin.markdown.insert-row-above") }
                    Button("Insert Row Below") { context.perform("builtin.markdown.insert-row-below") }
                    Button("Delete Row") { context.perform("builtin.markdown.delete-row") }
                    Divider()
                    Button("Insert Column Left") { context.perform("builtin.markdown.insert-column-left") }
                    Button("Insert Column Right") { context.perform("builtin.markdown.insert-column-right") }
                    Button("Delete Column") { context.perform("builtin.markdown.delete-column") }
                    Divider()
                    Menu("Align Column") {
                        Button("None") { context.perform("builtin.markdown.none") }
                        Button("Left") { context.perform("builtin.markdown.left") }
                        Button("Center") { context.perform("builtin.markdown.center") }
                        Button("Right") { context.perform("builtin.markdown.right") }
                    }
                    Button("Format Table") { context.perform("builtin.markdown.format-table") }
                    Divider()
                    Button("Delete Table") { context.perform("builtin.markdown.delete-table") }
                }
                Menu("Lines") {
                    Button("Move Up") { context.perform("builtin.markdown.move-up") }
                    Button("Move Down") { context.perform("builtin.markdown.move-down") }
                    Button("Duplicate") { context.perform("builtin.markdown.duplicate") }
                    Button("Delete") { context.perform("builtin.markdown.delete") }
                    Button("Join") { context.perform("builtin.markdown.join") }
                    Divider()
                    Button("Remove Blank Lines") { context.perform("builtin.markdown.remove-blank-lines") }
                    Button("Collapse Blank Lines") { context.perform("builtin.markdown.collapse-blank-lines") }
                    Button("Remove Trailing Spaces") { context.perform("builtin.markdown.remove-trailing-spaces") }
                    Divider()
                    Button("Sort Ascending") { context.perform("builtin.markdown.sort-ascending") }
                    Button("Sort Descending") { context.perform("builtin.markdown.sort-descending") }
                    Divider()
                    Button("Uppercase") { context.perform("builtin.markdown.uppercase") }
                    Button("Lowercase") { context.perform("builtin.markdown.lowercase") }
                    Button("Title Case") { context.perform("builtin.markdown.title-case") }
                    Button("Toggle Case") { context.perform("builtin.markdown.toggle-case") }
                }
                Menu("Text") {
                    Button("Format CJK Spacing") { context.perform("builtin.markdown.format-cjk-spacing") }
                }
                Divider()
            }
            .disabled(!canFormatMarkdown)
            // Placement is not formatting: it edits no source, and it works
            // in an editable source-only document where Command-click
            // placement already does. Sharing the formatting gate disabled
            // both commands for those documents.
            Group {
                Button("Add Next Occurrence") { context.perform("builtin.markdown.add-next-occurrence") }
                .keyboardShortcut("d", modifiers: [.command])
                Button("Select All Occurrences") { context.perform("builtin.markdown.select-all-occurrences") }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            .disabled(!canPlaceCarets)
            Divider()
            Button("Check Markdown") { context.perform("builtin.markdown.check-markdown") }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(!isMarkdownVisible)
            Button("Next Problem") { context.perform("builtin.markdown.next-problem") }
            .keyboardShortcut(KeyEquivalent("\u{F705}"), modifiers: [])
            .disabled(!isMarkdownVisible)
            Button("Previous Problem") { context.perform("builtin.markdown.previous-problem") }
            .keyboardShortcut(KeyEquivalent("\u{F705}"), modifiers: [.shift])
            .disabled(!isMarkdownVisible)
            Button("Command Palette") { context.perform("builtin.markdown.command-palette") }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!isMarkdownVisible)
            Button("Quick Open…") { context.perform("builtin.markdown.quick-open") }
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(!isMarkdownVisible)
        }
    }

    /// Mode switching changes the document the selected tab is showing; it
    /// must not act on a hidden workspace behind another tab or the terminal.
    private var isMarkdownVisible: Bool {
        context.isEditorSelected
            && context.isEditorVisible
    }

    /// Formatting commands act on the visible, editable Markdown source
    /// editor. With another tab selected they would modify a hidden document.
    private var canFormatMarkdown: Bool {
        context.isEditorSelected
            && context.isEditorVisible
            && workspace.selectedDocument?.mode == .source
            && workspace.selectedDocument?.isReadOnly == false
            && workspace.selectedDocument?.isSourceOnly == false
            && isSourceEditorFocused
    }

    /// Caret placement writes no source, so it only needs the visible,
    /// editable source editor. Source-only documents are eligible: their
    /// editor supports editing and Command-click placement, and excluding
    /// them here was the formatting gate leaking into placement.
    private var canPlaceCarets: Bool {
        context.isEditorSelected
            && context.isEditorVisible
            && workspace.selectedDocument?.mode == .source
            && workspace.selectedDocument?.isReadOnly == false
            && isSourceEditorFocused
    }

    /// The focused surface decides ownership. A terminal, find field, or
    /// popover must not receive a Markdown formatting action even when a
    /// Markdown tab is selected.
    private var isSourceEditorFocused: Bool {
        guard let document = workspace.selectedDocument else {
            return false
        }
        guard let responder = NSApp.keyWindow?.firstResponder as? NSTextView
        else {
            return false
        }
        return responder === workspace.controller(for: document).textView
    }
}
