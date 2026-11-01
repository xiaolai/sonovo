import AppKit
import SwiftUI
import SonovoDomainTypes
import SonovoDesignSystem
import SonovoFeatureAPI
import SonovoWorkspaceHost

/// One retained project editor. It is a separate SwiftUI root, so every
/// environment value it needs is injected explicitly.
struct ProjectEditorRoot: View {
    let state: AppState
    let project: Project
    let context: ProjectEditorHostContext

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            if state.showTabBar {
                EditorTabBar(state: state, project: project)
            }
            if state.showBreadcrumbs {
                EditorBreadcrumb(state: state, project: project)
            }
            EditorContentView(state: state, project: project)
                .appCanvasStyle(
                    inset: context.canvasInset,
                    radius: context.canvasRadius
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(state)
        .environment(\.projectIsVisible, context.isVisible)
        .environment(\.colorScheme, context.colorScheme)
        .environment(\.displayScale, context.displayScale)
        // This root is its own NSHostingView; environment values from the
        // window do not cross into it.
        .environment(\.workspaceTheme, context.workspaceTheme)
        .tint(context.workspaceTheme.accent)
        .onAppear {
            project.featureSessions.editorVisibilityChanged(context.isVisible)
        }
        .onChange(of: context.isVisible) { _, visible in
            // External-change policy follows the editor's actual visibility:
            // an inactive project and one hidden by the full-screen terminal
            // both advance only the disk until the user reviews.
            project.featureSessions.editorVisibilityChanged(visible)
            guard !visible else { return }
            // Hidden media must be silent, including subtitle media owned by
            // the workspace and the demo transport.
            state.runtime.editorVisibilityChanged(project: project, visible: visible)
        }
    }
}

struct ProjectEditorHostsView: NSViewRepresentable {
    let state: AppState
    /// Passed explicitly so the parent body observes project open/close and
    /// activation; reading them only in `updateNSView` would not schedule it.
    let projects: [Project]
    let active: Project
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.workspaceTheme) private var workspaceTheme
    @AppStorage("sonovo.canvasInset")
    private var canvasInset = AppTheme.Canvas.comfortableInset
    @AppStorage("sonovo.canvasRadius")
    private var canvasRadius = AppTheme.Canvas.roundedRadius

    func makeNSView(context: Context) -> ProjectEditorHostContainer {
        ProjectEditorHostContainer(
            state: state,
            colorScheme: colorScheme,
            displayScale: displayScale,
            canvasInset: CGFloat(canvasInset),
            canvasRadius: CGFloat(canvasRadius),
            workspaceTheme: workspaceTheme
        )
    }

    func updateNSView(
        _ nsView: ProjectEditorHostContainer,
        context: Context
    ) {
        nsView.sync(
            projects: projects,
            active: active,
            colorScheme: colorScheme,
            displayScale: displayScale,
            canvasInset: CGFloat(canvasInset),
            canvasRadius: CGFloat(canvasRadius),
            workspaceTheme: workspaceTheme
        )
    }

    static func dismantleNSView(
        _ nsView: ProjectEditorHostContainer,
        coordinator: ()
    ) {
        nsView.tearDown()
    }
}

extension ProjectEditorHostContainer {
    convenience init(state: AppState, colorScheme: ColorScheme, displayScale: CGFloat, canvasInset: CGFloat,
                     canvasRadius: CGFloat, workspaceTheme: WorkspaceTheme,
                     hostFactory: ((Project, ProjectEditorHostContext) -> NSView)? = nil) {
        self.init(colorScheme: colorScheme, displayScale: displayScale, canvasInset: canvasInset, canvasRadius: canvasRadius,
            workspaceTheme: workspaceTheme, hostFactory: hostFactory ?? { project, context in
                let host = NSHostingView(rootView: ProjectEditorRoot(state: state, project: project, context: context))
                host.sizingOptions = []; return host
            })
    }
}
