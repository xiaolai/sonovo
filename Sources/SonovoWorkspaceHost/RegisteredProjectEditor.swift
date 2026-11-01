import SwiftUI
import SonovoDomainTypes
import SonovoDesignSystem
import SonovoFeatureAPI

package struct RegisteredProjectEditor: View {
    package let project: Project
    package let isVisible: Bool
    package let terminalReferences: TerminalReferenceService?
    package let mediaReplaceRequests: (any MediaReplaceRequestSource)?
    package init(project: Project, isVisible: Bool, terminalReferences: TerminalReferenceService? = nil,
                 mediaReplaceRequests: (any MediaReplaceRequestSource)? = nil) {
        self.project = project; self.isVisible = isVisible; self.terminalReferences = terminalReferences
        self.mediaReplaceRequests = mediaReplaceRequests
    }
    package var body: some View {
        Group {
            if let tab = project.selectedTab,
               let provider = tab.workspaceProviderID ?? project.documentAdapter(for: tab)?.editorProviderID {
                editor(provider: provider, message: "Editor unavailable for this file.")
            } else if let asset = project.selectedAsset {
                if let descriptor = project.featureEditors.catalogue.resolve(asset.name) {
                    editor(provider: descriptor.id, message: "Preview unavailable for this file.")
                } else { placeholder("Preview unavailable for this file.") }
            } else { ProjectNoFileView() }
        }
    }
    @ViewBuilder private func editor(provider: EditorProviderID, message: String) -> some View {
        if let contribution = project.featureEditors.contribution(for: provider) {
            contribution.makeView(EditorRequest(project: project, asset: project.selectedAsset, isVisible: isVisible,
                terminalReferences: terminalReferences, mediaReplaceRequests: mediaReplaceRequests))
        } else { placeholder(message) }
    }
    private func placeholder(_ message: String) -> some View {
        Text(message).font(.system(size: AppTheme.TypeScale.sm)).foregroundStyle(.secondary)
    }
}

struct ProjectNoFileView: View {
    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "doc")
                .font(.system(size: AppTheme.TypeScale.displayLarge, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("No File")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
