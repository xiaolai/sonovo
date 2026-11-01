import SwiftUI

/// The recent-project list shared by the Projects toolbar menu, the overview,
/// and the Project menu. Paths are stored absolute; the label is the folder
/// name.
package struct RecentProjectsMenu: View {
    package init(state: AppState) { self.state = state }

    @Bindable package var state: AppState

    package var body: some View {
        ForEach(state.workspace.recentPaths, id: \.self) { path in
            Button(URL(fileURLWithPath: path).lastPathComponent) {
                state.openProject(at: URL(fileURLWithPath: path))
            }
        }
    }
}
