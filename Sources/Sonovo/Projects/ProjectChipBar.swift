import AppKit
import SwiftUI

/// The visible set of open projects. Appears when two or more real projects
/// are open; one project keeps the compact dropdown.
@MainActor
struct ProjectChipBar: View {
    let state: AppState
    @State private var showingOverview = false

    var body: some View {
        let model = ProjectSwitcherModel(workspace: state.workspace)
        HStack(spacing: AppTheme.Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(model.entries) { entry in
                        chip(entry)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.md)
            }

            menuButton
        }
        .frame(height: AppTheme.Layout.tabBarHeight)
        .task {
            // A terminal's live process is a Ghostty query, not an observable
            // property. Poll only while the rail is visible.
            while !Task.isCancelled {
                state.workspace.refreshTerminalProcessStates()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .popover(isPresented: $showingOverview, arrowEdge: .bottom) {
            ProjectOverviewView(state: state)
        }
    }

    private func chip(_ entry: ProjectSwitcherEntry) -> some View {
        Button {
            activate(entry)
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: entry.isDemo ? "house" : "folder")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(
                        entry.isActive ? Color.accentColor : .secondary
                    )

                Text(entry.name)
                    .font(
                        .system(
                            size: AppTheme.TypeScale.xs,
                            weight: entry.isActive ? .semibold : .regular
                        )
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)

                attentionBadges(entry.attention)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(height: AppTheme.ControlSize.medium)
            .frame(
                maxWidth: AppTheme.ProjectSwitcher.chipMaxWidth,
                alignment: .leading
            )
            .background(
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.control,
                    style: .continuous
                )
                .fill(entry.isActive ? Color.appCard : Color.clear)
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.control,
                    style: .continuous
                )
                .strokeBorder(
                    entry.isActive ? Color.appSeparator : Color.clear,
                    lineWidth: AppTheme.BorderWidth.hairline
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.detail)
        .accessibilityLabel(accessibilityLabel(entry))
        .accessibilityValue(entry.attention.summary)
        .accessibilityAddTraits(entry.isActive ? .isSelected : [])
        .contextMenu {
            Button("Activate") { activate(entry) }
                .disabled(entry.isActive)
            if entry.canClose {
                Button("Close Project") { close(entry) }
            }
            if !entry.isDemo {
                Divider()
                Button("Reveal in Finder") { reveal(entry) }
                Button("Copy Path") { copyPath(entry) }
            }
        }
    }

    @ViewBuilder
    private func attentionBadges(
        _ attention: ProjectAttentionSnapshot
    ) -> some View {
        if !attention.isQuiet {
            HStack(spacing: AppTheme.ProjectSwitcher.badgeGap) {
                ForEach(attention.badges()) { status in
                    Image(systemName: status.symbol)
                        .font(
                            .system(
                                size: AppTheme.ProjectSwitcher.badgeSize
                            )
                        )
                        .foregroundStyle(tint(for: status))
                        .help(status.label)
                        .accessibilityHidden(true)
                }
                if attention.overflowCount > 0 {
                    Text("+\(attention.overflowCount)")
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func tint(for status: ProjectAttentionStatus) -> Color {
        switch status {
        case .pendingSaveDecision, .offline, .dirtyDocuments:
            AppTheme.Palette.needsReview
        case .runningTerminal:
            AppTheme.Palette.approved
        case .converting3D, .backgroundChanges:
            AppTheme.Palette.generating
        }
    }

    private var menuButton: some View {
        Menu {
            Button("Open Project…") {
                ProjectOpenPanel.present(state: state)
            }

            if !state.workspace.recentPaths.isEmpty {
                Menu("Recent") {
                    RecentProjectsMenu(state: state)
                }
            }

            Divider()

            Button("Project Overview…") {
                // Let the menu finish dismissing before presenting the
                // popover from the same control.
                DispatchQueue.main.async {
                    showingOverview = true
                }
            }

            if !state.liveProject.isDemo {
                Button("Close Project") {
                    _ = state.workspace.closeProject(state.liveProject)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: AppTheme.TypeScale.sm))
                .frame(
                    width: AppTheme.Size.addIcon,
                    height: AppTheme.Size.addIcon
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.trailing, AppTheme.Spacing.md)
        .help("Project menu")
        .accessibilityLabel("Project menu")
    }

    private func accessibilityLabel(_ entry: ProjectSwitcherEntry) -> String {
        var label = entry.isDemo ? "Sample project" : entry.name
        if entry.isActive {
            label += ", active"
        }
        if !entry.attention.isQuiet {
            label += ", " + entry.attention.summary
        }
        return label
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

    private func reveal(_ entry: ProjectSwitcherEntry) {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: entry.detail)]
        )
    }

    private func copyPath(_ entry: ProjectSwitcherEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.detail, forType: .string)
    }
}
