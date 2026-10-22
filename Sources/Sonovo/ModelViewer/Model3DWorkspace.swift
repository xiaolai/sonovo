import AppKit
import Foundation
import Observation
import SonovoCore
import UniformTypeIdentifiers

/// Owns the open models, their file watches, and the explicit Blender
/// conversions. There is no save path: closing a model only stops work and
/// removes temporary output.
@MainActor
@Observable
final class Model3DWorkspace {
    private(set) var documents: [Model3DDocument] = []
    var selectedDocumentID: UUID?
    var lastError: String?

    private let converter: any BlendConverting
    private let fileManager: FileManager
    private var watchers: [UUID: MarkdownFileWatcher] = [:]
    private var watchTasks: [UUID: Task<Void, Never>] = [:]
    private var conversions: [UUID: Task<Void, Never>] = [:]
    private var closingDocuments: Set<UUID> = []
    /// Fires when a document becomes selected. `Project` uses it to keep the
    /// owning tab, breadcrumb, and persisted selection on the same model.
    var onDocumentActivated: ((URL) -> Void)?
    /// Fires after a document is removed. Without it, closing through the
    /// application menu leaves an asset tab that reopens the model.
    var onDocumentClosed: ((URL) -> Void)?
    /// Whether a Save As in another workspace is still writing this path.
    var isDestinationReserved: ((String) -> Bool)?
    /// Whether another workspace already owns this path.
    var isPathOwnedElsewhere: ((String) -> Bool)?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        converter: (any BlendConverting)? = nil,
        fileManager: FileManager = .default,
        opensDemoModel: Bool = true
    ) {
        self.fileManager = fileManager
        self.converter = converter ?? BlenderConverter(
            environment: environment,
            fileManager: fileManager
        )
        removeStaleTemporaryFiles()

        if opensDemoModel,
           let path = environment["SONOVO_DEMO_MODEL"], !path.isEmpty {
            _ = open(url: URL(fileURLWithPath: path))
        }
    }

    var selectedDocument: Model3DDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    var blenderInstallation: BlenderInstallation? {
        converter.locateBlender()
    }

    /// Any open model converting in the background, selected or not.
    var hasRunningConversion: Bool {
        documents.contains { $0.state.isConverting }
    }

    func dismissError() {
        lastError = nil
    }

    // MARK: - Documents

    @discardableResult
    func open(url: URL) -> Model3DDocument? {
        let target = MarkdownSecurity.canonical(url)
        if let existing = documents.first(where: {
            MarkdownSecurity.canonical($0.sourceURL).path == target.path
        }) {
            select(existing)
            return existing
        }
        guard isDestinationReserved?(target.path) != true else {
            lastError = "That file is being saved in another tab."
            return nil
        }
        guard isPathOwnedElsewhere?(target.path) != true else {
            lastError = "That file is already open in another tab."
            return nil
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: target.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            lastError = "Cannot open \(target.lastPathComponent): the file does not exist."
            return nil
        }
        guard fileManager.isReadableFile(atPath: target.path) else {
            lastError = "Cannot open \(target.lastPathComponent): permission denied."
            return nil
        }
        guard let format = Model3DFormat.detect(url: target) else {
            let name = target.pathExtension.isEmpty
                ? "files without an extension"
                : ".\(target.pathExtension) files"
            lastError = "Cannot open \(target.lastPathComponent): this viewer does not support \(name)."
            return nil
        }

        let document = Model3DDocument(url: target, format: format)
        // The initializer only sets the state. Beginning the load here also
        // schedules the off-main OBJ material scan; without it the first
        // page load had no material libraries. A .blend waits for the
        // explicit conversion instead.
        if !format.isConvertible {
            document.beginLoading()
        }
        documents.append(document)
        startWatcher(for: document)
        select(document)
        lastError = nil
        return document
    }

    func select(_ document: Model3DDocument) {
        selectedDocumentID = document.id
        onDocumentActivated?(document.sourceURL)
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let extensions = Model3DFormat.openPanelExtensions
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types.count == extensions.count
            ? types
            : [.data]
        if panel.runModal() == .OK {
            for url in panel.urls {
                _ = open(url: url)
            }
        }
    }

    func reload(_ document: Model3DDocument) {
        guard conversions[document.id] == nil,
              !closingDocuments.contains(document.id) else {
            return
        }
        document.reload()
    }

    func reloadSelected() {
        guard let document = selectedDocument else { return }
        reload(document)
    }

    @discardableResult
    func close(_ document: Model3DDocument) async -> Bool {
        guard !closingDocuments.contains(document.id) else { return false }
        closingDocuments.insert(document.id)
        defer { closingDocuments.remove(document.id) }

        // Keep the task registered while it winds down. Removing it first
        // would let a new conversion start during the await, and the old
        // task's cleanup would then unregister the new one.
        if let conversion = conversions[document.id] {
            conversion.cancel()
            await conversion.value
        }
        watchTasks.removeValue(forKey: document.id)?.cancel()
        watchers.removeValue(forKey: document.id)?.stop()
        document.markClosed()
        document.cleanUpTemporaryOutput()
        let sourceURL = document.sourceURL
        documents.removeAll { $0.id == document.id }
        if selectedDocumentID == document.id {
            selectedDocumentID = documents.last?.id
        }
        onDocumentClosed?(sourceURL)
        return true
    }

    func closeSelected() async {
        guard let document = selectedDocument else { return }
        await close(document)
    }

    // MARK: - Blender conversion

    func convert(_ document: Model3DDocument) {
        guard document.format.canConvertWithBlender,
              conversions[document.id] == nil,
              !closingDocuments.contains(document.id) else {
            return
        }
        document.beginConversion()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.conversions.removeValue(forKey: document.id) }
            do {
                let result = try await self.converter.convert(
                    source: document.sourceURL
                )
                document.finishConversion(
                    outputURL: result.outputURL,
                    temporaryDirectory: result.temporaryDirectory,
                    blenderVersion: result.version,
                    log: result.log,
                    warnings: result.warnings
                )
            } catch is CancellationError {
                document.cancelConversion()
            } catch {
                let log = (error as? BlenderConversionError)?.log ?? ""
                document.failConversion(
                    error.localizedDescription,
                    log: log
                )
            }
        }
        conversions[document.id] = task
    }

    func convertSelectedWithBlender() {
        guard let document = selectedDocument else { return }
        convert(document)
    }

    func cancelConversion(_ document: Model3DDocument) {
        conversions[document.id]?.cancel()
    }

    // MARK: - Termination

    /// Called before the app terminates. No saving is involved; this only
    /// stops child processes and removes their temporary output.
    func prepareForTermination() {
        for task in conversions.values {
            task.cancel()
        }
        conversions.removeAll()
        converter.terminateAll()
        for document in documents {
            document.markClosed()
            document.cleanUpTemporaryOutput()
        }
        for watcher in watchers.values {
            watcher.stop()
        }
        watchers.removeAll()
        for task in watchTasks.values {
            task.cancel()
        }
        watchTasks.removeAll()
    }

    // MARK: - Watching

    private func startWatcher(for document: Model3DDocument) {
        let id = document.id
        let watcher = MarkdownFileWatcher(
            fileURL: document.sourceURL
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleChangeCheck(for: id)
            }
        }
        watchers[id] = watcher
        watcher.start()
    }

    private func scheduleChangeCheck(for id: UUID) {
        watchTasks[id]?.cancel()
        watchTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self,
                  let document = self.documents.first(where: { $0.id == id })
            else {
                return
            }
            let date = Model3DDocument.modifiedDate(of: document.sourceURL)
            let size = Model3DDocument.fileSize(of: document.sourceURL)
            if date != document.sourceModifiedAt || size != document.fileSize {
                document.markExternalChange()
            }
        }
    }

    private func removeStaleTemporaryFiles() {
        let root = Model3DTemporaryFiles.root
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for child in children {
            // Another project in this process may still be showing this
            // conversion. Age alone is not ownership.
            guard !Model3DTemporaryFiles.isProtected(child) else {
                continue
            }
            let values = try? child.resourceValues(
                forKeys: [.contentModificationDateKey]
            )
            if let date = values?.contentModificationDate, date < cutoff {
                try? fileManager.removeItem(at: child)
            }
        }
    }
}
