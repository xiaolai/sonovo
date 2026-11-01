import SonovoFeatureAPI
import SonovoDesignSystem
import AppKit
import SwiftUI

/// The stable, observable inputs a retained editor root needs. The root view
/// is created once; changing this object updates the view without replacing
/// its identity, so @State survives.
@MainActor
@Observable
package final class ProjectEditorHostContext {
    package var isVisible: Bool
    package var colorScheme: ColorScheme
    package var displayScale: CGFloat
    package var canvasInset: CGFloat
    package var canvasRadius: CGFloat
    package var workspaceTheme: WorkspaceTheme

    package init(
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

    /// Applies only the values that changed. `updateNSView` runs for every
    /// environment change; writing an identical value into this observable
    /// object invalidates the retained editor root for nothing.
    package func update(
        colorScheme: ColorScheme,
        displayScale: CGFloat,
        canvasInset: CGFloat,
        canvasRadius: CGFloat,
        workspaceTheme: WorkspaceTheme
    ) {
        if self.colorScheme != colorScheme { self.colorScheme = colorScheme }
        if self.displayScale != displayScale {
            self.displayScale = displayScale
        }
        if self.canvasInset != canvasInset { self.canvasInset = canvasInset }
        if self.canvasRadius != canvasRadius {
            self.canvasRadius = canvasRadius
        }
        if self.workspaceTheme != workspaceTheme {
            self.workspaceTheme = workspaceTheme
        }
    }

    /// Visibility is published only from the sync pass, never from `layout()`.
    package func setVisible(_ visible: Bool) {
        if isVisible != visible { isVisible = visible }
    }
}

@MainActor
package final class ProjectEditorHostRegistry {
    package struct Entry {
        package let project: Project
        package let host: NSView
        package let context: ProjectEditorHostContext
    }

    package private(set) var entries: [ObjectIdentifier: Entry] = [:]
    private let makeHost: (Project, ProjectEditorHostContext) -> NSView

    package init(
        makeHost: @escaping (Project, ProjectEditorHostContext) -> NSView
    ) {
        self.makeHost = makeHost
    }

    package func entry(
        for project: Project,
        colorScheme: ColorScheme,
        displayScale: CGFloat,
        canvasInset: CGFloat,
        canvasRadius: CGFloat,
        workspaceTheme: WorkspaceTheme
    ) -> Entry {
        let key = ObjectIdentifier(project)
        if let existing = entries[key] {
            existing.context.update(
                colorScheme: colorScheme,
                displayScale: displayScale,
                canvasInset: canvasInset,
                canvasRadius: canvasRadius,
                workspaceTheme: workspaceTheme
            )
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

    package func update(
        colorScheme: ColorScheme,
        displayScale: CGFloat,
        canvasInset: CGFloat,
        canvasRadius: CGFloat,
        workspaceTheme: WorkspaceTheme
    ) {
        for entry in entries.values {
            entry.context.update(
                colorScheme: colorScheme,
                displayScale: displayScale,
                canvasInset: canvasInset,
                canvasRadius: canvasRadius,
                workspaceTheme: workspaceTheme
            )
        }
    }

    package func prune(keeping projects: [Project]) {
        let live = Set(projects.map { ObjectIdentifier($0) })
        for (key, entry) in entries where !live.contains(key) {
            entry.host.removeFromSuperview()
            entries[key] = nil
        }
    }

    package func removeAll() {
        for entry in entries.values {
            entry.host.removeFromSuperview()
        }
        entries.removeAll()
    }
}

/// Retains one editor host per visited project and shows only the active one.
@MainActor
package final class ProjectEditorHostContainer: NSView {
    package private(set) var registry: ProjectEditorHostRegistry
    private var projects: [Project] = []
    private var activeProject: Project?
    private var colorScheme: ColorScheme
    private var displayScale: CGFloat
    private var canvasInset: CGFloat
    private var canvasRadius: CGFloat
    private var workspaceTheme: WorkspaceTheme
    private weak var visibleEntryHost: NSView?
    /// A layout pass may have changed which host is visible; the observable
    /// publication is deferred to the next runloop turn and coalesced.
    private var visibilityPublishScheduled = false

    package init(
        colorScheme: ColorScheme,
        displayScale: CGFloat,
        canvasInset: CGFloat,
        canvasRadius: CGFloat,
        workspaceTheme: WorkspaceTheme,
        hostFactory: @escaping (Project, ProjectEditorHostContext) -> NSView
    ) {
        self.colorScheme = colorScheme
        self.displayScale = displayScale
        self.canvasInset = canvasInset
        self.canvasRadius = canvasRadius
        self.workspaceTheme = workspaceTheme
        registry = ProjectEditorHostRegistry(makeHost: hostFactory)
        super.init(frame: .zero)
    }

    package required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    package func sync(
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
        // Visibility publication is observable; doing it inside updateNSView
        // invalidates a view SwiftUI is currently updating. The coalesced
        // task publishes after the update returns.
        updateVisibility(publish: false)
        scheduleVisibilityPublish()
    }

    package override func layout() {
        super.layout()
        // Frames and hidden flags belong here. `context.isVisible` is
        // observable, and mutating it inside layout invalidates a SwiftUI
        // view during layout; publish it after the pass instead.
        updateVisibility(publish: false)
        scheduleVisibilityPublish()
    }

    package override func viewDidMoveToWindow() {
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

    package override func viewDidChangeBackingProperties() {
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

    package override func viewDidChangeEffectiveAppearance() {
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

    package func tearDown() {
        hideAll()
        // `registry.removeAll()` owns host removal; repeating the traversal
        // here removed the same views twice.
        registry.removeAll()
    }

    private func updateVisibility(publish: Bool = true) {
        guard let activeProject,
              projects.contains(where: { $0 === activeProject }),
              bounds.width > 0,
              bounds.height > 0 else {
            hideAll(publish: publish)
            return
        }
        // Layout may show or hide an existing host, but it must not update
        // that host's observable context. `sync` owns that publication; when
        // no host exists yet, creating one here is a local side effect only.
        let key = ObjectIdentifier(activeProject)
        let entry = registry.entries[key] ?? registry.entry(
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
            if publish {
                other.context.setVisible(false)
            }
        }

        if entry.host.superview !== self {
            addSubview(entry.host)
        }
        entry.host.frame = bounds
        entry.host.isHidden = false
        if publish {
            entry.context.setVisible(true)
        }
        visibleEntryHost = entry.host
    }

    private func scheduleVisibilityPublish() {
        guard !visibilityPublishScheduled else { return }
        visibilityPublishScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.visibilityPublishScheduled = false
            self.updateVisibility()
        }
    }

    private func hideAll(publish: Bool = true) {
        if let visibleEntryHost {
            resignFocus(in: visibleEntryHost)
        }
        visibleEntryHost = nil
        for entry in registry.entries.values {
            entry.host.isHidden = true
            if publish {
                entry.context.setVisible(false)
            }
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
