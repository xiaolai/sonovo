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
            ToolbarItemGroup(placement: .primaryAction) {
                TrailingToolbarView(state: state)

                Button {
                    state.inspectorVisible.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                        .labelStyle(.iconOnly)
                }
                .help(state.inspectorVisible ? "Hide Inspector" : "Show Inspector")
                .accessibilityLabel(state.inspectorVisible ? "Hide Inspector" : "Show Inspector")
            }
        }
        .navigationTitle("\(state.production.title) — \(state.production.episode)")
        .navigationSubtitle(state.activityText)
    }
}
