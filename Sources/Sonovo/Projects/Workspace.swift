import AppKit
import Foundation
import Observation
import SonovoCore

/// The set of open folders plus the built-in demo. This is the only place
/// that knows about more than one project; every other view reads the active
/// one.
@MainActor
@Observable
final class Workspace {
    private(set) var projects: [Project] = []
    private(set) var recentPaths: [String]
    let demoProject: Project
    /// nil means the demo project is active.
    private(set) var activeProjectID: String?
    var lastError: String?

    private let store: WorkspacePersisting
    private let scanner: ProjectScanner
    private let watchFactory: ProjectWatchFactory
    private let terminalEnvironment: TerminalEnvironment
    @ObservationIgnored private var mountObserver: NSObjectProtocol?
    @ObservationIgnored private var unmountObserver: NSObjectProtocol?

    init(
        demoProject: Project,
        store: WorkspacePersisting = UserDefaultsWorkspaceStore(),
        scanner: ProjectScanner = ProjectScanner(),
        watchFactory: @escaping ProjectWatchFactory = {
            FSEventSource(root: $0, onChange: $1)
        },
        terminalEnvironment: TerminalEnvironment = .disabled
    ) {
        self.demoProject = demoProject
        self.store = store
        self.scanner = scanner
        self.watchFactory = watchFactory
        self.terminalEnvironment = terminalEnvironment
        self.recentPaths = store.recentPaths
        observeVolumes()
    }

    isolated deinit {
        if let mountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(mountObserver)
        }
        if let unmountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(unmountObserver)
        }
    }

    var activeProject: Project? {
        guard let activeProjectID else { return nil }
        return projects.first { $0.id == activeProjectID }
    }

    var liveProject: Project {
        activeProject ?? demoProject
    }

    var allProjects: [Project] {
        projects + [demoProject]
    }

    var hasDirtyDocuments: Bool {
        allProjects.contains(where: \.hasDirtyDocuments)
    }

    private var recoveringProjects: Set<String> = []
    /// A recovery requested while the same project was already recovering.
    private var recoveryRetries: Set<String> = []

    // MARK: - Restore

    func restore() {
        var restored: [Project] = []
        for storedPath in store.projectPaths {
            let canonical = MarkdownSecurity.canonical(
                URL(fileURLWithPath: storedPath)
            )
            var isDirectory: ObjCBool = false
            let available = FileManager.default.fileExists(
                atPath: canonical.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue

            let volume = available ? volumeIdentifier(for: canonical) : nil
            let storedVolume = store.volumeIdentifiers[canonical.path]
            if available,
               let storedVolume,
               let volume,
               storedVolume != volume {
                let project = Project(
                    offlinePath: canonical.path,
                    reason: "This path now belongs to a different volume.",
                    expectedVolumeIdentifier: storedVolume,
                    scanner: scanner,
                    watchFactory: watchFactory,
                    terminalEnvironment: terminalEnvironment
                )
                attach(project)
                restored.append(project)
                continue
            }

            let project = available
                ? Project(
                    folderURL: canonical,
                    expectedVolumeIdentifier: storedVolume ?? volume,
                    scanner: scanner,
                    watchFactory: watchFactory,
                    terminalEnvironment: terminalEnvironment
                )
                : Project(
                    offlinePath: canonical.path,
                    reason: "This folder is unavailable.",
                    expectedVolumeIdentifier: storedVolume,
                    scanner: scanner,
                    watchFactory: watchFactory,
                    terminalEnvironment: terminalEnvironment
                )
            attach(project)
            restored.append(project)
        }
        projects = restored

        // Protect every restored selection before anything can persist a
        // pre-scan empty value.
        for project in projects {
            project.isRestoringSelection = true
        }

        if let activePath = store.activePath,
           let project = projects.first(where: { $0.id == activePath }) {
            activeProjectID = project.id
            if project.isOffline {
                // Recovery restores the stored selection; activation must
                // not start an unprotected load first.
                project.activate(loadIfOffline: false)
            } else {
                project.activate()
            }
        } else {
            activeProjectID = nil
            demoProject.activate()
        }
        recentPaths = store.recentPaths

        for project in projects
        where !project.isOffline || project.id == activeProjectID {
            Task { @MainActor [weak self] in
                await self?.recover(project)
            }
        }
    }

    /// One recovery path for restore, activation, and retry. It captures the
    /// stored selection before the scan, suppresses persistence until the
    /// scan finishes, and ignores a project that went offline or was closed
    /// while loading.
    private func recover(_ project: Project) async {
        guard !project.isDemo,
              projects.contains(where: { $0 === project }) else {
            return
        }
        guard !recoveringProjects.contains(project.id) else {
            // A mount or retry arrived while this project was recovering.
            // Its event is already consumed, so it must not be dropped:
            // queue one more attempt after the current one finishes.
            recoveryRetries.insert(project.id)
            return
        }
        recoveringProjects.insert(project.id)
        defer {
            recoveringProjects.remove(project.id)
            if recoveryRetries.remove(project.id) != nil {
                Task { @MainActor [weak self, weak project] in
                    guard let self, let project else { return }
                    await self.recover(project)
                }
            }
        }

        let selection = store.selections[project.id]
        let selectionRevision = project.selectionRevision
        project.isRestoringSelection = true
        await project.load()
        project.isRestoringSelection = false
        // Match the instance, not the path: closing and reopening the same
        // folder creates a new project whose saved selection this stale
        // recovery must not touch.
        guard projects.contains(where: { $0 === project }) else {
            return
        }
        if project.selectionRevision != selectionRevision {
            // The user changed the selection while the scan was running,
            // including choosing a synthetic workspace tab or closing every
            // tab. Persist that choice even when the project went offline
            // during the scan: the next recovery must not treat the stored
            // old selection as still valid. A nil selection is deliberate;
            // assigning nil removes the stored path.
            store.selections[project.id] = project.selectedAssetID
            return
        }
        guard !project.isOffline else { return }
        restoreSelection(project, path: selection)
    }

    private func restoreSelection(_ project: Project, path: String?) {
        guard let path,
              let asset = project.assets.first(where: { $0.id == path })
        else { return }
        project.openAsset(asset)
    }

    // MARK: - Opening

    @discardableResult
    func openProject(at url: URL, activate shouldActivate: Bool = true) -> Project? {
        let canonical = MarkdownSecurity.canonical(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: canonical.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            lastError = "That folder is unavailable."
            return nil
        }

        if let existing = projects.first(where: { $0.id == canonical.path }) {
            if shouldActivate { activate(existing) }
            return existing
        }

        for project in projects {
            guard let root = project.root else { continue }
            let rootPath = root.path.hasSuffix("/")
                ? root.path
                : root.path + "/"
            let candidatePath = canonical.path.hasSuffix("/")
                ? canonical.path
                : canonical.path + "/"
            if candidatePath.hasPrefix(rootPath)
                || rootPath.hasPrefix(candidatePath) {
                lastError = "“\(project.name)” already contains this folder. "
                    + "Open a folder that does not overlap an open project."
                return nil
            }
        }

        let volume = volumeIdentifier(for: canonical)
        let project = Project(
            folderURL: canonical,
            expectedVolumeIdentifier: volume,
            scanner: scanner,
            watchFactory: watchFactory,
            terminalEnvironment: terminalEnvironment
        )
        projects.append(project)
        attach(project)
        rememberPath(canonical.path)
        store.volumeIdentifiers[canonical.path] = volume
        store.projectPaths = projects.map(\.id)
        if shouldActivate {
            activate(project)
        }
        Task { @MainActor in
            await project.load()
        }
        return project
    }

    func retryOfflineProjects() {
        for project in projects where project.isOffline {
            retry(project)
        }
    }

    /// Retries one offline project through the same recovery path used at
    /// restore. A direct `load()` would skip the saved-selection restore and
    /// leave `isRestoringSelection` set, suppressing persistence afterwards.
    func retry(_ project: Project) {
        guard !project.isDemo,
              projects.contains(where: { $0 === project }) else {
            return
        }
        Task { @MainActor [weak self, weak project] in
            guard let self, let project else { return }
            await self.recover(project)
        }
    }

    // MARK: - Activation

    func activate(_ project: Project) {
        guard project.isDemo || projects.contains(where: { $0.id == project.id })
        else { return }
        // Selecting the active project again must not deactivate it: that
        // would pause its subtitle media and reset activation state. Compare
        // the stored active identity as well as the fallback `liveProject`:
        // after the last project closes, `liveProject` is the demo while the
        // stored ID still names the closed project.
        let isStoredActive = project.isDemo
            ? activeProjectID == nil
            : activeProjectID == project.id
        if isStoredActive, project.isActive, !project.isOffline {
            return
        }
        activeProject?.deactivate()
        demoProject.deactivate()
        activeProjectID = project.isDemo ? nil : project.id
        if project.isOffline {
            // Recover the saved selection ourselves; the project's own
            // activation would load without restoring it.
            project.activate(loadIfOffline: false)
            Task { @MainActor [weak self, weak project] in
                guard let self, let project else { return }
                await self.recover(project)
            }
        } else {
            project.activate()
        }
        store.activePath = project.isDemo ? nil : project.id
        if !project.isOffline {
            markSelectionChanged(project)
        }
    }

    func activateDemo() {
        activate(demoProject)
    }

    /// Refresh every project's terminal badge count. Called by the chip
    /// rail's polling task while it is visible.
    func refreshTerminalProcessStates() {
        for project in allProjects {
            project.terminalSessions.refreshProcessStates()
        }
    }

    /// The stable shortcut order: real projects in open order, then the demo.
    /// Commands and tests share this mapping so a digit never names two
    /// different projects.
    func project(atShortcutIndex index: Int) -> Project? {
        let entries = allProjects
        guard entries.indices.contains(index) else { return nil }
        return entries[index]
    }

    @discardableResult
    func activateNext() -> Project? {
        let entries = allProjects
        guard !entries.isEmpty else { return nil }
        let current = entries.firstIndex { $0 === liveProject } ?? -1
        let next = entries[(current + 1) % entries.count]
        activate(next)
        return next
    }

    @discardableResult
    func activatePrevious() -> Project? {
        let entries = allProjects
        guard !entries.isEmpty else { return nil }
        let current = entries.firstIndex { $0 === liveProject } ?? 0
        let previous = entries[
            (current - 1 + entries.count) % entries.count
        ]
        activate(previous)
        return previous
    }

    func markSelectionChanged(_ project: Project) {
        // An offline project has not restored its assets yet, and a project
        // being recovered is still reporting pre-scan state. Persisting
        // either would delete the saved selection before it is restored.
        guard !project.isOffline, !project.isRestoringSelection else {
            return
        }
        store.selections[project.id] = project.selectedAssetID
        if project.id == activeProjectID || project.isDemo {
            store.activePath = project.isDemo ? nil : project.id
        }
    }

    // MARK: - Closing

    @discardableResult
    func closeProject(_ project: Project) -> Bool {
        guard !project.isDemo else { return false }
        guard !project.hasDirtyDocuments else {
            lastError = "Save or close “\(project.name)”'s documents first."
            return false
        }
        // tmux-backed terminals detach on close and keep their agents
        // running. Only a direct shell can lose work, so only it prompts.
        if project.terminalSessions.hasLiveDirectProcess {
            let alert = NSAlert()
            alert.messageText = "Close “\(project.name)”?"
            alert.informativeText =
                "A terminal in this project is still running a process."
            alert.addButton(withTitle: "Close Project")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return false
            }
        }

        let wasActive = activeProjectID == project.id
        // Stop subtitle media and the activation contract before the object
        // leaves the workspace; activate(next) can no longer find this one.
        project.deactivate()
        project.invalidate()
        project.prepareForTermination()
        projects.removeAll { $0.id == project.id }
        store.projectPaths = projects.map(\.id)
        store.selections[project.id] = nil
        store.volumeIdentifiers[project.id] = nil
        if wasActive {
            if let next = projects.first {
                activate(next)
            } else {
                activateDemo()
            }
        }
        return true
    }

    // MARK: - Termination

    func prepareForTermination() {
        for project in allProjects {
            project.prepareForTermination()
        }
    }

    // MARK: - Helpers

    private func attach(_ project: Project) {
        project.onSelectionChanged = { [weak self, weak project] in
            guard let self, let project else { return }
            self.markSelectionChanged(project)
        }
    }

    private func rememberPath(_ path: String) {
        var recent = recentPaths.filter { $0 != path }
        recent.insert(path, at: 0)
        recentPaths = Array(recent.prefix(10))
        store.recentPaths = recentPaths
    }

    private func volumeIdentifier(for url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeUUIDStringKey])
            .volumeUUIDString
    }

    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.retryOfflineProjects() }
        }
        unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.markUnavailableProjectsOffline() }
        }
    }

    private func markUnavailableProjectsOffline() {
        for project in projects where !project.isOffline {
            guard let root = project.root else { continue }
            var isDirectory: ObjCBool = false
            let available = FileManager.default.fileExists(
                atPath: root.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
            if !available {
                project.markOffline("This folder is unavailable.")
            }
        }
    }
}
