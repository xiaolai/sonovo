import Foundation
import SonovoCore

/// A document type the autosave driver can save. Both Markdown and subtitle
/// documents expose the same lifecycle; their error enums differ.
@MainActor
protocol Autosaveable: AnyObject {
    var id: UUID { get }
    var hasUnresolvedConflict: Bool { get }
    var isDirty: Bool { get }
    func autosaveDelay(now: Date) -> TimeInterval?
    /// A no-argument save. The documents' own `save` takes defaulted
    /// parameters, which is not a witness for a no-argument requirement.
    func autosave() async throws
    func isClosedError(_ error: Error) -> Bool
}

extension MarkdownDocument: Autosaveable {
    var hasUnresolvedConflict: Bool { conflict != nil }

    func autosave() async throws {
        _ = try await save()
    }

    func isClosedError(_ error: Error) -> Bool {
        (error as? DocumentError) == .closed
    }
}

extension SubtitleDocument: Autosaveable {
    var hasUnresolvedConflict: Bool { conflict != nil }

    func autosave() async throws {
        _ = try await save()
    }

    func isClosedError(_ error: Error) -> Bool {
        (error as? SubtitleDocumentError) == .closed
    }
}

/// One autosave loop for every document workspace: due selection, conflict
/// suppression, closed-document checks, exponential backoff, and error
/// reporting live here instead of in each workspace.
@MainActor
final class AutosaveDriver<Document: Autosaveable> {
    private var task: Task<Void, Never>?
    private var retryAfter: [UUID: Date] = [:]
    private var failures: [UUID: Int] = [:]

    private let documents: () -> [Document]
    private let reportsError: (String) -> Void
    private let tick: Duration

    init(
        tick: Duration = .milliseconds(500),
        documents: @escaping () -> [Document],
        reportsError: @escaping (String) -> Void
    ) {
        self.tick = tick
        self.documents = documents
        self.reportsError = reportsError
    }

    func start() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.tick ?? .milliseconds(500))
                guard let self else { return }
                await self.saveDueDocuments()
            }
        }
    }

    /// Clears retry bookkeeping after a save outside the loop or a close.
    func didSave(_ id: UUID) {
        retryAfter.removeValue(forKey: id)
        failures.removeValue(forKey: id)
    }

    func forget(_ id: UUID) {
        didSave(id)
    }

    private func saveDueDocuments() async {
        let now = Date()
        let due = documents().filter { document in
            if let retry = retryAfter[document.id], retry > now {
                return false
            }
            guard let delay = document.autosaveDelay(now: now) else {
                return false
            }
            return delay <= 0
        }
        for document in due {
            // A conflict must never be overwritten by autosave.
            guard !document.hasUnresolvedConflict else { continue }
            // The document may have been closed while an earlier await in
            // this batch was running.
            guard documents().contains(where: { $0.id == document.id }) else {
                continue
            }
            do {
                try await document.autosave()
                didSave(document.id)
            } catch {
                if document.isClosedError(error) {
                    continue
                }
                // Surface the failure and back off instead of retrying the
                // same failing write every tick.
                let count = (failures[document.id] ?? 0) + 1
                failures[document.id] = count
                let delay = min(
                    30.0,
                    pow(2.0, Double(min(count, 5)))
                )
                retryAfter[document.id] = Date()
                    .addingTimeInterval(delay)
                reportsError("Autosave failed: \(error)")
            }
        }
    }
}
