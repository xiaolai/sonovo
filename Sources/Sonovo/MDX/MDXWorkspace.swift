import Foundation
import Observation
import SonovoCore
import SonovoMDXKit

/// Hosts MDX documents. It is deliberately separate from `MarkdownWorkspace`:
/// `.md` handling, canonical-source rules, and every Markdown feature stay
/// untouched, and a compiled preview never writes a file.
@MainActor
@Observable
final class MDXWorkspace {
    enum PreviewState: Equatable {
        case idle
        case compiling
        case ready([MDXCompiledModule])
        case failed(MDXCompileDiagnostic)
        /// The helper, the sandbox, or the graph resolver failed for a
        /// reason that is not a compile diagnostic.
        case unavailable(String)
    }

    private(set) var documents: [MDXDocument] = []
    var selectedDocumentID: UUID?
    var workspaceRoot: URL?

    /// Preview is opt-in for the whole workspace, not per file, and it stays
    /// off until the user turns it on.
    private(set) var previewEnabled = false
    private(set) var previewStates: [UUID: PreviewState] = [:]
    private(set) var lastError: String?

    /// A document whose close needs a save/discard decision. The app-level
    /// alert resolves it through `saveAndClose` / `discardAndClose`.
    private(set) var pendingClose: MDXDocument?

    var onDocumentClosed: ((MDXDocument) -> Void)?
    var onDocumentActivated: ((URL) -> Void)?

    private let service: MDXCompileService
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    private var compileTasks: [UUID: Task<Void, Never>] = [:]
    /// Bumped for each new compile of a document; only the matching task may
    /// publish a result.
    private var compileGeneration: [UUID: Int] = [:]

    init(service: MDXCompileService? = nil) {
        self.service = service ?? MDXCompileService.live()
    }

    var selectedDocument: MDXDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    var hasDirtyDocuments: Bool {
        documents.contains { $0.isDirty }
    }

    func setWorkspaceRoot(_ root: URL?) {
        workspaceRoot = root.map(MarkdownSecurity.canonical)
    }

    func dismissError() {
        lastError = nil
    }

    // MARK: - Opening and selection

    @discardableResult
    func open(url: URL) -> MDXDocument? {
        let canonical = MarkdownSecurity.canonical(url)
        if let existing = documents.first(where: {
            MarkdownSecurity.canonical($0.fileURL) == canonical
        }) {
            select(existing)
            return existing
        }
        guard let root = workspaceRoot else {
            lastError = "This workspace has no project folder."
            return nil
        }
        do {
            let document = try MDXDocument.load(url: canonical, projectRoot: root)
            documents.append(document)
            select(document)
            return document
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func select(_ document: MDXDocument) {
        guard documents.contains(where: { $0 === document }) else { return }
        selectedDocumentID = document.id
        onDocumentActivated?(document.fileURL)
        scheduleCompile(document)
    }

    // MARK: - Saving and closing

    func save(_ document: MDXDocument) async {
        do {
            try document.save()
        } catch {
            lastError = "The document could not be saved: "
                + error.localizedDescription
        }
    }

    func saveSelected() async {
        guard let document = selectedDocument else { return }
        await save(document)
    }

    /// Returns true only when the document is gone. A dirty document stays
    /// and becomes the pending close decision.
    func close(_ document: MDXDocument) async -> Bool {
        guard documents.contains(where: { $0 === document }) else {
            return true
        }
        guard !document.isDirty else {
            pendingClose = document
            return false
        }
        remove(document)
        return true
    }

    func saveAndClose(_ document: MDXDocument) async {
        do {
            try document.save()
        } catch {
            lastError = "The document could not be saved: "
                + error.localizedDescription
            return
        }
        pendingClose = nil
        remove(document)
    }

    func discardAndClose(_ document: MDXDocument) {
        pendingClose = nil
        remove(document)
    }

    func cancelPendingClose() {
        pendingClose = nil
    }

    private func remove(_ document: MDXDocument) {
        guard let index = documents.firstIndex(where: { $0 === document })
        else { return }
        debounceTasks[document.id]?.cancel()
        debounceTasks[document.id] = nil
        compileTasks[document.id]?.cancel()
        compileTasks[document.id] = nil
        previewStates[document.id] = nil
        documents.remove(at: index)
        if selectedDocumentID == document.id {
            let next = documents.indices.contains(index)
                ? documents[index]
                : documents.last
            selectedDocumentID = next?.id
        }
        onDocumentClosed?(document)
    }

    // MARK: - Preview

    func setPreviewEnabled(_ enabled: Bool) {
        guard previewEnabled != enabled else { return }
        previewEnabled = enabled
        if enabled {
            if let document = selectedDocument {
                scheduleCompile(document)
            }
            return
        }
        for task in debounceTasks.values { task.cancel() }
        debounceTasks.removeAll()
        for task in compileTasks.values { task.cancel() }
        compileTasks.removeAll()
        previewStates.removeAll()
    }

    /// Coalesces keystroke-driven compiles. The source revision check in
    /// `compileNow` discards any result that arrived after a newer edit.
    func scheduleCompile(_ document: MDXDocument) {
        guard previewEnabled,
              documents.contains(where: { $0 === document }) else {
            return
        }
        debounceTasks[document.id]?.cancel()
        debounceTasks[document.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.compileNow(document)
        }
    }

    /// Compiles now. The UI schedules this after a short debounce; tests call
    /// it directly and await the state change.
    func compileNow(_ document: MDXDocument) async {
        guard previewEnabled,
              documents.contains(where: { $0 === document }),
              let root = workspaceRoot else {
            return
        }
        let id = document.id
        let revision = document.revision
        previewStates[id] = .compiling
        // Only the newest compile may publish. Cancelling the previous task
        // stops its helper; the generation stops it even if cancellation
        // lands mid-flight.
        compileTasks[id]?.cancel()
        compileGeneration[id, default: 0] += 1
        let generation = compileGeneration[id] ?? 0
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.service.compile(
                    entryID: document.relativePath,
                    source: document.source,
                    projectRoot: root
                )
                guard !Task.isCancelled,
                      self.isCurrent(
                          document,
                          revision: revision,
                          generation: generation,
                          id: id
                      ) else {
                    return
                }
                if response.ok {
                    self.previewStates[id] = .ready(response.modules)
                } else {
                    self.previewStates[id] = .failed(
                        response.diagnostic
                            ?? MDXCompileDiagnostic(
                                message: "MDX compilation failed."
                            )
                    )
                }
            } catch let error as MDXImportGraphError {
                guard !Task.isCancelled,
                      self.isCurrent(
                          document,
                          revision: revision,
                          generation: generation,
                          id: id
                      ) else {
                    return
                }
                if case .compileFailed(let diagnostic) = error {
                    self.previewStates[id] = .failed(diagnostic)
                } else {
                    self.previewStates[id] = .unavailable(
                        error.localizedDescription
                    )
                }
            } catch {
                guard !Task.isCancelled,
                      self.isCurrent(
                          document,
                          revision: revision,
                          generation: generation,
                          id: id
                      ) else {
                    return
                }
                self.previewStates[id] = .unavailable(
                    error.localizedDescription
                )
            }
        }
        compileTasks[id] = task
        await task.value
    }

    func previewState(for document: MDXDocument) -> PreviewState {
        previewStates[document.id] ?? .idle
    }

    private func isCurrent(
        _ document: MDXDocument,
        revision: UInt64,
        generation: Int,
        id: UUID
    ) -> Bool {
        // Disabling the preview clears every state; a task that was already
        // running when that happened must not put a result back.
        previewEnabled
            && compileGeneration[id] == generation
            && documents.contains(where: { $0 === document })
            && document.revision == revision
    }

    // MARK: - Lifecycle

    /// Saves every dirty document. Returns false when one could not be
    /// written; that document becomes the pending close decision so the
    /// app-level alert can show it.
    func flushAllForTermination() async -> Bool {
        for document in documents where document.isDirty {
            do {
                try document.save()
            } catch {
                lastError = "The document could not be saved: "
                    + error.localizedDescription
                pendingClose = document
                return false
            }
        }
        return true
    }

    func prepareForTermination() {
        for task in debounceTasks.values { task.cancel() }
        debounceTasks.removeAll()
        for task in compileTasks.values { task.cancel() }
        compileTasks.removeAll()
    }
}
