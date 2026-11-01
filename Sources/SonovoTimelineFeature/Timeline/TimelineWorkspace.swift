import SonovoMediaUI
import SonovoMediaEngine
import SonovoDesignSystem
import SonovoFeatureAPI
import SonovoDocumentSupport
import SonovoFileIO
import SonovoDomainTypes
import Foundation
import Observation

/// Project-owned timeline documents. v1 keeps one named timeline open per
/// project; the workspace survives tab switches and owns save/close.
@MainActor
@Observable
package final class TimelineWorkspace {
    package init() {}
    package private(set) var document: TimelineDocument?
    package private(set) var lastError: String?
    package private(set) var isExporting = false
    package private(set) var exportProgress: Double = 0
    package private(set) var exportMessage: String?
    private var exportTask: Task<TimelineExportResult, Error>?
    private var exportGeneration: UInt64 = 0

    package var hasDirtyDocuments: Bool {
        document?.hasUnsavedChanges == true
    }

    package func open(url: URL) {
        let target = FilePathPolicy.canonical(url)
        if let document,
           FilePathPolicy.canonical(document.url) == target {
            return
        }
        do {
            try saveBeforeReplacing()
        } catch {
            lastError = error.localizedDescription
            return
        }
        let next = TimelineDocument(url: target)
        do {
            try next.load()
            document = next
            lastError = nil
        } catch {
            // Keep the failed document visible so the editor can report the
            // malformed file instead of silently presenting an empty one.
            document = next
            lastError = error.localizedDescription
        }
    }

    package func create(url: URL, timeline: ProjectTimeline) throws {
        let target = FilePathPolicy.canonical(url)
        try saveBeforeReplacing()
        let next = TimelineDocument(url: target)
        try next.create(timeline)
        document = next
        lastError = nil
    }

    /// Never drop a dirty timeline to make room for another one. A failed
    /// save keeps the old document and its error visible.
    private func saveBeforeReplacing() throws {
        guard let document else { return }
        if document.hasUnsavedChanges {
            try document.save()
        }
        document.close()
    }

    @discardableResult
    package func save() -> Bool {
        do {
            try document?.save()
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    package func reload() -> Bool {
        do {
            try document?.reload()
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Flushes before closing. A failed write keeps the document and its tab.
    @discardableResult
    package func close(url: URL? = nil) async -> Bool {
        guard let document else { return true }
        if let url,
           FilePathPolicy.canonical(document.url)
            != FilePathPolicy.canonical(url) {
            return true
        }
        do {
            try await document.flush()
        } catch {
            lastError = error.localizedDescription
            return false
        }
        // A different timeline may have been opened while the flush awaited.
        guard self.document === document else { return true }
        document.close()
        self.document = nil
        lastError = nil
        return true
    }

    package func flushAllForTermination() async -> Bool {
        guard let document else { return true }
        do {
            try await document.flush()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Exports through the workspace so deactivation and termination can
    /// cancel the job even when the timeline view is gone.
    package func exportTimeline(
        timeline: ProjectTimeline,
        assets: [ProjectAsset],
        destinationDirectory: URL
    ) async throws -> TimelineExportResult {
        cancelJobs()
        exportGeneration &+= 1
        let generation = exportGeneration
        isExporting = true
        exportProgress = 0
        exportMessage = nil
        let job = Task { @MainActor [weak self] in
            try await TimelineExportService.export(
                timeline: timeline,
                assets: assets,
                destinationDirectory: destinationDirectory
            ) { value in
                guard self?.exportGeneration == generation else { return }
                self?.exportProgress = value
            }
        }
        exportTask = job
        do {
            let result = try await job.value
            guard generation == exportGeneration else {
                return result
            }
            isExporting = false
            exportTask = nil
            exportMessage = "Exported \(result.url.lastPathComponent)"
            return result
        } catch {
            guard generation == exportGeneration else {
                throw error
            }
            isExporting = false
            exportTask = nil
            if error is CancellationError {
                exportMessage = "Export cancelled"
            }
            throw error
        }
    }

    package func cancelExport() {
        exportTask?.cancel()
    }

    package func cancelJobs() {
        exportGeneration &+= 1
        exportTask?.cancel()
        exportTask = nil
        isExporting = false
    }

    package func prepareForTermination() {
        document?.close()
    }

    package func handleExternalChange(url: URL) {
        guard let document,
              FilePathPolicy.canonical(document.url)
                == FilePathPolicy.canonical(url),
              document.hasExternalChanges else {
            return
        }
        // A dirty document keeps its edits and its failure state; the next
        // save refuses. A clean document simply adopts the new bytes.
        if !document.hasUnsavedChanges {
            do {
                try document.reload()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
