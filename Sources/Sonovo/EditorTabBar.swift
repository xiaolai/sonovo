import SwiftUI

struct EditorTabBar: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: AppTheme.Spacing.zero) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    ForEach(state.openTabs) { tab in
                        EditorTabButton(state: state, tab: tab)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
            }

            Spacer(minLength: AppTheme.Spacing.zero)

            Menu {
                ForEach(state.production.stages) { stage in
                    Section(stage.title) {
                        ForEach(stage.assets) { asset in
                            Button(asset.name) {
                                state.openAsset(asset.id)
                            }
                        }
                    }
                }
                Divider()
                Button("Close All Tabs") {
                    state.closeAllTabs()
                }
                .disabled(state.openTabs.isEmpty)
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
    @Bindable var state: AppState
    let tab: EditorTab

    @State private var isHovering = false

    private var isSelected: Bool {
        state.selectedTabID == tab.id
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                state.selectTab(tab.id)
            } label: {
                HStack(spacing: AppTheme.Spacing.s5) {
                    Image(systemName: tab.icon)
                        .font(.system(size: AppTheme.TypeScale.xs, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                    Text(tab.title)
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

            if isHovering || isSelected {
                Button {
                    state.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: AppTheme.TypeScale.micro, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: AppTheme.Size.tabClose, height: AppTheme.Size.tabClose)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
