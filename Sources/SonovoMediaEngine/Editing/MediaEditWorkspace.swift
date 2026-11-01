import SonovoDocumentSupport
import SonovoFileIO
import SonovoDomainTypes
import Foundation
import Observation

/// Project-owned media edit sessions. A tab switch must not discard undo or
/// selection; a tab close or project close must not leave a job writing into
/// a project after its document is gone.
@MainActor
@Observable
package final class MediaEditWorkspace {
    package private(set) var documents: [String: MediaEditDocument] = [:]
    package private(set) var activeDocumentID: String?
    package private(set) var exportingDocumentID: String?
    /// True from the start of an export until the project has finished
    /// refreshing/opening the result. This is what freezes edit controls;
    /// the export service's own busy flag clears slightly earlier.
    package private(set) var isExportingOperation = false
    package let recorder: AudioRecorder
    package let exportService: MediaExportService

    package init(
        recorder: AudioRecorder = AudioRecorder(),
        exportService: MediaExportService = MediaExportService()
    ) {
        self.recorder = recorder
        self.exportService = exportService
    }

    package var activeDocument: MediaEditDocument? {
        guard let activeDocumentID else { return nil }
        return documents[activeDocumentID]
    }

    /// The document for this file, created on first edit and updated with the
    /// current revision so an external overwrite becomes a stale session.
    package func document(for asset: ProjectAsset) -> MediaEditDocument {
        let key = FilePathPolicy.canonical(asset.url).path
        if let existing = documents[key] {
            existing.observe(asset: asset)
            return existing
        }
        let document = MediaEditDocument(asset: asset)
        documents[key] = document
        return document
    }

    package func activate(_ document: MediaEditDocument) {
        activeDocumentID = document.id
    }

    package func deactivate(_ document: MediaEditDocument) {
        if activeDocumentID == document.id {
            activeDocumentID = nil
        }
    }

    @discardableResult
    package func beginExport(_ document: MediaEditDocument) -> Bool {
        guard exportingDocumentID == nil, !isExportingOperation else {
            return false
        }
        exportingDocumentID = document.id
        isExportingOperation = true
        document.beginExportLock()
        return true
    }

    package func endExport(_ document: MediaEditDocument) {
        guard exportingDocumentID == nil
                || exportingDocumentID == document.id else {
            return
        }
        exportingDocumentID = nil
        isExportingOperation = false
        document.endExportLock()
    }

    package func close(url: URL) {
        let key = FilePathPolicy.canonical(url).path
        guard let document = documents.removeValue(forKey: key) else { return }
        if activeDocumentID == document.id {
            activeDocumentID = nil
        }
        // Cancel only the job owned by this document. Closing an unrelated
        // tab must not abort another document's export.
        if exportingDocumentID == document.id {
            exportingDocumentID = nil
            exportService.cancel()
        }
    }

    package func discardDocument(for url: URL) {
        close(url: url)
    }

    package func closeAll() {
        exportingDocumentID = nil
        exportService.cancel()
        documents.removeAll()
        activeDocumentID = nil
    }

    package func cancelJobs() {
        exportingDocumentID = nil
        exportService.cancel()
    }
}
