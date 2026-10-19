import SwiftUI

struct EditorBreadcrumb: View {
    let state: AppState

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if let tab = state.selectedTab,
               let asset = state.production.asset(id: tab.assetID) {
                Image(systemName: tab.kind.icon)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.secondary)

                Text(state.production.title)
                    .lineLimit(1)

                chevron
                Text(state.production.stage(for: asset.id)?.title ?? "Production")
                    .lineLimit(1)
                chevron
                Text(asset.name)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer(minLength: AppTheme.Spacing.sm)

                Text(asset.detail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                StatusBadge(status: state.status(for: asset))
            } else {
                Text("No Editor")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.system(size: AppTheme.FontSize.xs))
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.breadcrumbHeight)
        .background(Color.appWindow)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.appSeparator)
                .frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}
