import AppKit
import Foundation
import Observation
import SonovoCore
import UniformTypeIdentifiers

/// Whether the video surface is shown at all. Collapsed is the default: the
/// cue text is the work, and the player remains available in the floating bar.
enum SubtitlePreviewMode: String, Sendable, CaseIterable {
    case collapsed
    case expanded

    static func stored(_ raw: String?) -> SubtitlePreviewMode {
        switch raw {
        case "expanded", "stage":
            .expanded
        case "collapsed", "mini":
            .collapsed
        default:
            .collapsed
        }
    }
}

/// Owns open subtitle documents, their watchers, autosave, and the preview
/// player for the selected document.
@MainActor
@Observable
final class SubtitleWorkspace {
    private let store: SubtitleFileStore

    private(set) var documents: [SubtitleDocument] = []
    var selectedDocumentID: UUID?
    private(set) var mediaURLs: [UUID: URL] = [:]
    private(set) var reloadNotice: String?

    var previewMode: SubtitlePreviewMode {
        didSet {
            UserDefaults.standard.set(
                previewMode.rawValue,
                forKey: Self.previewModeKey
            )
        }
    }

    var lastError: String?
    /// Called after a document is removed so the owning project can remove
    /// the matching tab.
    var onDocumentClosed: ((URL) -> Void)?
    /// A selection change made inside the workspace. The owning project
    /// keeps its tab, breadcrumb, and persisted selection on the same file.
    var onDocumentActivated: ((URL) -> Void)?
    /// Whether another workspace of the project holds a Save As reservation.
    var isDestinationReserved: ((String) -> Bool)?
    /// Whether another workspace already owns this path.
    var isPathOwnedElsewhere: ((String) -> Bool)?
    /// The player serves the selected document; media is attached per
    /// document, so switching documents reloads it.
    let player = SubtitleMediaPlayer()

    /// A hidden project must not keep playing its media. Position and item
    /// remain; only the transport stops.
    func pauseForDeactivation() {
        player.pause()
    }

    private var watchers: [UUID: MarkdownFileWatcher] = [:]
    private var mediaOpenTasks: [UUID: Task<Void, Never>] = [:]
    private var sourceEditors: [UUID: SubtitleSourceEditorController] = [:]
    @ObservationIgnored
    private var autosave: AutosaveDriver<SubtitleDocument>!

    var selectedDocument: SubtitleDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    var hasDirtyDocuments: Bool {
        documents.contains { $0.isDirty || $0.hasPendingDraft }
    }

    init(
        store: SubtitleFileStore = SubtitleFileStore(),
        readsDemoEnvironment: Bool = true
    ) {
        self.store = store
        self.previewMode = SubtitlePreviewMode.stored(
            UserDefaults.standard.string(forKey: Self.previewModeKey)
        )
        autosave = AutosaveDriver(
            documents: { [weak self] in self?.documents ?? [] },
            reportsError: { [weak self] message in
                self?.lastError = message
            }
        )
        startAutosaveLoop()

        let environment = ProcessInfo.processInfo.environment
        if readsDemoEnvironment,
           let rawPreview = environment["SONOVO_DEMO_SUBTITLE_PREVIEW"] {
            previewMode = SubtitlePreviewMode.stored(rawPreview)
        }
        if readsDemoEnvironment,
           let path = environment["SONOVO_DEMO_SUBTITLE"] {
            _ = open(url: URL(fileURLWithPath: path))
        }
        if readsDemoEnvironment,
           environment["SONOVO_DEMO_SUBTITLE_MODE"] == "source",
           let document = selectedDocument {
            document.mode = .source
        }
        if readsDemoEnvironment,
           let path = environment["SONOVO_DEMO_MEDIA"],
           let document = selectedDocument {
            attachMedia(URL(fileURLWithPath: path), to: document)
        }
    }

    // MARK: - Documents

    @discardableResult
    func open(url: URL) -> SubtitleDocument? {
        let target = MarkdownSecurity.canonical(url)
        let key = target.path
        if let existing = documents.first(where: {
            MarkdownSecurity.canonical($0.fileURL).path == key
        }) {
            select(existing)
            return existing
        }
        guard isDestinationReserved?(key) != true else {
            // A Save As in another workspace is still writing this path.
            lastError = "That file is being saved in another tab."
            return nil
        }
        guard isPathOwnedElsewhere?(key) != true else {
            lastError = "That file is already open in another tab."
            return nil
        }

        do {
            let document = try SubtitleDocument(loading: target, store: store)
            documents.append(document)
            startWatcher(for: document)
            select(document)
            return document
        } catch {
            lastError = "Cannot open \(target.lastPathComponent): \(error)"
            return nil
        }
    }

    func select(_ document: SubtitleDocument) {
        selectedDocumentID = document.id
        reloadNotice = nil
        syncPlayer()
        onDocumentActivated?(document.fileURL)
    }

    /// Returns true only when the document was actually closed.
    @discardableResult
    func close(_ document: SubtitleDocument) async -> Bool {
        let outcome = await document.flushForClose()
        switch outcome {
        case .closed:
            remove(document)
            return true
        case let .needsDecision(blocker):
            report(blocker)
            return false
        }
    }

    private func report(_ blocker: CloseBlocker) {
        switch blocker {
        case let .saveFailed(message):
            lastError = "Save failed: \(message)"
        case .untitled:
            lastError = "The subtitle file has no path."
        }
    }

    func closeSelected() async {
        guard let document = selectedDocument else { return }
        await close(document)
    }

    // MARK: - Editing

    /// Applies one cue edit and surfaces a failure where the user can see it.
    @discardableResult
    func apply(
        _ edit: SubtitleEdit,
        to document: SubtitleDocument
    ) async -> SubtitleEditResult? {
        do {
            return try await document.apply(edit)
        } catch {
            lastError = "Edit failed: \(error)"
            return nil
        }
    }

    /// Applies a typed draft; nil means the cue changed underneath it.
    @discardableResult
    func applyDraft(
        text: String,
        ordinal: Int,
        baseText: String,
        revision: UInt64,
        to document: SubtitleDocument
    ) async -> SubtitleEditResult? {
        do {
            return try await document.applyDraft(
                ordinal: ordinal,
                text: text,
                baseText: baseText,
                revision: revision
            )
        } catch {
            lastError = "Edit failed: \(error)"
            return nil
        }
    }

    func seek(toMilliseconds milliseconds: Int) {
        guard player.isReady else { return }
        player.seek(toMilliseconds: max(0, milliseconds))
    }

    func sourceController(
        for document: SubtitleDocument
    ) -> SubtitleSourceEditorController {
        if let existing = sourceEditors[document.id] {
            return existing
        }
        let controller = SubtitleSourceEditorController(document: document)
        sourceEditors[document.id] = controller
        return controller
    }

    private func remove(_ document: SubtitleDocument) {
        let id = document.id
        document.markClosed()
        watchers[id]?.stop()
        watchers.removeValue(forKey: id)
        sourceEditors.removeValue(forKey: id)
        mediaOpenTasks.removeValue(forKey: id)?.cancel()
        mediaURLs.removeValue(forKey: id)
        autosave.forget(id)
        documents.removeAll { $0.id == id }

        if selectedDocumentID == id {
            selectedDocumentID = documents.first?.id
            syncPlayer()
        }
        onDocumentClosed?(document.fileURL)
    }

    // MARK: - Saving

    func save(_ document: SubtitleDocument) async {
        do {
            // A Save while a cue draft is open must include the words on
            // screen; the draft is not part of the source yet.
            if document.hasPendingDraft {
                guard await document.commitPendingDraft() else {
                    lastError = "Save failed: the cue draft conflicts with "
                        + "the file on disk."
                    return
                }
            }
            // A user Save is explicit: it may recreate a file deleted on
            // disk. Autosave keeps the automatic mode and refuses.
            try await document.save(mode: .explicitOverwrite)
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

    func flushAllForTermination() async -> Bool {
        for _ in 0..<3 {
            for document in documents
            where document.isDirty || document.hasPendingDraft {
                let outcome = await document.flushForClose()
                if case let .needsDecision(blocker) = outcome {
                    selectedDocumentID = document.id
                    report(blocker)
                    return false
                }
            }
            if !documents.contains(where: {
                $0.isDirty || $0.hasPendingDraft
            }) {
                return true
            }
        }
        lastError = "Some subtitle files could not be saved before closing."
        return !documents.contains(where: {
            $0.isDirty || $0.hasPendingDraft
        })
    }

    // MARK: - Media

    func togglePreviewMode() {
        previewMode = previewMode == .collapsed ? .expanded : .collapsed
    }

    func mediaURL(for document: SubtitleDocument) -> URL? {
        mediaURLs[document.id]
    }

    func attachMedia(_ url: URL, to document: SubtitleDocument) {
        let target = MarkdownSecurity.canonical(url)
        mediaURLs[document.id] = target
        if selectedDocumentID == document.id {
            openMedia(target, for: document)
        }
    }

    func detachMedia(for document: SubtitleDocument) {
        mediaOpenTasks.removeValue(forKey: document.id)?.cancel()
        mediaURLs.removeValue(forKey: document.id)
        if selectedDocumentID == document.id {
            player.close()
        }
    }

    private func syncPlayer() {
        // A queued open for another document must not run after the user
        // has already selected a document without media.
        for (id, task) in mediaOpenTasks
        where id != selectedDocument?.id {
            task.cancel()
            mediaOpenTasks[id] = nil
        }
        guard let document = selectedDocument,
              let url = mediaURLs[document.id] else {
            if player.url != nil {
                player.close()
            }
            return
        }
        if player.url != url {
            openMedia(url, for: document)
        }
    }

    private func openMedia(_ url: URL, for document: SubtitleDocument) {
        mediaOpenTasks[document.id]?.cancel()
        mediaOpenTasks[document.id] = Task { @MainActor [weak self, weak document] in
            guard let self,
                  let document,
                  !Task.isCancelled,
                  self.selectedDocumentID == document.id,
                  self.mediaURLs[document.id] == url else {
                return
            }
            await self.player.open(url: url)
        }
    }

    // MARK: - External changes

    private func startWatcher(for document: SubtitleDocument) {
        let url = document.fileURL
        watchers[document.id]?.stop()
        let id = document.id
        let watcher = MarkdownFileWatcher(fileURL: url) { [weak self] in
            Task { @MainActor in
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
        Task { @MainActor in
            do {
                let change = try await document.checkExternalChange()
                switch change {
                case .adopted:
                    // The notice is displayed above the selected document;
                    // a background file's reload must not appear there.
                    if selectedDocumentID == id {
                        reloadNotice =
                            "Reloaded changes written by another app."
                    }
                case .deleted:
                    lastError = "The file was deleted on disk: "
                        + document.fileURL.lastPathComponent
                case .conflict, .none:
                    break
                }
            } catch {
                lastError = "Cannot re-read "
                    + "\(document.fileURL.lastPathComponent): \(error)"
            }
        }
    }

    func reload(_ document: SubtitleDocument) {
        document.resolveExternalChange(.reload)
        reloadNotice = nil
    }

    func keepLocal(_ document: SubtitleDocument) {
        document.resolveExternalChange(.keepLocal)
    }

    func dismissReloadNotice() {
        reloadNotice = nil
    }

    func dismissError() {
        lastError = nil
    }

    // MARK: - Panels

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.subtitleTypes
        if panel.runModal() == .OK {
            for url in panel.urls {
                open(url: url)
            }
        }
    }

    func presentOpenMediaPanel(for document: SubtitleDocument) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audiovisualContent]
        if panel.runModal() == .OK, let url = panel.urls.first {
            attachMedia(url, to: document)
        }
    }

    // MARK: - Autosave

    private func startAutosaveLoop() {
        autosave.start()
    }

    // MARK: - Utilities

    private static let previewModeKey = "sonovo.subtitlePreviewMode"

    private static var subtitleTypes: [UTType] {
        ["srt", "vtt", "ass", "ssa"].compactMap {
            UTType(filenameExtension: $0)
        }
    }
}
