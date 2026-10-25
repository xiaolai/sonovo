import SwiftUI

struct EditorTabBar: View {
    let state: AppState
    let project: Project

    var body: some View {
        HStack(spacing: AppTheme.Spacing.zero) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    ForEach(project.openTabs) { tab in
                        EditorTabButton(project: project, tab: tab)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
            }

            Spacer(minLength: AppTheme.Spacing.zero)

            Menu {
                if project.isDemo {
                    ForEach(state.production.stages) { stage in
                        Section(stage.title) {
                            ForEach(stage.assets) { asset in
                                Button(asset.name) {
                                    state.openAsset(asset.id)
                                }
                            }
                        }
                    }
                } else {
                    ForEach(project.filteredGroups) { group in
                        Section(group.title) {
                            ForEach(group.assets) { asset in
                                Button(asset.name) {
                                    project.openAsset(asset)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Close All Tabs") {
                    Task { await project.closeAllTabs() }
                }
                .disabled(project.openTabs.isEmpty)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                    .frame(width: AppTheme.Size.addIcon, height: AppTheme.Size.addIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.trailing, AppTheme.Spacing.sm)
            .help("Open Asset")
            .accessibilityLabel("Open Asset")
        }
        .frame(height: AppTheme.Layout.tabBarHeight)
        .background(Color.appText)
    }
}

private struct EditorTabButton: View {
    let project: Project
    let tab: EditorTab

    @State private var isHovering = false

    private var isSelected: Bool {
        project.selectedTabID == tab.id
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                project.selectTab(tab.id)
            } label: {
                HStack(spacing: AppTheme.Spacing.s5) {
                    Image(systemName: tab.icon)
                        .font(.system(size: AppTheme.TypeScale.xs, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                    Text(project.displayName(for: tab))
                        .font(.system(size: AppTheme.TypeScale.sm, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)
                }
                .padding(.leading, AppTheme.Spacing.sm)
                .padding(
                    .trailing,
                    (isHovering || isSelected) ? AppTheme.ControlSize.regular : AppTheme.Spacing.sm
                )
                .frame(height: AppTheme.ControlSize.medium)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .fill(isSelected ? Color.appCard : Color.clear)
                )
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                            .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isHovering || isSelected {
                Button {
                    Task { await project.closeTab(tab.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: AppTheme.TypeScale.micro, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: AppTheme.Size.tabClose, height: AppTheme.Size.tabClose)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .padding(.trailing, AppTheme.Spacing.xs)
                .help("Close Tab")
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
