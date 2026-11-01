import Foundation
import Observation
import SonovoDomainTypes
import SonovoFileIO
import SonovoFeatureAPI
import SonovoDocumentSupport

/// One folder the user opened, or the built-in sample production. A project
/// owns its tabs, selection, workspaces, and terminals; nothing here is
/// shared with another project.
@MainActor
@Observable
package final class Project: Identifiable, MediaNavigationContext {
    package enum Availability: Equatable, Sendable {
        case available
        case scanning
        case offline(String)
    }

    package let id: String
    package let name: String
    package let root: URL?
    package let isDemo: Bool
    package let externalContent: (any ProjectExternalContent)?
    package let featureSessions: FeatureSessionRegistry
    package let featureEditors: FeatureEditorRegistry
    package let documentWorkspaces: DocumentWorkspaceRegistry
    package private(set) var assets: [ProjectAsset] = []
    package private(set) var groups: [ProjectAssetGroup] = []
    /// The Files navigator's folder hierarchy, rebuilt with each scan.
    package private(set) var fileTree: [FileNode] = []
    package private(set) var availability: Availability
    package private(set) var truncated = false
    package private(set) var visitedEntries = 0
    /// Bumped after every applied scan, including one whose metadata looks
    /// unchanged, so timeline source fingerprints are rechecked.
    package private(set) var scanRevision: UInt64 = 0

    package var openTabs: [EditorTab]
    package var selectedTabID: String
    package var selectedAssetID: String?
    /// The tab that was active before the current one. Ctrl+Tab toggles
    /// between the two; it is updated only by an explicit tab selection.
    package private(set) var lastUsedTabID: String?

    /// The file tabs worth restoring at launch. Synthetic workspace tabs are
    /// recreated on demand, and demo sample tabs have no scanned assets.
    package var restorableTabIDs: [String] {
        openTabs.compactMap { tab in
            tab.workspaceKind == nil ? tab.assetID : nil
        }
    }
    package var filterText = ""
    package var hasActivity = false
    package private(set) var isActive = false
    /// Set while a restored selection is being recovered. Persistence is
    /// suppressed so the empty pre-scan selection cannot overwrite it.
    package var isRestoringSelection = false

    /// Monotonic count of user-initiated selection changes. Scan
    /// reconciliation and restores do not bump it, so recovery can tell a
    /// deliberate choice (including clearing the selection) from its own
    /// work.
    package private(set) var selectionRevision: UInt64 = 0
    /// Counts tab-set changes that leave the selection alone, such as closing
    /// an unselected tab. Recovery compares it so a deliberate close is not
    /// undone by the saved tab list.
    package private(set) var tabRevision: UInt64 = 0
    /// True only while scan reconciliation mutates selection synchronously.
    private var isApplyingScan = false

    /// Workspace persistence hook. Called when the selection changes.
    package var onSelectionChanged: (() -> Void)?

    private let scanner: any ProjectScanning
    private let watchFactory: ProjectWatchFactory
    package private(set) var watcher: ProjectWatching?
    private var refreshTask: Task<Void, Never>?
    private var watcherRetryTask: Task<Void, Never>?
    /// Save As destinations reserved for the duration of a write, keyed by
    /// path and owned by the document doing the write. A destination is
    /// reserved before the await, so any workspace's `open` during the write
    /// cannot create a second document for the same path.
    private var sharedDestinationLeases: [String: DestinationLease] = [:]
    @ObservationIgnored private lazy var destinationLeases = DestinationLeaseRegistry {
        [weak self] path, excluding in
        self?.isDocumentPathOpen(path, excluding: excluding) ?? false
    }
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
    private var pendingWorkspaceClose: FeatureID?
    /// The document that blocked the workspace-tab close.
    private var pendingWorkspaceCloseDocumentID: UUID?
    /// The volume this project was opened on. Every recovery path compares
    /// against it so a path that now belongs to another disk is never read.
    package private(set) var expectedVolumeIdentifier: String?

    package init(
        id: String, name: String, root: URL?, isDemo: Bool = false, featureSessions: FeatureSessionRegistry,
        externalContent: (any ProjectExternalContent)? = nil, openTabs: [EditorTab] = [],
        selectedTabID: String = "", selectedAssetID: String? = nil, availability: Availability = .scanning,
        expectedVolumeIdentifier: String? = nil, scanner: any ProjectScanning,
        watchFactory: @escaping ProjectWatchFactory = { FSEventSource(root: $0, onChange: $1) }
    ) {
        self.id = id; self.name = name; self.root = root; self.isDemo = isDemo
        self.featureSessions = featureSessions; self.featureEditors = featureSessions.editors
        self.documentWorkspaces = featureSessions.documents; self.externalContent = externalContent
        self.openTabs = openTabs; self.selectedTabID = selectedTabID; self.selectedAssetID = selectedAssetID
        self.availability = availability; self.expectedVolumeIdentifier = expectedVolumeIdentifier
        self.scanner = scanner; self.watchFactory = watchFactory
        for adapter in documentWorkspaces.adapters {
            let kind = adapter.kind
            featureSessions.session(for: adapter.featureID)?.attachDocumentHost(DocumentHostServices(
                root: root,
                isPathOwned: { [weak self] path, excluding in self?.isDocumentPathOpen(path, excluding: excluding) ?? false },
                isDestinationReserved: { [weak self] in self?.destinationLeases.contains($0) == true },
                reserveDestination: { [weak self] path, owner in self?.reserveSharedDestination(path, owner: owner) ?? false },
                releaseDestination: { [weak self] path, owner in self?.releaseSharedDestination(path, owner: owner) },
                documentClosed: { [weak self] id, url in
                    guard let self else { return }
                    if let url { self.removeTabs(forFileAt: url, kind: kind) }
                    if let id { self.resumePendingClose(closedDocumentID: id) }
                },
                documentActivated: { [weak self] url in
                    if let url { self?.syncTabForDocument(at: url, adapter: adapter) }
                    else { self?.showWorkspace(featureID: adapter.featureID, preferExistingFile: false) }
                },
                documentMoved: { [weak self] oldURL, newURL in
                    self?.moveDocumentTabs(from: oldURL, to: newURL, adapter: adapter)
                },
                isEditorSelected: { [weak self] in
                    guard let self else { return false }
                    return self.selectedTab.flatMap { self.documentAdapter(for: $0)?.featureID } == adapter.featureID
                },
                openIndexedAsset: { [weak self] url in
                    guard let self, let asset = self.assets.first(where: {
                        FilePathPolicy.canonical($0.url) == FilePathPolicy.canonical(url)
                    }) else { return false }
                    self.openAsset(asset)
                    return true
                }
            ))
        }
    }

    /// Reserves a Save As destination across every workspace. The main actor
    /// makes the checks and the insert one step, with no await between them.
    private func reserveSharedDestination(_ path: String, owner: UUID) -> Bool {
        guard let lease = destinationLeases.reserve(path, owner: owner) else { return false }
        sharedDestinationLeases[path] = lease
        return true
    }

    private func releaseSharedDestination(_ path: String, owner: UUID) {
        guard let lease = sharedDestinationLeases[path], lease.owner == owner else { return }
        // Existing workspace callbacks run only after saveAs awaits the actual
        // atomic write. An autosave timeout does not invoke this callback.
        destinationLeases.finish(lease, outcome: .completed)
        sharedDestinationLeases.removeValue(forKey: path)
    }

    // MARK: - Loading

    package func load() async {
        guard !isDemo, !isInvalidated, let root else { return }
        startWatcherIfNeeded(root: root)
        await performScan(root: root)
        // A scan already in flight makes performScan queue one rescan and
        // return. Recovery must wait for the snapshot that includes that
        // rescan, not continue against the previous index.
        await waitForScanSettlement()
    }

    /// Waits for the scan slot to drain, but not forever. A stalled
    /// reconciliation used to suspend a continuation with no completion path,
    /// so `load()` and media replacement never resumed. Polling keeps the
    /// wait cancellation-aware without leaving continuations behind.
    package func waitForScanSettlement(timeout: TimeInterval? = 5) async {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while scanInFlight || rescanRequested {
            guard !Task.isCancelled, !isInvalidated else { return }
            if let deadline, Date() >= deadline { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Waits for the scan without a deadline, but cancellably. Session
    /// recovery uses this after `load`'s bounded wait: restoring tabs against
    /// an index that is still being built loses assets, so it waits for the
    /// scan already in flight instead. Closing the project or cancelling the
    /// task ends the wait.
    package func awaitScanSettled() async {
        await waitForScanSettlement(timeout: nil)
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

    package func noteFileSystemChange() {
        guard !isDemo else { return }
        hasActivity = !isActive
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshNow()
        }
    }

    package func refreshAssetsForNavigation() async {
        await refreshNow()
        await awaitScanSettled()
    }

    package func refreshNow() async {
        guard !isDemo, let root else { return }
        await performScan(root: root)
    }

    private func performScan(root: URL) async {
        guard !isInvalidated else { return }
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
        // The slot is held until the whole apply-and-rescan loop finishes,
        // including reconciliation and a queued rescan. Releasing it between
        // passes let a filesystem event interleave a second apply.
        defer { scanInFlight = false }
        let scanner = scanner
        while true {
            let generation = lifecycleGeneration
            let result = await Task.detached(priority: .userInitiated) {
                scanner.scan(root: root)
            }.value
            // Do not discard the scan because the debounce task that started
            // it was cancelled by a newer filesystem event. Its result is
            // still a valid snapshot; the queued rescan brings it up to date.
            if generation == lifecycleGeneration {
                await apply(result)
            }
            if rescanRequested {
                rescanRequested = false
                if isInvalidated { break }
                continue
            }
            break
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
        featureSessions.assetsChanged(effectiveAssets)

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
            featureSessions.projectRecovered()
        }
        if changed, !isActive {
            hasActivity = true
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

    package func markOffline(_ reason: String) {
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
        guard let url = tab.url ?? externalDocumentURL(for: tab),
              let adapter = documentAdapter(for: tab) else { return false }
        let query = adapter.dirtyQueryCanonicalizesURL ? FilePathPolicy.canonical(url) : url
        return adapter.documents.first { document in
            document.url.map { FilePathPolicy.canonical($0) == query } == true
        }?.isDirty == true
    }

    // MARK: - Selection

    package var selectedAsset: ProjectAsset? {
        guard let selectedAssetID else { return nil }
        return assets.first { $0.id == selectedAssetID }
    }

    /// The document a synthetic workspace tab is showing. A workspace tab
    /// has no file URL of its own, so breadcrumb and transport chrome must
    /// ask the hosted workspace instead of falling back to "No Editor".
    package var selectedFeatureID: FeatureID? {
        guard let tab = selectedTab else { return nil }
        return tab.ownerFeatureID ?? documentAdapter(for: tab)?.featureID
            ?? tab.projectAsset.flatMap { featureEditors.catalogue.resolve($0.name)?.featureID }
    }

    package func documentAdapter(for tab: EditorTab) -> DocumentWorkspaceAdapter? {
        if let owner = tab.ownerFeatureID { return documentWorkspaces.adapter(for: owner) }
        if let asset = tab.projectAsset, let provider = featureEditors.catalogue.resolve(asset.name), provider.kind == asset.kind,
           let adapter = documentWorkspaces.adapter(for: provider.featureID) { return adapter }
        return documentWorkspaces.adapter(for: tab.kind)
    }

    package func showWorkspace(featureID: FeatureID, role: String = "primary", preferExistingFile: Bool = true) {
        guard let descriptor = featureSessions.descriptor(for: featureID)?.workspaces.first(where: { $0.role == role }) else { return }
        noteSelectionChange()
        let id = descriptor.tabID(projectID: self.id, featureID: featureID)
        if let existing = openTabs.first(where: {
            $0.id == id || (preferExistingFile && documentAdapter(for: $0)?.featureID == featureID)
        }) { selectTab(existing.id); return }
        let tab = EditorTab(workspace: descriptor, featureID: featureID, projectID: self.id)
        openTabs.append(tab); selectTab(tab.id)
    }

    package func workspaceDocumentIdentity(for tab: EditorTab) -> (name: String, detail: String)? {
        guard let document = documentAdapter(for: tab)?.selectedDocument else { return nil }
        return (document.name, document.detail)
    }

    package func workspaceDocumentIdentity(
        for kind: AssetKind
    ) -> (name: String, detail: String)? {
        guard let document = documentWorkspaces.adapter(for: kind)?.selectedDocument else {
            return nil
        }
        return (document.name, document.detail)
    }

    package var selectedTab: EditorTab? {
        openTabs.first { $0.id == selectedTabID }
    }

    /// The filter is shared by every navigator mode. Whitespace-only input is
    /// no filter, so a stray space never empties the sidebar.
    package var trimmedFilterText: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package var filteredGroups: [ProjectAssetGroup] {
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

    private func noteSelectionChange() {
        guard !isApplyingScan else { return }
        selectionRevision &+= 1
    }

    private func noteTabChange() {
        guard !isApplyingScan else { return }
        tabRevision &+= 1
    }

    package func openAsset(_ asset: ProjectAsset) {
        noteSelectionChange()
        let path = FilePathPolicy.canonical(asset.url).path
        if closingPaths[path] != nil {
            // The user asked for this file while it was closing; keep the
            // tab and reopen the underlying document afterwards.
            reopenedDuringClose.insert(path)
        }
        if let existing = openTabs.first(where: { $0.id == asset.id }) {
            selectTab(existing.id)
            return
        }
        let requestedOwner = featureEditors.catalogue.resolve(asset.name)?.featureID
        if let owner = documentWorkspaces.owner(of: path), owner.featureID != requestedOwner {
            if let ownerTab = openTabs.first(where: { $0.url.map { FilePathPolicy.canonical($0).path == path } == true }) {
                selectTab(ownerTab.id)
            } else {
                showWorkspace(featureID: owner.featureID, preferExistingFile: false)
                owner.select(path: path)
            }
            return
        }
        let tab = EditorTab(asset: asset, ownerFeatureID: requestedOwner)
        openTabs.append(tab)
        selectTab(tab.id)
    }

    /// Selects the document that owns `path` in the given workspace.
    private func selectOwnedDocument(kind: AssetKind, path: String) {
        documentWorkspaces.adapter(for: kind)?.select(path: path)
    }

    /// The workspace that currently owns a document at the canonical path.
    private func owningKind(forCanonicalPath path: String) -> AssetKind? {
        documentWorkspaces.owner(of: path)?.kind
    }

    package func openExternalAsset(_ asset: ExternalEditorAsset) {
        noteSelectionChange()
        if let existing = openTabs.first(where: { $0.assetID == asset.id }) {
            noteReopenIfClosing(
                existing.url ?? externalDocumentURL(for: existing)
            )
            selectTab(existing.id)
            return
        }
        let tab = EditorTab(asset: asset)
        noteReopenIfClosing(tab.url ?? externalDocumentURL(for: tab))
        openTabs.append(tab)
        selectTab(tab.id)
    }

    /// Records that a file was asked for while its document close is
    /// awaiting, so the close does not remove the tab it just revived.
    private func noteReopenIfClosing(_ url: URL?) {
        guard let url else { return }
        let path = FilePathPolicy.canonical(url).path
        if closingPaths[path] != nil {
            reopenedDuringClose.insert(path)
        }
    }

    package func openAsset(id: String?) {
        guard let id else { return }
        if isDemo {
            guard let asset = externalContent?.asset(id: id) else { return }
            openExternalAsset(asset)
        } else if let asset = assets.first(where: { $0.id == id }) {
            openAsset(asset)
        }
    }

    /// Brings a workspace to the front even when no file of that kind is open.
    /// The synthetic tab hosts the empty state; the first opened document
    /// replaces it in the same tab.
    package func showWorkspace(_ kind: AssetKind) {
        if let adapter = documentWorkspaces.adapter(for: kind),
           featureSessions.descriptor(for: adapter.featureID)?.workspaces.contains(where: { $0.legacyKind == kind }) == true {
            showWorkspace(featureID: adapter.featureID, preferExistingFile: true)
            return
        }
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
    package func selectWorkspaceTab(_ kind: AssetKind) {
        if let adapter = documentWorkspaces.adapter(for: kind),
           featureSessions.descriptor(for: adapter.featureID)?.workspaces.contains(where: { $0.legacyKind == kind }) == true {
            showWorkspace(featureID: adapter.featureID, preferExistingFile: false)
            return
        }
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

    package func selectTab(_ id: String) {
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
    package func toggleLastUsedTab() {
        guard let lastUsedTabID,
              lastUsedTabID != selectedTabID,
              openTabs.contains(where: { $0.id == lastUsedTabID }) else {
            return
        }
        selectTab(lastUsedTabID)
    }

    package func selectNextTab() {
        selectTab(offset: 1)
    }

    package func selectPreviousTab() {
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
            documentAdapter(for: tab)?.open(url)
            return
        }
        guard let id = tab.externalAsset?.id else { return }
        do {
            if let prepared = try externalContent?.documentURL(for: id) { documentAdapter(for: tab)?.open(prepared) }
        } catch { externalContent?.documentPreparationFailed(for: id, kind: tab.kind, error: error) }
    }

    /// One dispatch for every workspace that hosts documents. Demo tabs and
    /// project tabs resolve their URL first, then take this path.
    private func openDocument(kind: AssetKind, url: URL) {
        documentWorkspaces.adapter(for: kind)?.open(url)
    }

    package func closeTab(_ id: String) async {
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
        adapter candidate: DocumentWorkspaceAdapter?
    ) async -> DocumentCloseOutcome {
        // A document with its own file tab belongs to that tab. Closing the
        // synthetic workspace tab must not close a document the user can
        // still see and reach from a file tab. The tabs are checked per
        // document, not captured once: a file tab can open while an earlier
        // close in this loop is awaiting a decision.
        func hasFileTab(_ url: URL) -> Bool {
            let path = FilePathPolicy.canonical(url).path
            return openTabs.contains { tab in
                guard tab.workspaceKind == nil,
                      let tabURL = tab.url ?? externalDocumentURL(for: tab)
                else {
                    return false
                }
                return FilePathPolicy.canonical(tabURL).path == path
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
            let path = url.map { FilePathPolicy.canonical($0).path }
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
                        candidate?.open(url)
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

        guard let adapter = candidate else { return .closed }
        let kind = adapter.kind
        adapter.beforeClose()
        switch adapter.workspaceClosePolicy {
        case .singleDocument:
            guard let document = adapter.documents.first else { return .closed }
            return await document.close() ? .closed : .failed
        case .trackedDocumentsPreservingFileTabs:
            for document in adapter.documents {
                if let url = document.url, hasFileTab(url) { continue }
                let outcome = await closeTracked(
                    url: document.url,
                    kind: kind,
                    pendingDocumentID: { adapter.pendingDecision?.document.id },
                    close: document.close
                )
                if let outcome {
                    if case let .deferred(id) = outcome {
                        pendingWorkspaceClose = adapter.featureID
                        pendingWorkspaceCloseDocumentID = id
                    }
                    return outcome
                }
            }
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
        if tab.workspaceKind != nil {
            return await closeWorkspaceDocuments(adapter: documentAdapter(for: tab))
        }
        if featureSessions.closeAssetTab(FeatureAssetTabClose(id: tab.assetID, kind: tab.kind,
            url: tab.url ?? externalContent?.resourceAsset(id: tab.assetID)?.url)) { return .closed }
        let url = tab.url ?? externalDocumentURL(for: tab)
        guard let url else { return .closed }
        let stillReferenced = openTabs.contains { other in
            other.id != tab.id
                && (other.url ?? externalDocumentURL(for: other)) == url
        }
        guard !stillReferenced else { return .closed }

        let path = FilePathPolicy.canonical(url).path
        beginClosing(path)
        let adapter = documentAdapter(for: tab)
        adapter?.beforeClose()
        let closed = await adapter?.document(at: path)?.close() ?? true
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
                adapter?.open(url)
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
            if adapter?.fileCloseDefersDecision == true,
               let pending = adapter?.pendingDecision?.document.id {
                return .deferred(pending)
            }
            return .failed
        }

        // A tab for the same file may have been opened while the close was
        // awaiting. Reopen the document so that tab does not point at a
        // closed document.
        let hasOtherTab = openTabs.contains { other in
            other.id != tab.id
                && (other.url ?? externalDocumentURL(for: other)) == url
        }
        if hasOtherTab {
            adapter?.open(url)
        }
        return .closed
    }

    /// The Markdown workspace can move its selected document by following a
    /// link. Keep the owning tab in step so its title, breadcrumb, and close
    /// target refer to the document on screen.
    private func syncTabForDocument(at url: URL, adapter: DocumentWorkspaceAdapter) {
        let kind = adapter.kind
        guard !isDemo, !isSyncingTab else { return }
        isSyncingTab = true
        defer { isSyncingTab = false }
        let path = FilePathPolicy.canonical(url).path
        if let tab = openTabs.first(where: { tab in
            guard tab.kind == kind, let tabURL = tab.url else { return false }
            return FilePathPolicy.canonical(tabURL).path == path
        }) {
            if selectedTabID != tab.id {
                selectTab(tab.id)
            }
            return
        }
        if let asset = assets.first(where: {
            FilePathPolicy.canonical($0.url).path == path
        }) {
            if asset.kind == kind {
                openAsset(asset)
            } else if adapter.tabPolicy.forceKindForUnindexedFiles {
                // The document is open in the code workspace, so its tab
                // must be a code tab even when the extension scans as
                // another kind (a code file saved as `.md`, for example).
                openDocumentTab(for: self.asset(asset, typedAs: kind), adapter: adapter)
            } else {
                showWorkspace(featureID: adapter.featureID, preferExistingFile: false)
            }
        } else if adapter.tabPolicy.forceKindForUnindexedFiles {
            // A code file opened from search or a link may not be in the
            // scan index yet; the tab still names the real file.
            openMovedDocument(at: url, adapter: adapter)
        } else {
            // The linked file is outside the scanned index; the workspace
            // tab follows the selected document.
            showWorkspace(featureID: adapter.featureID, preferExistingFile: false)
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
        let path = FilePathPolicy.canonical(url).path
        // The tab-close flow owns the tab while its close is awaiting.
        guard closingPaths[path] == nil else { return }
        // Only the closing workspace's tab goes: a duplicate document of
        // another kind must keep its tab even though it names the same path.
        let ids = openTabs.compactMap { tab -> String? in
            guard tab.kind == kind else { return nil }
            // Demo document tabs carry no URL; resolve their sample file.
            guard let tabURL = tab.url ?? externalDocumentURL(for: tab),
                  FilePathPolicy.canonical(tabURL).path == path else {
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

    // MARK: - Media links

    /// One `sonovo:` link's ask to place the transport after its media tab
    /// opens. It is one-shot: the media view consumes it when it is ready.
    package typealias PendingMediaSeek = MediaSeekRequest

    package private(set) var pendingMediaSeek: PendingMediaSeek?

    /// The project asset a media link names, or the selected media asset when
    /// the link carries no path. Only audio and video assets qualify.
    package func mediaAsset(
        for reference: MediaReference,
        documentURL: URL?
    ) -> ProjectAsset? {
        if let path = reference.path {
            guard let documentURL,
                  let root = root ?? mediaLinkSource?.root,
                  let url = resolveMediaPath(
                      path,
                      relativeTo: documentURL,
                      root: root
                  ) else {
                return nil
            }
            let canonical = FilePathPolicy.canonical(url)
            return assets.first { asset in
                isMedia(asset.kind)
                    && FilePathPolicy.canonical(asset.url) == canonical
            }
        }
        guard let selected = selectedAsset, isMedia(selected.kind) else {
            return nil
        }
        return selected
    }

    private var mediaLinkSource: DocumentMediaLinkContext? {
        documentWorkspaces.adapters.compactMap { $0.mediaLinkContext() }.first
    }

    private func resolveMediaPath(_ path: String, relativeTo document: URL, root: URL) -> URL? {
        mediaLinkSource?.resolveLocalPath(path, document, root)
    }

    /// Opens the media a link names and leaves a seek request for its view.
    /// `documentURL` is the document that displayed the link; without it a
    /// relative path would resolve against whichever pane has focus.
    package func openMediaReference(
        _ reference: MediaReference,
        documentURL: URL? = nil
    ) {
        guard let asset = mediaAsset(
            for: reference,
            documentURL: documentURL
                ?? mediaLinkSource?.documentURL
        ) else {
            return
        }
        openAsset(asset)
        pendingMediaSeek = PendingMediaSeek(
            path: FilePathPolicy.canonical(asset.url).path,
            seconds: reference.seconds
        )
    }

    /// Clears and returns the pending seek when it names this asset.
    package func takeMediaSeek(for asset: ProjectAsset) -> PendingMediaSeek? {
        guard let pending = pendingMediaSeek,
              pending.path
                == FilePathPolicy.canonical(asset.url).path else {
            return nil
        }
        pendingMediaSeek = nil
        return pending
    }

    private func isMedia(_ kind: AssetKind) -> Bool {
        kind == .audio || kind == .video
    }

    private func externalDocumentURL(for tab: EditorTab) -> URL? {
        guard let id = tab.externalAsset?.id else { return nil }
        return try? externalContent?.documentURL(for: id)
    }

    package func closeAllTabs() async {
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
        guard let featureID = pendingWorkspaceClose, let adapter = documentWorkspaces.adapter(for: featureID) else { return }
        guard closedDocumentID == pendingWorkspaceCloseDocumentID else {
            return
        }
        pendingWorkspaceClose = nil
        pendingWorkspaceCloseDocumentID = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard case .closed = await self.closeWorkspaceDocuments(
                adapter: adapter
            ) else {
                return
            }
            if let tab = self.openTabs.first(where: {
                $0.workspaceFeatureID == featureID || ($0.ownerFeatureID == nil && $0.workspaceKind == adapter.kind)
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
    package func cancelBulkClose() {
        bulkClosePending = false
        bulkClosePendingDocumentID = nil
        pendingWorkspaceClose = nil
        pendingWorkspaceCloseDocumentID = nil
    }

    /// Follow the owning document across Save As, using declared presentation
    /// policy rather than importing or switching on a concrete workspace.
    private func moveDocumentTabs(from oldURL: URL, to newURL: URL, adapter: DocumentWorkspaceAdapter) {
        let kind = adapter.kind
        let oldPath = FilePathPolicy.canonical(oldURL).path
        let ids = openTabs.compactMap { tab -> String? in
            guard tab.kind == kind,
                  let url = tab.url ?? (adapter.tabPolicy.movedExternalDocumentUsesWorkspace ? externalDocumentURL(for: tab) : nil),
                  FilePathPolicy.canonical(url).path == oldPath else { return nil }
            return tab.id
        }
        guard !ids.isEmpty else {
            if adapter.selectedDocument?.url.map({ FilePathPolicy.canonical($0) }) == FilePathPolicy.canonical(newURL) {
                if adapter.tabPolicy.movedUntabbedDocumentUsesActivation { syncTabForDocument(at: newURL, adapter: adapter) }
                else { openMovedDocument(at: newURL, adapter: adapter) }
            }
            return
        }
        let removedSelected = ids.contains(selectedTabID)
        let previousSelection = selectedTabID
        openTabs.removeAll { ids.contains($0.id) }
        noteTabChange()
        if removedSelected { selectedTabID = ""; selectedAssetID = nil }
        if isDemo && adapter.tabPolicy.movedExternalDocumentUsesWorkspace {
            showWorkspace(featureID: adapter.featureID, preferExistingFile: false)
            if !removedSelected, openTabs.contains(where: { $0.id == previousSelection }) { selectTab(previousSelection) }
        } else { openMovedDocument(at: newURL, adapter: adapter, select: removedSelected) }
        onSelectionChanged?()
    }

    private func openMovedDocument(at url: URL, adapter: DocumentWorkspaceAdapter, select: Bool = true) {
        let canonical = FilePathPolicy.canonical(url)
        let indexed = assets.first { FilePathPolicy.canonical($0.url) == canonical }
        let asset = indexed ?? syntheticAsset(for: canonical, kind: adapter.kind)
        openDocumentTab(for: adapter.tabPolicy.forceKindForUnindexedFiles ? self.asset(asset, typedAs: adapter.kind) : asset,
            adapter: adapter, select: select)
    }

    private func openDocumentTab(for asset: ProjectAsset, adapter: DocumentWorkspaceAdapter, select: Bool = true) {
        let path = FilePathPolicy.canonical(asset.url).path
        let documentID = adapter.document(at: path)?.id
        if isDocumentPathOpen(path, excluding: documentID) {
            if select, let existing = openTabs.first(where: { $0.id == asset.id }) { selectTab(existing.id) }
            return
        }
        if let existing = openTabs.first(where: { $0.id == asset.id }) {
            if existing.kind == adapter.kind {
                if select { selectTab(existing.id) }
                return
            }
            openTabs.removeAll { $0.id == existing.id }
        }
        let tab = EditorTab(asset: asset, ownerFeatureID: adapter.featureID)
        openTabs.append(tab)
        if select { selectTab(tab.id) }
    }

    /// An asset-shaped value for a file the last scan has not indexed yet.
    package func syntheticAsset(
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
            let path = FilePathPolicy.canonical($0).path
            return path.hasSuffix("/") ? path : path + "/"
        }
        let path = canonical.path
        let relative = rootPath.flatMap {
            path.hasPrefix($0) ? String(path.dropFirst($0.count)) : nil
        } ?? canonical.lastPathComponent
        let size = Int64(values?.fileSize ?? 0)
        let modified = values?.contentModificationDate
        return ProjectAsset(
            id: path,
            url: canonical,
            name: canonical.lastPathComponent,
            relativePath: relative,
            kind: kind,
            size: size,
            modified: modified,
            revision: AssetRevision.read(of: canonical) ?? AssetRevision(fileIdentifier: nil, size: size, modified: modified)
        )
    }

    private func asset(_ original: ProjectAsset, typedAs kind: AssetKind) -> ProjectAsset {
        ProjectAsset(id: original.id, url: original.url, name: original.name, relativePath: original.relativePath,
            kind: kind, size: original.size, modified: original.modified, revision: original.revision)
    }

    /// Whether any workspace of this project owns an open document at the
    /// path. Save As uses it to refuse replacing another tab's file; a nil
    /// exclusion asks about every workspace.
    package func isDocumentPathOpen(_ path: String, excluding id: UUID?) -> Bool {
        documentWorkspaces.owner(of: path, excluding: id) != nil
    }

    package func displayName(for tab: EditorTab) -> String {
        if let url = tab.url { return url.lastPathComponent }
        guard tab.id == selectedTabID,
              let adapter = documentAdapter(for: tab),
              adapter.usesSelectedDocumentNameForTab else { return tab.title }
        guard let document = adapter.selectedDocument,
              document.url != nil || adapter.tabPolicy.usesUntitledDocumentNameForTab else { return tab.title }
        return document.name
    }

    package func activate(loadIfOffline: Bool = true) {
        isActive = true
        hasActivity = false
        featureSessions.activate()
        externalContent?.refresh()
        if loadIfOffline, case .offline = availability {
            Task { @MainActor [weak self] in
                await self?.load()
            }
        }
    }

    /// Stops a removed project from applying an in-flight scan or persisting
    /// a selection after it no longer belongs to the workspace.
    package func invalidate() {
        isInvalidated = true
        lifecycleGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
        watcher?.stop()
        watcher = nil
        featureSessions.invalidate()
        onSelectionChanged = nil
    }

    package func deactivate() {
        isActive = false
        featureSessions.deactivate()
    }

    package var isOffline: Bool {
        if case .offline = availability { return true }
        return false
    }

    package var offlineReason: String? {
        if case .offline(let reason) = availability { return reason }
        return nil
    }

    package var hasDirtyDocuments: Bool { documentWorkspaces.hasDirtyDocuments }

    package func prepareForTermination() {
        refreshTask?.cancel()
        watcher?.stop()
        watcher = nil
        featureSessions.shutdown()
    }
}
