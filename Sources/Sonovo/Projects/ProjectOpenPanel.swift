import AppKit

/// One open-project panel shared by the sidebar and the Project menu. A
/// folder is the unit of work; multiple selection opens each folder and lets
/// the last one become active, matching the existing behavior.
@MainActor
enum ProjectOpenPanel {
    static func present(state: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open Project"
        panel.message = "Choose a folder to open as a project."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            state.openProject(at: url)
        }
    }
}
