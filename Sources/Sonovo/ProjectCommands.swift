import SwiftUI

/// Switching between open folder projects. The order and shortcut indices
/// come from `ProjectSwitcherModel`, the same model the Projects menu uses.
@MainActor
struct ProjectCommands: Commands {
    @Bindable var state: AppState

    var body: some Commands {
        CommandMenu("Project") {
            let model = ProjectSwitcherModel(workspace: state.workspace)
            let shortcutEntries = model.entries.filter {
                $0.shortcutIndex != nil
            }
            ForEach(shortcutEntries.indices, id: \.self) { offset in
                // Filtering keeps these contiguous at the front, so the
                // position is the 1-based digit.
                projectButton(shortcutEntries[offset], index: offset + 1)
            }

            if model.entries.contains(where: { $0.shortcutIndex == nil }) {
                Menu("More Projects") {
                    ForEach(
                        model.entries.filter { $0.shortcutIndex == nil }
                    ) { entry in
                        Button {
                            activate(entry)
                        } label: {
                            projectLabel(entry)
                        }
                    }
                }
            }

            Divider()

            Button("Next Project") {
                state.activateNextProject()
            }
            .keyboardShortcut(
                .rightArrow,
                modifiers: [.control, .command]
            )
            .disabled(model.entries.count < 2)

            Button("Previous Project") {
                state.activatePreviousProject()
            }
            .keyboardShortcut(
                .leftArrow,
                modifiers: [.control, .command]
            )
            .disabled(model.entries.count < 2)

            Divider()

            Button("Open Project…") {
                ProjectOpenPanel.present(state: state)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Menu("Open Recent") {
                RecentProjectsMenu(state: state)
            }
            .disabled(state.workspace.recentPaths.isEmpty)

            Button("Close Project") {
                _ = state.workspace.closeProject(state.liveProject)
            }
            .disabled(state.liveProject.isDemo)
        }
    }

    private func projectButton(
        _ entry: ProjectSwitcherEntry,
        index: Int
    ) -> some View {
        Button {
            activate(entry)
        } label: {
            projectLabel(entry)
        }
        .keyboardShortcut(
            KeyEquivalent(Character("\(index)")),
            modifiers: [.command]
        )
    }

    private func projectLabel(_ entry: ProjectSwitcherEntry) -> some View {
        Label(
            entry.isDemo ? "Sample Project" : entry.name,
            systemImage: entry.isActive ? "checkmark" : "folder"
        )
    }

    private func activate(_ entry: ProjectSwitcherEntry) {
        guard let project = state.workspace.allProjects.first(where: {
            $0.id == entry.id
        }) else {
            return
        }
        state.activateProject(project)
    }
}
