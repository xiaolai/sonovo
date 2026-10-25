import CoreGraphics
import Foundation
import Observation
import SonovoCore
import SwiftUI

enum TerminalPresentation: String, CaseIterable, Hashable, Identifiable, Sendable {
    case hidden
    case split
    case full

    var id: String { rawValue }
}

enum TerminalDock: String, CaseIterable, Hashable, Identifiable, Sendable {
    case automatic
    case right
    case bottom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .right: "Right"
        case .bottom: "Bottom"
        }
    }
}

enum TerminalDockPosition: Sendable {
    case right
    case bottom
    case full
}

@MainActor
enum AppStateRegistry {
    static weak var active: AppState?
}

@MainActor
@Observable
final class AppState {
    let production = Production.sample
    let transcript = SampleContent.transcript
    let workspace: Workspace
    let hygiene: TmuxHygieneStore
    let actionCoordinator: TmuxActionCoordinator?
    let archive: TmuxArchiveStore?
    let sessionsWindow: TmuxSessionsWindowModel
    private(set) var cleanupScheduler: TmuxCleanupScheduler?

    var navigatorMode: NavigatorMode = .production
    var columnVisibility: NavigationSplitViewVisibility = .all
    private var storedEditorMode: EditorMode = .player
    /// Compare and Transcript are demo surfaces that need an audio or video
    /// tab. The getter clamps the mode for every navigation path, including
    /// the Project methods that do not pass through `selectTab`.
    var editorMode: EditorMode {
        get { canUseMediaModes ? storedEditorMode : .player }
        set { storedEditorMode = newValue }
    }
    var inspectorVisible = false
    var showTabBar = true
    /// Set by the Media menu; the visible media edit surface owns the actual
    /// destructive-confirmation dialog.
    var mediaReplaceRequest = false
    /// A recording error that needs an alert because no media tab may be
    /// visible, such as a denied microphone request from the Project menu.
    var mediaErrorAlert: String?
    var showBreadcrumbs = Preferences.showBreadcrumbs {
        didSet {
            UserDefaults.standard.set(
                showBreadcrumbs,
                forKey: PreferenceKey.showBreadcrumbs
            )
        }
    }

    // Launch behavior. Settings binds these directly; the consumers are
    // `Workspace.restore` and `Workspace.recover`.
    var restoreTabs = Preferences.restoreTabs {
        didSet {
            UserDefaults.standard.set(
                restoreTabs,
                forKey: PreferenceKey.restoreTabs
            )
        }
    }
    var reopenLast = Preferences.reopenLast {
        didSet {
            UserDefaults.standard.set(
                reopenLast,
                forKey: PreferenceKey.reopenLast
            )
        }
    }

    var terminalPresentation: TerminalPresentation = .hidden
    var terminalDock: TerminalDock = .automatic
    var terminalFraction: CGFloat = AppTheme.Layout.terminalDefaultFraction

    var isPlaying = false
    var playhead: Double = 4.6 // token-exempt: demo playback state
    let duration: Double = 12.4 // token-exempt: demo playback state
    var volume: Double = 0.8 // token-exempt: demo playback state
    var isLooping = false
    var showCaptions = Preferences.captionsDefault {
        didSet {
            UserDefaults.standard.set(
                showCaptions,
                forKey: PreferenceKey.captionsDefault
            )
        }
    }
    var followPlayhead = Preferences.followPlayhead {
        didSet {
            UserDefaults.standard.set(
                followPlayhead,
                forKey: PreferenceKey.followPlayhead
            )
            if followPlayhead {
                selectedTranscriptID = currentTranscript?.id
            }
        }
    }

    var selectedTranscriptID: String? = "seg-2"
    var compareSplit: CGFloat = AppTheme.Layout.compareDefaultSplit
    var selectedStillIndex = 3
    var selectedShotIndex = 2

    var liveProject: Project { workspace.liveProject }

    /// Every active-project transition passes through here. Leaving the demo
    /// stops its transport; staying on the demo leaves playback alone.
    private func withProjectTransition<T>(_ change: () -> T) -> T {
        let wasDemo = liveProject.isDemo
        let result = change()
        if wasDemo, !liveProject.isDemo {
            isPlaying = false
        }
        return result
    }

    func activateProject(_ project: Project) {
        withProjectTransition {
            workspace.activate(project)
        }
    }

    @discardableResult
    func openProject(at url: URL) -> Project? {
        withProjectTransition {
            workspace.openProject(at: url)
        }
    }

    func activateNextProject() {
        withProjectTransition {
            _ = workspace.activateNext()
        }
    }

    func activatePreviousProject() {
        withProjectTransition {
            _ = workspace.activatePrevious()
        }
    }
    var markdown: MarkdownWorkspace { liveProject.markdown }
    var subtitles: SubtitleWorkspace { liveProject.subtitles }
    var models: Model3DWorkspace { liveProject.models }
    var code: CodeWorkspace { liveProject.code }
    var terminalSessions: TerminalSessionsStore {
        liveProject.terminalSessions
    }
    var openTabs: [EditorTab] { liveProject.openTabs }
    var selectedAssetID: String? {
        get { liveProject.selectedAssetID }
        set { liveProject.selectedAssetID = newValue }
    }
    var filterText: String {
        get { liveProject.filterText }
        set { liveProject.filterText = newValue }
    }
    /// Bumped by the Filter Navigator command. The sidebar watches it so a
    /// menu shortcut can focus the custom filter field.
    var focusSidebarFilter = 0

    var activityText: String {
        if liveProject.isRecordingAudio { return "Recording audio…" }
        if liveProject.mediaEdits.exportService.isBusy {
            return "Exporting media…"
        }
        if liveProject.isDemo {
            if isPlaying {
                return "Playing \(selectedAsset?.name ?? "media")"
            }
            return production.updated
        }
        if let reason = liveProject.offlineReason { return reason }
        return "\(liveProject.assets.count) files"
    }

    var windowTitle: String {
        liveProject.isDemo
            ? "\(production.title) — \(production.episode)"
            : liveProject.name
    }

    private struct TerminalServices {
        let hygiene: TmuxHygieneStore
        let coordinator: TmuxActionCoordinator?
        let archive: TmuxArchiveStore?
        let environment: TerminalEnvironment
    }

    init() {
        let runningTests = Self.isRunningTests
        let boot = BootIdentity(launchID: UUID(), startedAt: Date())
        let services = Self.makeTerminalServices(
            boot: boot,
            runningTests: runningTests
        )
        hygiene = services.hygiene
        actionCoordinator = services.coordinator
        archive = services.archive
        workspace = Workspace(
            demoProject: Self.makeDemoProject(
                production: production,
                terminalEnvironment: services.environment
            ),
            terminalEnvironment: services.environment
        )
        sessionsWindow = Self.makeSessionsWindow(services: services)
        cleanupScheduler = services.coordinator.map {
            TmuxCleanupScheduler(
                hygiene: services.hygiene,
                coordinator: $0
            )
        }
        AppStateRegistry.active = self
        applyLaunchEnvironment()
        configureHygiene(runningTests: runningTests)
    }

    private static func makeTerminalServices(
        boot: BootIdentity,
        runningTests: Bool
    ) -> TerminalServices {
        if runningTests {
            return TerminalServices(
                hygiene: TmuxHygieneStore(
                    transport: nil,
                    boot: boot,
                    ledgerStore: ObservedIdleLedgerStore(url: nil),
                    registry: TmuxOwnershipRegistryStore(url: nil),
                    settingsStore: TmuxHygieneSettingsStore(
                        defaults: UserDefaults(
                            suiteName:
                                "sonovo.tests.hygiene.\(UUID().uuidString)"
                        ) ?? .standard
                    ),
                    budgetStore: TmuxCleanupBudgetStore(url: nil),
                    reportStore: TmuxCleanupReportStore(url: nil)
                ),
                coordinator: nil,
                archive: nil,
                environment: .disabled
            )
        }

        let settingsStore = TmuxHygieneSettingsStore()
        let archive = TmuxArchiveStore(
            isEnabled: settingsStore.settings.captureEnabled,
            retentionDays: settingsStore.settings.retentionDays
        )
        let registry = TmuxOwnershipRegistryStore()
        let ledger = ObservedIdleLedgerStore()
        let coordinator = TmuxActionCoordinator(
            transport: LiveTmux.shared,
            boot: boot,
            archive: archive,
            registry: registry,
            ledger: ledger
        )
        let hygiene = TmuxHygieneStore(
            transport: LiveTmux.shared,
            boot: boot,
            ledgerStore: ledger,
            registry: registry,
            settingsStore: settingsStore,
            archive: archive
        )
        hygiene.uncertainProvider = {
            [weak coordinator] identity in
            coordinator?.isUncertain(identity) ?? true
        }
        coordinator.killSwitchProvider = {
            [weak hygiene] in
            guard let hygiene else { return true }
            return !hygiene.settings.isArmed
        }
        // Automatic End always captures and commits first. The archive being
        // off is a refusal, never a reason to delete without one.
        coordinator.captureRequiredProvider = { true }
        coordinator.automaticEligibilityProvider = {
            [weak hygiene] identity in
            hygiene?.attributes(for: identity)?.autoEligibility.eligible
                ?? false
        }
        hygiene.onPolicyChanged = { [weak coordinator] in
            coordinator?.invalidatePolicy()
        }
        coordinator.onActionCompleted = { [weak hygiene] in
            guard let hygiene else { return }
            hygiene.invalidateScan()
            Task { await hygiene.refresh() }
        }
        archive.isEnabled = settingsStore.settings.captureEnabled
        archive.setRetentionDays(settingsStore.settings.retentionDays)
        return TerminalServices(
            hygiene: hygiene,
            coordinator: coordinator,
            archive: archive,
            environment: TerminalEnvironment.live(
                isEnabled: {
                    UserDefaults.standard.object(
                        forKey: "sonovo.terminals.tmux"
                    ) as? Bool ?? true
                },
                coordinator: { [weak coordinator] in coordinator }
            )
        )
    }

    private static func makeDemoProject(
        production: Production,
        terminalEnvironment: TerminalEnvironment
    ) -> Project {
        Project.demo(
            production: production,
            markdown: MarkdownWorkspace(),
            subtitles: SubtitleWorkspace(),
            models: Model3DWorkspace(),
            terminalSessions: TerminalSessionsStore(
                workingDirectory: "~",
                projectKey: "sample",
                projectName: "Sample",
                terminalEnvironment: terminalEnvironment
            ),
            sampleDocuments: SampleProjectDocuments.live()
        )
    }

    private static func makeSessionsWindow(
        services: TerminalServices
    ) -> TmuxSessionsWindowModel {
        TmuxSessionsWindowModel(
            hygiene: services.hygiene,
            coordinator: services.coordinator,
            archive: services.archive,
            migration: TmuxMigrationModel(
                reportStore: TmuxMigrationReportStore(
                    url: TmuxMigrationReportStore.defaultURL()
                )
            )
        )
    }

    /// Launch-only presentation and demo environment. Kept out of `init` so
    /// construction and launch policy can be read independently.
    private func applyLaunchEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        let demoMode = environment["SONOVO_DEMO_TAB"] != nil
            || environment["SONOVO_DEMO_MODEL"] != nil
            || environment["SONOVO_DEMO_MARKDOWN"] != nil
            || environment["SONOVO_DEMO_SUBTITLE"] != nil
        if !Self.isRunningTests, !demoMode {
            workspace.restore()
        }
        if demoMode {
            workspace.activateDemo()
        }
        if let demoAssetID = environment["SONOVO_DEMO_TAB"],
           production.asset(id: demoAssetID) != nil {
            workspace.demoProject.openAsset(id: demoAssetID)
        }
        if let rawMode = environment["SONOVO_DEMO_MODE"],
           let mode = EditorMode(rawValue: rawMode) {
            editorMode = mode
        }
        if let rawTerminal = environment["SONOVO_DEMO_TERMINAL"] {
            let normalized = rawTerminal == "half" ? "split" : rawTerminal
            if let presentation = TerminalPresentation(rawValue: normalized) {
                terminalPresentation = presentation
            }
        }
        if environment["SONOVO_DEMO_MODEL"] != nil {
            showModel3DWorkspace()
        }
    }

    private func configureHygiene(runningTests: Bool) {
        let store = hygiene
        let workspace = workspace
        store.knownPathsProvider = { [weak workspace] in
            workspace?.hygieneKnownPaths ?? TmuxKnownPaths()
        }
        workspace.onKnownPathsChanged = { [weak self] in
            guard let self else { return }
            self.hygiene.knownPaths = self.workspace.hygieneKnownPaths
            self.hygiene.recomputeAttributes()
            self.actionCoordinator?.invalidateWorkspace()
        }
        sessionsWindow.knownPathsProvider = { [weak workspace] in
            workspace?.hygieneKnownPaths ?? TmuxKnownPaths()
        }
        sessionsWindow.projectChoices = { [weak self] in
            self?.projectChoices() ?? []
        }
        sessionsWindow.openSession = { [weak self] observation in
            self?.openTmuxSession(observation) ?? false
        }
        sessionsWindow.folderIdentity = { [weak self] path in
            self?.workspace.folderIdentity(forPath: path)
        }
        sessionsWindow.migrationSourceHint = { [weak self] projectID in
            guard let self,
                  let project = self.workspace.projects.first(where: {
                      $0.id == projectID
                  }) else {
                return nil
            }
            return self.workspace.migrationSourceHint(for: project)
        }
        sessionsWindow.reserveNames = { [weak self] names in
            self?.forAllTerminalStores { $0.reserveSessionNames(names) }
        }
        sessionsWindow.releaseNames = { [weak self] names in
            self?.forAllTerminalStores { $0.releaseSessionNames(names) }
        }
        sessionsWindow.rebindTabs = { [weak self] rebind in
            self?.rebindAdoptedTabs(rebind)
        }
        if !runningTests {
            store.startCadence()
            cleanupScheduler?.start()
        }
    }

    private func forAllTerminalStores(
        _ body: (TerminalSessionsStore) -> Void
    ) {
        for project in workspace.allProjects {
            body(project.terminalSessions)
        }
    }

    /// Adoption rebinds across both terminal stores: the source tab is
    /// removed (never killed), and the destination project gets an
    /// attach-only tab for the renamed session. Restarting a stale source
    /// tab can no longer recreate the old session.
    private func rebindAdoptedTabs(_ rebind: AdoptedTabRebind) {
        forAllTerminalStores { store in
            store.detachTab(named: rebind.oldName)
        }
        let canonical = TmuxKnownPaths.canonical(rebind.destinationPath)
        guard let destination = workspace.projects.first(where: {
            TmuxKnownPaths.canonical($0.id) == canonical
        }) else {
            return
        }
        destination.terminalSessions.attachExistingSession(
            named: rebind.newName
        )
    }

    private func projectChoices() -> [SessionsProjectChoice] {
        workspace.projects.filter { !$0.isOffline }.map { project in
            SessionsProjectChoice(
                id: project.id,
                name: project.name,
                prefix: TmuxNaming.prefix(
                    projectKey: project.id,
                    projectName: project.name
                ),
                identity: workspace.folderIdentity(for: project)
            )
        }
    }

    /// Open from the Sessions window is attach-only: it selects or appends a
    /// tab in the project that verifiably owns the session. It never creates
    /// a session or a project.
    func openTmuxSession(
        _ observation: TmuxSessionObservation
    ) -> Bool {
        guard let path = observation.ownership.verifiedProjectPath else {
            return false
        }
        let canonical = TmuxKnownPaths.canonical(path)
        guard let project = workspace.projects.first(where: {
            TmuxKnownPaths.canonical($0.id) == canonical
        }), !project.isOffline else {
            return false
        }
        activateProject(project)
        let attached = project.terminalSessions.attachExistingSession(
            named: observation.name
        )
        if attached {
            terminalPresentation = .split
        }
        return attached
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]
            != nil
            || NSClassFromString("XCTestCase") != nil
    }

    var selectedAsset: ProductionAsset? {
        selectedAsset(in: liveProject)
    }

    /// Resolve a demo asset against a specific project. A hidden demo host
    /// must not read the active project's selection.
    func selectedAsset(in project: Project) -> ProductionAsset? {
        guard project.isDemo, let id = project.selectedAssetID else {
            return nil
        }
        return project.sampleProductionAsset(id: id)
    }

    var selectedTab: EditorTab? {
        liveProject.selectedTab
    }

    /// The name the top chrome should show for a tab. A script or subtitle
    /// tab hosts a file workspace, whose open document is the file actually
    /// being edited; the production asset name would describe the demo slot.
    func displayName(for tab: EditorTab) -> String {
        liveProject.displayName(for: tab)
    }

    func displayName(for asset: ProductionAsset) -> String {
        displayName(for: asset, in: liveProject)
    }

    func displayName(
        for asset: ProductionAsset,
        in project: Project
    ) -> String {
        guard project.isDemo,
              project.selectedTab?.assetID == asset.id else {
            return asset.name
        }
        switch asset.kind {
        case .script:
            guard let document = project.markdown.selectedDocument else {
                return asset.name
            }
            return document.fileURL?.lastPathComponent ?? "Untitled"
        case .subtitle:
            guard let document = project.subtitles.selectedDocument else {
                return asset.name
            }
            return document.fileURL.lastPathComponent
        case .model3d:
            guard let document = project.models.selectedDocument else {
                return asset.name
            }
            return document.displayName
        default:
            return asset.name
        }
    }

    /// Counts words the way an editor footer should: whitespace-separated
    /// runs, with CJK characters counted individually because they are not
    /// space-delimited.
    func markdownWordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                inWord = false
            } else if Self.isCJK(scalar) {
                count += 1
                inWord = false
            } else if !inWord {
                count += 1
                inWord = true
            }
        }
        return count
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana and Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0x20000...0x2FA1F: // CJK Extension B and later
            return true
        default:
            return false
        }
    }

    var selectedTranscript: TranscriptSegment? {
        transcript.first { $0.id == selectedTranscriptID }
    }

    /// The segment under the playhead. Captions follow playback, skipping,
    /// and scrubbing; `selectedTranscriptID` remains the explicit transcript
    /// selection.
    var currentTranscript: TranscriptSegment? {
        if let active = transcript.first(where: {
            playhead >= $0.start && playhead < $0.end
        }) {
            return active
        }
        return transcript.last { $0.end <= playhead } ?? transcript.first
    }

    var canUseMediaModes: Bool {
        // Compare and Transcript remain demo surfaces for video. Audio uses
        // the real MediaAssetView and has no synthetic mode switch.
        guard liveProject.isDemo,
              let kind = selectedTab?.kind else { return false }
        return kind == .video
    }

    var activeMediaEditDocument: MediaEditDocument? {
        guard terminalPresentation != .full else { return nil }
        return liveProject.mediaEdits.activeDocument
    }

    var isRecordingAudio: Bool {
        liveProject.isRecordingAudio
    }

    var canStartAudioRecording: Bool {
        liveProject.canRecordAudio && !liveProject.isRecordingAudio
    }

    var canTrimMediaSelection: Bool {
        activeMediaEditDocument?.canTrimToSelection == true
    }

    var canDeleteMediaSelection: Bool {
        activeMediaEditDocument?.canDeleteSelection == true
    }

    var canSaveMediaTake: Bool {
        guard let document = activeMediaEditDocument else { return false }
        return document.canExport
            && !liveProject.mediaEdits.exportService.isBusy
    }

    var canReplaceMediaOriginal: Bool {
        guard let document = activeMediaEditDocument else { return false }
        return document.canReplaceOriginal
            && !liveProject.mediaEdits.exportService.isBusy
    }

    var canUndoMediaEdit: Bool {
        activeMediaEditDocument?.canUndo == true
    }

    var canRedoMediaEdit: Bool {
        activeMediaEditDocument?.canRedo == true
    }

    func startAudioRecording() async {
        let started = await liveProject.startAudioRecording()
        if !started {
            mediaErrorAlert = liveProject.mediaError
                ?? "Audio recording could not start."
        }
    }

    func stopAudioRecording() {
        guard liveProject.isRecordingAudio else { return }
        if liveProject.stopAudioRecording() == nil,
           let message = liveProject.mediaError {
            mediaErrorAlert = message
        }
    }

    func trimMediaSelection() {
        _ = activeMediaEditDocument?.trimToSelection()
    }

    func deleteMediaSelection() {
        _ = activeMediaEditDocument?.deleteSelection()
    }

    func resetMediaEdit() {
        _ = activeMediaEditDocument?.reset()
    }

    func undoMediaEdit() {
        _ = activeMediaEditDocument?.undo()
    }

    func redoMediaEdit() {
        _ = activeMediaEditDocument?.redo()
    }

    func saveMediaTake() async {
        guard let document = activeMediaEditDocument else { return }
        do {
            _ = try await liveProject.exportMedia(
                document,
                mode: .newTake
            )
        } catch {
            // The project records the error for the visible edit surface.
        }
    }

    func requestReplaceMediaOriginal() {
        guard activeMediaEditDocument?.canReplaceOriginal == true else {
            return
        }
        mediaReplaceRequest = true
    }

    var filteredStages: [ProductionStage] {
        liveProject.filteredStages
    }

    func openAsset(_ id: String?) {
        liveProject.openAsset(id: id)
    }

    func selectTab(_ id: String) {
        liveProject.selectTab(id)
    }

    func selectTranscript(_ id: String) {
        selectedTranscriptID = id
        if let segment = transcript.first(where: { $0.id == id }) {
            playhead = segment.start + AppTheme.Layout.transcriptPlayheadOffset
        }
    }

    func togglePlayback() {
        isPlaying.toggle()
    }

    /// Brings the Markdown workspace's tab to the front. Menu commands that
    /// create or open a document must not leave it hidden behind an audio or
    /// delivery tab.
    func showMarkdownWorkspace() {
        showWorkspace(.script, demoAssetID: "script-md")
    }

    func showSubtitleWorkspace() {
        showWorkspace(.subtitle, demoAssetID: "captions-srt")
    }

    func showModel3DWorkspace() {
        showWorkspace(.model3d, demoAssetID: "model-3d")
    }

    private func showWorkspace(_ kind: AssetKind, demoAssetID: String) {
        if terminalPresentation == .full {
            terminalPresentation = .hidden
        }
        if liveProject.isDemo {
            if let tab = openTabs.first(where: {
                $0.assetID == demoAssetID
            }) {
                selectTab(tab.id)
            } else if production.asset(id: demoAssetID) != nil {
                openAsset(demoAssetID)
            }
        } else {
            liveProject.showWorkspace(kind)
        }
    }

    /// Brings a subtitle document to the front so a save started from another
    /// tab fails where the document and its error are visible.
    func revealSubtitleDocument(_ document: SubtitleDocument) {
        let owner = workspace.allProjects.first { project in
            project.subtitles.documents.contains { $0 === document }
        }
        revealDocument(
            kind: .subtitle,
            url: document.fileURL,
            owner: owner
        ) { project in
            project.subtitles.select(document)
        }
    }

    /// Brings a specific model to the front. Converting or reloading the
    /// selected model must not leave another model's tab visible.
    func revealModelDocument(_ document: Model3DDocument) {
        let owner = workspace.allProjects.first { project in
            project.models.documents.contains { $0 === document }
        }
        revealDocument(
            kind: .model3d,
            url: document.sourceURL,
            owner: owner
        ) { project in
            project.models.select(document)
        }
    }

    /// ⌘S dispatches on the visible editor. Saving a hidden workspace would
    /// report success for a file the user cannot see.
    var canSaveSelectedDocument: Bool {
        guard terminalPresentation != .full else { return false }
        switch selectedTab?.kind {
        case .script:
            return true
        case .subtitle:
            return subtitles.selectedDocument != nil
        case .code:
            return code.selectedDocument?.canAttemptSave == true
        default:
            return false
        }
    }

    func saveSelectedDocument() async {
        switch selectedTab?.kind {
        case .script:
            await markdown.saveSelected()
        case .subtitle:
            await subtitles.saveSelected()
        case .code:
            await code.saveSelected()
        default:
            break
        }
    }

    var canSaveSelectedDocumentAs: Bool {
        guard terminalPresentation != .full else { return false }
        switch selectedTab?.kind {
        case .script:
            return true
        case .code:
            return code.selectedDocument != nil
        default:
            return false
        }
    }

    func saveSelectedDocumentAs() async {
        switch selectedTab?.kind {
        case .script:
            await markdown.saveSelectedAs()
        case .code:
            await code.saveAsSelected()
        default:
            break
        }
    }

    /// Saves every project's workspaces before the window closes. Subtitle
    /// files always have a path, so they never ask for a save/discard
    /// decision; a failed subtitle save cancels the close and leaves the
    /// failing project active and visible.
    func flushAllBeforeClose() async -> Bool {
        let ordered = [liveProject] + workspace.allProjects.filter {
            $0 !== liveProject
        }
        // A document saved early can become dirty again while later saves
        // run. Recheck the whole set and make another pass before allowing
        // the window to close.
        for _ in 0..<3 {
            for project in ordered {
                if project.subtitles.hasDirtyDocuments {
                    let saved = await project.subtitles.flushAllForTermination()
                    guard saved else {
                        activateProject(project)
                        if let document = project.subtitles.selectedDocument {
                            revealSubtitleDocument(document)
                        }
                        return false
                    }
                }
                if project.markdown.hasDirtyDocuments {
                    let saved = await project.markdown.flushAllForTermination()
                    guard saved else {
                        activateProject(project)
                        if let document = project.markdown.pendingClose
                            ?? project.markdown.selectedDocument {
                            revealMarkdownDocument(document)
                        }
                        return false
                    }
                }
                if project.code.hasDirtyDocuments {
                    let saved = await project.code.flushAllForTermination()
                    guard saved else {
                        activateProject(project)
                        if let document = project.code.pendingClose
                            ?? project.code.selectedDocument {
                            revealCodeDocument(document)
                        }
                        return false
                    }
                }
            }
            if !workspace.hasDirtyDocuments {
                return true
            }
        }
        return false
    }

    /// The workspace that owns a pending Markdown save decision. It need not
    /// be the active project; switching projects must not hide the alert or
    /// send its buttons to the wrong workspace.
    var pendingCloseOwner: Project? {
        workspace.allProjects.first { $0.markdown.pendingClose != nil }
    }

    var pendingCloseDocument: MarkdownDocument? {
        pendingCloseOwner?.markdown.pendingClose
    }

    var pendingCodeCloseOwner: Project? {
        workspace.allProjects.first { $0.code.pendingClose != nil }
    }

    var pendingCodeCloseDocument: CodeDocument? {
        pendingCodeCloseOwner?.code.pendingClose
    }

    var hasPendingCloseDecision: Bool {
        pendingCloseDocument != nil || pendingCodeCloseDocument != nil
    }

    func savePendingClose() {
        if let owner = pendingCloseOwner,
           let document = owner.markdown.pendingClose {
            revealMarkdownDocument(document)
            Task { await owner.markdown.saveAndClose(document) }
            return
        }
        if let owner = pendingCodeCloseOwner,
           let document = owner.code.pendingClose {
            revealCodeDocument(document)
            Task { await owner.code.saveAndClose(document) }
        }
    }

    func discardPendingClose() {
        if let owner = pendingCloseOwner,
           let document = owner.markdown.pendingClose {
            owner.markdown.discardAndClose(document)
            return
        }
        if let owner = pendingCodeCloseOwner,
           let document = owner.code.pendingClose {
            owner.code.discardAndClose(document)
        }
    }

    func cancelPendingClose() {
        if let owner = pendingCloseOwner {
            owner.markdown.cancelPendingClose()
            // A bulk close that stopped at this decision stays stopped; its
            // remaining tabs must not close later when this document is
            // closed for some other reason.
            owner.cancelBulkClose()
        }
        if let owner = pendingCodeCloseOwner {
            owner.code.cancelPendingClose()
            owner.cancelBulkClose()
        }
    }

    var hasDirtyDocuments: Bool {
        workspace.hasDirtyDocuments
    }

    func prepareForTermination() {
        // No scan or automatic action may start on quit.
        hygiene.stopCadence()
        cleanupScheduler?.stop()
        workspace.prepareForTermination()
    }

    /// Brings a Markdown document to the front so a save started from another
    /// tab fails where the document and its error are visible.
    func revealMarkdownDocument(_ document: MarkdownDocument) {
        let owner = workspace.allProjects.first { project in
            project.markdown.documents.contains { $0 === document }
        }
        revealDocument(
            kind: .script,
            url: document.fileURL,
            owner: owner
        ) { project in
            project.markdown.select(document)
        }
    }

    /// Brings a code document to the front for the same reason.
    func revealCodeDocument(_ document: CodeDocument) {
        let owner = workspace.allProjects.first { project in
            project.code.documents.contains { $0 === document }
        }
        revealDocument(
            kind: .code,
            url: document.fileURL,
            owner: owner
        ) { project in
            project.code.select(document)
        }
    }

    /// The production sink for a code reference. The active project and the
    /// selected terminal session are captured synchronously; the sink never
    /// creates a session.
    func codeReferenceDelivery(for project: Project) -> CodeReferenceDelivery {
        var send: ((String) -> Bool)?
        if terminalPresentation != .hidden,
           project === liveProject,
           let session = project.terminalSessions.selectedSession {
            send = { text in
                session.view.insertLiteral(text)
            }
        }
        return CodeReferenceDelivery(
            send: send,
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        )
    }

    /// The shared path for revealing a document: leave full-screen terminal,
    /// activate its owning project when known, select the tab that names it,
    /// and fall back to the workspace when the document has no owner tab.
    private func revealDocument(
        kind: AssetKind,
        url: URL?,
        owner: Project?,
        select: (Project) -> Void
    ) {
        if terminalPresentation == .full {
            terminalPresentation = .hidden
        }
        if let owner {
            activateProject(owner)
            revealTab(in: owner, kind: kind, url: url)
            select(owner)
            return
        }
        switch kind {
        case .script:
            showMarkdownWorkspace()
        case .subtitle:
            showSubtitleWorkspace()
        case .model3d:
            showModel3DWorkspace()
        default:
            break
        }
        select(liveProject)
    }

    /// Select the tab that shows this document, or a workspace tab that
    /// follows the selected document. Selecting the first tab of the kind
    /// could point the breadcrumb and inspector at a different file.
    private func revealTab(in project: Project, kind: AssetKind, url: URL?) {
        let canonical = url.map { MarkdownSecurity.canonical($0).path }
        if let canonical,
           let tab = project.openTabs.first(where: { tab in
               guard tab.kind == kind, let tabURL = tab.url else {
                   return false
               }
               return MarkdownSecurity.canonical(tabURL).path == canonical
           }) {
            project.selectTab(tab.id)
            return
        }
        if let tab = project.openTabs.first(where: { tab in
            guard tab.kind == kind else { return false }
            if case .workspace(let tabKind) = tab.content {
                return tabKind == kind
            }
            return false
        }) {
            project.selectTab(tab.id)
            return
        }
        project.selectWorkspaceTab(kind)
    }

}
