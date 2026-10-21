import SwiftUI

/// The script tab hosts the native Markdown workspace. The old static
/// prototype is gone: source is the document, and both modes project the same
/// parsed model.
struct ScriptView: View {
    let project: Project

    var body: some View {
        MarkdownWorkspaceView(workspace: project.markdown)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
