import SwiftUI

/// Project switching and project-level actions live in the toolbar, not in
/// the navigator sidebar. The navigator tabs own the sidebar's top edge.
@MainActor
struct ProjectMenuButton: View {
    @Bindable var state: AppState
    @State private var showingOverview = false

    var body: some View {
        let model = ProjectSwitcherModel(workspace: state.workspace)
        Menu {
            ForEach(model.entries) { entry in
                Button {
                    activate(entry)
                } label: {
                    Label(
                        entry.name,
                        systemImage: entry.isActive
                            ? "checkmark"
                            : (entry.isDemo ? "house" : "folder")
                    )
                }
                .help(entry.detail)
            }

            Divider()

            Button("Project Overview…") {
                // Let the menu dismiss before presenting a popover from the
                // same control.
                DispatchQueue.main.async {
                    showingOverview = true
                }
            }

            Button("Open Project…") {
                ProjectOpenPanel.present(state: state)
            }

            if !state.workspace.recentPaths.isEmpty {
                Menu("Recent") {
                    RecentProjectsMenu(state: state)
                }
            }

            if !state.liveProject.isDemo {
                Divider()
                Button("Close Project") {
                    _ = state.workspace.closeProject(state.liveProject)
                }
            }
        } label: {
            Label("Projects", systemImage: "folder")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .help("Projects")
        .accessibilityLabel("Projects")
        .popover(isPresented: $showingOverview, arrowEdge: .bottom) {
            ProjectOverviewView(state: state)
        }
        .onAppear {
            state.workspace.refreshTerminalProcessStates()
        }
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
