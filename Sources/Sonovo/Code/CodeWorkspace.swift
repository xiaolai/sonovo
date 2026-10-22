import AppKit
import Foundation
import Observation
import SonovoCore
import UniformTypeIdentifiers

/// Owns the open code documents, their watchers, autosave, close decisions,
/// and the retained editor controllers.
///
/// Code keeps exact-change semantics: a save carries the exact bytes it was
/// based on, and an external change is compared byte for byte. There is no
/// soft equality and no silent overwrite.
@MainActor
@Observable
final class CodeWorkspace {
    private let store: MarkdownFileStore
    private let reader: CodeFileReader
    let editorCache: CodeEditorCache

    private(set) var documents: [CodeDocument] = []
    var selectedDocumentID: UUID?
    private(set) var workspaceRoot: URL?
    private(set) var workspaceFiles: [URL] = []
    /// The search query belongs to the workspace: switching tabs keeps it,
    /// relaunching does not.
    var searchQuery = ""

    var lastError: String?
    var pendingClose: CodeDocument?
    /// A Save As destination whose overwrite the user must confirm.
    private(set) var pendingOverwrite: CodeOverwriteRequest?
    private(set) var reloadNotices: [UUID: String] = [:]

    var onDocumentClosed: ((CodeDocument) -> Void)?
    var onDocumentActivated: ((URL) -> Void)?
    var onDocumentMoved: ((URL, URL) -> Void)?
    /// Answers whether a path is already open in any workspace of the project.
    var isPathOwned: ((String, UUID) -> Bool)?
    /// Whether any workspace of the project already owns a document at the
    /// path. `open` has no document yet, so it cannot exclude an id.
    var isPathOwnedAnywhere: ((String) -> Bool)?
    /// Reserves a Save As destination across every workspace of the project.
    /// Returns false when another reservation already holds it.
    var reserveDestination: ((String, UUID) -> Bool)?
    var releaseDestination: ((String, UUID) -> Void)?
    /// Whether any workspace holds a Save As reservation for a path.
    var isDestinationReserved: ((String) -> Bool)?

    private(set) var isProjectVisible = false
    private var watchers: [UUID: MarkdownFileWatcher] = [:]
    private var loadTasks: [UUID: Task<Void, Never>] = [:]
    private var navigationTask: Task<Void, Never>?
    private var navigationGeneration: UInt64 = 0
    private var reservedDestinations: Set<String> = []
    private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored
    private var autosave: AutosaveDriver<CodeDocument>!

    struct CodeOverwriteRequest: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let expected: DiskSnapshot
    }

    init(
        store: MarkdownFileStore = MarkdownFileStore(),
        reader: CodeFileReader = CodeFileReader(),
        editorCache: CodeEditorCache = CodeEditorCache(),
        readsDemoEnvironment: Bool = true
    ) {
        self.store = store
        self.reader = reader
        self.editorCache = editorCache
        autosave = AutosaveDriver(
            documents: { [weak self] in self?.documents ?? [] },
            reportsError: { [weak self] message in
                self?.lastError = message
            }
        )
        autosave.start()

        if readsDemoEnvironment,
           let path = ProcessInfo.processInfo.environment["SONOVO_DEMO_CODE"] {
            _ = open(url: URL(fileURLWithPath: path))
        }
    }

    var selectedDocument: CodeDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    var hasDirtyDocuments: Bool {
        documents.contains {
            $0.isDirty || $0.hasQueuedConflictResolution
        }
    }

    func dismissError() {
        lastError = nil
    }

    // MARK: - Root and discovery

    func setWorkspaceRoot(_ root: URL?) {
        guard workspaceRoot != root else { return }
        workspaceRoot = root
        discoveryTask?.cancel()
        workspaceFiles = []
        guard let root else { return }
        discoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let task = Task.detached(priority: .utility) {
                CodeWorkspace.codeFiles(in: root)
            }
            let files = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled, self.workspaceRoot == root else {
                return
            }
            self.workspaceFiles = files
        }
    }

    /// Filename-based discovery. Hidden files and ignored directories are
    /// excluded here and again at read/search time.
    nonisolated static func codeFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var files: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            if Task.isCancelled {
                break
            }
            visited += 1
            if visited > CodeLimits.discoveryVisitedEntries
                || files.count >= CodeLimits.discoveryFiles {
                break
            }
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            if values?.isDirectory == true {
                if values?.isSymbolicLink == true
                    || ProjectPathPolicy.isIgnoredDirectory(
                        url.lastPathComponent
                    ) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isSymbolicLink != true else { continue }
            guard CodeLanguage.language(forFilename: url.lastPathComponent)
                != nil else {
                continue
            }
            files.append(url.standardizedFileURL)
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Documents

    @discardableResult
    func open(url: URL) -> CodeDocument? {
        let target = MarkdownSecurity.canonical(url)
        if let root = workspaceRoot,
           !ProjectPathPolicy.isAllowed(target, in: root) {
            lastError = "That file is outside this project."
            return nil
        }
        let key = target.path
        if let existing = documents.first(where: {
            MarkdownSecurity.canonical($0.fileURL).path == key
        }) {
            select(existing)
            return existing
        }
        guard !reservedDestinations.contains(key),
              isDestinationReserved?(key) != true else {
            lastError = "That file is being saved in another tab."
            return nil
        }
        if isPathOwnedAnywhere?(key) == true {
            // One document per path across every workspace; opening a
            // second model would give two autosave owners.
            lastError = "That file is already open in another tab."
            return nil
        }

        let document = CodeDocument(
            url: target,
            store: store,
            reader: reader
        )
        documents.append(document)
        select(document)
        startWatcher(for: document)
        startLoad(document)
        return document
    }

    private func startLoad(_ document: CodeDocument) {
        loadTasks[document.id]?.cancel()
        loadTasks[document.id] = Task { @MainActor [weak self, weak document] in
            guard let document else { return }
            await document.load()
            guard !Task.isCancelled, let self else { return }
            self.loadTasks[document.id] = nil
            guard !document.isClosed else { return }
            if let error = document.lastError {
                self.lastError = error
            }
        }
    }

    // MARK: - Search navigation

    private static let searchNavigationTimeout: TimeInterval = 15

    /// Opens a search result and moves the caret to the match. The task
    /// belongs to the workspace, not to the search sheet: dismissing the
    /// sheet must not cancel a navigation that is still waiting for the
    /// document to load.
    func openSearchMatch(_ match: CodeSearchMatch) {
        guard let document = open(url: match.url) else { return }
        let controller = controller(for: document)
        navigationTask?.cancel()
        navigationGeneration &+= 1
        let generation = navigationGeneration
        navigationTask = Task { @MainActor [weak self, weak document] in
            guard let self, let document else { return }
            // A cancelled predecessor must not clear its successor's handle;
            // only the current generation owns it.
            defer {
                if self.navigationGeneration == generation {
                    self.navigationTask = nil
                }
            }
            let deadline = Date().addingTimeInterval(
                Self.searchNavigationTimeout
            )
            while !document.isReady,
                  !document.isClosed,
                  document.refusal == nil,
                  Date() < deadline {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !Task.isCancelled, document.isReady else {
                if !Task.isCancelled,
                   document.refusal == nil,
                   self.selectedDocumentID == document.id {
                    self.lastError =
                        "The file did not finish opening in time."
                }
                return
            }
            // The user may have switched tabs while the file loaded; do not
            // pull the caret in a file they are no longer looking at.
            guard self.selectedDocumentID == document.id else { return }
            controller.goToOffset(
                document.offset(line: match.line, column: match.column)
            )
        }
    }

    func select(_ document: CodeDocument) {
        selectedDocumentID = document.id
        onDocumentActivated?(document.fileURL)
    }

    /// Test seam for the close/save race matrix.
    @ObservationIgnored var closeHooks: SaveHooks?

    /// Returns true only when the document actually closed.
    @discardableResult
    func close(_ document: CodeDocument) async -> Bool {
        let outcome = await document.flushForClose(hooks: closeHooks)
        switch outcome {
        case .closed:
            remove(document)
            return true
        case .needsDecision:
            if pendingClose == nil || pendingClose === document {
                pendingClose = document
            }
            return false
        }
    }

    func saveAndClose(_ document: CodeDocument) async {
        do {
            try await document.save(mode: .automatic)
        } catch {
            lastError = "Save failed: \(error)"
            return
        }
        guard !document.isDirty else {
            pendingClose = document
            lastError = "The document changed while saving; save again."
            return
        }
        pendingClose = nil
        remove(document)
    }

    func discardAndClose(_ document: CodeDocument) {
        pendingClose = nil
        remove(document)
    }

    func cancelPendingClose() {
        pendingClose = nil
    }

    func dismissCloseAlert() {
        pendingClose = nil
    }

    private func remove(_ document: CodeDocument) {
        let id = document.id
        document.markClosed()
        if pendingClose === document {
            pendingClose = nil
        }
        watchers[id]?.stop()
        watchers.removeValue(forKey: id)
        loadTasks.removeValue(forKey: id)?.cancel()
        editorCache.remove(for: id)
        autosave.forget(id)
        reloadNotices.removeValue(forKey: id)
        documents.removeAll { $0.id == id }
        if selectedDocumentID == id {
            selectedDocumentID = documents.first?.id
        }
        onDocumentClosed?(document)
    }

    // MARK: - Saving

    func save(_ document: CodeDocument) async {
        do {
            try await document.save(mode: .automatic)
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

    func saveAsSelected() async {
        guard let document = selectedDocument else { return }
        await saveAs(document)
    }

    func saveAs(_ document: CodeDocument) async {
        guard let url = presentSavePanel(for: document) else { return }
        await saveAs(document, to: url)
    }

    @discardableResult
    func saveAs(_ document: CodeDocument, to url: URL) async -> Bool {
        await performSaveAs(document, to: url, overwrite: nil)
    }

    /// Completes a Save As after the user confirmed replacing the captured
    /// destination bytes.
    func confirmOverwrite(_ request: CodeOverwriteRequest) async {
        pendingOverwrite = nil
        guard let document = documents.first(where: {
            $0.id == request.id
        }) else { return }
        _ = await performSaveAs(
            document,
            to: request.url,
            overwrite: CodeOverwriteConfirmation(
                url: request.url,
                expected: request.expected
            )
        )
    }

    /// The one Save As path: boundary policy, project-level ownership, a
    /// reservation for the write, watcher replacement, and the move
    /// notification. A queued Save As uses the document's current identity
    /// because the move source is read only after the write completes.
    private func performSaveAs(
        _ document: CodeDocument,
        to url: URL,
        overwrite: CodeOverwriteConfirmation?
    ) async -> Bool {
        let target = MarkdownSecurity.canonical(url.standardizedFileURL)
        if let root = workspaceRoot,
           !ProjectPathPolicy.isAllowed(target, in: root) {
            lastError = "That destination is outside this project."
            return false
        }
        if isPathOwned?(target.path, document.id) == true {
            lastError = "That file is already open in another document."
            return false
        }
        let key = target.path
        // The project-wide reservation and the workspace's own set are
        // checked together, before any await: another workspace must not be
        // able to open this destination while the write is in flight.
        guard !reservedDestinations.contains(key),
              isDestinationReserved?(key) != true else {
            lastError = "That file is already being saved."
            return false
        }
        guard reserveDestination?(key, document.id) ?? true else {
            lastError = "That file is being saved in another tab."
            return false
        }
        reservedDestinations.insert(key)
        defer {
            reservedDestinations.remove(key)
            releaseDestination?(key, document.id)
        }

        do {
            try await document.saveAs(to: target, overwrite: overwrite)
            guard documents.contains(where: { $0 === document }),
                  !document.isClosed else {
                return false
            }
            startWatcher(for: document)
            lastError = nil
            if let previousURL = document.previousFileURL,
               previousURL != target {
                onDocumentMoved?(previousURL, target)
            }
            return true
        } catch CodeDocumentError.overwriteConfirmationRequired(
            let url,
            let expected
        ) {
            pendingOverwrite = CodeOverwriteRequest(
                id: document.id,
                url: url,
                expected: expected
            )
            return false
        } catch {
            lastError = "Save As failed: \(error)"
            return false
        }
    }

    func cancelOverwrite() {
        pendingOverwrite = nil
    }

    func flushAllForTermination() async -> Bool {
        for _ in 0..<3 {
            // A decision queued while another document was draining is
            // drained at the start of each pass.
            for document in documents {
                await document.waitForQueuedConflictResolution()
            }
            for document in documents where document.isDirty {
                let outcome = await document.flushForClose()
                if case .needsDecision = outcome {
                    selectedDocumentID = document.id
                    pendingClose = document
                    return false
                }
            }
            if !documents.contains(where: {
                $0.isDirty || $0.hasQueuedConflictResolution
            }) {
                return true
            }
        }
        lastError = "Some code files could not be saved before closing."
        return !documents.contains(where: {
            $0.isDirty || $0.hasQueuedConflictResolution
        })
    }

    // MARK: - External changes

    func setProjectVisible(_ visible: Bool) {
        isProjectVisible = visible
    }

    private func startWatcher(for document: CodeDocument) {
        watchers[document.id]?.stop()
        let id = document.id
        let watcher = MarkdownFileWatcher(fileURL: document.fileURL) {
            // Never call back synchronously on the watcher queue: stop()
            // waits for that queue while holding the main actor.
            Task { @MainActor [weak self] in
                self?.handleFileChange(id)
            }
        }
        watcher.start()
        watchers[document.id] = watcher
    }

    private func handleFileChange(_ id: UUID) {
        guard let document = documents.first(where: { $0.id == id }) else {
            return
        }
        Task { @MainActor [weak self, weak document] in
            guard let self, let document else { return }
            let change = await document.checkExternalChange(
                projectVisible: self.isProjectVisible
            )
            switch change {
            case .none:
                break
            case .adopted:
                if self.selectedDocumentID == id {
                    self.reloadNotices[id] = "Changed on disk. Reloaded."
                }
            case .pendingReview:
                self.reloadNotices[id] = "Changed on disk"
            case .conflict:
                self.reloadNotices[id] = "Changed on disk"
            case .deleted:
                self.lastError = "The file was deleted on disk: "
                    + document.displayName
            }
        }
    }

    func dismissNotice(for document: CodeDocument) {
        reloadNotices[document.id] = nil
    }

    func notice(for document: CodeDocument) -> String? {
        reloadNotices[document.id]
    }

    func captureReviewDiff(_ document: CodeDocument) {
        document.captureReviewDiff()
        document.viewMode = .unifiedDiff
        reloadNotices[document.id] = nil
    }

    func reload(_ document: CodeDocument) {
        // A conflict wins over a pending review. An edit followed by a failed
        // save can leave both; reverting is refused while the conflict is
        // open, so the conflict resolution must run first.
        if document.conflict != nil {
            if document.resolveConflictImmediately(.reload) {
                reloadNotices[document.id] = nil
                return
            }
            document.queueConflictResolution(.reload)
            reloadNotices[document.id] = nil
            return
        }
        if document.pendingReview {
            Task { @MainActor [weak self, weak document] in
                guard let self, let document else { return }
                do {
                    try await document.reloadPendingDiskChange()
                    self.reloadNotices[document.id] =
                        "Reloaded the disk version."
                } catch {
                    self.lastError = "Reload failed: \(error)"
                }
            }
        } else {
            reloadNotices[document.id] = nil
        }
    }

    func keepLocal(_ document: CodeDocument) {
        if document.resolveConflictImmediately(.keepLocal) { return }
        document.queueConflictResolution(.keepLocal)
    }

    func revertToDisk(_ document: CodeDocument) async {
        do {
            try await document.revertToDisk()
            document.viewMode = .source
            reloadNotices[document.id] = nil
        } catch {
            lastError = "Revert failed: \(error)"
        }
    }

    // MARK: - Panels and applications

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.openPanelTypes
        if let root = workspaceRoot {
            panel.directoryURL = root
        }
        if panel.runModal() == .OK {
            for url in panel.urls {
                open(url: url)
            }
        }
    }

    func presentSavePanel(for document: CodeDocument) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.displayName
        panel.directoryURL = document.fileURL.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    func openInDefaultApplication(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func controller(for document: CodeDocument) -> CodeEditorController {
        editorCache.controller(for: document)
    }

    // MARK: - Termination

    func prepareForTermination() {
        discoveryTask?.cancel()
        discoveryTask = nil
        navigationTask?.cancel()
        navigationTask = nil
        navigationGeneration &+= 1
        for watcher in watchers.values {
            watcher.stop()
        }
        watchers.removeAll()
        for task in loadTasks.values {
            task.cancel()
        }
        loadTasks.removeAll()
    }

    private static var openPanelTypes: [UTType] {
        var types: [UTType] = [.plainText, .sourceCode, .text]
        for fileExtension in CodeLanguage.extensions {
            if let type = UTType(filenameExtension: fileExtension) {
                types.append(type)
            }
        }
        return types
    }
}
