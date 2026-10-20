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

/// The active workspace, reachable by the app delegate for quit flushing.
@MainActor
enum MarkdownWorkspaceRegistry {
    static weak var active: MarkdownWorkspace?
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

    func dismissError() {
        lastError = nil
    }
    /// Called exactly once when a quit waiting on a close decision resolves.
    var onTerminationResolved: (@MainActor (Bool) -> Void)?
    var scrollTargets: [UUID: String] = [:]

    private var watchers: [UUID: MarkdownFileWatcher] = [:]
    private var autosaveTask: Task<Void, Never>?
    private var autosaveRetryAfter: [UUID: Date] = [:]
    private var autosaveFailures: [UUID: Int] = [:]
    private var reservedDestinations: Set<String> = []
    nonisolated(unsafe) private var workspaceWatcher: WorkspaceDirectoryWatcher?
    private var workspaceScanTask: Task<Void, Never>?
    private var workspaceScanGeneration = 0
    nonisolated(unsafe) private var fileChangeObserver: NSObjectProtocol?

    deinit {
        if let fileChangeObserver {
            NotificationCenter.default.removeObserver(fileChangeObserver)
        }
        workspaceWatcher?.stop()
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
        editorCache: MarkdownEditorCache = .shared
    ) {
        self.store = store
        self.parseService = parseService
        self.editorCache = editorCache
        MarkdownWorkspaceRegistry.active = self

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

        startAutosaveLoop()

        if let path = ProcessInfo.processInfo.environment["SONOVO_DEMO_MARKDOWN"] {
            open(url: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Documents

    @discardableResult
    func newDocument() -> MarkdownDocument {
        if let existing = documents.first(where: {
            $0.fileURL == nil && !$0.isDirty
        }) {
            selectedDocumentID = existing.id
            return existing
        }

        let document = MarkdownDocument(untitledWith: store)
        document.mode = .source
        documents.append(document)
        selectedDocumentID = document.id
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
            selectedDocumentID = existing.id
            return existing
        }
        guard !reservedDestinations.contains(key) else {
            // A Save As is about to write this path; opening it now would
            // create a second model that the completed save cannot see.
            lastError = "That file is being saved in another tab."
            return nil
        }

        do {
            let document = try MarkdownDocument(loading: target, store: store)
            document.mode = Self.defaultOpenMode
            documents.append(document)
            selectedDocumentID = document.id
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
        selectedDocumentID = document.id
    }

    func close(_ document: MarkdownDocument) async {
        let outcome = await document.flushForClose()
        switch outcome {
        case .closed:
            remove(document)
        case .needsDecision:
            pendingClose = document
        }
    }

    /// Saves and closes a document that was waiting for a close decision.
    func saveAndClose(_ document: MarkdownDocument) async {
        if document.fileURL == nil {
            guard let url = presentSavePanel(for: document) else {
                resolveTerminationIfPending()
                return
            }
            guard await saveAs(document, to: url) else {
                resolveTerminationIfPending()
                return
            }
        } else {
            do {
                try await document.save()
            } catch {
                lastError = "Save failed: \(error)"
                resolveTerminationIfPending()
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
        resolveTerminationIfPending()
    }

    func discardAndClose(_ document: MarkdownDocument) {
        pendingClose = nil
        remove(document)
        resolveTerminationIfPending()
    }

    func cancelPendingClose() {
        pendingClose = nil
        resolveTerminationIfPending()
    }

    /// The close alert dismissed itself. Its button action owns the actual
    /// decision, so dropping the presentation state must not cancel a quit
    /// whose Save is still in flight.
    func dismissCloseAlert() {
        pendingClose = nil
    }

    /// Finishes a quit that was waiting for the close alert. A failure to
    /// clear every dirty document resolves to "do not quit" rather than
    /// leaving the application waiting forever.
    private func resolveTerminationIfPending() {
        guard let completion = onTerminationResolved, pendingClose == nil else {
            return
        }
        let allowed = !hasDirtyDocuments
        onTerminationResolved = nil
        completion(allowed)
    }

    private func remove(_ document: MarkdownDocument) {
        let id = document.id
        document.markClosed()
        watchers[id]?.stop()
        watchers.removeValue(forKey: id)
        editorCache.remove(for: id)
        documents.removeAll { $0.id == id }
        scrollTargets.removeValue(forKey: id)
        autosaveRetryAfter.removeValue(forKey: id)
        autosaveFailures.removeValue(forKey: id)
        // The parse service otherwise retains this document's AST, heading
        // index, and source for the life of the process.
        Task { await parseService.release(documentID: id) }

        if selectedDocumentID == id {
            selectedDocumentID = documents.first?.id
        }
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
            autosaveRetryAfter.removeValue(forKey: document.id)
            autosaveFailures.removeValue(forKey: document.id)
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
        defer { releaseDestination(reservation) }
        do {
            try await document.saveAs(to: target)
            startWatcher(for: document)
            registerWorkspaceFile(target)
            lastError = nil
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
        guard !reservedDestinations.contains(key) else {
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
            selectedDocumentID = existing.id
            lastError = "That file is already open in another tab."
            return nil
        }
        reservedDestinations.insert(key)
        return key
    }

    private func releaseDestination(_ key: String) {
        reservedDestinations.remove(key)
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
        editorCache.entry(
            for: document,
            parseService: parseService
        ).controller
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
        workspaceRoot = root
        workspaceWatcher?.stop()

        // Basename wiki resolution must see files added to nested folders
        // while the workspace is open.
        let watcher = WorkspaceDirectoryWatcher(path: root.path) { [weak self] in
            Task { @MainActor in
                self?.scheduleWorkspaceRescan()
            }
        }
        watcher.start()
        workspaceWatcher = watcher

        await rescanWorkspaceIndex(root: root)
    }

    /// Rebuilds the index off the main actor. A scan that finishes after a
    /// newer one has started is discarded.
    private func rescanWorkspaceIndex(root: URL) async {
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
                    selectedDocumentID = document.id
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
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                let now = Date()
                let due = self.documents.filter {
                    if let retry = self.autosaveRetryAfter[$0.id], retry > now {
                        return false
                    }
                    guard let delay = $0.autosaveDelay(now: now) else {
                        return false
                    }
                    return delay <= 0
                }
                for document in due {
                    // A conflict must never be overwritten by autosave.
                    guard document.conflict == nil else { continue }
                    // The document may have been closed while an earlier
                    // await in this batch was running.
                    guard self.documents.contains(where: {
                        $0.id == document.id
                    }) else {
                        continue
                    }
                    do {
                        try await document.save()
                        self.autosaveRetryAfter.removeValue(forKey: document.id)
                        self.autosaveFailures.removeValue(forKey: document.id)
                    } catch let error as DocumentError where error == .closed {
                        continue
                    } catch {
                        // Surface the failure and back off instead of
                        // retrying the same failing write every 500 ms.
                        let failures = (self.autosaveFailures[document.id] ?? 0) + 1
                        self.autosaveFailures[document.id] = failures
                        let delay = min(
                            30.0,
                            pow(2.0, Double(min(failures, 5)))
                        )
                        self.autosaveRetryAfter[document.id] = Date()
                            .addingTimeInterval(delay)
                        self.lastError = "Autosave failed: \(error)"
                    }
                }
            }
        }
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
