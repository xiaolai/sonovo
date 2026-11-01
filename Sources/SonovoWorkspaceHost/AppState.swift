import SonovoFileIO
import Foundation
import Observation
import SwiftUI
import SonovoDomainTypes
import SonovoDesignSystem
import SonovoFeatureAPI
import SonovoDocumentSupport

@MainActor @Observable package final class AppState: MediaReplaceRequestSource {
    package let workspace: Workspace
    package let runtime: any ApplicationRuntime
    private let documentCloseCoordinator = DocumentCloseCoordinator()
    package var appAlert: AppAlert?
    package var navigatorMode: NavigatorMode = .production
    package var columnVisibility: NavigationSplitViewVisibility = .all
    package var inspectorVisible = false
    package var showTabBar = true
    package var mediaReplaceRequest: MediaReplaceRequest?
    package var showBreadcrumbs = Preferences.showBreadcrumbs {
        didSet {
            UserDefaults.standard.set(
                showBreadcrumbs,
                forKey: PreferenceKey.showBreadcrumbs
            )
        }
    }

    // Launch behavior. Settings binds these directly; the consumers are
    // `Workspace.restore` and `Workspace.recover`.
    package var restoreTabs = Preferences.restoreTabs {
        didSet {
            UserDefaults.standard.set(
                restoreTabs,
                forKey: PreferenceKey.restoreTabs
            )
        }
    }
    package var reopenLast = Preferences.reopenLast {
        didSet {
            UserDefaults.standard.set(
                reopenLast,
                forKey: PreferenceKey.reopenLast
            )
        }
    }

    package var terminalPresentation: TerminalPresentation = .hidden
    package var terminalDock: TerminalDock = .automatic
    package var terminalFraction: CGFloat = AppTheme.Layout.terminalDefaultFraction

    package var liveProject: Project { workspace.liveProject }

    /// Every active-project transition passes through here. Leaving the demo
    /// stops its transport; staying on the demo leaves playback alone.
    private func withProjectTransition<T>(_ change: () -> T) -> T {
        let previous = liveProject
        mediaReplaceRequest = nil
        let result = change()
        runtime.projectDidTransition(from: previous, to: liveProject)
        return result
    }

    package func activateProject(_ project: Project) {
        withProjectTransition {
            workspace.activate(project)
        }
    }

    @discardableResult
    package func openProject(at url: URL) -> Project? {
        withProjectTransition {
            workspace.openProject(at: url)
        }
    }

    package func activateNextProject() {
        withProjectTransition {
            _ = workspace.activateNext()
        }
    }

    package func activatePreviousProject() {
        withProjectTransition {
            _ = workspace.activatePrevious()
        }
    }
    package var openTabs: [EditorTab] { liveProject.openTabs }
    package var selectedAssetID: String? {
        get { liveProject.selectedAssetID }
        set { liveProject.selectedAssetID = newValue }
    }
    package var filterText: String {
        get { liveProject.filterText }
        set { liveProject.filterText = newValue }
    }
    /// Bumped by the Filter Navigator command. The sidebar watches it so a
    /// menu shortcut can focus the custom filter field.
    package var focusSidebarFilter = 0


    package var activityText: String {
        if let activity = liveProject.featureSessions.activity { return activity.text }
        if let native = runtime.activityText(for: liveProject) { return native }
        if let reason = liveProject.offlineReason { return reason }
        return "\(liveProject.assets.count) files"
    }
    package var windowTitle: String { runtime.windowTitle(for: liveProject) ?? liveProject.name }
    package init(hostWorkspace: Workspace, runtime: any ApplicationRuntime = NoopApplicationRuntime()) {
        self.workspace = hostWorkspace; self.runtime = runtime
    }
    package var selectedTab: EditorTab? { liveProject.selectedTab }
    package func displayName(for tab: EditorTab) -> String { liveProject.displayName(for: tab) }
    package func openAsset(_ id: String?) { liveProject.openAsset(id: id) }
    package func selectTab(_ id: String) { liveProject.selectTab(id) }
    /// ⌘S dispatches on the visible editor. Saving a hidden workspace would
    /// report success for a file the user cannot see.
    private var selectedSaveCommands: DocumentSaveCommands? {
        guard let tab = selectedTab else { return nil }
        return liveProject.documentAdapter(for: tab)?.saveCommands
    }

    package var canSaveSelectedDocument: Bool {
        terminalPresentation != .full && selectedSaveCommands?.canSave == true
    }

    package func saveSelectedDocument() async {
        guard canSaveSelectedDocument, let commands = selectedSaveCommands else { return }
        await commands.save()
    }

    package var canSaveSelectedDocumentAs: Bool {
        terminalPresentation != .full && selectedSaveCommands?.canSaveAs == true
    }

    package func saveSelectedDocumentAs() async {
        guard canSaveSelectedDocumentAs, let commands = selectedSaveCommands else { return }
        await commands.saveAs()
    }

    /// Saves every project's workspaces before the window closes. Subtitle
    /// files always have a path, so they never ask for a save/discard
    /// decision; a failed subtitle save cancels the close and leaves the
    /// failing project active and visible.
    package func flushAllBeforeClose() async -> Bool {
        let ordered = [liveProject] + workspace.allProjects.filter { $0 !== liveProject }
        return await documentCloseCoordinator.flush(
            participants: {
                ordered.flatMap { project in
                    project.documentWorkspaces.adapters.compactMap { adapter ->
                        (DocumentWorkspaceAdapter, DocumentTerminationParticipant)? in
                        guard let participant = adapter.termination else { return nil }
                        return (adapter, participant)
                    }.sorted { $0.1.priority < $1.1.priority }.map { adapter, participant in
                        CloseFlushParticipant(
                            isDirty: { adapter.hasDirtyDocuments },
                            flush: participant.flush,
                            revealFailure: { [weak self] in
                                guard let self else { return }
                                self.activateProject(project)
                                let document = adapter.pendingDecision?.document
                                    ?? adapter.selectedDocument ?? adapter.documents.first
                                guard let document else { return }
                                self.revealDocument(featureID: adapter.featureID, document: document, owner: project)
                            }
                        )
                    }
                }
            },
            allClean: { !self.workspace.hasDirtyDocuments }
        )
    }

    private var pendingDecisionFeatures: [FeatureID] {
        var seen = Set<FeatureID>()
        return workspace.allProjects.flatMap { $0.documentWorkspaces.adapters }
            .filter { $0.decisionPriority != nil && seen.insert($0.featureID).inserted }
            .sorted { ($0.decisionPriority ?? 0) < ($1.decisionPriority ?? 0) }
            .map(\.featureID)
    }

    private func pendingDecision(for featureID: FeatureID) ->
        (Project, DocumentWorkspaceAdapter, DocumentPendingDecision)? {
        for project in workspace.allProjects {
            guard let adapter = project.documentWorkspaces.adapter(for: featureID),
                  let decision = adapter.pendingDecision else { continue }
            return (project, adapter, decision)
        }
        return nil
    }

    private var firstPendingDecision: (Project, DocumentWorkspaceAdapter, DocumentPendingDecision)? {
        pendingDecisionFeatures.lazy.compactMap { self.pendingDecision(for: $0) }.first
    }

    package var hasPendingCloseDecision: Bool { firstPendingDecision != nil }

    package func savePendingClose() {
        guard let (owner, adapter, decision) = firstPendingDecision else { return }
        revealDocument(featureID: adapter.featureID, document: decision.document, owner: owner)
        Task { await decision.save() }
    }

    package func discardPendingClose() {
        firstPendingDecision?.2.discard()
    }

    package func cancelPendingClose() {
        for featureID in pendingDecisionFeatures {
            guard let (owner, _, decision) = pendingDecision(for: featureID) else { continue }
            decision.cancel()
            owner.cancelBulkClose()
        }
    }

    package var hasDirtyDocuments: Bool {
        workspace.hasDirtyDocuments
    }


    package func prepareForTermination() {
        runtime.prepareForTermination()
        workspace.prepareForTermination()
    }
    package func revealDocument(kind: AssetKind, url: URL?, owner: Project?, select: (Project) -> Void) {
        if terminalPresentation == .full { terminalPresentation = .hidden }
        let project = owner ?? liveProject
        if let owner { activateProject(owner) }
        if let featureID = project.documentWorkspaces.adapter(for: kind)?.featureID {
            revealTab(in: project, featureID: featureID, url: url)
        }
        select(project)
    }
    package func revealDocument(featureID: FeatureID, document: WorkspaceDocumentReference, owner: Project) {
        if terminalPresentation == .full { terminalPresentation = .hidden }
        activateProject(owner)
        revealTab(in: owner, featureID: featureID, url: document.url)
        document.select()
    }
    private func revealTab(in project: Project, featureID: FeatureID, url: URL?) {
        let canonical = url.map { SonovoFileIO.FilePathPolicy.canonical($0).path }
        if let canonical, let tab = project.openTabs.first(where: { tab in
            project.documentAdapter(for: tab)?.featureID == featureID
                && tab.url.map { SonovoFileIO.FilePathPolicy.canonical($0).path == canonical } == true
        }) { project.selectTab(tab.id); return }
        if let tab = project.openTabs.first(where: {
            $0.workspaceKind != nil && project.documentAdapter(for: $0)?.featureID == featureID
        }) { project.selectTab(tab.id); return }
        project.showWorkspace(featureID: featureID, preferExistingFile: false)
    }
}
