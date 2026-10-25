import Foundation
import Observation
import SonovoCore

/// Project-owned media edit sessions. A tab switch must not discard undo or
/// selection; a tab close or project close must not leave a job writing into
/// a project after its document is gone.
@MainActor
@Observable
final class MediaEditWorkspace {
    private(set) var documents: [String: MediaEditDocument] = [:]
    private(set) var activeDocumentID: String?
    let recorder: AudioRecorder
    let exportService: MediaExportService

    init(
        recorder: AudioRecorder = AudioRecorder(),
        exportService: MediaExportService = MediaExportService()
    ) {
        self.recorder = recorder
        self.exportService = exportService
    }

    var activeDocument: MediaEditDocument? {
        guard let activeDocumentID else { return nil }
        return documents[activeDocumentID]
    }

    /// The document for this file, created on first edit and updated with the
    /// current revision so an external overwrite becomes a stale session.
    func document(for asset: ProjectAsset) -> MediaEditDocument {
        let key = MarkdownSecurity.canonical(asset.url).path
        if let existing = documents[key] {
            existing.observe(asset: asset)
            return existing
        }
        let document = MediaEditDocument(asset: asset)
        documents[key] = document
        return document
    }

    func activate(_ document: MediaEditDocument) {
        activeDocumentID = document.id
    }

    func deactivate(_ document: MediaEditDocument) {
        if activeDocumentID == document.id {
            activeDocumentID = nil
        }
    }

    func close(url: URL) {
        let key = MarkdownSecurity.canonical(url).path
        guard let document = documents.removeValue(forKey: key) else { return }
        if activeDocumentID == document.id {
            activeDocumentID = nil
        }
        // One export runs at a time in this workspace; a tab closing must not
        // leave a job writing into a project after its document is gone.
        exportService.cancel()
    }

    func discardDocument(for url: URL) {
        close(url: url)
    }

    func closeAll() {
        exportService.cancel()
        documents.removeAll()
        activeDocumentID = nil
    }

    func cancelJobs() {
        exportService.cancel()
    }
}
