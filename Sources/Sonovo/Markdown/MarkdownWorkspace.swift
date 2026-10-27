import AppKit
import Foundation
import Observation
import SonovoCore
import UniformTypeIdentifiers

extension Notification.Name {
    static let sonovoMarkdownFileChanged = Notification.Name(
        "sonovo.markdown.fileChanged"
    )
}

/// Which of the two visible Markdown panes a document occupies.
enum MarkdownPane: Sendable, Equatable {
    case primary
    case secondary
}

/// Owns the open Markdown documents, their tabs, autosave, and watchers.
@MainActor
@Observable
final class MarkdownWorkspace {
    let parseService: MarkdownParseService
    let parseCoordinator: MarkdownParseCoordinator
    let editorCache: MarkdownEditorCache
    let linkProbe = MarkdownLinkProbeService()
    private(set) var lintResults: [UUID: MarkdownLintResult] = [:]

    /// Lint diagnostics only while they describe the current revision. A
    /// result from before an edit would mark ranges that have moved.
    func lintDiagnostics(for document: MarkdownDocument) -> [MarkdownDiagnostic] {
        guard let result = lintResults[document.id],
              result.revision == document.revision else {
            return []
        }
        return result.diagnostics
    }
    var isPaletteVisible = false
    var isOutlineVisible = false
    var isQuickOpenVisible = false
    var isHistoryVisible = false
    /// Rendered find is per document: two panes each keep their own query,
    /// matches, and current index, so neither replaces the other's results.
    private var renderedFinds: [UUID: RenderedFindController] = [:]
    /// Review comments live in a sidecar beside each document; this
    /// controller owns their state and every write.
    let reviewComments = ReviewCommentsController()
    var isReviewVisible = false

    /// The proposal currently previewed in the diff sheet. Nil when no sheet
    /// is open. The proposal file is the only source of truth; nothing about
    /// it is cached beyond this preview.
    struct ProposalPreview: Identifiable {
        let fileURL: URL
        let proposal: MarkdownProposal
        /// The exact source the preview validated against, so a stale sheet
        /// can refuse instead of applying to a changed document.
        let expectedSource: String

        var id: String { fileURL.path }
    }

    var proposalPreview: ProposalPreview?
    var isProposalVisible = false
    var proposalError: String?
    /// Bumped whenever snapshots or transitions change, so panels refresh.
    private(set) var historyRevision = 0
    /// The owning project routes a local asset link to its viewer. Returns
    /// false when the project does not own the file, so the link falls back
    /// to the default app.
    var onOpenAsset: ((URL) -> Bool)?

    private let store: MarkdownFileStore

    private(set) var documents: [MarkdownDocument] = []
    /// The primary (left) pane's document.
    var selectedDocumentID: UUID?
    /// The second pane's document; nil when only one pane is open.
    var secondaryDocumentID: UUID?
    /// The document whose pane owns commands and the project's active tab.
    var focusedDocumentID: UUID?
    private(set) var workspaceRoot: URL?
    /// Incremented when the effective root changes, so a captured action
    /// target can refuse after a project switch.
    private(set) var rootGeneration: UInt64 = 0
    private(set) var workspaceFiles: [URL] = []

    var lastError: String?
    var pendingClose: MarkdownDocument?
    /// Called after a document is removed, including a close resolved later
    /// through the save/discard prompt. The owning project uses it to remove
    /// the matching tab.
    /// Reports the document that closed. The object carries its stable ID,
    /// which survives a Save As and identifies an untitled document that
    /// has no URL yet.
    var onDocumentClosed: ((MarkdownDocument) -> Void)?
    /// Called when the workspace's selected document changes, including
    /// navigation to a linked file. The owning project keeps its tabs in
    /// step so the tab title never names a different document than the one
    /// on screen.
    var onDocumentActivated: ((URL?) -> Void)?
    /// A Save As changed a document's file identity. Tabs naming the old
    /// path must follow it rather than keep pointing at a stale file.
    var onDocumentMoved: ((URL, URL) -> Void)?
    /// Whether another workspace of the project holds a Save As reservation.
    var isDestinationReserved: ((String) -> Bool)?
    /// Whether another workspace already owns this path.
    var isPathOwnedElsewhere: ((String) -> Bool)?
    /// Reserves a destination across every workspace of the project.
    var reserveSharedDestination: ((String, UUID) -> Bool)?
    var releaseSharedDestination: ((String, UUID) -> Void)?

    func dismissError() {
        lastError = nil
    }
    var scrollTargets: [UUID: String] = [:]

    /// Documents showing Source and Rendered side by side. Session-only by
    /// design: the saved `mode` is the surface a document reopens in.
    private(set) var splitDocuments: Set<UUID> = []
    /// Source offsets the rendered pane wants the source pane to reveal.
    var sourceScrollTargets: [UUID: Int] = [:]
    /// Whether split scrolling follows the other pane.
    var isSplitScrollSynced = true
    /// The clock behind split-scroll echo suppression. Tests replace it.
    @ObservationIgnored
    var splitSyncNow: () -> Date = { Date() }

    private enum SplitSyncDirection {
        case source
        case rendered
    }

    private struct SplitSyncIgnore {
        let direction: SplitSyncDirection
        let until: Date
    }

    @ObservationIgnored
    private var splitReturnModes: [UUID: MarkdownDocumentMode] = [:]
    @ObservationIgnored
    private var splitSyncIgnore: [UUID: SplitSyncIgnore] = [:]

    /// Per-document reading state for the current session. Source keeps the
    /// selection and the scroll origin; Rendered keeps its last scroll ID.
    struct ReadingPosition {
        var selection: Range<Int>?
        var source: SourceReadingAnchor?
        var rendered: RenderedReadingAnchor?
    }

    @ObservationIgnored
    private var readingPositions: [UUID: ReadingPosition] = [:]
    /// A rendered anchor waiting for the viewer to mount after a surface or
    /// tab switch. The viewer clears its entry once it has scrolled there.
    var pendingRenderedAnchors: [UUID: RenderedReadingAnchor] = [:]
    private var watchers: [UUID: MarkdownFileWatcher] = [:]
    @ObservationIgnored
    private var autosave: AutosaveDriver<MarkdownDocument>!
    private var reservedDestinations: Set<String> = []
    private var workspaceWatcher: WorkspaceDirectoryWatcher?
    private var workspaceScanTask: Task<Void, Never>?
    @ObservationIgnored
    private var watcherRetryTask: Task<Void, Never>?
    /// An explicit folder open must survive a watcher rescan that starts
    /// while the open is enumerating: the newer scan inherits the intent.
    @ObservationIgnored
    private let snapshotBaseDirectory: URL
    @ObservationIgnored
    private var snapshotStore: MarkdownSnapshotStore?
    @ObservationIgnored
    private var pendingOpenFirst = false
    private var workspaceScanGeneration = 0
    private var fileChangeObserver: NSObjectProtocol?

    isolated deinit {
        if let fileChangeObserver {
            NotificationCenter.default.removeObserver(fileChangeObserver)
        }
        workspaceWatcher?.stop()
    }

    /// Releases every retained editor, watcher, and cached parse for a
    /// project that is closing. The shared editor cache is process-wide, so
    /// a closed project's controllers would otherwise live until quit.
    func shutdown() {
        for document in documents {
            document.markClosed()
            watchers[document.id]?.stop()
            editorCache.remove(for: document.id)
            autosave.forget(document.id)
            let id = document.id
            parseCoordinator.release(documentID: id)
        }
        documents.removeAll()
        watchers.removeAll()
        reviewComments.discardAll()
        scrollTargets.removeAll()
        splitDocuments.removeAll()
        sourceScrollTargets.removeAll()
        splitReturnModes.removeAll()
        splitSyncIgnore.removeAll()
        secondaryDocumentID = nil
        focusedDocumentID = nil
        readingPositions.removeAll()
        pendingRenderedAnchors.removeAll()
        pendingClose = nil
        workspaceWatcher?.stop()
        workspaceWatcher = nil
        workspaceScanTask?.cancel()
        workspaceScanTask = nil
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
    }

    /// The document in the primary (left) pane.
    var primaryDocument: MarkdownDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    /// The document in the second pane, when one is open.
    var secondaryDocument: MarkdownDocument? {
        guard let secondaryDocumentID else { return nil }
        return documents.first { $0.id == secondaryDocumentID }
    }

    /// The pane that owns commands, formatting, find, save, and the project's
    /// active tab. It defaults to the primary pane and follows the last
    /// focused pane in a two-document split.
    var focusedDocument: MarkdownDocument? {
        if let focusedDocumentID,
           let focused = documents.first(where: { $0.id == focusedDocumentID }) {
            return focused
        }
        return primaryDocument
    }

    /// Command-facing selection. In a two-document split this is the focused
    /// pane's document, so every existing command path follows focus without
    /// a second routing table.
    var selectedDocument: MarkdownDocument? { focusedDocument }

    var focusedPane: MarkdownPane {
        if let secondaryDocumentID, focusedDocumentID == secondaryDocumentID {
            return .secondary
        }
        return .primary
    }

    /// The pane currently showing `document`, or nil when it is open but not
    /// on screen.
    func pane(of document: MarkdownDocument) -> MarkdownPane? {
        if document.id == selectedDocumentID { return .primary }
        if document.id == secondaryDocumentID { return .secondary }
        return nil
    }

    var hasDirtyDocuments: Bool {
        documents.contains(where: \.isDirty)
    }

    init(
        store: MarkdownFileStore = MarkdownFileStore(),
        parseService: MarkdownParseService = MarkdownParseService(),
        editorCache: MarkdownEditorCache = .shared,
        snapshotBaseDirectory: URL? = nil,
        readsDemoEnvironment: Bool = true
    ) {
        self.store = store
        self.snapshotBaseDirectory = snapshotBaseDirectory
            ?? Self.defaultSnapshotBaseDirectory
        self.parseService = parseService
        self.parseCoordinator = MarkdownParseCoordinator(service: parseService)
        self.editorCache = editorCache

        fileChangeObserver = NotificationCenter.default.addObserver(
            forName: .sonovoMarkdownFileChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let id = notification.userInfo?["id"] as? UUID else { return }
            Task { @MainActor in
                self?.handleFileChange(id)
            }
        }

        autosave = AutosaveDriver(
            documents: { [weak self] in self?.documents ?? [] },
            reportsError: { [weak self] message in
                self?.lastError = message
            },
            onSaved: { [weak self] id in
                guard let self,
                      let document = self.documents.first(where: {
                          $0.id == id
                      }) else {
                    return
                }
                Task { @MainActor in
                    await self.recordSaveHistory(
                        for: document,
                        kind: .autosave
                    )
                }
            }
        )
        startAutosaveLoop()

        if readsDemoEnvironment,
           let path = ProcessInfo.processInfo.environment["SONOVO_DEMO_MARKDOWN"] {
            open(url: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Documents

    @discardableResult
    func newDocument() -> MarkdownDocument {
        if let existing = documents.first(where: {
            $0.fileURL == nil && !$0.isDirty
        }) {
            setSelectedDocument(existing)
            return existing
        }

        let document = MarkdownDocument(untitledWith: store)
        document.mode = .source
        documents.append(document)
        ensureRenderedFind(for: document)
        setSelectedDocument(document)
        return document
    }

    @discardableResult
    func open(url: URL) -> MarkdownDocument? {
        // File identity is the symlink-resolved path, matching
        // `reserveDestination`. Two documents for one inode would fight over
        // autosave, and writing through a symlink path would replace the
        // link itself.
        let target = MarkdownSecurity.canonical(url)
        let key = target.path
        if let existing = documents.first(where: { candidate in
            guard let fileURL = candidate.fileURL else { return false }
            return MarkdownSecurity.canonical(fileURL).path == key
        }) {
            setSelectedDocument(existing)
            return existing
        }
        guard !reservedDestinations.contains(key),
              isDestinationReserved?(key) != true else {
            // A Save As is about to write this path; opening it now would
            // create a second model that the completed save cannot see.
            lastError = "That file is being saved in another tab."
            return nil
        }
        guard isPathOwnedElsewhere?(key) != true else {
            lastError = "That file is already open in another tab."
            return nil
        }

        do {
            let document = try MarkdownDocument(loading: target, store: store)
            document.mode = Self.defaultOpenMode
            documents.append(document)
            ensureRenderedFind(for: document)
            setSelectedDocument(document)
            startWatcher(for: document)
            if workspaceRoot == nil {
                workspaceFiles = Array(Set(workspaceFiles + [target]))
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
            return document
        } catch {
            lastError = "Cannot open \(target.lastPathComponent): \(error)"
            return nil
        }
    }

    func select(_ document: MarkdownDocument) {
        if let current = selectedDocument, current.id != document.id {
            captureReadingPosition(for: current)
        }
        if document.mode == .rendered,
           let anchor = readingPositions[document.id]?.rendered {
            pendingRenderedAnchors[document.id] = anchor
        }
        setSelectedDocument(document)
    }

    private func setSelectedDocument(_ document: MarkdownDocument) {
        // Moving focus to another document — including by selecting one that
        // is already visible in the other pane — is a collapse surface for
        // the pane being left, exactly as `focus` and `show` treat it.
        if focusedDocumentID != document.id {
            collapseForPolicy(.splitFocus, focusedDocument)
        }
        if secondaryDocumentID != nil {
            // The focused pane receives the new document. A document already
            // visible in the other pane is focused, never duplicated.
            switch focusedPane {
            case .primary:
                if document.id == secondaryDocumentID {
                    focusedDocumentID = document.id
                } else {
                    selectedDocumentID = document.id
                    focusedDocumentID = document.id
                }
            case .secondary:
                if document.id == selectedDocumentID {
                    focusedDocumentID = document.id
                } else {
                    secondaryDocumentID = document.id
                    focusedDocumentID = document.id
                }
            }
        } else {
            selectedDocumentID = document.id
            focusedDocumentID = document.id
        }
        // An untitled document still changes the identity on screen; the
        // owning tab must stop naming the previously selected file.
        onDocumentActivated?(document.fileURL)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reviewComments.load(document)
            self.editorCache.cachedEntry(for: document.id)?
                .controller.refreshReviewMarkers()
        }
    }

    /// Returns true only when the document was actually closed. A document
    /// waiting for a save decision stays open, so its project tab must stay
    /// open too.
    @discardableResult
    func close(_ document: MarkdownDocument) async -> Bool {
        // Close is a collapse surface: the caret set names offsets in a
        // document that is about to leave the workspace.
        collapseForPolicy(.close, document)
        let outcome = await document.flushForClose()
        switch outcome {
        case .closed:
            remove(document)
            return true
        case .needsDecision:
            // One decision at a time. A second unresolved close must not
            // replace the first document's alert.
            if pendingClose == nil || pendingClose === document {
                pendingClose = document
            }
            return false
        }
    }

    /// Saves and closes a document that was waiting for a close decision.
    func saveAndClose(_ document: MarkdownDocument) async {
        if document.fileURL == nil {
            guard let url = presentSavePanel(for: document) else {
                return
            }
            guard await saveAs(document, to: url) else {
                return
            }
        } else {
            do {
                try await document.save()
            } catch {
                lastError = "Save failed: \(error)"
                return
            }
        }
        // Edits made while the write was pending are still dirty. Removing
        // the document now would silently lose them.
        guard !document.isDirty else {
            pendingClose = document
            lastError = "The document changed while saving; save again."
            return
        }
        pendingClose = nil
        remove(document)
    }

    func discardAndClose(_ document: MarkdownDocument) {
        pendingClose = nil
        remove(document)
    }

    func cancelPendingClose() {
        pendingClose = nil
    }

    /// The close alert dismissed itself. Its button action owns the actual
    /// decision, so dropping the presentation state must not cancel a quit
    /// whose Save is still in flight.
    func dismissCloseAlert() {
        pendingClose = nil
    }

    private func remove(_ document: MarkdownDocument) {
        let id = document.id
        let secondarySurvivor = secondaryDocumentID.flatMap { secondaryID in
            documents.first { $0.id == secondaryID }
        }
        document.markClosed()
        // A pending decision whose document closed through another path is
        // no longer pending. Keeping it would make the next close report a
        // document that already fired its callback, so no later decision
        // could ever resume the operation waiting on it.
        if pendingClose === document {
            pendingClose = nil
        }
        watchers[id]?.stop()
        watchers.removeValue(forKey: id)
        editorCache.remove(for: id)
        reviewComments.discard(documentID: id)
        renderedFinds.removeValue(forKey: id)
        documents.removeAll { $0.id == id }
        scrollTargets.removeValue(forKey: id)
        splitDocuments.remove(id)
        sourceScrollTargets.removeValue(forKey: id)
        splitReturnModes.removeValue(forKey: id)
        splitSyncIgnore.removeValue(forKey: id)
        readingPositions.removeValue(forKey: id)
        pendingRenderedAnchors.removeValue(forKey: id)
        autosave.forget(id)
        // The parse service otherwise retains this document's AST, heading
        // index, and source for the life of the process.
        parseCoordinator.release(documentID: id)

        if secondaryDocumentID == id {
            secondaryDocumentID = nil
        }
        if selectedDocumentID == id {
            // The surviving secondary pane becomes the primary, so closing
            // the left document never leaves an empty editor.
            if let survivor = secondarySurvivor, survivor.id != id {
                selectedDocumentID = survivor.id
                secondaryDocumentID = nil
            } else {
                selectedDocumentID = documents.first?.id
            }
        }
        if focusedDocumentID == id || focusedDocumentID == nil {
            focusedDocumentID = selectedDocumentID
        }
        if let focused = focusedDocument {
            onDocumentActivated?(focused.fileURL)
        }
        // An untitled document has no file to remove tabs for, but its
        // removal still completes a deferred close (and must resume a bulk
        // close waiting on it).
        onDocumentClosed?(document)
    }

    // MARK: - Saving

    func save(_ document: MarkdownDocument) async {
        // Save on a new document must go through the panel; `save()` throws
        // `untitled` and the command would appear broken.
        guard document.fileURL != nil else {
            await saveAs(document)
            return
        }
        do {
            try await document.save()
            autosave.didSave(document.id)
            lastError = nil
            await recordSaveHistory(for: document, kind: .explicit)
        } catch {
            lastError = "Save failed: \(error)"
        }
    }

    func saveSelected() async {
        guard let document = selectedDocument else { return }
        await save(document)
    }

    func saveAs(_ document: MarkdownDocument) async {
        guard let url = presentSavePanel(for: document) else { return }
        await saveAs(document, to: url)
    }

    /// Writes `document` to `url` and performs the shared Save As
    /// bookkeeping: identity registration, watcher replacement, and cleanup
    /// ownership when the write fails.
    @discardableResult
    func saveAs(
        _ document: MarkdownDocument,
        to url: URL
    ) async -> Bool {
        // Resolve a chosen symlink to its target before writing: replacing
        // the link path would destroy the link rather than update the file.
        let target = MarkdownSecurity.canonical(url)
        guard let reservation = reserveDestination(
            target,
            excluding: document
        ) else {
            return false
        }
        defer { releaseDestination(reservation, owner: document.id) }
        let previousURL = document.fileURL
        do {
            try await document.saveAs(to: target)
            // The write can outrun a close. A document that left the
            // workspace must not get its watcher reinstalled or report a
            // move after its removal.
            guard documents.contains(where: { $0 === document }),
                  !document.isClosed else {
                return false
            }
            // Save As changes the document's identity; carets anchored to
            // the old identity do not survive it.
            collapseForPolicy(.saveAs, document)
            startWatcher(for: document)
            registerWorkspaceFile(target)
            lastError = nil
            // Comments belong to the file identity: a Save As adopts the new
            // path's sidecar, not the old file's threads.
            reviewComments.discard(documentID: document.id)
            await reviewComments.load(document)
            editorCache.cachedEntry(for: document.id)?
                .controller.refreshReviewMarkers()
            await recordSaveHistory(for: document, kind: .explicit)
            if let previousURL {
                onDocumentMoved?(previousURL, target)
            } else if document === selectedDocument {
                onDocumentActivated?(target)
            }
            return true
        } catch {
            lastError = "Save As failed: \(error)"
            return false
        }
    }

    private func registerWorkspaceFile(_ url: URL) {
        let target = MarkdownSecurity.canonical(url)
        if !workspaceFiles.contains(where: {
            MarkdownSecurity.canonical($0) == target
        }) {
            workspaceFiles.append(target)
            workspaceFiles.sort { $0.path < $1.path }
        }
    }

    /// Two document models for one file would fight over autosave. Compare
    /// canonical paths (symlink-resolved) and reserve the destination for the
    /// duration of the asynchronous save.
    private func reserveDestination(
        _ url: URL,
        excluding document: MarkdownDocument
    ) -> String? {
        let key = MarkdownSecurity.canonical(
            url.standardizedFileURL
        ).path
        guard !reservedDestinations.contains(key),
              isDestinationReserved?(key) != true else {
            lastError = "That file is already being saved."
            return nil
        }
        if let existing = documents.first(where: { candidate in
            guard candidate.id != document.id,
                  let fileURL = candidate.fileURL else {
                return false
            }
            return MarkdownSecurity.canonical(
                fileURL.standardizedFileURL
            ).path == key
        }) {
            setSelectedDocument(existing)
            lastError = "That file is already open in another tab."
            return nil
        }
        guard reserveSharedDestination?(key, document.id) ?? true else {
            lastError = "That file is being saved in another tab."
            return nil
        }
        reservedDestinations.insert(key)
        return key
    }

    private func releaseDestination(_ key: String, owner: UUID) {
        reservedDestinations.remove(key)
        releaseSharedDestination?(key, owner)
    }

    func saveSelectedAs() async {
        guard let document = selectedDocument else { return }
        await saveAs(document)
    }

    // MARK: - Mode

    func toggleMode() {
        if let current = selectedDocument {
            renderedFind(for: current).close()
        }
        guard let document = selectedDocument, !document.isSourceOnly else {
            return
        }
        setMode(document.mode == .source ? .rendered : .source, for: document)
    }

    /// Select the source range of a rendered block. The slice the viewer
    /// parsed is compared with the current bytes; a changed block refuses
    /// rather than selecting the wrong paragraph.
    func editInSource(
        range: SourceRange,
        expectedSource: String,
        in document: MarkdownDocument
    ) async {
        let expected = expectedSource as NSString
        guard range.lowerBound >= 0,
              range.upperBound <= expected.length else {
            lastError = "This block is no longer available."
            return
        }
        let expectedSlice = expected.substring(
            with: NSRange(
                location: range.lowerBound,
                length: range.upperBound - range.lowerBound
            )
        )
        let current = document.source as NSString
        guard range.upperBound <= current.length else {
            lastError = "This block changed. Switch to Source and try again."
            return
        }
        let currentSlice = current.substring(
            with: NSRange(
                location: range.lowerBound,
                length: range.upperBound - range.lowerBound
            )
        )
        guard currentSlice == expectedSlice else {
            lastError = "This block changed. Switch to Source and try again."
            return
        }
        let target = MarkdownActionTarget(
            documentID: document.id,
            identityGeneration: document.identityGeneration,
            sourceRevision: document.revision,
            range: range.lowerBound..<range.upperBound,
            expectedSlice: expectedSlice,
            rootGeneration: rootGeneration
        )
        let context = MarkdownCommandContext(
            source: document.source,
            selection: target.range,
            documentID: document.id,
            identityGeneration: document.identityGeneration,
            sourceRevision: document.revision,
            rootGeneration: rootGeneration,
            target: target
        )
        guard target.isCurrent(in: context) else {
            lastError = "This block changed. Switch to Source and try again."
            return
        }
        setMode(.source, for: document)
        setSourceAnchor(for: document, selection: target.range)
        controller(for: document).select(range: target.range)
    }

    /// Sets the authored `open` default of a rendered details block. The
    /// slice the viewer parsed is compared with the current bytes first; a
    /// changed block refuses rather than editing the wrong tag.
    func setDetailsOpenDefault(
        at range: SourceRange,
        expectedSource: String,
        open: Bool,
        in document: MarkdownDocument
    ) {
        guard !document.isReadOnly else {
            lastError = "This document is read-only."
            return
        }
        let expected = expectedSource as NSString
        let current = document.source as NSString
        let length = range.upperBound - range.lowerBound
        guard range.lowerBound >= 0,
              range.upperBound <= expected.length,
              range.upperBound <= current.length else {
            lastError = "This block is no longer available."
            return
        }
        let expectedSlice = expected.substring(
            with: NSRange(location: range.lowerBound, length: length)
        )
        let currentSlice = current.substring(
            with: NSRange(location: range.lowerBound, length: length)
        )
        guard currentSlice == expectedSlice else {
            lastError = "This block changed. Switch to Source and try again."
            return
        }
        // The command locates the opening tag strictly before the caret, so
        // the caret goes just inside the block's own tag. An indented block
        // starts with whitespace; skip it to the `<`.
        var tagStart = range.lowerBound
        while tagStart < range.upperBound,
              current.character(at: tagStart) == 0x20
                || current.character(at: tagStart) == 0x09 {
            tagStart += 1
        }
        let prefixLength = "<details".utf16.count
        guard tagStart + prefixLength <= current.length,
              current.substring(
                  with: NSRange(location: tagStart, length: prefixLength)
              ).lowercased() == "<details" else {
            lastError = "This details block could not be located in the source."
            return
        }
        controller(for: document).setDetailsOpenDefault(
            open: open,
            at: tagStart + 1
        )
    }

    /// Capture the current surface's reading state before a tab or mode
    /// switch. The source surface computes its anchor on demand; the rendered
    /// surface reports its anchor while scrolling, so only the selection
    /// needs copying here. Selection changes are view state, not undo.
    func captureReadingPosition(for document: MarkdownDocument) {
        guard document.mode == .source || isSplitView(document) else {
            return
        }
        var position = readingPositions[document.id] ?? ReadingPosition()
        position.selection = document.selection
        if let entry = editorCache.cachedEntry(for: document.id),
           let anchor = entry.controller.readingAnchor() {
            position.source = anchor
        }
        readingPositions[document.id] = position
    }

    /// Restore a captured position without changing the document or its
    /// undo history. The source surface restores from `sourceReadingAnchor`
    /// when it mounts; the rendered surface consumes a pending anchor.
    func restoreReadingPosition(for document: MarkdownDocument) {
        guard let position = readingPositions[document.id] else { return }
        if isSplitView(document) {
            // Both surfaces are mounted; each restores its own position.
            if let selection = position.selection {
                document.selection = selection
            }
            if let anchor = position.rendered {
                pendingRenderedAnchors[document.id] = anchor
            }
        } else if document.mode == .source, let selection = position.selection {
            document.selection = selection
        } else if document.mode == .rendered, let anchor = position.rendered {
            pendingRenderedAnchors[document.id] = anchor
        }
    }

    /// The anchor the source surface should restore when it mounts.
    func sourceReadingAnchor(for document: MarkdownDocument) -> SourceReadingAnchor? {
        readingPositions[document.id]?.source
    }

    /// The stored anchors for a document, for diagnostics and acceptance
    /// checks. Reading them has no side effects.
    func storedReadingAnchors(
        for document: MarkdownDocument
    ) -> (source: SourceReadingAnchor?, rendered: RenderedReadingAnchor?) {
        let position = readingPositions[document.id]
        return (position?.source, position?.rendered)
    }

    /// Records the rendered surface's visible position. The viewer calls this
    /// while scrolling; the storage is not observed, so a scroll does not
    /// invalidate any view.
    func recordRenderedAnchor(
        _ anchor: RenderedReadingAnchor,
        for document: MarkdownDocument
    ) {
        var position = readingPositions[document.id] ?? ReadingPosition()
        position.rendered = anchor
        readingPositions[document.id] = position
    }

    // MARK: - Two-document split

    /// Makes `document` the focused pane without changing the pane layout.
    /// A document that is not visible is selected into the focused pane.
    func focus(_ document: MarkdownDocument) {
        guard documents.contains(where: { $0.id == document.id }) else {
            return
        }
        guard document.id != focusedDocumentID else { return }
        guard document.id == selectedDocumentID
                || document.id == secondaryDocumentID else {
            setSelectedDocument(document)
            return
        }
        // A split focus change is a collapse surface for the pane being left.
        collapseForPolicy(.splitFocus, focusedDocument)
        focusedDocumentID = document.id
        onDocumentActivated?(document.fileURL)
    }

    /// Shows a document in a named pane. Choosing the document already in the
    /// other pane focuses it instead of duplicating it.
    func show(_ document: MarkdownDocument, inPane pane: MarkdownPane) {
        guard documents.contains(where: { $0.id == document.id }) else {
            return
        }
        // Moving focus between panes is a collapse surface for the pane
        // being left.
        if focusedDocumentID != document.id {
            collapseForPolicy(.splitFocus, focusedDocument)
        }
        switch pane {
        case .primary:
            guard document.id != secondaryDocumentID else {
                focus(document)
                return
            }
            if selectedDocumentID != document.id {
                if let current = primaryDocument {
                    captureReadingPosition(for: current)
                }
                selectedDocumentID = document.id
            }
            focusedDocumentID = document.id
        case .secondary:
            guard document.id != selectedDocumentID else {
                focus(document)
                return
            }
            if secondaryDocumentID == nil {
                // Two document panes and the source/rendered split are
                // mutually exclusive: the contract is at most two Markdown
                // surfaces per project.
                collapseDocumentSplitViews()
            }
            if secondaryDocumentID != document.id {
                if let current = secondaryDocument {
                    captureReadingPosition(for: current)
                }
                secondaryDocumentID = document.id
            }
            focusedDocumentID = document.id
        }
        onDocumentActivated?(document.fileURL)
    }

    /// Opens a second document pane, refusing to duplicate the primary.
    func openInSecondPane(_ document: MarkdownDocument) {
        show(document, inPane: .secondary)
    }

    /// Closes the second pane. The document stays open and remains reachable
    /// from the document menu; only the pane goes away.
    func closeSplitPane() {
        guard secondaryDocumentID != nil else { return }
        let wasFocused = focusedDocumentID == secondaryDocumentID
        if wasFocused {
            collapseForPolicy(.splitFocus, secondaryDocument)
        }
        secondaryDocumentID = nil
        if wasFocused || focusedDocumentID == nil {
            focusedDocumentID = selectedDocumentID
            if let primary = primaryDocument {
                onDocumentActivated?(primary.fileURL)
            }
        }
    }

    private func collapseDocumentSplitViews() {
        let ids = splitDocuments
        for id in ids {
            guard let document = documents.first(where: { $0.id == id })
            else { continue }
            setSplitView(false, for: document)
        }
    }

    /// Switches surfaces, capturing the one being left and handing the new
    /// surface its stored anchor. An explicit navigation that sets its own
    /// target can call this and then override the scroll.
    func setMode(_ mode: MarkdownDocumentMode, for document: MarkdownDocument) {
        // A single-surface mode and the split view are mutually exclusive.
        if isSplitView(document) {
            setSplitView(false, for: document)
        }
        guard document.mode != mode else { return }
        // A mode switch is a collapse surface: the source caret set does not
        // survive leaving the source surface.
        collapseForPolicy(.modeSwitch, document)
        captureReadingPosition(for: document)
        document.mode = mode
        restoreReadingPosition(for: document)
    }

    // MARK: - Split view

    func isSplitView(_ document: MarkdownDocument) -> Bool {
        splitDocuments.contains(document.id)
    }

    /// Shows or hides Source and Rendered side by side for one document.
    ///
    /// Split is layered on Source: `document.mode` becomes `.source` while it
    /// is on, so commands, find, and the palette keep their source behavior,
    /// and the mode the document came from is restored when split closes.
    /// The state is session-only; reopening the document shows its saved mode.
    func setSplitView(_ enabled: Bool, for document: MarkdownDocument) {
        if enabled {
            guard !document.isSourceOnly,
                  secondaryDocumentID == nil,
                  !splitDocuments.contains(document.id) else {
                return
            }
            collapseForPolicy(.modeSwitch, document)
            captureReadingPosition(for: document)
            splitReturnModes[document.id] = document.mode
            splitDocuments.insert(document.id)
            document.mode = .source
            restoreReadingPosition(for: document)
        } else {
            guard splitDocuments.remove(document.id) != nil else { return }
            // Closing the split leaves the source surface, so it is a collapse
            // surface: a restore to Rendered must not carry the caret set
            // into a cached source controller.
            collapseForPolicy(.modeSwitch, document)
            captureReadingPosition(for: document)
            sourceScrollTargets.removeValue(forKey: document.id)
            splitSyncIgnore.removeValue(forKey: document.id)
            let mode = splitReturnModes.removeValue(forKey: document.id)
                ?? .source
            document.mode = mode
            restoreReadingPosition(for: document)
        }
    }

    func toggleSplitView(for document: MarkdownDocument) {
        setSplitView(!isSplitView(document), for: document)
    }

    /// Why split scrolling cannot follow the anchor right now, or nil when
    /// every visible position maps exactly. The toggle shows this as help.
    func splitSyncRefusalReason(
        for document: MarkdownDocument
    ) -> String? {
        guard isSplitView(document) else { return "Split view is off." }
        guard !document.isSourceOnly else {
            return "Rendered is unavailable for this document."
        }
        guard let output = currentSplitOutput(for: document) else {
            return "Scroll sync needs a current render."
        }
        guard output.ast.blocks.contains(where: { $0.range != nil }) else {
            return "This document has no mapped blocks."
        }
        return nil
    }

    /// The source pane moved: scroll the rendered pane to the block that
    /// contains the top line, when the mapping is exact.
    func sourceDidScroll(
        _ anchor: SourceReadingAnchor,
        in document: MarkdownDocument
    ) {
        guard isSplitView(document),
              isSplitScrollSynced,
              !ignoresSplitSync(.source, for: document),
              let output = currentSplitOutput(for: document),
              let index = MarkdownSplitSync.renderedBlockIndex(
                  forSourceOffset: anchor.lineOffset,
                  in: output.ast.blocks
              ),
              let target = MarkdownSplitSync.renderedScrollAnchor(
                  forBlockIndex: index,
                  in: output.ast.blocks,
                  headings: output.headings.headings
              ) else {
            return
        }
        suppressSplitSync(.rendered, for: document)
        scrollTargets[document.id] = target
    }

    /// The rendered pane moved: record its reading anchor and, when split is
    /// on and the anchor is exact, reveal the block's source line.
    func renderedDidScroll(
        _ anchor: RenderedReadingAnchor,
        in document: MarkdownDocument
    ) {
        recordRenderedAnchor(anchor, for: document)
        guard isSplitView(document),
              isSplitScrollSynced,
              !ignoresSplitSync(.rendered, for: document),
              let output = currentSplitOutput(for: document),
              let offset = MarkdownSplitSync.sourceOffset(
                  for: anchor,
                  in: output.ast.blocks
              ) else {
            return
        }
        suppressSplitSync(.source, for: document)
        sourceScrollTargets[document.id] = offset
    }

    private func currentSplitOutput(
        for document: MarkdownDocument
    ) -> MarkdownParseOutput? {
        guard case let .ready(output) = parseCoordinator.state(
            for: document.id
        ), output.documentID == document.id,
           output.revision == document.revision else {
            return nil
        }
        return output
    }

    private func ignoresSplitSync(
        _ direction: SplitSyncDirection,
        for document: MarkdownDocument
    ) -> Bool {
        guard let entry = splitSyncIgnore[document.id] else { return false }
        if splitSyncNow() >= entry.until {
            splitSyncIgnore.removeValue(forKey: document.id)
            return false
        }
        return entry.direction == direction
    }

    private func suppressSplitSync(
        _ direction: SplitSyncDirection,
        for document: MarkdownDocument
    ) {
        splitSyncIgnore[document.id] = SplitSyncIgnore(
            direction: direction,
            until: splitSyncNow().addingTimeInterval(0.35)
        )
    }

    /// Records where an explicit source navigation should land, so the mount
    /// restore reproduces it instead of the previous reading position.
    private func setSourceAnchor(
        for document: MarkdownDocument,
        selection: Range<Int>
    ) {
        let ns = document.source as NSString
        guard ns.length > 0 else { return }
        var lineStart = min(max(selection.lowerBound, 0), ns.length - 1)
        while lineStart > 0, ns.character(at: lineStart - 1) != 0x0A {
            lineStart -= 1
        }
        var position = readingPositions[document.id] ?? ReadingPosition()
        position.selection = selection
        position.source = SourceReadingAnchor(
            lineOffset: lineStart,
            viewportOffset: 0,
            selection: selection
        )
        readingPositions[document.id] = position
    }

    /// Re-parse before offering Rendered after a nesting refusal. The reason
    /// clears only on a successful current-revision parse.
    /// Re-parses before offering Rendered after a nesting refusal. The reason
    /// clears only on a successful current-revision parse.
    func tryRendered(_ document: MarkdownDocument) async {
        guard !document.isLarge, !document.isReadOnly else { return }
        let revision = document.revision
        parseCoordinator.request(
            documentID: document.id,
            identityGeneration: document.identityGeneration,
            revision: revision,
            source: document.source
        )
        guard let state = await parseCoordinator.awaitSettled(
            documentID: document.id,
            revision: revision
        ), document.revision == revision else {
            lastError = "The document changed while parsing. Try again."
            return
        }
        switch state {
        case .ready:
            document.setNestingLimit(false)
            if !document.isSourceOnly {
                setMode(.rendered, for: document)
            }
        case .refused:
            document.setNestingLimit(true)
        case .idle, .parsing:
            lastError = "The document changed while parsing. Try again."
        }
    }

    // MARK: - Commands

    /// The source controller Find should act on: the focused document when
    /// it shows Source. A key-window lookup is unsafe with retained editors,
    /// so the workspace resolves the target instead.
    func sourceFindTarget() -> MarkdownEditorController? {
        guard let document = focusedDocument, document.mode == .source else {
            return nil
        }
        return editorCache.cachedEntry(for: document.id)?.controller
    }

    /// Collapses a document's caret set. Only an already-built controller is
    /// touched: a surface that was never shown has nothing to clear.
    func collapseMultiCursor(for document: MarkdownDocument?) {
        guard let document else { return }
        editorCache.cachedEntry(for: document.id)?.controller.resetMultiCursor()
    }

    /// The one-outcome policy table. The workspace's collapse surfaces
    /// consult it instead of deciding for themselves; injectable so a test
    /// can prove the wiring.
    var multiCursorPolicy: (MultiCursorPolicy.Operation)
        -> MultiCursorPolicy.Outcome = { $0.outcome }

    /// Collapses when the table names the operation a collapse surface. An
    /// entry that says anything else leaves the set alone.
    private func collapseForPolicy(
        _ operation: MultiCursorPolicy.Operation,
        _ document: MarkdownDocument?
    ) {
        guard multiCursorPolicy(operation) == .collapse else { return }
        collapseMultiCursor(for: document)
    }

    func controller(for document: MarkdownDocument) -> MarkdownEditorController {
        let controller = editorCache.entry(
            for: document,
            parseCoordinator: parseCoordinator
        ).controller
        controller.onCommandError = { [weak self] message in
            self?.lastError = message
        }
        controller.rootGenerationProvider = { [weak self] in
            self?.rootGeneration ?? 0
        }
        controller.reviewMarkerProvider = { [weak self] in
            guard let self else { return [] }
            return self.reviewComments.placements(for: document)
                .compactMap { placement in
                    guard let range = placement.range else { return nil }
                    return ReviewMarkerRulerView.Marker(
                        id: placement.id,
                        offset: range.lowerBound,
                        resolved: !placement.isOpen,
                        anchored: true
                    )
                }
        }
        controller.onReviewMarkerSelected = { [weak self] threadID in
            self?.revealReviewComment(threadID, in: document)
        }
        controller.refreshReviewMarkers()
        return controller
    }

    // MARK: - Review comments

    func loadReviewComments(for document: MarkdownDocument) async {
        await reviewComments.load(document)
        editorCache.cachedEntry(for: document.id)?
            .controller.refreshReviewMarkers()
    }

    @discardableResult
    func addReviewComment(
        to document: MarkdownDocument,
        selection: Range<Int>? = nil,
        body: String
    ) async -> Bool {
        let target = selection ?? document.selection
        let added = await reviewComments.addComment(
            to: document,
            selection: target,
            body: body
        )
        didChangeReviewComments(for: document)
        return added
    }

    @discardableResult
    func replyToReviewComment(
        _ threadID: UUID,
        in document: MarkdownDocument,
        body: String
    ) async -> Bool {
        let replied = await reviewComments.reply(
            to: threadID,
            in: document,
            body: body
        )
        didChangeReviewComments(for: document)
        return replied
    }

    @discardableResult
    func setReviewCommentResolved(
        _ resolved: Bool,
        threadID: UUID,
        in document: MarkdownDocument
    ) async -> Bool {
        let changed = await reviewComments.setResolved(
            resolved,
            threadID: threadID,
            in: document
        )
        didChangeReviewComments(for: document)
        return changed
    }

    @discardableResult
    func deleteReviewComment(
        _ threadID: UUID,
        from document: MarkdownDocument
    ) async -> Bool {
        let deleted = await reviewComments.delete(
            threadID: threadID,
            from: document
        )
        didChangeReviewComments(for: document)
        return deleted
    }

    @discardableResult
    func reloadReviewComments(for document: MarkdownDocument) async -> Bool {
        let reloaded = await reviewComments.reload(document)
        didChangeReviewComments(for: document)
        return reloaded
    }

    @discardableResult
    func overwriteReviewComments(for document: MarkdownDocument) async -> Bool {
        let overwritten = await reviewComments.overwrite(document)
        didChangeReviewComments(for: document)
        return overwritten
    }

    /// Reveals a thread's anchored range in Source. An unanchored thread has
    /// no range to show; the panel keeps it visible instead.
    func revealReviewComment(
        _ threadID: UUID,
        in document: MarkdownDocument
    ) {
        reviewComments.selectedThreadID = threadID
        guard let placement = reviewComments.placements(for: document)
            .first(where: { $0.id == threadID }),
              let range = placement.range else {
            return
        }
        setMode(.source, for: document)
        setSourceAnchor(for: document, selection: range)
        controller(for: document).select(range: range)
    }

    private func didChangeReviewComments(for document: MarkdownDocument) {
        editorCache.cachedEntry(for: document.id)?
            .controller.refreshReviewMarkers()
    }

    // MARK: - Source projections

    /// Replaces exactly the captured block range in the rendered viewer. The
    /// expected slice is the one the viewer displayed; if the document no
    /// longer holds it, nothing is written and the editor can reopen.
    @discardableResult
    func commitBlockEdit(
        range: SourceRange,
        expectedSlice: String,
        replacement: String,
        in document: MarkdownDocument
    ) -> Bool {
        guard !document.isReadOnly else {
            lastError = "This document is read-only."
            return false
        }
        do {
            let commit = try MarkdownBlockProjector.commit(
                MarkdownBlockProjection(
                    range: range.lowerBound..<range.upperBound,
                    expectedSlice: expectedSlice
                ),
                replacement: replacement,
                in: document.source
            )
            try document.replaceSource(
                commit.source,
                actionName: commit.actionName
            )
            document.selection = commit.selection
            lastError = nil
            return true
        } catch MarkdownBlockProjectionError.staleBlock {
            lastError = "This block changed since it opened. "
                + "Close the editor and try again."
            return false
        } catch {
            lastError = "Could not edit the block: \(error)"
            return false
        }
    }

    // MARK: - Proposals

    /// Shows the conventional `.<name>.proposal.diff` when it exists, or asks
    /// for a proposal file.
    func presentProposal(for document: MarkdownDocument) {
        guard let documentURL = document.fileURL else {
            proposalError = "Save the document before reviewing a proposal."
            return
        }
        let conventional = MarkdownProposal.proposalURL(for: documentURL)
        if FileManager.default.fileExists(atPath: conventional.path) {
            _ = loadProposal(from: conventional, for: document)
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "diff") ?? .plainText,
            .plainText,
        ]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = documentURL.deletingLastPathComponent()
        panel.message =
            "Choose a proposal diff for \(documentURL.lastPathComponent)"
        guard panel.runModal() == .OK, let chosen = panel.url else {
            return
        }
        _ = loadProposal(from: chosen, for: document)
    }

    @discardableResult
    func loadProposal(
        from url: URL,
        for document: MarkdownDocument
    ) -> Bool {
        guard let documentName = document.fileURL?.lastPathComponent else {
            proposalError = "Save the document before reviewing a proposal."
            return false
        }
        do {
            let proposal = try MarkdownProposal.load(from: url)
            guard proposal.documentName == documentName else {
                proposalError = "This proposal is for "
                    + "\(proposal.documentName), not \(documentName)."
                return false
            }
            guard proposal.matches(source: document.source) else {
                proposalError = "The document changed since this proposal "
                    + "was written. Its base no longer matches."
                return false
            }
            proposalPreview = ProposalPreview(
                fileURL: url,
                proposal: proposal,
                expectedSource: document.source
            )
            proposalError = nil
            isProposalVisible = true
            return true
        } catch {
            proposalError = Self.proposalMessage(for: error)
            return false
        }
    }

    func dismissProposal() {
        isProposalVisible = false
        proposalPreview = nil
        proposalError = nil
    }

    /// Applies the accepted hunks as one undoable source edit, then saves
    /// through the document's ordinary compare-and-swap path.
    @discardableResult
    func applyProposal(
        accepting hunkIDs: Set<Int>,
        in document: MarkdownDocument
    ) async -> Bool {
        guard let preview = proposalPreview else { return false }
        guard document.source == preview.expectedSource else {
            proposalError = "The document changed while this proposal was "
                + "open. Reopen it."
            return false
        }
        do {
            let newSource = try preview.proposal.apply(
                accepting: hunkIDs,
                to: document.source
            )
            guard newSource != document.source else {
                proposalError = "No hunks were accepted."
                return false
            }
            try document.replaceSource(
                newSource,
                actionName: "Apply Proposal"
            )
            dismissProposal()
            await save(document)
            return true
        } catch {
            proposalError = Self.proposalMessage(for: error)
            return false
        }
    }

    private static func proposalMessage(for error: Error) -> String {
        switch error {
        case MarkdownProposalError.staleBase:
            return "The document changed since this proposal was written."
        case let MarkdownProposalError.hunkOutOfDate(hunk):
            return "Hunk \(hunk) no longer matches the document."
        case MarkdownProposalError.overlappingHunks:
            return "The proposal has overlapping hunks."
        case MarkdownProposalError.noHunksSelected:
            return "Select at least one hunk."
        case let MarkdownProposalError.unsupportedVersion(version):
            return "The proposal uses format \(version), which this build "
                + "cannot read."
        case let MarkdownProposalError.unreadable(detail):
            return "Cannot read the proposal: \(detail)"
        case let MarkdownProposalError.malformed(detail):
            return "The proposal is malformed: \(detail)"
        case let MarkdownProposalError.documentMismatch(expected, actual):
            return "The proposal targets \(actual), not \(expected)."
        default:
            return String(describing: error)
        }
    }

    /// Runs the correctness-only lint and the local link probe for one
    /// document, then hands the diagnostics to its source editor.
    func checkMarkdown(_ document: MarkdownDocument) async {
        let revision = document.revision
        parseCoordinator.request(
            documentID: document.id,
            identityGeneration: document.identityGeneration,
            revision: revision,
            source: document.source
        )
        guard let state = await parseCoordinator.awaitSettled(
            documentID: document.id,
            revision: revision
        ), document.revision == revision,
           case .ready(let output) = state else {
            return
        }
        let base = MarkdownLintEngine.lint(
            source: document.source,
            ast: output.ast,
            documentID: document.id,
            revision: revision
        )
        let targets = MarkdownLintEngine.probeTargets(ast: output.ast)
        let outcomes = await linkProbe.check(
            destinations: targets.map(\.destination),
            documentURL: document.fileURL,
            root: workspaceRoot
        )
        guard document.revision == revision,
              !document.isClosed,
              documents.contains(where: { $0 === document }) else {
            return
        }
        let result = MarkdownLintEngine.appendingProbeResults(
            outcomes,
            targets: targets,
            to: base
        )
        lintResults[document.id] = result
        controller(for: document).setLintDiagnostics(result.diagnostics)
    }

    /// Scrolls to a heading in the current surface.
    func jumpToHeading(_ row: TOCRow, in document: MarkdownDocument) {
        if document.mode == .source, let range = row.range {
            controller(for: document).select(
                range: range.lowerBound..<range.upperBound
            )
        } else if let scrollID = row.scrollID {
            scrollTargets[document.id] = scrollID
        }
    }

    func quickOpenEntries() -> [MarkdownQuickOpenEntry] {
        let tabs = documents.compactMap(\.fileURL)
        return MarkdownQuickOpen.entries(
            tabs: tabs,
            files: workspaceFiles,
            root: workspaceRoot
        )
    }

    func openQuickEntry(_ entry: MarkdownQuickOpenEntry) {
        isQuickOpenVisible = false
        _ = open(url: entry.url)
    }

    /// Opens a file and selects the 1-based line and 1-based UTF-16 column
    /// (the convention `CodeSearchMatch` reports). When `query` is present
    /// the source find bar opens seeded with it, so the reader can step
    /// through the other matches.
    func openResult(
        url: URL,
        line: Int,
        column: Int,
        query: String? = nil
    ) {
        guard let document = open(url: url) else { return }
        let map = SourceMap(source: document.source)
        guard let text = map.lineText(line),
              let utf8Column = Self.utf8Column(
                  in: text,
                  utf16Column: column
              ),
              var offset = map.utf16Offset(
                  line: line,
                  utf8Column: utf8Column
              ) else {
            return
        }
        offset = min(offset, (document.source as NSString).length)
        setMode(.source, for: document)
        setSourceAnchor(for: document, selection: offset..<offset)
        let controller = controller(for: document)
        controller.select(range: offset..<offset)
        if let query, !query.isEmpty {
            controller.seedFindBar(with: query, at: offset)
        }
    }

    /// Converts a 1-based UTF-16 column within a line to the 1-based UTF-8
    /// column `SourceMap` resolves. A column past the line end clamps to the
    /// line end; one that splits a surrogate pair resolves to nil.
    private static func utf8Column(
        in text: Substring,
        utf16Column: Int
    ) -> Int? {
        let line = String(text)
        let utf16 = line.utf16
        let offset = min(max(utf16Column - 1, 0), utf16.count)
        guard
            let boundary = utf16.index(
                utf16.startIndex,
                offsetBy: offset,
                limitedBy: utf16.endIndex
            ),
            let byteIndex = boundary.samePosition(in: line.utf8)
        else {
            return nil
        }
        return line.utf8.distance(
            from: line.utf8.startIndex,
            to: byteIndex
        ) + 1
    }

    func findInFiles(
        _ query: String
    ) async -> CodeSearchResult? {
        guard let root = workspaceRoot else { return nil }
        return await CodeProjectSearch().search(
            root: root,
            query: query,
            scope: .markdown
        )
    }

    func showRenderedFind() {
        guard let document = selectedDocument else { return }
        renderedFind(for: document).show()
    }

    func stepRenderedFind(_ delta: Int) {
        guard let document = selectedDocument else { return }
        renderedFind(for: document).step(delta)
    }

    /// The controller for one document's rendered find bar. Created on
    /// demand; documents get one at open time so the first body evaluation
    /// does not mutate workspace state.
    @discardableResult
    private func ensureRenderedFind(for document: MarkdownDocument)
        -> RenderedFindController {
        if let existing = renderedFinds[document.id] { return existing }
        let controller = RenderedFindController()
        renderedFinds[document.id] = controller
        return controller
    }

    func renderedFind(
        for document: MarkdownDocument
    ) -> RenderedFindController {
        ensureRenderedFind(for: document)
    }

    func togglePalette() {
        guard let document = selectedDocument,
              document.mode == .source,
              !document.isReadOnly else {
            isPaletteVisible = false
            return
        }
        isPaletteVisible.toggle()
    }

    func paletteEntries() -> [MarkdownCommandCatalog.Entry] {
        guard let document = selectedDocument else { return [] }
        let controller = controller(for: document)
        let available = Set(controller.availableCommands())
        return MarkdownCommandCatalog.paletteEntries {
            available.contains($0)
        }
    }

    func executePaletteCommand(_ command: MarkdownCommandKind) {
        guard let document = selectedDocument else { return }
        let controller = controller(for: document)
        isPaletteVisible = false
        if case .insertLink = command {
            controller.presentLinkPopover()
            return
        }
        _ = controller.perform(command)
    }

    func checkSelectedMarkdown() {
        guard let document = selectedDocument else { return }
        Task { await checkMarkdown(document) }
    }

    func goToNextProblem() {
        guard let document = selectedDocument else { return }
        controller(for: document).goToDiagnostic(backwards: false)
    }

    func goToPreviousProblem() {
        guard let document = selectedDocument else { return }
        controller(for: document).goToDiagnostic(backwards: true)
    }

    /// Replaces the frontmatter range through the one command path.
    func commitFrontmatter(
        _ document: MarkdownDocument,
        range: Range<Int>,
        text: String
    ) {
        controller(for: document).commitFrontmatter(
            range: range,
            text: text
        )
    }

    /// Opens the link popover over the selected source document's caret, or
    /// inserts a link when the caret is not on one.
    func presentLinkPopoverOnSelected() {
        guard let document = selectedDocument, document.mode == .source else {
            return
        }
        controller(for: document).presentLinkPopover()
    }

    func perform(_ command: MarkdownCommandKind, on document: MarkdownDocument) {
        controller(for: document).perform(command)
    }

    func performSelected(_ command: MarkdownCommandKind) {
        guard let document = selectedDocument else { return }
        perform(command, on: document)
    }

    // MARK: - External changes

    private func startWatcher(for document: MarkdownDocument) {
        guard let url = document.fileURL else { return }
        watchers[document.id]?.stop()

        let id = document.id
        let watcher = MarkdownFileWatcher(fileURL: url) {
            // Never post a main-queue notification synchronously from the
            // watcher queue: stop() waits for that queue while holding main.
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .sonovoMarkdownFileChanged,
                    object: nil,
                    userInfo: ["id": id]
                )
            }
        }
        watcher.start()
        watchers[document.id] = watcher
    }

    private func handleFileChange(_ id: UUID) {
        guard let document = documents.first(where: { $0.id == id }) else {
            return
        }
        // Capture before the disk version can replace the source, so an
        // adoption restores the reading position instead of a stale viewport.
        captureReadingPosition(for: document)
        Task { @MainActor in
            do {
                let change = try await document.checkExternalChange()
                switch change {
                case .adopted:
                    restoreAfterSourceReplacement(document)
                    await observeExternalChange(for: document)
                case .conflict:
                    await observeExternalChange(for: document)
                case .deleted:
                    lastError = "The file was deleted on disk: "
                        + (document.fileURL?.lastPathComponent ?? "document")
                case .none:
                    break
                }
            } catch {
                lastError = "Cannot re-read "
                    + "\(document.fileURL?.lastPathComponent ?? "document"): \(error)"
            }
        }
    }

    func reload(_ document: MarkdownDocument) {
        captureReadingPosition(for: document)
        // Reload is a collapse surface in the policy table. Relying on the
        // changed text to reset the caret set missed a reload whose source is
        // canonically unchanged (a BOM or line-ending change), leaving carets
        // that name the old bytes.
        collapseForPolicy(.reload, document)
        document.resolveExternalChange(.reload)
        restoreAfterSourceReplacement(document)
    }

    /// Reapplies the captured reading position after an external replacement
    /// of the whole source. The source pane consumes its anchor on the next
    /// sync; the rendered pane consumes the pending-anchor binding.
    private func restoreAfterSourceReplacement(_ document: MarkdownDocument) {
        if document.mode == .source || isSplitView(document),
           let anchor = readingPositions[document.id]?.source,
           let controller = editorCache.cachedEntry(for: document.id)?
               .controller {
            controller.restoreReadingAnchorAfterSourceReplacement(anchor)
        }
        restoreReadingPosition(for: document)
    }

    func keepLocal(_ document: MarkdownDocument) {
        document.resolveExternalChange(.keepLocal)
    }

    // MARK: - Wiki links

    func wikiState(
        for link: WikiLink,
        in document: MarkdownDocument
    ) -> WikiLinkVisualState {
        guard let documentURL = document.fileURL else { return .missing }
        let resolver = wikiResolver(documentURL: documentURL)
        switch resolver.resolve(link) {
        case .resolved: return .normal
        case .ambiguous: return .ambiguous
        case .missing: return .missing
        }
    }

    func openWikiLink(_ link: WikiLink, in document: MarkdownDocument) async {
        guard let documentURL = document.fileURL else {
            lastError = "Save the document before following wiki links."
            return
        }

        let resolver = wikiResolver(documentURL: documentURL)
        switch resolver.resolve(link) {
        case let .resolved(url):
            // A failed open leaves the previous selection in place. Acting
            // on `selectedDocument` would apply the fragment to that document.
            guard let target = open(url: url) else { return }
            await navigate(to: target, fragment: link.fragment)
        case .ambiguous:
            lastError = "Wiki link is ambiguous: \(link.targetWithFragment)"
        case .missing:
            lastError = "Wiki link not found: \(link.targetWithFragment)"
        }
    }

    /// Switches to rendered mode and resolves a heading fragment through the
    /// parse service instead of reparsing on the main actor.
    private func navigate(
        to document: MarkdownDocument,
        fragment: String?
    ) async {
        setMode(.rendered, for: document)
        guard let fragment, !fragment.isEmpty else { return }
        let revision = document.revision
        parseCoordinator.request(
            documentID: document.id,
            identityGeneration: document.identityGeneration,
            revision: revision,
            source: document.source
        )
        guard let state = await parseCoordinator.awaitSettled(
            documentID: document.id,
            revision: revision
        ), document.revision == revision,
           case .ready(let output) = state else {
            return
        }
        if let scrollID = output.headings
            .heading(forFragment: fragment)?
            .scrollID {
            scrollTargets[document.id] = scrollID
        }
    }

    private func wikiResolver(documentURL: URL) -> WikiLinkResolver {
        let root = workspaceRoot ?? documentURL.deletingLastPathComponent()
        var files = workspaceFiles
        if files.isEmpty {
            files = [documentURL]
        } else if !files.contains(documentURL) {
            files.append(documentURL)
        }
        return WikiLinkResolver(
            workspaceRoot: root,
            documentURL: documentURL,
            markdownFiles: files
        )
    }

    func openLocalLink(_ path: String, from document: MarkdownDocument) async {
        guard let documentURL = document.fileURL else { return }
        let root = workspaceRoot ?? documentURL.deletingLastPathComponent()

        // `guide.md#setup` is a path plus a fragment. Passing the whole
        // string to the filesystem resolver looks for a file whose name
        // contains `#setup`.
        let pieces = path.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let filePath = String(pieces[0])
        let fragment = pieces.count > 1
            ? (String(pieces[1]).removingPercentEncoding ?? String(pieces[1]))
            : nil

        guard let url = MarkdownSecurity.resolveLocalPath(
            filePath,
            relativeTo: documentURL,
            root: root
        ) else {
            lastError = "Link points outside the workspace: \(path)"
            return
        }
        if url.pathExtension.lowercased() == "md"
            || url.pathExtension.lowercased() == "markdown" {
            guard let target = open(url: url) else { return }
            await navigate(to: target, fragment: fragment)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "File not found: \(path)"
            return
        }
        if onOpenAsset?(url) == true { return }
        if let fragment, !fragment.isEmpty,
           var components = URLComponents(
               url: url,
               resolvingAgainstBaseURL: false
           ) {
            components.fragment = fragment
            NSWorkspace.shared.open(components.url ?? url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Panels

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.markdownTypes
        if panel.runModal() == .OK {
            for url in panel.urls {
                open(url: url)
            }
        }
    }

    func presentOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.urls.first {
            Task { await openFolder(url) }
        }
    }

    /// Exports the focused document to a self-contained HTML file or a PDF.
    ///
    /// The source is snapshotted when the save panel closes, so a concurrent
    /// edit cannot produce a document that never existed; an edit made after
    /// the click belongs to the next export.
    func exportSelected(as format: MarkdownExportFormat) {
        guard let document = selectedDocument else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export as \(format.displayName)"
        panel.nameFieldStringValue = "\(MarkdownExportService.title(for: document)).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let root = workspaceRoot
        Task { [weak self] in
            guard let self else { return }
            do {
                try await MarkdownExportService.write(
                    document: document,
                    format: format,
                    to: url,
                    workspaceRoot: root,
                    theme: MarkdownReadingSettings.currentTheme()
                )
            } catch {
                self.lastError = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    /// Binds the project root without opening a document. The project owns
    /// its tabs; binding only makes project-relative resolution and the
    /// Markdown file index available.
    func setWorkspaceRoot(_ url: URL) {
        let root = MarkdownSecurity.canonical(url)
        guard workspaceRoot != root else { return }
        workspaceScanTask?.cancel()
        workspaceScanTask = nil
        workspaceRoot = root
        rootGeneration &+= 1
        pendingOpenFirst = false
        configureSnapshots(for: root)
        workspaceWatcher?.stop()
        watcherRetryTask?.cancel()
        startWorkspaceWatcher(for: root)
        workspaceScanTask = Task { @MainActor [weak self] in
            await self?.rescanWorkspaceIndex(root: root, openFirst: false)
        }
    }

    func openFolder(_ url: URL) async {
        let root = MarkdownSecurity.canonical(url)
        // A debounced rescan from the previous folder must not survive the
        // switch and invalidate the new folder's scan generation.
        workspaceScanTask?.cancel()
        workspaceScanTask = nil
        workspaceRoot = root
        rootGeneration &+= 1
        pendingOpenFirst = false
        configureSnapshots(for: root)
        workspaceWatcher?.stop()
        watcherRetryTask?.cancel()

        startWorkspaceWatcher(for: root)

        await rescanWorkspaceIndex(root: root, openFirst: true)
    }

    /// Starts the folder watcher, retrying a failed start while this folder
    /// remains the workspace. FSEvents can fail transiently (for example
    /// during a volume mount), and requiring the user to reopen the folder
    /// would silently leave the index stale.
    /// The snapshot store follows the project root; a new root is a new
    /// store, and old evidence stays under the old root.
    private func configureSnapshots(for root: URL) {
        snapshotStore = MarkdownSnapshotStore(
            baseDirectory: snapshotBaseDirectory,
            projectRoot: root
        )
    }

    private static var defaultSnapshotBaseDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent(
            "Sonovo/MarkdownSnapshots",
            isDirectory: true
        )
    }

    private func relativeSnapshotPath(for url: URL) -> String? {
        guard let root = workspaceRoot else { return nil }
        let rootPath = MarkdownSecurity.canonical(root).path
        let path = MarkdownSecurity.canonical(url).path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private func diskBytes(at url: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            try? MarkdownFileStore.readBoundedData(at: url)
        }.value
    }

    @discardableResult
    private func recordSaveHistory(
        for document: MarkdownDocument,
        kind: MarkdownHistoryPolicy.SaveKind
    ) async -> MarkdownSnapshotRecord? {
        // Record the bytes the save actually committed, not a fresh read:
        // an external writer between the swap and this call must not be
        // recorded as Sonovo's save or become the review baseline.
        guard let snapshots = snapshotStore,
              let url = document.fileURL,
              let relative = relativeSnapshotPath(for: url),
              let bytes = document.diskSnapshot?.bytes else {
            return nil
        }
        let result = await snapshots.recordHistory(
            rawBytes: bytes,
            relativePath: relative,
            kind: kind
        )
        historyRevision &+= 1
        switch result {
        case .captured(let record):
            await snapshots.setBaseline(
                relativePath: relative,
                recordID: record.id
            )
            return record
        case .merged(let record):
            await snapshots.setBaseline(
                relativePath: relative,
                recordID: record.id
            )
            return record
        case .evidenceUnavailable:
            return nil
        }
    }

    private func observeExternalChange(for document: MarkdownDocument) async {
        guard let snapshots = snapshotStore,
              let url = document.fileURL,
              let relative = relativeSnapshotPath(for: url),
              let bytes = await diskBytes(at: url) else {
            return
        }
        _ = await snapshots.observe(
            relativePath: relative,
            diskBytes: bytes
        )
        historyRevision &+= 1
    }

    // MARK: - History and review panels

    func historyRecords(
        for document: MarkdownDocument
    ) async -> [MarkdownSnapshotRecord] {
        guard let snapshots = snapshotStore,
              let url = document.fileURL,
              let relative = relativeSnapshotPath(for: url) else {
            return []
        }
        return await snapshots.records(for: relative)
    }

    func reviewTransitions(
        for document: MarkdownDocument
    ) async -> [MarkdownReviewTransition] {
        guard let snapshots = snapshotStore,
              let url = document.fileURL,
              let relative = relativeSnapshotPath(for: url) else {
            return []
        }
        return await snapshots.transitions(for: relative)
    }

    func restoreSnapshot(
        _ record: MarkdownSnapshotRecord,
        in document: MarkdownDocument
    ) async {
        // Keep the pre-restore state in history; a restore is never the only
        // copy of what it replaced.
        await recordSaveHistory(for: document, kind: .restore)
        guard let snapshots = snapshotStore,
              case let .bytes(rawBytes, _) = await snapshots.load(id: record.id),
              let url = document.fileURL,
              let current = await diskBytes(at: url) else {
            lastError = "Snapshot evidence is unavailable."
            return
        }
        do {
            _ = try await document.restore(
                rawBytes: rawBytes,
                expectedDiskBytes: current
            )
            historyRevision &+= 1
        } catch {
            lastError = "Restore failed: \(error)"
        }
    }

    func deleteSnapshot(_ record: MarkdownSnapshotRecord) async {
        await snapshotStore?.delete(id: record.id)
        historyRevision &+= 1
    }

    func keepTransition(_ transition: MarkdownReviewTransition) async {
        _ = await snapshotStore?.decide(
            transitionID: transition.id,
            keep: true
        )
        historyRevision &+= 1
    }

    func revertTransition(
        _ transition: MarkdownReviewTransition,
        in document: MarkdownDocument
    ) async {
        guard let snapshots = snapshotStore,
              let url = document.fileURL,
              let current = await diskBytes(at: url) else { return }
        // Validate and obtain the bytes without recording the decision. A
        // failed restore must not leave history saying the revert happened.
        let decision = await snapshots.prepareRevert(
            transitionID: transition.id,
            currentDiskBytes: current
        )
        switch decision {
        case .revert(let rawBytes):
            do {
                _ = try await document.restore(
                    rawBytes: rawBytes,
                    expectedDiskBytes: current
                )
                if !(await snapshots.commitRevert(
                    transitionID: transition.id
                )) {
                    lastError = "Reverted, but the review history "
                        + "could not be updated."
                }
            } catch {
                lastError = "Revert failed: \(error)"
            }
        case .staleDisk:
            lastError = "The file changed again; review the new state."
        case .evidenceUnavailable:
            lastError = "Snapshot evidence is unavailable."
        case .kept, .alreadyDecided:
            break
        }
        historyRevision &+= 1
    }

    private func startWorkspaceWatcher(for root: URL) {
        let watcher = WorkspaceDirectoryWatcher(path: root.path) {
            [weak self] in
            Task { @MainActor in
                self?.scheduleWorkspaceRescan()
            }
        }
        if watcher.start() {
            workspaceWatcher = watcher
            return
        }
        workspaceWatcher = nil
        lastError = "This folder could not be watched for changes. "
            + "Retrying automatically."
        watcherRetryTask = Task { @MainActor [weak self] in
            var delayMilliseconds = 1_000
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .milliseconds(delayMilliseconds)
                )
                guard let self, !Task.isCancelled,
                      self.workspaceRoot == root else {
                    return
                }
                let retry = WorkspaceDirectoryWatcher(path: root.path) {
                    [weak self] in
                    Task { @MainActor in
                        self?.scheduleWorkspaceRescan()
                    }
                }
                if retry.start() {
                    self.workspaceWatcher = retry
                    self.lastError = nil
                    // Events during the failed period were missed; rebuild
                    // the index now that the watcher is live again.
                    self.scheduleWorkspaceRescan()
                    return
                }
                delayMilliseconds = min(delayMilliseconds * 2, 30_000)
            }
        }
    }

    /// Rebuilds the index off the main actor. A scan that finishes after a
    /// newer one has started is discarded. Rescans are index-only unless a
    /// caller explicitly opens the folder; a filesystem change must never
    /// open a document on the user's behalf.
    func rescanWorkspaceIndex(
        root: URL,
        openFirst: Bool = false
    ) async {
        // Reject a scan for an old root before touching the generation;
        // otherwise it invalidates the new root's scan and then discards
        // itself, leaving no index at all.
        guard workspaceRoot == root else { return }
        if openFirst { pendingOpenFirst = true }
        workspaceScanGeneration += 1
        let generation = workspaceScanGeneration
        let files = await Task.detached(priority: .userInitiated) {
            Self.markdownFiles(in: root)
        }.value

        guard generation == workspaceScanGeneration,
              workspaceRoot == root else {
            return
        }
        workspaceFiles = files
        // The intent belongs to the folder, not to one scan: a watcher
        // rescan that superseded an explicit open still opens the document.
        let shouldOpen = pendingOpenFirst
        pendingOpenFirst = false
        if shouldOpen, documents.isEmpty, let first = files.first {
            open(url: first)
        }
    }

    private func scheduleWorkspaceRescan() {
        guard let root = workspaceRoot else { return }
        workspaceScanTask?.cancel()
        workspaceScanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await self.rescanWorkspaceIndex(root: root)
        }
    }

    func presentSavePanel(for document: MarkdownDocument) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.markdownTypes
        panel.nameFieldStringValue = document.fileURL?.lastPathComponent
            ?? "Untitled.md"
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Termination

    func flushAllForTermination() async -> Bool {
        // A later save can take long enough for an earlier document to
        // become dirty again. Recheck the whole set before allowing close.
        for _ in 0..<3 {
            for document in documents where document.isDirty {
                let outcome = await document.flushForClose()
                if case .needsDecision = outcome {
                    setSelectedDocument(document)
                    pendingClose = document
                    return false
                }
            }
            if !documents.contains(where: \.isDirty) {
                return true
            }
        }
        lastError = "Some documents could not be saved before closing."
        return !documents.contains(where: \.isDirty)
    }

    // MARK: - Autosave

    private func startAutosaveLoop() {
        autosave.start()
    }

    // MARK: - Utilities

    private static var markdownTypes: [UTType] {
        var types: [UTType] = []
        if let md = UTType(filenameExtension: "md") {
            types.append(md)
        }
        if let markdown = UTType(filenameExtension: "markdown") {
            types.append(markdown)
        }
        return types
    }

    private static var defaultOpenMode: MarkdownDocumentMode {
        let rendered = UserDefaults.standard.object(
            forKey: "sonovo.markdownRendered"
        ) as? Bool ?? true
        return rendered ? .rendered : .source
    }

    nonisolated private static func markdownFiles(in root: URL) -> [URL] {
        let skip: Set<String> = [
            ".git", ".build", "node_modules", "assets", ".swiftpm"
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if skip.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let extensionName = url.pathExtension.lowercased()
            guard extensionName == "md" || extensionName == "markdown" else {
                continue
            }
            // A directory can be named `notes.md`; only regular files are
            // documents.
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey]
            )
            if values?.isRegularFile == true {
                files.append(url.standardizedFileURL)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
