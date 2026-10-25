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
                HStack(spacing: AppTheme.Spacing.s6) {
                    ProjectMenuButton(state: state)
                    EditorChromeToggle(
                        isOn: $state.showTabBar,
                        icon: "rectangle.topthird.inset.filled",
                        title: "Tab Bar"
                    )
                    EditorChromeToggle(
                        isOn: $state.showBreadcrumbs,
                        icon: "chevron.right",
                        title: "Breadcrumbs"
                    )
                }
            }

            if state.canUseMediaModes {
                ToolbarItemGroup(placement: .primaryAction) {
                    ViewModeButton(state: state, mode: .player)
                    ViewModeButton(state: state, mode: .compare)
                    ViewModeButton(state: state, mode: .transcript)
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            ToolbarItem(placement: .primaryAction) {
                TerminalMenu(state: state)
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItemGroup(placement: .primaryAction) {
                InspectorButton(state: state)
            }
        }
        .background(
            WindowCloseGuard { await state.flushAllBeforeClose() }
        )
        .navigationTitle(state.windowTitle)
        .navigationSubtitle(state.activityText)
        .alert(
            "Unsaved Changes",
            isPresented: Binding(
                get: { state.hasPendingCloseDecision },
                set: { _ in
                    // Every button resolves the decision it was presented
                    // for. Clearing here would resolve whatever is pending
                    // after Discard advanced the queue, dropping another
                    // document's decision.
                }
            )
        ) {
            Button("Save") {
                // The owner may not be the active project; AppState resolves
                // it and reveals the document before saving.
                state.savePendingClose()
            }
            Button("Discard", role: .destructive) {
                state.discardPendingClose()
            }
            Button("Cancel", role: .cancel) {
                state.cancelPendingClose()
            }
        } message: {
            Text("This document has unsaved changes.")
        }
    }
}
