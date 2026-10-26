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
    let code: CodeWorkspace
    let terminalSessions: TerminalSessionsStore
    let mediaEdits: MediaEditWorkspace
    let timelines: TimelineWorkspace
    /// The Sample project's files live in Application Support and have no
    /// folder scan; this registry supplies its recorded takes and exports.
    let sampleMedia: SampleMediaRegistry?

    private(set) var assets: [ProjectAsset] = []
    private(set) var groups: [ProjectAssetGroup] = []
    /// The Files navigator's folder hierarchy, rebuilt with each scan.
    private(set) var fileTree: [FileNode] = []
    private(set) var availability: Availability
    private(set) var truncated = false
    private(set) var visitedEntries = 0
    /// The last recording or export error, shown in the media edit surface.
    private(set) var mediaError: String?
    /// Bumped when a media file is created or replaced. Demo assets are not
    /// scanned, so this is what makes their views re-read the file revision.
    private(set) var mediaGeneration: UInt64 = 0
    /// Bumped after every applied scan, including one whose metadata looks
    /// unchanged, so timeline source fingerprints are rechecked.
    private(set) var scanRevision: UInt64 = 0

    var openTabs: [EditorTab]
    var selectedTabID: String
    var selectedAssetID: String?
    /// The tab that was active before the current one. Ctrl+Tab toggles
    /// between the two; it is updated only by an explicit tab selection.
    private(set) var lastUsedTabID: String?

    /// The file tabs worth restoring at launch. Synthetic workspace tabs are
    /// recreated on demand, and demo sample tabs have no scanned assets.
    var restorableTabIDs: [String] {
        openTabs.compactMap { tab in
            tab.workspaceKind == nil ? tab.assetID : nil
        }
    }
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
    /// Counts tab-set changes that leave the selection alone, such as closing
    /// an unselected tab. Recovery compares it so a deliberate close is not
    /// undone by the saved tab list.
    private(set) var tabRevision: UInt64 = 0
    /// True only while scan reconciliation mutates selection synchronously.
    private var isApplyingScan = false

    /// Workspace persistence hook. Called when the selection changes.
    var onSelectionChanged: (() -> Void)?

    private let scanner: any ProjectScanning
    private let watchFactory: ProjectWatchFactory
    private let sampleDocuments: SampleProjectDocuments?
    private(set) var watcher: ProjectWatching?
    private var refreshTask: Task<Void, Never>?
    private var watcherRetryTask: Task<Void, Never>?
    private var recordingDestinationDirectory: URL?
    /// Save As destinations reserved for the duration of a write, keyed by
    /// path and owned by the document doing the write. A destination is
    /// reserved before the await, so any workspace's `open` during the write
    /// cannot create a second document for the same path.
    private var sharedReservedDestinations: [String: UUID] = [:]
    private var scanInFlight = false
    private var rescanRequested = false
    private var scanSettlementWaiters: [CheckedContinuation<Void, Never>] = []
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
        code: CodeWorkspace,
        terminalSessions: TerminalSessionsStore,
        openTabs: [EditorTab],
        selectedTabID: String,
        selectedAssetID: String?,
        availability: Availability,
        expectedVolumeIdentifier: String?,
        scanner: any ProjectScanning,
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
        self.code = code
        self.terminalSessions = terminalSessions
        self.openTabs = openTabs
        self.selectedTabID = selectedTabID
        self.selectedAssetID = selectedAssetID
        self.availability = availability
        self.expectedVolumeIdentifier = expectedVolumeIdentifier
        self.scanner = scanner
        self.watchFactory = watchFactory
        self.sampleDocuments = sampleDocuments
        self.mediaEdits = MediaEditWorkspace()
        self.timelines = TimelineWorkspace()
        if isDemo, let sampleDocuments {
            self.sampleMedia = SampleMediaRegistry(
                directory: sampleDocuments.destinationDirectory
            )
        } else {
            self.sampleMedia = nil
        }
        self.markdown.onDocumentClosed = { [weak self] document in
            guard let self else { return }
            if let url = document.fileURL {
                self.removeTabs(forFileAt: url, kind: .script)
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
            self?.removeTabs(forFileAt: url, kind: .subtitle)
        }
        self.subtitles.onDocumentActivated = { [weak self] url in
            self?.syncTabForDocument(at: url, kind: .subtitle)
        }
        self.models.onDocumentActivated = { [weak self] url in
            self?.syncTabForDocument(at: url, kind: .model3d)
        }
        self.models.onDocumentClosed = { [weak self] url in
            self?.removeTabs(forFileAt: url, kind: .model3d)
        }
        self.code.onDocumentClosed = { [weak self] document in
            guard let self else { return }
            self.removeTabs(forFileAt: document.fileURL, kind: .code)
            self.resumePendingCloseIfNeeded(codeDocument: document)
        }
        self.code.onDocumentActivated = { [weak self] url in
            self?.syncTabForDocument(at: url, kind: .code)
        }
        self.code.onDocumentMoved = { [weak self] oldURL, newURL in
            self?.moveCodeTabs(from: oldURL, to: newURL)
        }
        self.code.isPathOwned = { [weak self] path, excluding in
            self?.isDocumentPathOpen(path, excluding: excluding) ?? false
        }
        self.code.isPathOwnedAnywhere = { [weak self] path in
            self?.isDocumentPathOpen(path, excluding: nil) ?? false
        }
        self.code.isEditorTabSelected = { [weak self] in
            guard let self else { return false }
            return self.openTabs.first {
                $0.id == self.selectedTabID
            }?.kind == .code
        }
        self.markdown.isDestinationReserved = { [weak self] path in
            self?.sharedReservedDestinations[path] != nil
        }
        self.markdown.isPathOwnedElsewhere = { [weak self] path in
            self?.isDocumentPathOpen(path, excluding: nil) ?? false
        }
        self.markdown.reserveSharedDestination = { [weak self] path, owner in
            self?.reserveSharedDestination(path, owner: owner) ?? false
        }
        self.markdown.releaseSharedDestination = { [weak self] path, owner in
            self?.releaseSharedDestination(path, owner: owner)
        }
        self.subtitles.isDestinationReserved = { [weak self] path in
            self?.sharedReservedDestinations[path] != nil
        }
        self.subtitles.isPathOwnedElsewhere = { [weak self] path in
            self?.isDocumentPathOpen(path, excluding: nil) ?? false
        }
        self.models.isDestinationReserved = { [weak self] path in
            self?.sharedReservedDestinations[path] != nil
        }
        self.models.isPathOwnedElsewhere = { [weak self] path in
            self?.isDocumentPathOpen(path, excluding: nil) ?? false
        }
        self.code.reserveDestination = { [weak self] path, owner in
            self?.reserveSharedDestination(path, owner: owner) ?? false
        }
        self.code.releaseDestination = { [weak self] path, owner in
            self?.releaseSharedDestination(path, owner: owner)
        }
        self.code.isDestinationReserved = { [weak self] path in
            self?.sharedReservedDestinations[path] != nil
        }
    }

    /// Reserves a Save As destination across every workspace. The main actor
    /// makes the checks and the insert one step, with no await between them.
    private func reserveSharedDestination(
        _ path: String,
        owner: UUID
    ) -> Bool {
        // Ownership is checked here too, so a Markdown Save As cannot take a
        // path an open code document already owns (or vice versa).
        if isDocumentPathOpen(path, excluding: owner) {
            return false
        }
        if let existing = sharedReservedDestinations[path], existing != owner {
            return false
        }
        sharedReservedDestinations[path] = owner
        return true
    }

    private func releaseSharedDestination(_ path: String, owner: UUID) {
        if sharedReservedDestinations[path] == owner {
            sharedReservedDestinations.removeValue(forKey: path)
        }
    }

    convenience init(
        folderURL: URL,
        expectedVolumeIdentifier: String? = nil,
        scanner: any ProjectScanning = ProjectScanner(),
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
        scanner: any ProjectScanning = ProjectScanner(),
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
        scanner: any ProjectScanning,
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
            code: CodeWorkspace(readsDemoEnvironment: false),
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
        code.setWorkspaceRoot(root)
        markdown.setWorkspaceRoot(root)
        markdown.onOpenAsset = { [weak self] url in
            guard let self else { return false }
            let path = MarkdownSecurity.canonical(url).path
            guard let asset = self.assets.first(where: {
                MarkdownSecurity.canonical($0.url).path == path
            }) else {
                return false
            }
            self.openAsset(asset)
            return true
        }
    }

    static func demo(
        production: Production,
        markdown: MarkdownWorkspace,
        subtitles: SubtitleWorkspace,
        models: Model3DWorkspace,
        terminalSessions: TerminalSessionsStore,
        sampleDocuments: SampleProjectDocuments?,
        code: CodeWorkspace = CodeWorkspace(readsDemoEnvironment: false)
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
            code: code,
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
        // A scan already in flight makes performScan queue one rescan and
        // return. Recovery must wait for the snapshot that includes that
        // rescan, not continue against the previous index.
        await waitForScanSettlement()
    }

    private func waitForScanSettlement() async {
        while scanInFlight || rescanRequested {
            await withCheckedContinuation { continuation in
                scanSettlementWaiters.append(continuation)
            }
        }
    }

    private func settleScanIfIdle() {
        guard !scanInFlight, !rescanRequested else { return }
        let waiters = scanSettlementWaiters
        scanSettlementWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
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
        guard !isInvalidated else {
            settleScanIfIdle()
            return
        }
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
        defer { settleScanIfIdle() }
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
        if let document = timelines.document {
            timelines.handleExternalChange(url: document.url)
        }
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
        scanRevision &+= 1
        // A complete scan already built groups; only a merged partial or
        // truncated result needs them recomputed.
        groups = result.isPartial || result.truncated
            ? ProjectScanner.groups(from: effectiveAssets)
            : result.groups
        fileTree = ProjectFileTree.nodes(from: effectiveAssets)
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
            // The scan excludes some files the app can still open (an
            // unrecognized extension saved from a code tab). Absence from
            // the index is not deletion; the disk decides.
            if let url = tab.url,
               FileManager.default.fileExists(atPath: url.path) {
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
        case .code:
            return code.documents.first {
                MarkdownSecurity.canonical($0.fileURL) == url
            }?.isDirty == true
        case .timeline:
            guard let document = timelines.document else { return false }
            return MarkdownSecurity.canonical(document.url)
                == MarkdownSecurity.canonical(url)
                && document.hasUnsavedChanges
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
        case .code:
            guard let document = code.selectedDocument else { return nil }
            let language = document.language.displayName
            if let reason = document.readOnlyReason {
                return (document.displayName, "\(language) · \(reason)")
            }
            return (
                document.displayName,
                "\(language) · \(document.lineEnding == .crlf ? "CRLF" : "LF")"
            )
        default:
            return nil
        }
    }

    var selectedTab: EditorTab? {
        openTabs.first { $0.id == selectedTabID }
    }

    /// The filter is shared by every navigator mode. Whitespace-only input is
    /// no filter, so a stray space never empties the sidebar.
    var trimmedFilterText: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var filteredGroups: [ProjectAssetGroup] {
        let query = trimmedFilterText
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let matches = group.assets.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.relativePath.localizedCaseInsensitiveContains(query)
            }
            return matches.isEmpty
                ? nil
                : ProjectAssetGroup(
                    descriptor: group.descriptor,
                    assets: matches
                )
        }
    }

    var sampleStages: [ProductionStage] {
        guard let demoProduction else { return [] }
        // Demo files are not scanned. Reading the generation makes the
        // sample rows re-read their durations after a replace.
        _ = mediaGeneration
        var stages = demoProduction.stages.map { stage in
            ProductionStage(
                id: stage.id,
                title: stage.title,
                assets: stage.assets.map(resolvedSampleAsset)
            )
        }
        if let recordings = sampleMedia?.productionStage() {
            if let voiceIndex = stages.firstIndex(where: { $0.id == "voice" }) {
                stages.insert(recordings, at: voiceIndex + 1)
            } else {
                stages.append(recordings)
            }
        }
        return stages
    }

    private func resolvedSampleAsset(
        _ asset: ProductionAsset
    ) -> ProductionAsset {
        guard asset.kind == .audio,
              let media = sampleMediaAsset(for: asset.id),
              let audio = MediaAudioMetadata.describe(url: media.url) else {
            return asset
        }
        return ProductionAsset(
            id: asset.id,
            name: asset.name,
            detail: audio.detail,
            kind: asset.kind
        )
    }

    func sampleStage(for assetID: String) -> ProductionStage? {
        sampleStages.first { stage in
            stage.assets.contains { $0.id == assetID }
        }
    }

    var filteredStages: [ProductionStage] {
        let stages = sampleStages
        let query = trimmedFilterText
        guard !query.isEmpty else { return stages }
        return stages.compactMap { stage in
            let matches = stage.assets.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.detail.localizedCaseInsensitiveContains(query)
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

    private func noteTabChange() {
        guard !isApplyingScan else { return }
        tabRevision &+= 1
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
        if let ownerKind = owningKind(forCanonicalPath: path),
           ownerKind != asset.kind {
            // The path is open in another workspace (a symlink asset or a
            // kind mismatch). A tab of this asset's kind could not bind a
            // second document, so route to the owner instead.
            if let ownerTab = openTabs.first(where: { tab in
                guard let url = tab.url else { return false }
                return MarkdownSecurity.canonical(url).path == path
            }) {
                selectTab(ownerTab.id)
            } else {
                selectWorkspaceTab(ownerKind)
                // The workspace tab alone does not choose among several open
                // documents; select the one this path names.
                selectOwnedDocument(kind: ownerKind, path: path)
            }
            return
        }
        let tab = EditorTab(asset: asset)
        openTabs.append(tab)
        selectTab(tab.id)
    }

    /// Selects the document that owns `path` in the given workspace.
    private func selectOwnedDocument(kind: AssetKind, path: String) {
        switch kind {
        case .script:
            if let document = markdown.documents.first(where: {
                $0.fileURL.map {
                    MarkdownSecurity.canonical($0).path
                } == path
            }) {
                markdown.select(document)
            }
        case .subtitle:
            if let document = subtitles.documents.first(where: {
                MarkdownSecurity.canonical($0.fileURL).path == path
            }) {
                subtitles.select(document)
            }
        case .model3d:
            if let document = models.documents.first(where: {
                MarkdownSecurity.canonical($0.sourceURL).path == path
            }) {
                models.select(document)
            }
        case .code:
            if let document = code.documents.first(where: {
                MarkdownSecurity.canonical($0.fileURL).path == path
            }) {
                code.select(document)
            }
        case .timeline:
            break
        default:
            break
        }
    }

    /// The workspace that currently owns a document at the canonical path.
    private func owningKind(forCanonicalPath path: String) -> AssetKind? {
        if markdown.documents.contains(where: {
            guard let url = $0.fileURL else { return false }
            return MarkdownSecurity.canonical(url).path == path
        }) {
            return .script
        }
        if subtitles.documents.contains(where: {
            MarkdownSecurity.canonical($0.fileURL).path == path
        }) {
            return .subtitle
        }
        if models.documents.contains(where: {
            MarkdownSecurity.canonical($0.sourceURL).path == path
        }) {
            return .model3d
        }
        if code.documents.contains(where: {
            MarkdownSecurity.canonical($0.fileURL).path == path
        }) {
            return .code
        }
        if let document = timelines.document,
           MarkdownSecurity.canonical(document.url).path == path {
            return .timeline
        }
        return nil
    }

    func openSampleAsset(_ asset: ProductionAsset) {
        noteSelectionChange()
        if let existing = openTabs.first(where: { $0.assetID == asset.id }) {
            noteReopenIfClosing(
                existing.url ?? sampleDocumentURL(for: existing)
            )
            selectTab(existing.id)
            return
        }
        let tab = EditorTab(asset: asset)
        noteReopenIfClosing(tab.url ?? sampleDocumentURL(for: tab))
        openTabs.append(tab)
        selectTab(tab.id)
    }

    /// Records that a file was asked for while its document close is
    /// awaiting, so the close does not remove the tab it just revived.
    private func noteReopenIfClosing(_ url: URL?) {
        guard let url else { return }
        let path = MarkdownSecurity.canonical(url).path
        if closingPaths[path] != nil {
            reopenedDuringClose.insert(path)
        }
    }

    func openAsset(id: String?) {
        guard let id else { return }
        if isDemo {
            guard let asset = sampleProductionAsset(id: id) else { return }
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
        if selectedTabID != id, !selectedTabID.isEmpty {
            lastUsedTabID = selectedTabID
        }
        selectedTabID = id
        selectedAssetID = tab.assetID
        bindDocument(for: tab)
        onSelectionChanged?()
    }

    /// Ctrl+Tab. Selecting the previous tab makes it the new previous, so a
    /// second press returns to where the user started.
    func toggleLastUsedTab() {
        guard let lastUsedTabID,
              lastUsedTabID != selectedTabID,
              openTabs.contains(where: { $0.id == lastUsedTabID }) else {
            return
        }
        selectTab(lastUsedTabID)
    }

    func selectNextTab() {
        selectTab(offset: 1)
    }

    func selectPreviousTab() {
        selectTab(offset: -1)
    }

    private func selectTab(offset: Int) {
        guard openTabs.count > 1,
              let current = openTabs.firstIndex(where: {
                  $0.id == selectedTabID
              }) else {
            return
        }
        let count = openTabs.count
        let index = ((current + offset) % count + count) % count
        selectTab(openTabs[index].id)
    }

    private func bindDocument(for tab: EditorTab) {
        if let url = tab.url {
            openDocument(kind: tab.kind, url: url)
            return
        }
        guard isDemo,
              let assetID = tab.sampleAsset?.id,
              let name = Self.sampleDocumentNames[assetID] else {
            return
        }
        let prepared: URL
        do {
            guard let sampleDocuments else {
                throw SampleDocumentError.sourceUnavailable(name)
            }
            prepared = try sampleDocuments.documentURL(named: name)
        } catch {
            let message = "The sample document “\(name)” could not be "
                + "prepared: \(error.localizedDescription)"
            if tab.kind == .subtitle {
                subtitles.lastError = message
                subtitles.selectedDocumentID = nil
            } else {
                markdown.lastError = message
                markdown.selectedDocumentID = nil
            }
            return
        }
        openDocument(kind: tab.kind, url: prepared)
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
        case .code:
            code.open(url: url)
        case .timeline:
            timelines.open(url: url)
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
        noteTabChange()
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
        // still see and reach from a file tab. The tabs are checked per
        // document, not captured once: a file tab can open while an earlier
        // close in this loop is awaiting a decision.
        func hasFileTab(_ url: URL) -> Bool {
            let path = MarkdownSecurity.canonical(url).path
            return openTabs.contains { tab in
                guard tab.workspaceKind == nil,
                      let tabURL = tab.url ?? sampleDocumentURL(for: tab)
                else {
                    return false
                }
                return MarkdownSecurity.canonical(tabURL).path == path
            }
        }

        // Routes one workspace-hosted document through the same close
        // tracking a file tab uses, so a reopen during the close is honored.
        // Returns nil when the document closed and the loop should continue.
        func closeTracked(
            url: URL?,
            kind: AssetKind,
            pendingDocumentID: () -> UUID?,
            close: () async -> Bool
        ) async -> DocumentCloseOutcome? {
            let path = url.map { MarkdownSecurity.canonical($0).path }
            if let path { beginClosing(path) }
            let closed = await close()
            if let path {
                let remaining = endClosing(path)
                let reopened = reopenedDuringClose.contains(path)
                if remaining == 0, reopened {
                    reopenedDuringClose.remove(path)
                }
                if reopened, closed {
                    if remaining == 0, let url {
                        reopenDocument(kind: kind, url: url)
                    }
                    return .failed
                }
            }
            guard !closed else { return nil }
            if let pending = pendingDocumentID() {
                return .deferred(pending)
            }
            return .failed
        }

        switch kind {
        case .script:
            for document in markdown.documents {
                if let url = document.fileURL, hasFileTab(url) {
                    continue
                }
                let outcome = await closeTracked(
                    url: document.fileURL,
                    kind: .script,
                    // Only a Markdown save decision resumes through the
                    // document-closed callback; a failed save does not. The
                    // pending document identifies the decision itself; the
                    // attempted document can differ when a second close
                    // arrives while the first decision is unresolved.
                    pendingDocumentID: { [weak self] in
                        self?.markdown.pendingClose?.id
                    },
                    close: { [weak self] in
                        guard let self else { return false }
                        return await self.markdown.close(document)
                    }
                )
                if let outcome {
                    if case let .deferred(id) = outcome {
                        pendingWorkspaceClose = kind
                        pendingWorkspaceCloseDocumentID = id
                    }
                    return outcome
                }
            }
            return .closed
        case .code:
            for document in code.documents {
                if hasFileTab(document.fileURL) {
                    continue
                }
                let outcome = await closeTracked(
                    url: document.fileURL,
                    kind: .code,
                    pendingDocumentID: { [weak self] in
                        self?.code.pendingClose?.id
                    },
                    close: { [weak self] in
                        guard let self else { return false }
                        return await self.code.close(document)
                    }
                )
                if let outcome {
                    if case let .deferred(id) = outcome {
                        pendingWorkspaceClose = kind
                        pendingWorkspaceCloseDocumentID = id
                    }
                    return outcome
                }
            }
            return .closed
        case .subtitle:
            for document in subtitles.documents {
                if hasFileTab(document.fileURL) {
                    continue
                }
                // A subtitle close failure is reported, not deferred: no
                // decision alert re-enters this close, so keeping the tab
                // is the final state until the user closes it again.
                let outcome = await closeTracked(
                    url: document.fileURL,
                    kind: .subtitle,
                    pendingDocumentID: { nil },
                    close: { [weak self] in
                        guard let self else { return false }
                        return await self.subtitles.close(document)
                    }
                )
                if let outcome { return outcome }
            }
            return .closed
        case .model3d:
            for document in models.documents {
                if hasFileTab(document.sourceURL) {
                    continue
                }
                let outcome = await closeTracked(
                    url: document.sourceURL,
                    kind: .model3d,
                    pendingDocumentID: { nil },
                    close: { [weak self] in
                        guard let self else { return false }
                        return await self.models.close(document)
                    }
                )
                if let outcome { return outcome }
            }
            return .closed
        case .timeline:
            timelines.cancelJobs()
            return await timelines.close() ? .closed : .failed
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
        if tab.kind == .audio || tab.kind == .video {
            stopOrCancelRecordingForLifecycle()
            if let url = tab.url
                ?? (isDemo ? sampleMediaAsset(for: tab.assetID)?.url : nil) {
                mediaEdits.close(url: url)
            }
            return .closed
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
        case .code:
            if let document = code.documents.first(where: {
                MarkdownSecurity.canonical($0.fileURL).path == path
            }) {
                closed = await code.close(document)
            } else {
                closed = true
            }
        case .timeline:
            timelines.cancelJobs()
            closed = await timelines.close(url: url)
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
            if tab.kind == .code, let pending = code.pendingClose {
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
            if asset.kind == kind {
                openAsset(asset)
            } else if kind == .code {
                // The document is open in the code workspace, so its tab
                // must be a code tab even when the extension scans as
                // another kind (a code file saved as `.md`, for example).
                openCodeTab(for: codeAsset(from: asset))
            } else {
                selectWorkspaceTab(kind)
            }
        } else if kind == .code {
            // A code file opened from search or a link may not be in the
            // scan index yet; the tab still names the real file.
            openMovedCodeDocument(at: url)
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
    private func removeTabs(forFileAt url: URL, kind: AssetKind) {
        let path = MarkdownSecurity.canonical(url).path
        // The tab-close flow owns the tab while its close is awaiting.
        guard closingPaths[path] == nil else { return }
        // Only the closing workspace's tab goes: a duplicate document of
        // another kind must keep its tab even though it names the same path.
        let ids = openTabs.compactMap { tab -> String? in
            guard tab.kind == kind else { return nil }
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
        noteTabChange()
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

    /// The Sample project's audio takes are real WAV files shipped in the
    /// bundle. They are copied into Application Support on first use so the
    /// real MediaAssetView can read them like any other project asset.
    func sampleAudioAsset(for id: String) -> ProjectAsset? {
        guard isDemo, let sampleDocuments else { return nil }
        let name = "\(id).wav"
        guard let url = try? sampleDocuments.documentURL(named: name) else {
            return nil
        }
        let values = try? url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        let size = Int64(values?.fileSize ?? 0)
        let modified = values?.contentModificationDate
        let identifier = values?.fileResourceIdentifier.map {
            String(describing: $0)
        }
        return ProjectAsset(
            id: id,
            url: url,
            name: name,
            relativePath: name,
            kind: .audio,
            size: size,
            modified: modified,
            revision: AssetRevision(
                fileIdentifier: identifier,
                size: size,
                modified: modified,
            )
        )
    }

    /// A Sample media row, whether bundled or created by recording/export.
    func sampleMediaAsset(for id: String) -> ProjectAsset? {
        if let registered = sampleMedia?.asset(id: id) {
            return registered
        }
        return sampleAudioAsset(for: id)
    }

    /// The production row for a Sample tab. New recordings and exports are
    /// not in the static production, so the registry supplies them.
    func sampleProductionAsset(id: String) -> ProductionAsset? {
        if let asset = sampleStages.first(where: {
            $0.assets.contains { $0.id == id }
        })?.assets.first(where: { $0.id == id }) {
            return asset
        }
        return demoProduction?.asset(id: id)
    }

    var mediaDestinationDirectory: URL? {
        if isDemo { return sampleDocuments?.destinationDirectory }
        return root
    }

    var canRecordAudio: Bool {
        guard mediaDestinationDirectory != nil else { return false }
        if case .offline = availability { return false }
        return true
    }

    var isRecordingAudio: Bool {
        mediaEdits.recorder.isRecording
    }

    func clearMediaError() {
        mediaError = nil
    }

    func startAudioRecording() async -> Bool {
        mediaError = nil
        guard canRecordAudio,
              let destination = mediaDestinationDirectory else {
            mediaError = "This project has no writable folder for recordings."
            return false
        }
        guard !mediaEdits.isExportingOperation else {
            mediaError = "Wait for the current export to finish before recording."
            return false
        }
        if mediaEdits.recorder.isRecording { return true }
        guard !mediaEdits.recorder.isPreparing else {
            mediaError = "A recording is already starting."
            return false
        }
        do {
            let temporary = try MediaStorage.makeTemporaryURL(
                pathExtension: "wav"
            )
            try await mediaEdits.recorder.start(to: temporary)
            recordingDestinationDirectory = destination
            return true
        } catch is CancellationError {
            mediaError = nil
            return false
        } catch {
            mediaError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func stopAudioRecording(openWhenFinished: Bool = true) -> ProjectAsset? {
        guard let temporary = mediaEdits.recorder.stop() else {
            if let error = mediaEdits.recorder.lastError {
                mediaError = "The recording could not be saved: \(error)"
            }
            return nil
        }
        guard let destination = recordingDestinationDirectory
                ?? mediaDestinationDirectory else {
            mediaError = "This project has no writable folder for recordings."
            MediaStorage.removeIfPresent(temporary)
            return nil
        }
        recordingDestinationDirectory = nil
        let name = "Recording-\(MediaStorage.timestamp()).wav"
        let target = MediaStorage.uniqueURL(
            in: destination,
            preferredName: name
        )
        do {
            try MediaStorage.installAtomically(
                from: temporary,
                to: target,
                replacing: false
            )
        } catch {
            mediaError = "The recording could not be saved (temporary file "
                + "remains at \(temporary.path)): "
                + error.localizedDescription
            return nil
        }
        MediaStorage.removeIfPresent(temporary)
        let asset = registerCreatedMedia(
            at: target,
            kind: .audio,
            openWhenFinished: openWhenFinished
        )
        if asset != nil {
            mediaGeneration &+= 1
        }
        return asset
    }

    func cancelAudioRecording() {
        mediaEdits.recorder.cancel()
        recordingDestinationDirectory = nil
        mediaError = nil
    }

    /// Exports the document's current decision as a new take or replaces the
    /// source after keeping a backup. The source is never touched until the
    /// exporter has produced and verified a complete file.
    func exportMedia(
        _ document: MediaEditDocument,
        mode: MediaExportMode
    ) async throws -> ProjectAsset {
        guard let destination = mediaDestinationDirectory else {
            throw MediaExportError.exportFailed(
                "This project has no writable folder for exports."
            )
        }
        guard !document.isStale, let state = document.editState else {
            throw MediaStorageError.sourceChanged(document.asset.name)
        }
        mediaError = nil
        guard mediaEdits.beginExport(document) else {
            throw MediaExportError.busy
        }
        defer { mediaEdits.endExport(document) }
        do {
            let outcome = try await mediaEdits.exportService.export(
                source: document.asset,
                state: state,
                destinationDirectory: destination,
                projectName: name,
                mode: mode
            )
            switch mode {
            case .newTake:
                let kind = Self.mediaKind(for: outcome.url)
                guard let asset = registerCreatedMedia(
                    at: outcome.url,
                    kind: kind,
                    openWhenFinished: true
                ) else {
                    throw MediaExportError.missingOutput
                }
                mediaGeneration &+= 1
                return asset
            case .replaceOriginal:
                mediaEdits.discardDocument(for: document.asset.url)
                if isDemo {
                    sampleMedia?.refresh()
                    guard let asset = sampleMediaAsset(for: document.asset.id) else {
                        throw MediaExportError.missingOutput
                    }
                    openAsset(id: asset.id)
                    mediaGeneration &+= 1
                    return asset
                }
                await refreshNow()
                await waitForScanSettlement()
                let canonical = MarkdownSecurity.canonical(outcome.url)
                if let asset = assets.first(where: {
                    MarkdownSecurity.canonical($0.url) == canonical
                }) {
                    openAsset(asset)
                    mediaGeneration &+= 1
                    return asset
                }
                let asset = syntheticAsset(
                    for: canonical,
                    kind: document.asset.kind
                )
                openAsset(asset)
                mediaGeneration &+= 1
                return asset
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            mediaError = error.localizedDescription
            throw error
        }
    }

    private func registerCreatedMedia(
        at url: URL,
        kind: AssetKind,
        openWhenFinished: Bool
    ) -> ProjectAsset? {
        if isDemo {
            guard let asset = sampleMedia?.register(url: url) else {
                return nil
            }
            if openWhenFinished {
                openAsset(id: asset.id)
            }
            return asset
        }
        let asset = syntheticAsset(
            for: MarkdownSecurity.canonical(url),
            kind: kind
        )
        if openWhenFinished {
            openAsset(asset)
        }
        // The watcher would discover the file on its own; an immediate scan
        // makes the new asset authoritative before the next user action.
        Task { @MainActor [weak self] in
            await self?.refreshNow()
        }
        return asset
    }

    private static func mediaKind(for url: URL) -> AssetKind {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
            ? .video
            : .audio
    }

    private func sampleDocumentURL(for tab: EditorTab) -> URL? {
        guard isDemo,
              let assetID = tab.sampleAsset?.id,
              let name = Self.sampleDocumentNames[assetID],
              let sampleDocuments else {
            return nil
        }
        return try? sampleDocuments.documentURL(named: name)
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
        resumePendingClose(closedDocumentID: closedDocument.id)
    }

    private func resumePendingCloseIfNeeded(codeDocument: CodeDocument) {
        resumePendingClose(closedDocumentID: codeDocument.id)
    }

    private func resumePendingClose(closedDocumentID: UUID) {
        if bulkClosePending {
            // Only the document that blocked the bulk close may resume it.
            // A close of any other document leaves the decision pending.
            guard closedDocumentID == bulkClosePendingDocumentID else {
                return
            }
            pendingWorkspaceClose = nil
            pendingWorkspaceCloseDocumentID = nil
            resumeBulkCloseIfNeeded()
            return
        }
        guard let kind = pendingWorkspaceClose else { return }
        guard closedDocumentID == pendingWorkspaceCloseDocumentID else {
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
        let previousSelection = selectedTabID
        openTabs.removeAll { ids.contains($0.id) }
        noteTabChange()
        if removedSelected {
            selectedTabID = ""
            selectedAssetID = nil
            if isDemo {
                // Sample documents are not scanned assets, so there is no
                // asset tab to follow the moved file. The Markdown workspace
                // tab is the demo's identity for it.
                selectWorkspaceTab(.script)
            } else {
                openMovedMarkdownDocument(at: newURL)
            }
        } else {
            // The moved document keeps a tab even when another tab is in
            // front. Creating it selects it, so put the previous selection
            // back afterwards.
            if isDemo {
                selectWorkspaceTab(.script)
            } else {
                openMovedMarkdownDocument(at: newURL, select: false)
            }
            if openTabs.contains(where: { $0.id == previousSelection }) {
                selectTab(previousSelection)
            }
        }
        onSelectionChanged?()
    }

    /// A code Save As moved a document to a new path. The old tab is removed
    /// and the new identity becomes the selected asset.
    private func moveCodeTabs(from oldURL: URL, to newURL: URL) {
        let oldPath = MarkdownSecurity.canonical(oldURL).path
        let ids = openTabs.compactMap { tab -> String? in
            guard tab.kind == .code,
                  let tabURL = tab.url,
                  MarkdownSecurity.canonical(tabURL).path == oldPath else {
                return nil
            }
            return tab.id
        }
        guard !ids.isEmpty else {
            let newPath = MarkdownSecurity.canonical(newURL).path
            let selectedPath = code.selectedDocument.map {
                MarkdownSecurity.canonical($0.fileURL).path
            }
            if selectedPath == newPath {
                openMovedCodeDocument(at: newURL)
            }
            return
        }
        let removedSelected = ids.contains(selectedTabID)
        openTabs.removeAll { ids.contains($0.id) }
        noteTabChange()
        if removedSelected {
            selectedTabID = ""
            selectedAssetID = nil
        }
        // The moved document keeps a tab even when another tab is in front;
        // only a move of the selected tab moves the selection.
        openMovedCodeDocument(at: newURL, select: removedSelected)
        onSelectionChanged?()
    }

    /// The new identity of a Markdown Save As may not be in the scan index
    /// yet. Build one tab for it now; the next scan reconciles by the
    /// canonical path id.
    private func openMovedMarkdownDocument(at url: URL, select: Bool = true) {
        let canonical = MarkdownSecurity.canonical(url)
        if let asset = assets.first(where: {
            MarkdownSecurity.canonical($0.url) == canonical
        }) {
            openMarkdownTab(for: asset, select: select)
            return
        }
        openMarkdownTab(
            for: syntheticAsset(for: canonical, kind: .script),
            select: select
        )
    }

    private func openMarkdownTab(
        for asset: ProjectAsset,
        select: Bool = true
    ) {
        let path = MarkdownSecurity.canonical(asset.url).path
        let markdownID = markdown.documents.first {
            $0.fileURL.map {
                MarkdownSecurity.canonical($0).path == path
            } == true
        }?.id
        if isDocumentPathOpen(path, excluding: markdownID) {
            // Another workspace owns this path; a Markdown tab could not
            // bind a second document, so keep the existing tab instead.
            if select,
               let existing = openTabs.first(where: { $0.id == asset.id }) {
                selectTab(existing.id)
            }
            return
        }
        if let existing = openTabs.first(where: { $0.id == asset.id }) {
            if existing.kind == .script {
                if select { selectTab(existing.id) }
                return
            }
            openTabs.removeAll { $0.id == existing.id }
        }
        let tab = EditorTab(asset: asset)
        openTabs.append(tab)
        if select {
            selectTab(tab.id)
        }
    }

    /// An asset-shaped value for a file the last scan has not indexed yet.
    private func syntheticAsset(
        for canonical: URL,
        kind: AssetKind
    ) -> ProjectAsset {
        let values = try? canonical.resourceValues(
            forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        let rootPath = root.map {
            let path = MarkdownSecurity.canonical($0).path
            return path.hasSuffix("/") ? path : path + "/"
        }
        let path = canonical.path
        let relative = rootPath.flatMap {
            path.hasPrefix($0) ? String(path.dropFirst($0.count)) : nil
        } ?? canonical.lastPathComponent
        let size = Int64(values?.fileSize ?? 0)
        let modified = values?.contentModificationDate
        let identifier = values?.fileResourceIdentifier.map {
            String(describing: $0)
        }
        return ProjectAsset(
            id: path,
            url: canonical,
            name: canonical.lastPathComponent,
            relativePath: relative,
            kind: kind,
            size: size,
            modified: modified,
            revision: AssetRevision(
                fileIdentifier: identifier,
                size: size,
                modified: modified,
            )
        )
    }

    /// The new identity of a Save As may not be in the scan index yet. Build
    /// one tab for it now; the next scan reconciles by the canonical path id.
    private func openMovedCodeDocument(at url: URL, select: Bool = true) {
        let canonical = MarkdownSecurity.canonical(url)
        if let asset = assets.first(where: {
            MarkdownSecurity.canonical($0.url) == canonical
        }) {
            // The path's extension may belong to another viewer (code saved
            // as `.md`, for example). The tab must follow the document that
            // is actually open — the code workspace — not the asset's kind.
            openCodeTab(
                for: asset.kind == .code ? asset : codeAsset(from: asset),
                select: select
            )
            return
        }
        openCodeTab(
            for: syntheticAsset(for: canonical, kind: .code),
            select: select
        )
    }

    /// Opens a code tab for an asset-shaped value, replacing a wrong-kind tab
    /// for the same path. A file whose extension now belongs to another
    /// viewer can still be the open code document's new identity.
    private func openCodeTab(
        for asset: ProjectAsset,
        select: Bool = true
    ) {
        let path = MarkdownSecurity.canonical(asset.url).path
        let codeID = code.documents.first {
            MarkdownSecurity.canonical($0.fileURL).path == path
        }?.id
        if isDocumentPathOpen(path, excluding: codeID) {
            // Another workspace owns this path; a code tab could not bind a
            // second document, so keep the existing tab instead.
            if select,
               let existing = openTabs.first(where: { $0.id == asset.id }) {
                selectTab(existing.id)
            }
            return
        }
        if let existing = openTabs.first(where: { $0.id == asset.id }) {
            if existing.kind == .code {
                if select { selectTab(existing.id) }
                return
            }
            // No other workspace owns the path, so a wrong-kind tab here is
            // stale (its document failed to open) and can be replaced.
            openTabs.removeAll { $0.id == existing.id }
        }
        let tab = EditorTab(asset: asset)
        openTabs.append(tab)
        if select {
            selectTab(tab.id)
        }
    }

    private func codeAsset(from asset: ProjectAsset) -> ProjectAsset {
        ProjectAsset(
            id: asset.id,
            url: asset.url,
            name: asset.name,
            relativePath: asset.relativePath,
            kind: .code,
            size: asset.size,
            modified: asset.modified,
            revision: asset.revision
        )
    }

    /// Whether any workspace of this project owns an open document at the
    /// path. Save As uses it to refuse replacing another tab's file; a nil
    /// exclusion asks about every workspace.
    func isDocumentPathOpen(_ path: String, excluding id: UUID?) -> Bool {
        for document in markdown.documents where document.id != id {
            if let url = document.fileURL,
               MarkdownSecurity.canonical(url).path == path {
                return true
            }
        }
        for document in subtitles.documents where document.id != id {
            if MarkdownSecurity.canonical(document.fileURL).path == path {
                return true
            }
        }
        for document in models.documents where document.id != id {
            if MarkdownSecurity.canonical(document.sourceURL).path == path {
                return true
            }
        }
        for document in code.documents where document.id != id {
            if MarkdownSecurity.canonical(document.fileURL).path == path {
                return true
            }
        }
        if let document = timelines.document,
           MarkdownSecurity.canonical(document.url).path == path {
            return true
        }
        return false
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
        case .code:
            return code.selectedDocument?.displayName ?? tab.title
        default:
            return tab.title
        }
    }

    func activate(loadIfOffline: Bool = true) {
        isActive = true
        hasActivity = false
        if isDemo {
            sampleMedia?.refresh()
        }
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
        stopOrCancelRecordingForLifecycle()
        mediaEdits.cancelJobs()
        mediaEdits.closeAll()
        onSelectionChanged = nil
    }

    func deactivate() {
        isActive = false
        // Subtitle media is owned by the workspace, not by a removable view,
        // so it must be paused explicitly when the project stops being shown.
        subtitles.pauseForDeactivation()
        stopOrCancelRecordingForLifecycle()
        mediaEdits.cancelJobs()
        timelines.cancelJobs()
    }

    private func stopOrCancelRecordingForLifecycle() {
        if mediaEdits.recorder.isRecording {
            _ = stopAudioRecording(openWhenFinished: false)
        } else if mediaEdits.recorder.isPreparing {
            mediaEdits.recorder.cancel()
            recordingDestinationDirectory = nil
        }
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
            || code.hasDirtyDocuments || timelines.hasDirtyDocuments
    }

    func prepareForTermination() {
        refreshTask?.cancel()
        watcher?.stop()
        watcher = nil
        stopOrCancelRecordingForLifecycle()
        mediaEdits.cancelJobs()
        mediaEdits.closeAll()
        timelines.cancelJobs()
        markdown.shutdown()
        models.prepareForTermination()
        code.prepareForTermination()
        timelines.prepareForTermination()
        terminalSessions.shutdownAll(force: true)
    }
}

private final class NoopProjectWatcher: ProjectWatching {
    var isRunning = true
    func start() {}
    func stop() { isRunning = false }
}
