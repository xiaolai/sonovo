import SwiftUI

struct EditorBreadcrumb: View {
    let state: AppState
    let project: Project

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if let content {
                Image(systemName: content.icon)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)

                Text(content.rootTitle)
                    .lineLimit(1)

                chevron
                Text(content.groupTitle)
                    .lineLimit(1)
                chevron
                Text(content.name)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer(minLength: AppTheme.Spacing.sm)

                Text(content.detail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if let status = content.status {
                    StatusBadge(status: status)
                }
            } else {
                Text("No Editor")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.system(size: AppTheme.TypeScale.xs))
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Layout.breadcrumbHeight)
        .background(Color.appWindow)
    }

    /// The breadcrumb trail for the selected asset, workspace document, or
    /// sample asset. Resolving it before the layout keeps one rendering path.
    private var content: BreadcrumbContent? {
        if !project.isDemo, let asset = project.selectedAsset {
            return BreadcrumbContent(
                icon: asset.kind.icon,
                rootTitle: project.name,
                groupTitle: asset.kind.projectGroup.title,
                name: asset.name,
                detail: asset.detail,
                status: nil
            )
        }
        if !project.isDemo,
           let kind = project.selectedTab?.workspaceKind,
           let identity = project.workspaceDocumentIdentity(for: kind) {
            return BreadcrumbContent(
                icon: kind.icon,
                rootTitle: project.name,
                groupTitle: kind.projectGroup.title,
                name: identity.name,
                detail: identity.detail,
                status: nil
            )
        }
        if project.isDemo,
           let tab = project.selectedTab,
           let asset = state.production.asset(id: tab.assetID) {
            return BreadcrumbContent(
                icon: tab.kind.icon,
                rootTitle: state.production.title,
                groupTitle: state.production.stage(for: asset.id)?.title
                    ?? "Production",
                name: state.displayName(for: asset),
                detail: asset.detail,
                status: state.status(for: asset)
            )
        }
        return nil
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: AppTheme.TypeScale.tiny, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

private struct BreadcrumbContent {
    let icon: String
    let rootTitle: String
    let groupTitle: String
    let name: String
    let detail: String
    let status: ReviewStatus?
}
