import AppKit
import SwiftUI

private struct ProjectIsVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// True only while this project's editor is actually on screen. A hidden
    /// project and an editor hidden by terminal-full both report false.
    var projectIsVisible: Bool {
        get { self[ProjectIsVisibleKey.self] }
        set { self[ProjectIsVisibleKey.self] = newValue }
    }
}

/// The stable, observable inputs a retained editor root needs. The root view
/// is created once; changing this object updates the view without replacing
/// its identity, so @State survives.
@MainActor
@Observable
final class ProjectEditorHostContext {
    var isVisible: Bool
    var colorScheme: ColorScheme
    var displayScale: CGFloat
    var canvasInset: CGFloat
    var canvasRadius: CGFloat
    var workspaceTheme: WorkspaceTheme

    init(
        isVisible: Bool = false,
        colorScheme: ColorScheme,
        displayScale: CGFloat,
        canvasInset: CGFloat,
        canvasRadius: CGFloat,
        workspaceTheme: WorkspaceTheme
    ) {
        self.isVisible = isVisible
        self.colorScheme = colorScheme
        self.displayScale = displayScale
        self.canvasInset = canvasInset
        self.canvasRadius = canvasRadius
        self.workspaceTheme = workspaceTheme
    }
}

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
            project.code.setProjectVisible(context.isVisible)
        }
        .onChange(of: context.isVisible) { _, visible in
            // External-change policy follows the editor's actual visibility:
            // an inactive project and one hidden by the full-screen terminal
            // both advance only the disk until the user reviews.
            project.code.setProjectVisible(visible)
            guard !visible else { return }
            // Hidden media must be silent, including subtitle media owned by
            // the workspace and the demo transport.
            project.subtitles.pauseForDeactivation()
            if project.isDemo {
                state.isPlaying = false
            }
        }
    }
}

@MainActor
final class ProjectEditorHostRegistry {
    struct Entry {
        let project: Project
        let host: NSView
        let context: ProjectEditorHostContext
    }

    private(set) var entries: [ObjectIdentifier: Entry] = [:]
    private let makeHost: (Project, ProjectEditorHostContext) -> NSView

    init(
        makeHost: @escaping (Project, ProjectEditorHostContext) -> NSView
    ) {
        self.makeHost = makeHost
    }

    func entry(
        for project: Project,
        colorScheme: ColorScheme,
        displayScale: CGFloat,
        canvasInset: CGFloat,
        canvasRadius: CGFloat,
        workspaceTheme: WorkspaceTheme
    ) -> Entry {
        let key = ObjectIdentifier(project)
        if let existing = entries[key] {
            existing.context.colorScheme = colorScheme
            existing.context.displayScale = displayScale
            existing.context.canvasInset = canvasInset
            existing.context.canvasRadius = canvasRadius
            existing.context.workspaceTheme = workspaceTheme
            return existing
        }
        let context = ProjectEditorHostContext(
            colorScheme: colorScheme,
            displayScale: displayScale,
            canvasInset: canvasInset,
            canvasRadius: canvasRadius,
            workspaceTheme: workspaceTheme
        )
        let entry = Entry(
            project: project,
            host: makeHost(project, context),
            context: context
        )
        entries[key] = entry
        return entry
    }

    func update(
        colorScheme: ColorScheme,
        displayScale: CGFloat,
        canvasInset: CGFloat,
        canvasRadius: CGFloat,
        workspaceTheme: WorkspaceTheme
    ) {
        for entry in entries.values {
            entry.context.colorScheme = colorScheme
            entry.context.displayScale = displayScale
            entry.context.canvasInset = canvasInset
            entry.context.canvasRadius = canvasRadius
            entry.context.workspaceTheme = workspaceTheme
        }
    }

    func prune(keeping projects: [Project]) {
        let live = Set(projects.map { ObjectIdentifier($0) })
        for (key, entry) in entries where !live.contains(key) {
            entry.host.removeFromSuperview()
            entries[key] = nil
        }
    }

    func removeAll() {
        for entry in entries.values {
            entry.host.removeFromSuperview()
        }
        entries.removeAll()
    }
}

/// Retains one editor host per visited project and shows only the active one.
@MainActor
final class ProjectEditorHostContainer: NSView {
    private(set) var registry: ProjectEditorHostRegistry
    private var projects: [Project] = []
    private var activeProject: Project?
    private var colorScheme: ColorScheme
    private var displayScale: CGFloat
    private var canvasInset: CGFloat
    private var canvasRadius: CGFloat
    private var workspaceTheme: WorkspaceTheme
    private weak var visibleEntryHost: NSView?

    init(
        state: AppState,
        colorScheme: ColorScheme,
        displayScale: CGFloat,
        canvasInset: CGFloat,
        canvasRadius: CGFloat,
        workspaceTheme: WorkspaceTheme,
        hostFactory: ((Project, ProjectEditorHostContext) -> NSView)? = nil
    ) {
        self.colorScheme = colorScheme
        self.displayScale = displayScale
        self.canvasInset = canvasInset
        self.canvasRadius = canvasRadius
        self.workspaceTheme = workspaceTheme
        registry = ProjectEditorHostRegistry(
            makeHost: hostFactory ?? { project, context in
                let host = NSHostingView(
                    rootView: ProjectEditorRoot(
                        state: state,
                        project: project,
                        context: context
                    )
                )
                host.sizingOptions = []
                return host
            }
        )
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func sync(
        projects: [Project],
        active: Project,
        colorScheme: ColorScheme,
        displayScale: CGFloat,
        canvasInset: CGFloat,
        canvasRadius: CGFloat,
        workspaceTheme: WorkspaceTheme
    ) {
        self.projects = projects
        self.activeProject = active
        self.colorScheme = colorScheme
        self.displayScale = displayScale
        self.canvasInset = canvasInset
        self.canvasRadius = canvasRadius
        self.workspaceTheme = workspaceTheme
        registry.prune(keeping: projects)
        registry.update(
            colorScheme: colorScheme,
            displayScale: displayScale,
            canvasInset: canvasInset,
            canvasRadius: canvasRadius,
            workspaceTheme: workspaceTheme
        )
        updateVisibility()
    }

    override func layout() {
        super.layout()
        updateVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor {
            displayScale = scale
            registry.update(
                colorScheme: colorScheme,
                displayScale: displayScale,
                canvasInset: canvasInset,
                canvasRadius: canvasRadius,
                workspaceTheme: workspaceTheme
            )
        }
        updateVisibility()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor, scale != displayScale {
            displayScale = scale
            registry.update(
                colorScheme: colorScheme,
                displayScale: displayScale,
                canvasInset: canvasInset,
                canvasRadius: canvasRadius,
                workspaceTheme: workspaceTheme
            )
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let scheme: ColorScheme =
            effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                == .darkAqua ? .dark : .light
        if scheme != colorScheme {
            colorScheme = scheme
            registry.update(
                colorScheme: colorScheme,
                displayScale: displayScale,
                canvasInset: canvasInset,
                canvasRadius: canvasRadius,
                workspaceTheme: workspaceTheme
            )
        }
    }

    func tearDown() {
        hideAll()
        // `registry.removeAll()` owns host removal; repeating the traversal
        // here removed the same views twice.
        registry.removeAll()
    }

    private func updateVisibility() {
        guard let activeProject,
              projects.contains(where: { $0 === activeProject }),
              bounds.width > 0,
              bounds.height > 0 else {
            hideAll()
            return
        }
        let entry = registry.entry(
            for: activeProject,
            colorScheme: colorScheme,
            displayScale: displayScale,
            canvasInset: canvasInset,
            canvasRadius: canvasRadius,
            workspaceTheme: workspaceTheme
        )

        if let visibleEntryHost, visibleEntryHost !== entry.host {
            resignFocus(in: visibleEntryHost)
            visibleEntryHost.isHidden = true
        }

        for other in registry.entries.values where other.project !== activeProject {
            other.host.isHidden = true
            other.context.isVisible = false
        }

        if entry.host.superview !== self {
            addSubview(entry.host)
        }
        entry.host.frame = bounds
        entry.host.isHidden = false
        entry.context.isVisible = true
        visibleEntryHost = entry.host
    }

    private func hideAll() {
        if let visibleEntryHost {
            resignFocus(in: visibleEntryHost)
        }
        visibleEntryHost = nil
        for entry in registry.entries.values {
            entry.host.isHidden = true
            entry.context.isVisible = false
        }
    }

    private func resignFocus(in host: NSView) {
        guard let window = host.window,
              let responder = window.firstResponder as? NSView,
              responder === host || responder.isDescendant(of: host) else {
            return
        }
        if !window.makeFirstResponder(nil) {
            window.endEditing(for: nil)
            _ = window.makeFirstResponder(nil)
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
