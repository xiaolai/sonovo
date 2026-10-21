import SwiftUI

/// The recent-project list shared by the compact switcher, the chip rail,
/// the overview, and the Project menu. Paths are stored absolute; the label
/// is the folder name.
struct RecentProjectsMenu: View {
    @Bindable var state: AppState

    var body: some View {
        ForEach(state.workspace.recentPaths, id: \.self) { path in
            Button(URL(fileURLWithPath: path).lastPathComponent) {
                state.openProject(at: URL(fileURLWithPath: path))
            }
        }
    }
}
