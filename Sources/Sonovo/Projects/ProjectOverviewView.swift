import SwiftUI

/// A live status board for open projects. This is current state, not an event
/// log: no timestamps, no history.
@MainActor
struct ProjectOverviewView: View {
    let state: AppState

    var body: some View {
        let model = ProjectSwitcherModel(workspace: state.workspace)
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            HStack {
                Text("Projects")
                    .font(
                        .system(
                            size: AppTheme.TypeScale.xs,
                            weight: .semibold
                        )
                    )
                    .tracking(AppTheme.Tracking.normal)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(model.entries.count) open")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.top, AppTheme.Spacing.md)
            .padding(.bottom, AppTheme.Spacing.sm)

            ScrollView {
                VStack(spacing: AppTheme.Spacing.zero) {
                    ForEach(model.entries) { entry in
                        row(entry)
                    }
                }
            }
            .frame(
                maxHeight: AppTheme.ProjectSwitcher.overviewMaxHeight
            )

            Divider()

            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Open Project…") {
                    ProjectOpenPanel.present(state: state)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if !state.workspace.recentPaths.isEmpty {
                    Menu("Recent") {
                        RecentProjectsMenu(state: state)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Spacer()
            }
            .padding(AppTheme.Spacing.md)
        }
        .frame(width: AppTheme.ProjectSwitcher.overviewWidth)
    }

    private func row(_ entry: ProjectSwitcherEntry) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(
                systemName: entry.isActive
                    ? "checkmark.circle.fill"
                    : (entry.isDemo ? "house" : "folder")
            )
            .font(.system(size: AppTheme.TypeScale.sm))
            .foregroundStyle(
                entry.isActive ? Color.accentColor : .secondary
            )
            .frame(width: AppTheme.Size.menuIcon)

            Button {
                activate(entry)
            } label: {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(entry.name)
                        .font(
                            .system(
                                size: AppTheme.TypeScale.sm,
                                weight: entry.isActive ? .semibold : .medium
                            )
                        )
                        .lineLimit(1)

                    if !entry.isDemo {
                        Text(entry.detail)
                            .font(.system(size: AppTheme.TypeScale.xxs))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if !entry.attention.isQuiet {
                        Text(entry.attention.summary)
                            .font(.system(size: AppTheme.TypeScale.xxs))
                            .foregroundStyle(
                                AppTheme.Palette.warning
                            )
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.detail)

            if entry.canClose {
                Button {
                    close(entry)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: AppTheme.TypeScale.sm))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close Project")
                .accessibilityLabel("Close \(entry.name)")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .frame(minHeight: AppTheme.ProjectSwitcher.overviewRowMinHeight)
        .background(entry.isActive ? Color.appCard : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(entry.isActive ? .isSelected : [])
    }

    private func project(for entry: ProjectSwitcherEntry) -> Project? {
        state.workspace.allProjects.first { $0.id == entry.id }
    }

    private func activate(_ entry: ProjectSwitcherEntry) {
        guard let project = project(for: entry) else { return }
        state.activateProject(project)
    }

    private func close(_ entry: ProjectSwitcherEntry) {
        guard let project = project(for: entry) else { return }
        _ = state.workspace.closeProject(project)
    }
}
