import SwiftUI

struct MainWindow: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: $state.columnVisibility) {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(
                    min: AppTheme.Layout.sidebarMinWidth,
                    ideal: AppTheme.Layout.sidebarWidth,
                    max: AppTheme.Layout.sidebarMaxWidth
                )
        } detail: {
            DetailWorkspace(state: state)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                LeadingToolbarView(state: state)
            }
            ToolbarItem(placement: .primaryAction) {
                TrailingToolbarView(state: state)
            }
        }
        .navigationTitle("\(state.production.title) — \(state.production.episode)")
        .navigationSubtitle(state.activityText)
    }
}
