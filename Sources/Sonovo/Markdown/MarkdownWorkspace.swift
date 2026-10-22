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

/// Owns the open Markdown documents, their tabs, autosave, and watchers.
@MainActor
@Observable
final class MarkdownWorkspace {
    let parseService: MarkdownParseService
    let editorCache: MarkdownEditorCache

    private let store: MarkdownFileStore

    private(set) var documents: [MarkdownDocument] = []
    var selectedDocumentID: UUID?
    private(set) var workspaceRoot: URL?
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

    private var watchers: [UUID: MarkdownFileWatcher] = [:]
    @ObservationIgnored
    private var autosave: AutosaveDriver<MarkdownDocument>!
    private var reservedDestinations: Set<String> = []
    nonisolated(unsafe) private var workspaceWatcher: WorkspaceDirectoryWatcher?
    private var workspaceScanTask: Task<Void, Never>?
    @ObservationIgnored
    private var watcherRetryTask: Task<Void, Never>?
    private var workspaceScanGeneration = 0
    nonisolated(unsafe) private var fileChangeObserver: NSObjectProtocol?

    deinit {
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
            Task { await parseService.release(documentID: id) }
        }
        documents.removeAll()
        watchers.removeAll()
        scrollTargets.removeAll()
        pendingClose = nil
        workspaceWatcher?.stop()
        workspaceWatcher = nil
        workspaceScanTask?.cancel()
        workspaceScanTask = nil
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
    }

    var selectedDocument: MarkdownDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    var hasDirtyDocuments: Bool {
        documents.contains(where: \.isDirty)
    }

    init(
        store: MarkdownFileStore = MarkdownFileStore(),
        parseService: MarkdownParseService = MarkdownParseService(),
        editorCache: MarkdownEditorCache = .shared,
        readsDemoEnvironment: Bool = true
    ) {
        self.store = store
        self.parseService = parseService
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
        setSelectedDocument(document)
    }

    private func setSelectedDocument(_ document: MarkdownDocument) {
        selectedDocumentID = document.id
        // An untitled document still changes the identity on screen; the
        // owning tab must stop naming the previously selected file.
        onDocumentActivated?(document.fileURL)
    }

    /// Returns true only when the document was actually closed. A document
    /// waiting for a save decision stays open, so its project tab must stay
    /// open too.
    @discardableResult
    func close(_ document: MarkdownDocument) async -> Bool {
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
        documents.removeAll { $0.id == id }
        scrollTargets.removeValue(forKey: id)
        autosave.forget(id)
        // The parse service otherwise retains this document's AST, heading
        // index, and source for the life of the process.
        Task { await parseService.release(documentID: id) }

        if selectedDocumentID == id {
            selectedDocumentID = documents.first?.id
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
    private func saveAs(
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
            startWatcher(for: document)
            registerWorkspaceFile(target)
            lastError = nil
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
        guard let document = selectedDocument else { return }
        document.mode = document.mode == .source ? .rendered : .source
    }

    // MARK: - Commands

    func controller(for document: MarkdownDocument) -> MarkdownEditorController {
        let controller = editorCache.entry(
            for: document,
            parseService: parseService
        ).controller
        controller.onCommandError = { [weak self] message in
            self?.lastError = message
        }
        return controller
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
        Task { @MainActor in
            do {
                let change = try await document.checkExternalChange()
                if change == .deleted {
                    lastError = "The file was deleted on disk: "
                        + (document.fileURL?.lastPathComponent ?? "document")
                }
            } catch {
                lastError = "Cannot re-read "
                    + "\(document.fileURL?.lastPathComponent ?? "document"): \(error)"
            }
        }
    }

    func reload(_ document: MarkdownDocument) {
        document.resolveExternalChange(.reload)
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
        document.mode = .rendered
        guard let fragment, !fragment.isEmpty else { return }
        let output = await parseService.parse(
            MarkdownParseInput(
                documentID: document.id,
                revision: document.revision,
                source: document.source
            )
        )
        guard let output,
              output.documentID == document.id,
              output.revision == document.revision else {
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
        } else if let fragment, !fragment.isEmpty,
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

    func openFolder(_ url: URL) async {
        let root = MarkdownSecurity.canonical(url)
        // A debounced rescan from the previous folder must not survive the
        // switch and invalidate the new folder's scan generation.
        workspaceScanTask?.cancel()
        workspaceScanTask = nil
        workspaceRoot = root
        workspaceWatcher?.stop()
        watcherRetryTask?.cancel()

        startWorkspaceWatcher(for: root)

        await rescanWorkspaceIndex(root: root)
    }

    /// Starts the folder watcher, retrying a failed start while this folder
    /// remains the workspace. FSEvents can fail transiently (for example
    /// during a volume mount), and requiring the user to reopen the folder
    /// would silently leave the index stale.
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
    /// newer one has started is discarded.
    private func rescanWorkspaceIndex(root: URL) async {
        // Reject a scan for an old root before touching the generation;
        // otherwise it invalidates the new root's scan and then discards
        // itself, leaving no index at all.
        guard workspaceRoot == root else { return }
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
        if documents.isEmpty, let first = files.first {
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
