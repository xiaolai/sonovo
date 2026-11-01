import SonovoFeatureAPI
import SonovoWorkspaceHost
import SonovoDomainTypes
import SonovoDesignSystem
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

                breadcrumbContribution?.accessory?.makeView(editorRequest)

                Spacer(minLength: AppTheme.Spacing.sm)

                Text(content.detail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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

    private var editorRequest: EditorRequest {
        EditorRequest(project: project, asset: project.selectedAsset, isVisible: project.isActive && state.terminalPresentation != .full)
    }
    private var breadcrumbContribution: FeatureBreadcrumbContribution? {
        project.selectedFeatureID.flatMap { project.featureSessions.session(for: $0)?.breadcrumb }
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
                detail: breadcrumbContribution?.detail(editorRequest) ?? asset.detail
            )
        }
        if !project.isDemo,
           let tab = project.selectedTab, let kind = tab.workspaceKind,
           let identity = project.workspaceDocumentIdentity(for: tab) {
            return BreadcrumbContent(
                icon: kind.icon,
                rootTitle: project.name,
                groupTitle: kind.projectGroup.title,
                name: identity.name,
                detail: identity.detail
            )
        }
        if project.isDemo,
           let tab = project.selectedTab,
           let asset = project.sampleProductionAsset(id: tab.assetID) {
            return BreadcrumbContent(
                icon: tab.kind.icon,
                rootTitle: state.production.title,
                groupTitle: project.sampleStage(for: asset.id)?.title
                    ?? "Production",
                name: state.displayName(for: asset),
                detail: asset.detail
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
}
