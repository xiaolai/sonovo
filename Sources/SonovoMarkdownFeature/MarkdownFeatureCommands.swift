import AppKit
import SwiftUI
import SonovoFeatureAPI

extension MarkdownFeatureSession {
    package var menus: [FeatureMenuContribution] {
        [FeatureMenuContribution(title: "Markdown") { [workspace] in
            AnyView(MarkdownMenuContent(workspace: workspace, context: $0))
        }]
    }
    package var commands: [FeatureCommandContribution] {
        [
            FeatureCommandContribution(id: "builtin.markdown.new-document", title: { "New Document" },
                requiresSelectedEditor: false,
                requiresVisibleEditor: false, action: { [workspace] invocation in
                    invocation.revealWorkspace()
                workspace.newDocument()
                }),
            FeatureCommandContribution(id: "builtin.markdown.open", title: { "Open…" },
                requiresSelectedEditor: false,
                requiresVisibleEditor: false, action: { [workspace] invocation in
                    invocation.revealWorkspace()
                workspace.presentOpenPanel()
                }),
            FeatureCommandContribution(id: "builtin.markdown.open-folder", title: { "Open Folder…" },
                requiresSelectedEditor: false,
                requiresVisibleEditor: false, action: { [workspace] invocation in
                    invocation.revealWorkspace()
                workspace.presentOpenFolderPanel()
                }),
            FeatureCommandContribution(id: "builtin.markdown.toggle-source-rendered", title: { "Toggle Source/Rendered" },
                requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.toggleMode()
                }),
            FeatureCommandContribution(id: "builtin.markdown.export-as-html", title: { "Export as HTML…" },
                requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.exportSelected(as: .html)
                }),
            FeatureCommandContribution(id: "builtin.markdown.export-as-pdf", title: { "Export as PDF…" },
                requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.exportSelected(as: .pdf)
                }),
            FeatureCommandContribution(id: "builtin.markdown.bold", title: { "Bold" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.toggleStrong)
                }),
            FeatureCommandContribution(id: "builtin.markdown.italic", title: { "Italic" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.toggleEmphasis)
                }),
            FeatureCommandContribution(id: "builtin.markdown.inline-code", title: { "Inline Code" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.toggleInlineCode)
                }),
            FeatureCommandContribution(id: "builtin.markdown.strikethrough", title: { "Strikethrough" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.toggleStrikethrough)
                }),
            FeatureCommandContribution(id: "builtin.markdown.highlight", title: { "Highlight" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.toggleHighlight)
                }),
            FeatureCommandContribution(id: "builtin.markdown.underline", title: { "Underline" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.toggleUnderline)
                }),
            FeatureCommandContribution(id: "builtin.markdown.superscript", title: { "Superscript" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.toggleSuperscript)
                }),
            FeatureCommandContribution(id: "builtin.markdown.subscript", title: { "Subscript" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.toggleSubscript)
                })
        ] +
        (1...6).map { level in
                FeatureCommandContribution(id: "builtin.markdown.heading.\(level)", title: { "Heading \(level)" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(
                                .toggleHeading(level: level)
                            )
                })
            } +
        [
            FeatureCommandContribution(id: "builtin.markdown.block-quote", title: { "Block Quote" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.toggleBlockQuote)
                }),
            FeatureCommandContribution(id: "builtin.markdown.bullet", title: { "Bullet" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(
                            .toggleList(kind: .bullet)
                        )
                }),
            FeatureCommandContribution(id: "builtin.markdown.numbered", title: { "Numbered" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(
                            .toggleList(kind: .ordered)
                        )
                }),
            FeatureCommandContribution(id: "builtin.markdown.task", title: { "Task" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(
                            .toggleList(kind: .task)
                        )
                }),
            FeatureCommandContribution(id: "builtin.markdown.insert-link", title: { "Insert Link" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.presentLinkPopoverOnSelected()
                }),
            FeatureCommandContribution(id: "builtin.markdown.insert-wiki-link", title: { "Insert Wiki Link" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(
                        .insertWikiLink(target: "", alias: nil)
                    )
                }),
            FeatureCommandContribution(id: "builtin.markdown.insert-details", title: { "Insert Details" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(
                        .insertDetails(summary: "Details")
                    )
                }),
            FeatureCommandContribution(id: "builtin.markdown.insert-toc", title: { "Insert TOC" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.insertTOC)
                }),
            FeatureCommandContribution(id: "builtin.markdown.insert-table", title: { "Insert Table" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(
                            .insertTable(rows: 2, columns: 2)
                        )
                }),
            FeatureCommandContribution(id: "builtin.markdown.insert-row-above", title: { "Insert Row Above" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(
                            .insertTableRowAbove
                        )
                }),
            FeatureCommandContribution(id: "builtin.markdown.insert-row-below", title: { "Insert Row Below" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(
                            .insertTableRowBelow
                        )
                }),
            FeatureCommandContribution(id: "builtin.markdown.delete-row", title: { "Delete Row" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.deleteTableRow)
                }),
            FeatureCommandContribution(id: "builtin.markdown.insert-column-left", title: { "Insert Column Left" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(
                            .insertTableColumnLeft
                        )
                }),
            FeatureCommandContribution(id: "builtin.markdown.insert-column-right", title: { "Insert Column Right" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(
                            .insertTableColumnRight
                        )
                }),
            FeatureCommandContribution(id: "builtin.markdown.delete-column", title: { "Delete Column" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.deleteTableColumn)
                }),
            FeatureCommandContribution(id: "builtin.markdown.none", title: { "None" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(
                                .setTableAlignment(.none)
                            )
                }),
            FeatureCommandContribution(id: "builtin.markdown.left", title: { "Left" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(
                                .setTableAlignment(.left)
                            )
                }),
            FeatureCommandContribution(id: "builtin.markdown.center", title: { "Center" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(
                                .setTableAlignment(.center)
                            )
                }),
            FeatureCommandContribution(id: "builtin.markdown.right", title: { "Right" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(
                                .setTableAlignment(.right)
                            )
                }),
            FeatureCommandContribution(id: "builtin.markdown.format-table", title: { "Format Table" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.formatTable)
                }),
            FeatureCommandContribution(id: "builtin.markdown.delete-table", title: { "Delete Table" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.deleteTable)
                }),
            FeatureCommandContribution(id: "builtin.markdown.move-up", title: { "Move Up" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.lineUp)
                }),
            FeatureCommandContribution(id: "builtin.markdown.move-down", title: { "Move Down" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.lineDown)
                }),
            FeatureCommandContribution(id: "builtin.markdown.duplicate", title: { "Duplicate" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.duplicateLine)
                }),
            FeatureCommandContribution(id: "builtin.markdown.delete", title: { "Delete" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.deleteLine)
                }),
            FeatureCommandContribution(id: "builtin.markdown.join", title: { "Join" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.joinLines)
                }),
            FeatureCommandContribution(id: "builtin.markdown.remove-blank-lines", title: { "Remove Blank Lines" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.removeBlankLines)
                }),
            FeatureCommandContribution(id: "builtin.markdown.collapse-blank-lines", title: { "Collapse Blank Lines" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.collapseBlankLines)
                }),
            FeatureCommandContribution(id: "builtin.markdown.remove-trailing-spaces", title: { "Remove Trailing Spaces" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.trimTrailingSpaces)
                }),
            FeatureCommandContribution(id: "builtin.markdown.sort-ascending", title: { "Sort Ascending" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.sortLinesAscending)
                }),
            FeatureCommandContribution(id: "builtin.markdown.sort-descending", title: { "Sort Descending" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.sortLinesDescending)
                }),
            FeatureCommandContribution(id: "builtin.markdown.uppercase", title: { "Uppercase" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.uppercase)
                }),
            FeatureCommandContribution(id: "builtin.markdown.lowercase", title: { "Lowercase" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.lowercase)
                }),
            FeatureCommandContribution(id: "builtin.markdown.title-case", title: { "Title Case" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.titleCase)
                }),
            FeatureCommandContribution(id: "builtin.markdown.toggle-case", title: { "Toggle Case" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.toggleCase)
                }),
            FeatureCommandContribution(id: "builtin.markdown.format-cjk-spacing", title: { "Format CJK Spacing" },
                isEnabled: { [weak self] in self?.canFormat == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.formatCJK)
                }),
            FeatureCommandContribution(id: "builtin.markdown.add-next-occurrence", title: { "Add Next Occurrence" },
                isEnabled: { [weak self] in self?.canPlaceCarets == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.addNextOccurrence)
                }),
            FeatureCommandContribution(id: "builtin.markdown.select-all-occurrences", title: { "Select All Occurrences" },
                isEnabled: { [weak self] in self?.canPlaceCarets == true }, requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.performSelected(.selectAllOccurrences)
                }),
            FeatureCommandContribution(id: "builtin.markdown.check-markdown", title: { "Check Markdown" },
                requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.checkSelectedMarkdown()
                }),
            FeatureCommandContribution(id: "builtin.markdown.next-problem", title: { "Next Problem" },
                requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.goToNextProblem()
                }),
            FeatureCommandContribution(id: "builtin.markdown.previous-problem", title: { "Previous Problem" },
                requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.goToPreviousProblem()
                }),
            FeatureCommandContribution(id: "builtin.markdown.command-palette", title: { "Command Palette" },
                requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.togglePalette()
                }),
            FeatureCommandContribution(id: "builtin.markdown.quick-open", title: { "Quick Open…" },
                requiresSelectedEditor: true,
                requiresVisibleEditor: true, action: { [workspace] invocation in
                    workspace.isQuickOpenVisible = true
                })
        ] + findCommands
    }
    private var sourceEditorFocused: Bool {
        guard let document = workspace.selectedDocument,
              let responder = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return responder === workspace.controller(for: document).textView
    }
    private var canPlaceCarets: Bool {
        workspace.selectedDocument?.mode == .source && workspace.selectedDocument?.isReadOnly == false && sourceEditorFocused
    }
    private var canFormat: Bool { canPlaceCarets && workspace.selectedDocument?.isSourceOnly == false }

    private var findCommands: [FeatureCommandContribution] {
        [
            findCommand(.find, title: "Find", action: .showFindPanel),
            findCommand(.findNext, title: "Find Next", action: .next),
            findCommand(.findPrevious, title: "Find Previous", action: .previous),
            FeatureCommandContribution(id: "builtin.markdown.replace", title: { "Replace…" },
                isEnabled: { [weak self] in self?.canReplace == true }, requiresSelectedEditor: true,
                role: .replace, showsInMenu: false, perform: { [weak self] in self?.performTextFinder(.showReplaceInterface) }),
            FeatureCommandContribution(id: "builtin.markdown.replace-all", title: { "Replace All" },
                isEnabled: { [weak self] in self?.canReplace == true }, requiresSelectedEditor: true,
                role: .replaceAll, showsInMenu: false, perform: { [weak self] in self?.performFind(.replaceAll) })
        ]
    }
    private var canReplace: Bool {
        workspace.sourceFindTarget()?.textView != nil && workspace.selectedDocument?.isReadOnly == false
    }
    private func findCommand(_ role: FeatureCommandRole, title: String, action: NSFindPanelAction) -> FeatureCommandContribution {
        FeatureCommandContribution(id: "builtin.markdown.find-\(String(describing: role).lowercased())", title: { title },
            isEnabled: { [workspace] in workspace.selectedDocument?.mode == .rendered || workspace.sourceFindTarget()?.textView != nil },
            requiresSelectedEditor: true, role: role, showsInMenu: false, perform: { [weak self] in
                guard let self else { return }
                if workspace.selectedDocument?.mode == .rendered {
                    switch role {
                    case .find: workspace.showRenderedFind()
                    case .findNext: workspace.stepRenderedFind(1)
                    case .findPrevious: workspace.stepRenderedFind(-1)
                    default: break
                    }
                } else { performFind(action) }
            })
    }
    private func performFind(_ action: NSFindPanelAction) {
        guard let textView = workspace.sourceFindTarget()?.textView else { return }
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem(); item.tag = Int(action.rawValue)
        DispatchQueue.main.async { textView.performFindPanelAction(item) }
    }
    private func performTextFinder(_ action: NSTextFinder.Action) {
        guard let textView = workspace.sourceFindTarget()?.textView else { return }
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem(); item.tag = action.rawValue
        DispatchQueue.main.async { textView.performTextFinderAction(item) }
    }
}
