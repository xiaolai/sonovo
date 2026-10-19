import SwiftUI

struct MainWindow: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: $state.columnVisibility) {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(
                    min: AppTheme.sidebarMinWidth,
                    ideal: AppTheme.sidebarWidth,
                    max: AppTheme.sidebarMaxWidth
                )
        } detail: {
            DetailWorkspace(state: state)
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                LeadingToolbarView(state: state)
            }
            ToolbarItem(placement: .principal) {
                TitleToolbarView(state: state)
            }
            ToolbarItem(placement: .primaryAction) {
                TrailingToolbarView(state: state)
            }
        }
        .navigationTitle("\(state.production.title) — \(state.production.episode)")
    }
}
