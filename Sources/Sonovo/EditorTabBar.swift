import SwiftUI

struct EditorTabBar: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(state.openTabs) { tab in
                        EditorTabButton(state: state, tab: tab)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)

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
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.trailing, AppTheme.Spacing.sm)
            .help("Open Asset")
        }
        .frame(height: AppTheme.tabBarHeight)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.appSeparator)
                .frame(height: AppTheme.BorderWidth.hairline)
        }
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
                HStack(spacing: 5) {
                    Image(systemName: tab.icon)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                    Text(tab.title)
                        .font(.system(size: AppTheme.FontSize.sm, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)
                }
                .padding(.leading, AppTheme.Spacing.sm)
                .padding(.trailing, (isHovering || isSelected) ? 22 : AppTheme.Spacing.sm)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                        .fill(isSelected ? Color.appCard : Color.clear)
                )
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
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
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 15, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .help("Close Tab")
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
