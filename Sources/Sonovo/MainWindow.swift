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
        .background(
            WindowCloseGuard { await state.flushAllBeforeClose() }
        )
        .navigationTitle("\(state.production.title) — \(state.production.episode)")
        .navigationSubtitle(state.activityText)
        .alert(
            "Unsaved Changes",
            isPresented: Binding(
                get: { state.markdown.pendingClose != nil },
                set: { presented in
                    if !presented { state.markdown.dismissCloseAlert() }
                }
            )
        ) {
            Button("Save") {
                guard let document = state.markdown.pendingClose else {
                    return
                }
                // A save can fail; show the document and its error instead
                // of failing silently behind a non-Markdown tab.
                state.revealMarkdownDocument(document)
                Task { await state.markdown.saveAndClose(document) }
            }
            Button("Discard", role: .destructive) {
                guard let document = state.markdown.pendingClose else {
                    return
                }
                state.markdown.discardAndClose(document)
            }
            Button("Cancel", role: .cancel) {
                state.markdown.cancelPendingClose()
            }
        } message: {
            Text("This document has unsaved changes.")
        }
    }
}
