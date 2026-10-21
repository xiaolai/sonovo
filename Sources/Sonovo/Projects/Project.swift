import Foundation
import Observation
import SonovoCore

/// One folder the user opened, or the built-in sample production. A project
/// owns its tabs, selection, workspaces, and terminals; nothing here is
/// shared with another project.
@MainActor
@Observable
final class Project: Identifiable {
    enum Availability: Equatable, Sendable {
        case available
        case scanning
        case offline(String)
    }

    let id: String
    let name: String
    let root: URL?
    let isDemo: Bool
    let demoProduction: Production?
    let markdown: MarkdownWorkspace
    let subtitles: SubtitleWorkspace
    let models: Model3DWorkspace
    let terminalSessions: TerminalSessionsStore

    private(set) var assets: [ProjectAsset] = []
    private(set) var groups: [ProjectAssetGroup] = []
    private(set) var availability: Availability
    private(set) var truncated = false
    private(set) var visitedEntries = 0

    var openTabs: [EditorTab]
    var selectedTabID: String
    var selectedAssetID: String?
    var filterText = ""
    var hasActivity = false
    private(set) var isActive = false
    /// Set while a restored selection is being recovered. Persistence is
    /// suppressed so the empty pre-scan selection cannot overwrite it.
    var isRestoringSelection = false

    /// Monotonic count of user-initiated selection changes. Scan
    /// reconciliation and restores do not bump it, so recovery can tell a
    /// deliberate choice (including clearing the selection) from its own
    /// work.
    private(set) var selectionRevision: UInt64 = 0
    /// True only while scan reconciliation mutates selection synchronously.
    private var isApplyingScan = false

    /// Workspace persistence hook. Called when the selection changes.
    var onSelectionChanged: (() -> Void)?

    private let scanner: ProjectScanner
    private let watchFactory: ProjectWatchFactory
    private let sampleDocuments: SampleProjectDocuments?
    private(set) var watcher: ProjectWatching?
    private var refreshTask: Task<Void, Never>?
    private var watcherRetryTask: Task<Void, Never>?
    private var scanInFlight = false
    private var rescanRequested = false
    /// Invalidates an in-flight scan when the project goes offline or closes.
    private var lifecycleGeneration: UInt64 = 0
    /// A removed project must never restart a queued scan or apply results.
    private var isInvalidated = false
    /// Guard against tab synchronisation re-entering through the workspace.
    private var isSyncingTab = false
    /// Paths whose document close is awaiting, with a count so concurrent
    /// closes of the same file do not clear each other's tracking. A close
    /// resolved later by the Markdown save prompt must not remove a tab
    /// while this flow owns it.
    private var closingPaths: [String: Int] = [:]
    /// Paths the user reopened while their document close was awaiting.
    private var reopenedDuringClose: Set<String> = []
    /// A bulk close stopped at a document that needs a decision. Resolving
    /// that document resumes the remaining tabs instead of abandoning them.
    private var bulkClosePending = false
    /// The document that blocked the bulk close. Only its close may resume
    /// the operation; an unrelated Markdown close must not.
    private var bulkClosePendingDocumentID: UUID?
    /// A single workspace-tab close stopped at a save decision. Resolving it
    /// resumes the workspace's remaining documents and then removes the tab.
    private var pendingWorkspaceClose: AssetKind?
    /// The document that blocked the workspace-tab close.
    private var pendingWorkspaceCloseDocumentID: UUID?
    /// The volume this project was opened on. Every recovery path compares
    /// against it so a path that now belongs to another disk is never read.
    private(set) var expectedVolumeIdentifier: String?

    private static let sampleDocumentNames: [String: String] = [
        "script-md": "tidewater-script.md",
        "outline-md": "outline.md",
        "captions-srt": "captions.srt"
    ]

    private init(
        id: String,
        name: String,
        root: URL?,
        isDemo: Bool,
        demoProduction: Production?,
        markdown: MarkdownWorkspace,
        subtitles: SubtitleWorkspace,
        models: Model3DWorkspace,
        terminalSessions: TerminalSessionsStore,
        openTabs: [EditorTab],
        selectedTabID: String,
        selectedAssetID: String?,
        availability: Availability,
        expectedVolumeIdentifier: String?,
        scanner: ProjectScanner,
        watchFactory: @escaping ProjectWatchFactory,
        sampleDocuments: SampleProjectDocuments?
    ) {
        self.id = id
        self.name = name
        self.root = root
        self.isDemo = isDemo
        self.demoProduction = demoProduction
        self.markdown = markdown
        self.subtitles = subtitles
        self.models = models
        self.terminalSessions = terminalSessions
        self.openTabs = openTabs
        self.selectedTabID = selectedTabID
        self.selectedAssetID = selectedAssetID
        self.availability = availability
        self.expectedVolumeIdentifier = expectedVolumeIdentifier
        self.scanner = scanner
        self.watchFactory = watchFactory
        self.sampleDocuments = sampleDocuments
        self.markdown.onDocumentClosed = { [weak self] document in
            guard let self else { return }
            if let url = document.fileURL {
                self.removeTabs(forFileAt: url)
            }
            self.resumePendingCloseIfNeeded(closedDocument: document)
        }
        self.markdown.onDocumentActivated = { [weak self] url in
            guard let self else { return }
            if let url {
                self.syncTabForDocument(at: url, kind: .script)
            } else {
                // An untitled document has no file to name; the Markdown
                // workspace tab is its identity.
                self.selectWorkspaceTab(.script)
            }
        }
        self.markdown.onDocumentMoved = { [weak self] oldURL, newURL in
            self?.moveTabs(from: oldURL, to: newURL)
        }
        self.subtitles.onDocumentClosed = { [weak self] url in
            self?.removeTabs(forFileAt: url)
        }
        self.subtitles.onDocumentActivated = { [weak self] url in
            self?.syncTabForDocument(at: url, kind: .subtitle)
        }
        self.models.onDocumentActivated = { [weak self] url in
            self?.syncTabForDocument(at: url, kind: .model3d)
        }
        self.models.onDocumentClosed = { [weak self] url in
            self?.removeTabs(forFileAt: url)
        }
    }

    convenience init(
        folderURL: URL,
        expectedVolumeIdentifier: String? = nil,
        scanner: ProjectScanner = ProjectScanner(),
        watchFactory: @escaping ProjectWatchFactory = {
            FSEventSource(root: $0, onChange: $1)
        },
        terminalEnvironment: TerminalEnvironment = .disabled
    ) {
        self.init(
            folderBackedRoot: MarkdownSecurity.canonical(folderURL),
            availability: .scanning,
            expectedVolumeIdentifier: expectedVolumeIdentifier,
            scanner: scanner,
            watchFactory: watchFactory,
            terminalEnvironment: terminalEnvironment
        )
    }

    convenience init(
        offlinePath: String,
        reason: String,
        expectedVolumeIdentifier: String? = nil,
        scanner: ProjectScanner = ProjectScanner(),
        watchFactory: @escaping ProjectWatchFactory = {
            FSEventSource(root: $0, onChange: $1)
        },
        terminalEnvironment: TerminalEnvironment = .disabled
    ) {
        self.init(
            folderBackedRoot: URL(fileURLWithPath: offlinePath)
                .standardizedFileURL,
            availability: .offline(reason),
            expectedVolumeIdentifier: expectedVolumeIdentifier,
            scanner: scanner,
            watchFactory: watchFactory,
            terminalEnvironment: terminalEnvironment
        )
    }

    /// Folder and offline projects differ only in availability and how their
    /// root is canonicalized; everything else is shared.
    private convenience init(
        folderBackedRoot root: URL,
        availability: Availability,
        expectedVolumeIdentifier: String?,
        scanner: ProjectScanner,
        watchFactory: @escaping ProjectWatchFactory,
        terminalEnvironment: TerminalEnvironment
    ) {
        self.init(
            id: root.path,
            name: root.lastPathComponent,
            root: root,
            isDemo: false,
            demoProduction: nil,
            markdown: MarkdownWorkspace(readsDemoEnvironment: false),
            subtitles: SubtitleWorkspace(readsDemoEnvironment: false),
            models: Model3DWorkspace(opensDemoModel: false),
            terminalSessions: TerminalSessionsStore(
                workingDirectory: root.path,
                projectKey: root.path,
                projectName: root.lastPathComponent,
                terminalEnvironment: terminalEnvironment
            ),
            openTabs: [],
            selectedTabID: "",
            selectedAssetID: nil,
            availability: availability,
            expectedVolumeIdentifier: expectedVolumeIdentifier,
            scanner: scanner,
            watchFactory: watchFactory,
            sampleDocuments: nil
        )
    }

    static func demo(
        production: Production,
        markdown: MarkdownWorkspace,
        subtitles: SubtitleWorkspace,
        models: Model3DWorkspace,
        terminalSessions: TerminalSessionsStore,
        sampleDocuments: SampleProjectDocuments?
    ) -> Project {
        let initialIDs = [
            "script-md", "captions-srt", "vo-take-03", "take-03", "stills",
            "storyboard-html"
        ]
        let tabs = initialIDs.compactMap { id in
            production.asset(id: id).map(EditorTab.init(asset:))
        }
        return Project(
            id: "demo",
            name: production.title,
            root: nil,
            isDemo: true,
            demoProduction: production,
            markdown: markdown,
            subtitles: subtitles,
            models: models,
            terminalSessions: terminalSessions,
            openTabs: tabs,
            selectedTabID: "vo-take-03",
            selectedAssetID: "vo-take-03",
            availability: .available,
            expectedVolumeIdentifier: nil,
            scanner: ProjectScanner(),
            watchFactory: { _, _ in
                // The demo project has no folder to watch.
                NoopProjectWatcher()
            },
            sampleDocuments: sampleDocuments
        )
    }

    // MARK: - Loading

    func load() async {
        guard !isDemo, !isInvalidated, let root else { return }
        startWatcherIfNeeded(root: root)
        await performScan(root: root)
    }

    private func startWatcherIfNeeded(root: URL) {
        guard !isInvalidated, watcher == nil else { return }
        let watcher = watchFactory(root) { [weak self] in
            Task { @MainActor in
                self?.noteFileSystemChange()
            }
        }
        watcher.start()
        guard watcher.isRunning else {
            // A failed stream is not a watcher. Stop it, leave `watcher`
            // nil so the guard permits a retry, and try again shortly.
            watcher.stop()
            watcherRetryTask?.cancel()
            watcherRetryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.startWatcherIfNeeded(root: root)
            }
            return
        }
        self.watcher = watcher
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
    }

    func noteFileSystemChange() {
        guard !isDemo else { return }
        hasActivity = !isActive
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshNow()
        }
    }

    func refreshNow() async {
        guard !isDemo, let root else { return }
        await performScan(root: root)
    }

    private func performScan(root: URL) async {
        guard !isInvalidated else { return }
        let generation = lifecycleGeneration
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            markOffline("This folder is unavailable.")
            return
        }
        if let expectedVolumeIdentifier,
           let current = Self.volumeIdentifier(for: root),
           current != expectedVolumeIdentifier {
            markOffline("This path now belongs to a different volume.")
            return
        }
        if scanInFlight {
            rescanRequested = true
            return
        }
        scanInFlight = true
        let scanner = scanner
        let result = await Task.detached(priority: .userInitiated) {
            scanner.scan(root: root)
        }.value
        // Do not discard the scan because the debounce task that started it
        // was cancelled by a newer filesystem event. Its result is still a
        // valid snapshot; the queued rescan below brings it up to date.
        guard generation == lifecycleGeneration else {
            scanInFlight = false
            // A recovery load may have arrived while the invalidated scan
            // was still running. Honor it with a fresh generation.
            if rescanRequested {
                rescanRequested = false
                await performScan(root: root)
            }
            return
        }
        // Applying a scan awaits document closes. Keep the scan slot held
        // until reconciliation finishes, so a filesystem event during that
        // window queues one rescan instead of interleaving a second apply.
        await apply(result)
        scanInFlight = false
        if rescanRequested {
            rescanRequested = false
            await performScan(root: root)
        }
    }

    private func apply(_ result: ProjectScanResult) async {
        let generation = lifecycleGeneration
        let previousAssets = assets
        let effectiveAssets = mergedAssets(for: result)
        applySnapshot(
            result,
            effectiveAssets: effectiveAssets,
            previousAssets: previousAssets
        )
        reloadChangedModelResources()

        guard await reconcileMissingTabs(generation: generation) else {
            return
        }
        isApplyingScan = true
        reconcileSelection(
            previousAssets: previousAssets,
            effectiveAssets: effectiveAssets,
            ids: Set(effectiveAssets.map(\.id))
        )
        isApplyingScan = false
        onSelectionChanged?()
    }

    /// A partial scan (an unreadable directory) must not delete tabs or
    /// documents. Keep the last known assets until a complete scan confirms
    /// what actually disappeared.
    private func mergedAssets(
        for result: ProjectScanResult
    ) -> [ProjectAsset] {
        guard result.isPartial || result.truncated else {
            return result.assets
        }
        let foundIDs = Set(result.assets.map(\.id))
        let preserved = assets.filter { !foundIDs.contains($0.id) }
        return (result.assets + preserved).sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath)
                == .orderedAscending
        }
    }

    private func applySnapshot(
        _ result: ProjectScanResult,
        effectiveAssets: [ProjectAsset],
        previousAssets: [ProjectAsset]
    ) {
        let previousRevisions = Dictionary(
            uniqueKeysWithValues: previousAssets.map { ($0.id, $0.revision) }
        )
        let nextRevisions = Dictionary(
            uniqueKeysWithValues: effectiveAssets.map { ($0.id, $0.revision) }
        )
        let changed = previousRevisions != nextRevisions
        let wasOffline = isOffline

        assets = effectiveAssets
        // A complete scan already built groups; only a merged partial or
        // truncated result needs them recomputed.
        groups = result.isPartial || result.truncated
            ? ProjectScanner.groups(from: effectiveAssets)
            : result.groups
        truncated = result.truncated || result.isPartial
        visitedEntries = result.visitedEntries
        availability = .available
        if wasOffline {
            // The directory exists again; discover tmux sessions that were
            // started before the project went offline or in another process.
            terminalSessions.restoreTmuxSessions()
        }
        if changed, !isActive {
            hasActivity = true
        }
    }

    /// A model can serve sidecars the folder scanner does not index (.bin,
    /// .mtl, textures). Compare the identity recorded when each resource was
    /// served, for every open model, so a changed or deleted sidecar reloads
    /// the viewer even when no asset revision changed.
    private func reloadChangedModelResources() {
        for document in models.documents where !document.resourcePaths.isEmpty {
            let resourceChanged = document.resourcePaths.contains { path in
                document.resourceRevisions[path]
                    != Model3DDocument.revision(
                        of: URL(fileURLWithPath: path)
                    )
            }
            if resourceChanged {
                models.reload(document)
            }
        }
    }

    /// Closes tabs whose files disappeared. Returns false when the project
    /// was invalidated or went offline while a close was awaiting; selection
    /// reconciliation must not run against that stale snapshot.
    private func reconcileMissingTabs(generation: UInt64) async -> Bool {
        let ids = Set(assets.map(\.id))
        let missingTabs = openTabs.filter { tab in
            guard tab.projectAsset != nil, !ids.contains(tab.id) else {
                return false
            }
            // A dirty document whose file vanished stays available so the
            // user can still save it. Clean documents are closed normally.
            return !documentIsDirty(for: tab)
        }
        guard !missingTabs.isEmpty else { return true }

        var removableIDs: Set<String> = []
        for tab in missingTabs {
            // Remove the tab only after its document actually closed.
            // A failed or deferred close keeps both.
            if case .closed = await closeDocumentIfNeeded(for: tab) {
                removableIDs.insert(tab.id)
            }
        }
        // The project may have gone offline or been closed while the
        // document close was awaiting.
        guard generation == lifecycleGeneration, !isInvalidated else {
            return false
        }
        if !removableIDs.isEmpty {
            isApplyingScan = true
            openTabs.removeAll { removableIDs.contains($0.id) }
            if !openTabs.contains(where: { $0.id == selectedTabID }) {
                if let first = openTabs.first {
                    selectTab(first.id)
                } else {
                    selectedTabID = ""
                    selectedAssetID = nil
                }
            }
            isApplyingScan = false
        }
        return true
    }

    private func reconcileSelection(
        previousAssets: [ProjectAsset],
        effectiveAssets: [ProjectAsset],
        ids: Set<String>
    ) {
        // Any tab still open for a missing file survived because its close
        // failed or is awaiting a decision. Its selection must not be
        // replaced by the fallback asset.
        let preservedMissingIDs = Set(openTabs.compactMap { tab -> String? in
            guard tab.projectAsset != nil, !ids.contains(tab.id) else {
                return nil
            }
            return tab.id
        })
        if let selectedAssetID,
           !ids.contains(selectedAssetID),
           !preservedMissingIDs.contains(selectedAssetID) {
            let previousKind = previousAssets
                .first { $0.id == selectedAssetID }?.kind
            let replacement = effectiveAssets.first {
                $0.kind == previousKind
            } ?? effectiveAssets.first
            if let replacement {
                openAsset(replacement)
            } else {
                selectedTabID = ""
                self.selectedAssetID = nil
            }
        }
        if !selectedTabID.isEmpty,
           !openTabs.contains(where: { $0.id == selectedTabID }) {
            if let first = openTabs.first {
                selectTab(first.id)
            } else {
                selectedTabID = ""
                selectedAssetID = nil
            }
        }
    }

    func markOffline(_ reason: String) {
        lifecycleGeneration &+= 1
        availability = .offline(reason)
        watcher?.stop()
        watcher = nil
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    private static func volumeIdentifier(for url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeUUIDStringKey])
            .volumeUUIDString
    }

    private func documentIsDirty(for tab: EditorTab) -> Bool {
        guard let url = tab.url ?? sampleDocumentURL(for: tab) else {
            return false
        }
        switch tab.kind {
        case .script:
            return markdown.documents.first {
                $0.fileURL.map {
                    MarkdownSecurity.canonical($0) == url
                } == true
            }?.isDirty == true
        case .subtitle:
            return subtitles.documents.first {
                MarkdownSecurity.canonical($0.fileURL) == url
            }?.isDirty == true
        default:
            return false
        }
    }

    // MARK: - Selection

    var selectedAsset: ProjectAsset? {
        guard let selectedAssetID else { return nil }
        return assets.first { $0.id == selectedAssetID }
    }

    /// The document a synthetic workspace tab is showing. A workspace tab
    /// has no file URL of its own, so breadcrumb and transport chrome must
    /// ask the hosted workspace instead of falling back to "No Editor".
    func workspaceDocumentIdentity(
        for kind: AssetKind
    ) -> (name: String, detail: String)? {
        switch kind {
        case .script:
            guard let document = markdown.selectedDocument else { return nil }
            return (
                document.fileURL?.lastPathComponent ?? "Untitled",
                "Markdown"
            )
        case .subtitle:
            guard let document = subtitles.selectedDocument else { return nil }
            return (document.fileURL.lastPathComponent, "Subtitle")
        case .model3d:
            guard let document = models.selectedDocument else { return nil }
            return (document.displayName, "3D model")
        default:
            return nil
        }
    }

    var selectedTab: EditorTab? {
        openTabs.first { $0.id == selectedTabID }
    }

    var filteredGroups: [ProjectAssetGroup] {
        guard !filterText.isEmpty else { return groups }
        return groups.compactMap { group in
            let matches = group.assets.filter {
                $0.name.localizedCaseInsensitiveContains(filterText)
                    || $0.relativePath.localizedCaseInsensitiveContains(
                        filterText
                    )
            }
            return matches.isEmpty
                ? nil
                : ProjectAssetGroup(
                    descriptor: group.descriptor,
                    assets: matches
                )
        }
    }

    var filteredStages: [ProductionStage] {
        guard let demoProduction else { return [] }
        guard !filterText.isEmpty else { return demoProduction.stages }
        return demoProduction.stages.compactMap { stage in
            let matches = stage.assets.filter {
                $0.name.localizedCaseInsensitiveContains(filterText)
                    || $0.detail.localizedCaseInsensitiveContains(filterText)
            }
            return matches.isEmpty
                ? nil
                : ProductionStage(
                    id: stage.id,
                    title: stage.title,
                    assets: matches
                )
        }
    }

    private func noteSelectionChange() {
        guard !isApplyingScan else { return }
        selectionRevision &+= 1
    }

    func openAsset(_ asset: ProjectAsset) {
        noteSelectionChange()
        let path = MarkdownSecurity.canonical(asset.url).path
        if closingPaths[path] != nil {
            // The user asked for this file while it was closing; keep the
            // tab and reopen the underlying document afterwards.
            reopenedDuringClose.insert(path)
        }
        if let existing = openTabs.first(where: { $0.id == asset.id }) {
            selectTab(existing.id)
            return
        }
        let tab = EditorTab(asset: asset)
        openTabs.append(tab)
        selectTab(tab.id)
    }

    func openSampleAsset(_ asset: ProductionAsset) {
        noteSelectionChange()
        if let existing = openTabs.first(where: { $0.assetID == asset.id }) {
            selectTab(existing.id)
            return
        }
        let tab = EditorTab(asset: asset)
        openTabs.append(tab)
        selectTab(tab.id)
    }

    func openAsset(id: String?) {
        guard let id else { return }
        if isDemo {
            guard let asset = demoProduction?.asset(id: id) else { return }
            openSampleAsset(asset)
        } else if let asset = assets.first(where: { $0.id == id }) {
            openAsset(asset)
        }
    }

    /// Brings a workspace to the front even when no file of that kind is open.
    /// The synthetic tab hosts the empty state; the first opened document
    /// replaces it in the same tab.
    func showWorkspace(_ kind: AssetKind) {
        noteSelectionChange()
        if let tab = openTabs.first(where: { $0.kind == kind }) {
            selectTab(tab.id)
            return
        }
        let tab = EditorTab(workspaceKind: kind)
        openTabs.append(tab)
        selectTab(tab.id)
    }

    /// Selects or creates the synthetic workspace tab without falling back
    /// to an arbitrary file tab of the same kind.
    func selectWorkspaceTab(_ kind: AssetKind) {
        noteSelectionChange()
        let id = "workspace-\(kind.rawValue)"
        if openTabs.contains(where: { $0.id == id }) {
            selectTab(id)
            return
        }
        let tab = EditorTab(workspaceKind: kind)
        openTabs.append(tab)
        selectTab(tab.id)
    }

    func selectTab(_ id: String) {
        guard let tab = openTabs.first(where: { $0.id == id }) else { return }
        noteSelectionChange()
        selectedTabID = id
        selectedAssetID = tab.assetID
        bindDocument(for: tab)
        onSelectionChanged?()
    }

    private func bindDocument(for tab: EditorTab) {
        if let url = tab.url {
            openDocument(kind: tab.kind, url: url)
            return
        }
        guard isDemo,
              let assetID = tab.sampleAsset?.id,
              let name = Self.sampleDocumentNames[assetID],
              let url = sampleDocuments?.documentURL(named: name) else {
            return
        }
        openDocument(kind: tab.kind, url: url)
    }

    /// One dispatch for every workspace that hosts documents. Demo tabs and
    /// project tabs resolve their URL first, then take this path.
    private func openDocument(kind: AssetKind, url: URL) {
        switch kind {
        case .script:
            markdown.open(url: url)
        case .subtitle:
            subtitles.open(url: url)
        case .model3d:
            models.open(url: url)
        default:
            break
        }
    }

    func closeTab(_ id: String) async {
        guard let tab = openTabs.first(where: { $0.id == id }) else {
            return
        }
        // The document decides whether it can close: a dirty document that
        // cannot save, or one waiting for a save decision, keeps its tab.
        guard case .closed = await closeDocumentIfNeeded(for: tab) else {
            return
        }
        removeTab(id: id)
        onSelectionChanged?()
    }

    /// Removes one tab and keeps the selection on a surviving neighbour.
    private func removeTab(id: String) {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else {
            return
        }
        openTabs.remove(at: index)
        guard selectedTabID == id else { return }
        noteSelectionChange()
        if openTabs.isEmpty {
            selectedTabID = ""
            selectedAssetID = nil
        } else {
            selectTab(openTabs[min(index, openTabs.count - 1)].id)
        }
    }

    /// How a tab's document close ended. Only `.deferred` has a callback
    /// that will resume it; `.failed` needs the user to try again. The
    /// associated ID names the exact document whose decision is pending.
    private enum DocumentCloseOutcome {
        case closed
        case deferred(UUID)
        case failed
    }

    /// Closes every document hosted by a synthetic workspace tab. Stops at
    /// the first document that needs a decision; the tab stays and the
    /// normal resume path continues after the decision.
    private func closeWorkspaceDocuments(
        kind: AssetKind
    ) async -> DocumentCloseOutcome {
        // A document with its own file tab belongs to that tab. Closing the
        // synthetic workspace tab must not close a document the user can
        // still see and reach from a file tab.
        let fileTabPaths = Set(openTabs.compactMap { tab -> String? in
            guard tab.workspaceKind == nil,
                  let url = tab.url ?? sampleDocumentURL(for: tab) else {
                return nil
            }
            return MarkdownSecurity.canonical(url).path
        })
        switch kind {
        case .script:
            for document in markdown.documents {
                if let url = document.fileURL,
                   fileTabPaths.contains(
                       MarkdownSecurity.canonical(url).path
                   ) {
                    continue
                }
                guard await markdown.close(document) else {
                    // Only a Markdown save decision resumes through the
                    // document-closed callback; a failed save does not. The
                    // pending document identifies the decision itself; the
                    // attempted document can differ when a second close
                    // arrives while the first decision is unresolved.
                    guard let pending = markdown.pendingClose else {
                        return .failed
                    }
                    pendingWorkspaceClose = kind
                    pendingWorkspaceCloseDocumentID = pending.id
                    return .deferred(pending.id)
                }
            }
            return .closed
        case .subtitle:
            for document in subtitles.documents {
                if fileTabPaths.contains(
                    MarkdownSecurity.canonical(document.fileURL).path
                ) {
                    continue
                }
                // A subtitle close failure is reported, not deferred: no
                // decision alert re-enters this close, so keeping the tab
                // is the final state until the user closes it again.
                guard await subtitles.close(document) else {
                    return .failed
                }
            }
            return .closed
        case .model3d:
            for document in models.documents {
                if fileTabPaths.contains(
                    MarkdownSecurity.canonical(document.sourceURL).path
                ) {
                    continue
                }
                guard await models.close(document) else {
                    return .failed
                }
            }
            return .closed
        default:
            return .closed
        }
    }

    /// Reports whether the tab's documents actually closed. A tab stays when
    /// its document must stay open: a failed save, a pending save decision,
    /// or a deliberate reopen during the close.
    private func closeDocumentIfNeeded(
        for tab: EditorTab
    ) async -> DocumentCloseOutcome {
        // A synthetic workspace tab has no file of its own; its documents
        // are what must close. Returning true here without closing them
        // would leave dirty documents and their tabs behind.
        if let kind = tab.workspaceKind {
            return await closeWorkspaceDocuments(kind: kind)
        }
        let url = tab.url ?? sampleDocumentURL(for: tab)
        guard let url else { return .closed }
        let stillReferenced = openTabs.contains { other in
            other.id != tab.id
                && (other.url ?? sampleDocumentURL(for: other)) == url
        }
        guard !stillReferenced else { return .closed }

        let path = MarkdownSecurity.canonical(url).path
        beginClosing(path)
        let closed: Bool
        switch tab.kind {
        case .script:
            if let document = markdown.documents.first(where: {
                $0.fileURL.map {
                    MarkdownSecurity.canonical($0).path == path
                } == true
            }) {
                closed = await markdown.close(document)
            } else {
                closed = true
            }
        case .subtitle:
            if let document = subtitles.documents.first(where: {
                MarkdownSecurity.canonical($0.fileURL).path == path
            }) {
                closed = await subtitles.close(document)
            } else {
                closed = true
            }
        case .model3d:
            if let document = models.documents.first(where: {
                MarkdownSecurity.canonical($0.sourceURL).path == path
            }) {
                closed = await models.close(document)
            } else {
                closed = true
            }
        default:
            closed = true
        }
        let remaining = endClosing(path)

        let reopened = reopenedDuringClose.contains(path)
        if remaining == 0, reopened {
            // The marker belongs to the close attempt, not to a document
            // that never closed. A failed final close must not leave it
            // behind to surprise the next close.
            reopenedDuringClose.remove(path)
        }
        if reopened, closed {
            // The user reopened this file while a close was awaiting. Only
            // the last concurrent close reopens the document; earlier
            // closes keep their tabs and do nothing.
            if remaining == 0 {
                reopenDocument(kind: tab.kind, url: url)
            }
            return .failed
        }
        guard closed else {
            // A Markdown save decision resumes through the close callback,
            // keyed by the pending document itself. Its identity survives a
            // Save As, where a path would change; an untitled document has
            // no path at all. Every other failure (a rejected save, a
            // running conversion that could not cancel) needs an explicit
            // retry.
            if tab.kind == .script, let pending = markdown.pendingClose {
                return .deferred(pending.id)
            }
            return .failed
        }

        // A tab for the same file may have been opened while the close was
        // awaiting. Reopen the document so that tab does not point at a
        // closed document.
        let hasOtherTab = openTabs.contains { other in
            other.id != tab.id
                && (other.url ?? sampleDocumentURL(for: other)) == url
        }
        if hasOtherTab {
            reopenDocument(kind: tab.kind, url: url)
        }
        return .closed
    }

    /// The Markdown workspace can move its selected document by following a
    /// link. Keep the owning tab in step so its title, breadcrumb, and close
    /// target refer to the document on screen.
    private func syncTabForDocument(at url: URL, kind: AssetKind) {
        guard !isDemo, !isSyncingTab else { return }
        isSyncingTab = true
        defer { isSyncingTab = false }
        let path = MarkdownSecurity.canonical(url).path
        if let tab = openTabs.first(where: { tab in
            guard tab.kind == kind, let tabURL = tab.url else { return false }
            return MarkdownSecurity.canonical(tabURL).path == path
        }) {
            if selectedTabID != tab.id {
                selectTab(tab.id)
            }
            return
        }
        if let asset = assets.first(where: {
            MarkdownSecurity.canonical($0.url).path == path
        }) {
            openAsset(asset)
        } else {
            // The linked file is outside the scanned index; the workspace
            // tab follows the selected document.
            selectWorkspaceTab(kind)
        }
    }

    private func reopenDocument(kind: AssetKind, url: URL) {
        openDocument(kind: kind, url: url)
    }

    private func beginClosing(_ path: String) {
        closingPaths[path, default: 0] += 1
    }

    @discardableResult
    private func endClosing(_ path: String) -> Int {
        guard let count = closingPaths[path] else { return 0 }
        if count <= 1 {
            closingPaths[path] = nil
            return 0
        }
        let remaining = count - 1
        closingPaths[path] = remaining
        return remaining
    }

    /// Removes tabs whose file was closed through the workspace itself, such
    /// as a save/discard decision resolved after the tab close was deferred.
    private func removeTabs(forFileAt url: URL) {
        let path = MarkdownSecurity.canonical(url).path
        // The tab-close flow owns the tab while its close is awaiting.
        guard closingPaths[path] == nil else { return }
        let ids = openTabs.compactMap { tab -> String? in
            // Demo document tabs carry no URL; resolve their sample file.
            guard let tabURL = tab.url ?? sampleDocumentURL(for: tab),
                  MarkdownSecurity.canonical(tabURL).path == path else {
                return nil
            }
            return tab.id
        }
        guard !ids.isEmpty else { return }
        let removedSelected = ids.contains(selectedTabID)
        openTabs.removeAll { ids.contains($0.id) }
        noteSelectionChange()
        if removedSelected {
            if let first = openTabs.first {
                selectTab(first.id)
            } else {
                selectedTabID = ""
                selectedAssetID = nil
            }
        }
        onSelectionChanged?()
    }

    private func sampleDocumentURL(for tab: EditorTab) -> URL? {
        guard isDemo,
              let assetID = tab.sampleAsset?.id,
              let name = Self.sampleDocumentNames[assetID] else {
            return nil
        }
        return sampleDocuments?.documentURL(named: name)
    }

    func closeAllTabs() async {
        let tabs = openTabs
        bulkClosePending = false
        bulkClosePendingDocumentID = nil
        for tab in tabs {
            // Remove each tab as soon as its document closes. Deferring the
            // removals lets a file reopened during a later awaiting close
            // reuse the old tab, which the final sweep would then delete.
            switch await closeDocumentIfNeeded(for: tab) {
            case .closed:
                removeTab(id: tab.id)
            case .deferred(let documentID):
                // Stop at the first document that needs a save decision;
                // the workspace can hold only one pending decision at a
                // time. Resolving that exact document resumes the tabs.
                bulkClosePending = true
                bulkClosePendingDocumentID = documentID
                onSelectionChanged?()
                return
            case .failed:
                // Nothing will call us back. Keep the remaining tabs open
                // rather than resuming the close on an unrelated event.
                onSelectionChanged?()
                return
            }
        }
        if openTabs.isEmpty {
            noteSelectionChange()
            selectedTabID = ""
            selectedAssetID = nil
        }
        onSelectionChanged?()
    }

    /// A document close resolved. Resume whichever close was waiting on it.
    private func resumePendingCloseIfNeeded(closedDocument: MarkdownDocument) {
        if bulkClosePending {
            // Only the document that blocked the bulk close may resume it.
            // A close of any other document leaves the decision pending.
            guard closedDocument.id == bulkClosePendingDocumentID else {
                return
            }
            pendingWorkspaceClose = nil
            pendingWorkspaceCloseDocumentID = nil
            resumeBulkCloseIfNeeded()
            return
        }
        guard let kind = pendingWorkspaceClose else { return }
        guard closedDocument.id == pendingWorkspaceCloseDocumentID else {
            return
        }
        pendingWorkspaceClose = nil
        pendingWorkspaceCloseDocumentID = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard case .closed = await self.closeWorkspaceDocuments(
                kind: kind
            ) else {
                return
            }
            if let tab = self.openTabs.first(where: {
                $0.workspaceKind == kind
            }) {
                await self.closeTab(tab.id)
            }
        }
    }

    /// Resumes a bulk close that stopped at a save decision.
    private func resumeBulkCloseIfNeeded() {
        guard bulkClosePending else { return }
        bulkClosePending = false
        bulkClosePendingDocumentID = nil
        Task { @MainActor [weak self] in
            await self?.closeAllTabs()
        }
    }

    /// The user cancelled the save decision; the remaining tabs stay open.
    func cancelBulkClose() {
        bulkClosePending = false
        bulkClosePendingDocumentID = nil
        pendingWorkspaceClose = nil
        pendingWorkspaceCloseDocumentID = nil
    }

    /// A Save As moved a Markdown document to a new path. Tabs naming the
    /// old path are removed, and the new identity is selected when the moved
    /// document was the one on screen.
    private func moveTabs(from oldURL: URL, to newURL: URL) {
        let oldPath = MarkdownSecurity.canonical(oldURL).path
        let ids = openTabs.compactMap { tab -> String? in
            guard tab.kind == .script,
                  let tabURL = tab.url ?? sampleDocumentURL(for: tab),
                  MarkdownSecurity.canonical(tabURL).path == oldPath else {
                return nil
            }
            return tab.id
        }
        guard !ids.isEmpty else {
            // A document that had no tab (a new file being saved for the
            // first time) follows the normal activation path, but only when
            // it is the document on screen.
            let newPath = MarkdownSecurity.canonical(newURL).path
            let selectedPath = markdown.selectedDocument?.fileURL.map {
                MarkdownSecurity.canonical($0).path
            }
            if selectedPath == newPath {
                syncTabForDocument(at: newURL, kind: .script)
            }
            return
        }
        let removedSelected = ids.contains(selectedTabID)
        openTabs.removeAll { ids.contains($0.id) }
        if removedSelected {
            selectedTabID = ""
            selectedAssetID = nil
            if isDemo {
                // Sample documents are not scanned assets, so there is no
                // asset tab to follow the moved file. The Markdown workspace
                // tab is the demo's identity for it.
                selectWorkspaceTab(.script)
            } else {
                syncTabForDocument(at: newURL, kind: .script)
            }
        }
        onSelectionChanged?()
    }

    func displayName(for tab: EditorTab) -> String {
        if let url = tab.url {
            return url.lastPathComponent
        }
        guard tab.id == selectedTabID else { return tab.title }
        switch tab.kind {
        case .script:
            return markdown.selectedDocument?.fileURL?
                .lastPathComponent ?? tab.title
        case .subtitle:
            return subtitles.selectedDocument?.fileURL
                .lastPathComponent ?? tab.title
        case .model3d:
            return models.selectedDocument?.displayName ?? tab.title
        default:
            return tab.title
        }
    }

    func activate(loadIfOffline: Bool = true) {
        isActive = true
        hasActivity = false
        if loadIfOffline, case .offline = availability {
            Task { @MainActor [weak self] in
                await self?.load()
            }
        }
    }

    /// Stops a removed project from applying an in-flight scan or persisting
    /// a selection after it no longer belongs to the workspace.
    func invalidate() {
        isInvalidated = true
        lifecycleGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
        watcher?.stop()
        watcher = nil
        onSelectionChanged = nil
    }

    func deactivate() {
        isActive = false
        // Subtitle media is owned by the workspace, not by a removable view,
        // so it must be paused explicitly when the project stops being shown.
        subtitles.pauseForDeactivation()
    }

    var isOffline: Bool {
        if case .offline = availability { return true }
        return false
    }

    var offlineReason: String? {
        if case .offline(let reason) = availability { return reason }
        return nil
    }

    var hasDirtyDocuments: Bool {
        markdown.hasDirtyDocuments || subtitles.hasDirtyDocuments
    }

    func prepareForTermination() {
        refreshTask?.cancel()
        watcher?.stop()
        watcher = nil
        models.prepareForTermination()
        terminalSessions.shutdownAll(force: true)
    }
}

private final class NoopProjectWatcher: ProjectWatching {
    var isRunning = true
    func start() {}
    func stop() { isRunning = false }
}
