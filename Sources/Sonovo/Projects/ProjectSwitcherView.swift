import AppKit
import SwiftUI

/// The workspace switcher. A project is a folder; this is the only list of
/// folders, not a second hierarchy inside the asset browser.
struct ProjectSwitcherView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            if ProjectSwitcherModel(workspace: state.workspace).showsChipRail {
                ProjectChipBar(state: state)
            } else {
                compactSwitcher
            }

            if let error = state.workspace.lastError {
                Text(error)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(AppTheme.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .onTapGesture {
                        state.workspace.lastError = nil
                    }
            }
        }
    }

    private var compactSwitcher: some View {
        Menu {
            Section("Projects") {
                projectButton(state.workspace.demoProject)
                ForEach(state.workspace.projects) { project in
                    projectButton(project)
                }
            }

            Divider()

            Button("Open Project…") {
                ProjectOpenPanel.present(state: state)
            }

            if !state.workspace.recentPaths.isEmpty {
                Menu("Recent") {
                    RecentProjectsMenu(state: state)
                }
            }

            if let active = state.workspace.activeProject {
                Divider()
                Button("Close Project") {
                    _ = state.workspace.closeProject(active)
                }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "folder")
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(.secondary)

                Text(state.liveProject.name)
                    .font(.system(size: AppTheme.TypeScale.body, weight: .medium))
                    .lineLimit(1)

                if state.liveProject.hasActivity {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(
                            width: AppTheme.Spacing.s5,
                            height: AppTheme.Spacing.s5
                        )
                        .accessibilityLabel("New files")
                }

                Spacer(minLength: AppTheme.Spacing.xs)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: AppTheme.TypeScale.micro))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.top, AppTheme.Spacing.sm)
    }

    private func projectButton(_ project: Project) -> some View {
        Button {
            state.activateProject(project)
        } label: {
            HStack {
                if project.id == state.liveProject.id {
                    Image(systemName: "checkmark")
                }
                Text(project.name)
                if project.isOffline {
                    Image(systemName: "exclamationmark.triangle")
                } else if project.hasActivity {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: AppTheme.Spacing.s5, height: AppTheme.Spacing.s5)
                }
            }
        }
    }
}
