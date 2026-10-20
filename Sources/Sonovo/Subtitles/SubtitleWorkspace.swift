import AppKit
import Foundation
import Observation
import SonovoCore
import UniformTypeIdentifiers

/// The active subtitle workspace, reachable by the app delegate for quit
/// flushing.
@MainActor
enum SubtitleWorkspaceRegistry {
    static weak var active: SubtitleWorkspace?
}

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
    /// The player serves the selected document; media is attached per
    /// document, so switching documents reloads it.
    let player = SubtitleMediaPlayer()

    private var watchers: [UUID: MarkdownFileWatcher] = [:]
    private var sourceEditors: [UUID: SubtitleSourceEditorController] = [:]
    private var autosaveTask: Task<Void, Never>?
    private var autosaveRetryAfter: [UUID: Date] = [:]
    private var autosaveFailures: [UUID: Int] = [:]

    var selectedDocument: SubtitleDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    var hasDirtyDocuments: Bool {
        documents.contains(where: \.isDirty)
    }

    init(store: SubtitleFileStore = SubtitleFileStore()) {
        self.store = store
        self.previewMode = SubtitlePreviewMode.stored(
            UserDefaults.standard.string(forKey: Self.previewModeKey)
        )
        SubtitleWorkspaceRegistry.active = self
        startAutosaveLoop()

        let environment = ProcessInfo.processInfo.environment
        if let rawPreview = environment["SONOVO_DEMO_SUBTITLE_PREVIEW"] {
            previewMode = SubtitlePreviewMode.stored(rawPreview)
        }
        if let path = environment["SONOVO_DEMO_SUBTITLE"] {
            _ = open(url: URL(fileURLWithPath: path))
        }
        if environment["SONOVO_DEMO_SUBTITLE_MODE"] == "source",
           let document = selectedDocument {
            document.mode = .source
        }
        if let path = environment["SONOVO_DEMO_MEDIA"],
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
    }

    func close(_ document: SubtitleDocument) async {
        let outcome = await document.flushForClose()
        switch outcome {
        case .closed:
            remove(document)
        case let .needsDecision(blocker):
            switch blocker {
            case let .saveFailed(message):
                lastError = "Save failed: \(message)"
            case .untitled:
                lastError = "The subtitle file has no path."
            }
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
        mediaURLs.removeValue(forKey: id)
        autosaveRetryAfter.removeValue(forKey: id)
        autosaveFailures.removeValue(forKey: id)
        documents.removeAll { $0.id == id }

        if selectedDocumentID == id {
            selectedDocumentID = documents.first?.id
            syncPlayer()
        }
    }

    // MARK: - Saving

    func save(_ document: SubtitleDocument) async {
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

    func flushAllForTermination() async -> Bool {
        for _ in 0..<3 {
            for document in documents where document.isDirty {
                let outcome = await document.flushForClose()
                if case let .needsDecision(blocker) = outcome {
                    selectedDocumentID = document.id
                    switch blocker {
                    case let .saveFailed(message):
                        lastError = "Save failed: \(message)"
                    case .untitled:
                        lastError = "The subtitle file has no path."
                    }
                    return false
                }
            }
            if !documents.contains(where: \.isDirty) {
                return true
            }
        }
        lastError = "Some subtitle files could not be saved before closing."
        return !documents.contains(where: \.isDirty)
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
            Task { await player.open(url: target) }
        }
    }

    func detachMedia(for document: SubtitleDocument) {
        mediaURLs.removeValue(forKey: document.id)
        if selectedDocumentID == document.id {
            player.close()
        }
    }

    private func syncPlayer() {
        guard let document = selectedDocument,
              let url = mediaURLs[document.id] else {
            if player.url != nil {
                player.close()
            }
            return
        }
        if player.url != url {
            Task { await player.open(url: url) }
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
                    reloadNotice = "Reloaded changes written by another app."
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
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                let now = Date()
                let due = self.documents.filter {
                    if let retry = self.autosaveRetryAfter[$0.id],
                       retry > now {
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
                    guard self.documents.contains(where: {
                        $0.id == document.id
                    }) else {
                        continue
                    }
                    do {
                        try await document.save()
                        self.autosaveRetryAfter.removeValue(
                            forKey: document.id
                        )
                        self.autosaveFailures.removeValue(forKey: document.id)
                    } catch let error as SubtitleDocumentError
                        where error == .closed {
                        continue
                    } catch {
                        let failures =
                            (self.autosaveFailures[document.id] ?? 0) + 1
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

    private static let previewModeKey = "sonovo.subtitlePreviewMode"

    private static var subtitleTypes: [UTType] {
        ["srt", "vtt", "ass", "ssa"].compactMap {
            UTType(filenameExtension: $0)
        }
    }
}
