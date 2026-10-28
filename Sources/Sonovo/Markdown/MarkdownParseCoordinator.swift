import Foundation
import Observation
import SonovoCore

/// The one owner of parse state per document.
///
/// The editor, viewer, outline, lint, and future split all read this state.
/// None of them starts its own parse task: a request is coalesced to the newest
/// revision, retried with bounded backoff when the parse service drops it, and
/// published only while the document identity and revision still match.
@MainActor
@Observable
final class MarkdownParseCoordinator {
    typealias ParseOperation = @Sendable (MarkdownParseInput) async -> MarkdownParseOutput?
    typealias ReleaseOperation = @Sendable (UUID) -> Void

    struct Request: Sendable, Equatable {
        let identityGeneration: UInt64
        let revision: UInt64
        let source: String
        let enableAutolinks: Bool
    }

    private struct Awaiter {
        let id: UUID
        let revision: UInt64
        let continuation: CheckedContinuation<MarkdownParseState?, Never>
    }

    private struct Bookkeeping {
        var identityGeneration: UInt64 = 0
        var latestRevision: UInt64 = 0
        var pending: Request?
        var worker: Task<Void, Never>?
        var workerToken: UInt64 = 0
        var observers: [UUID: (MarkdownParseState) -> Void] = [:]
        var awaiters: [Awaiter] = []
        var lastSuccess: MarkdownParseOutput?
        /// The parser option the successful output was produced with. A
        /// repeat request with a different option is a different parse.
        var lastEnableAutolinks: Bool?
        var closed = false
    }

    private(set) var states: [UUID: MarkdownParseState] = [:]
    @ObservationIgnored private var bookkeeping: [UUID: Bookkeeping] = [:]
    @ObservationIgnored private let parseOperation: ParseOperation
    @ObservationIgnored private let releaseOperation: ReleaseOperation
    @ObservationIgnored private let maximumAttempts: Int
    @ObservationIgnored private let initialRetryDelay: TimeInterval
    @ObservationIgnored private let maximumRetryDelay: TimeInterval

    init(
        maximumAttempts: Int = 6,
        initialRetryDelay: TimeInterval = 0.05,
        maximumRetryDelay: TimeInterval = 2.0,
        parse: @escaping ParseOperation,
        release: @escaping ReleaseOperation = { _ in }
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.initialRetryDelay = max(0, initialRetryDelay)
        self.maximumRetryDelay = max(0, maximumRetryDelay)
        self.parseOperation = parse
        self.releaseOperation = release
    }

    convenience init(service: MarkdownParseService) {
        self.init(
            parse: { input in await service.parse(input) },
            release: { documentID in
                Task { await service.release(documentID: documentID) }
            }
        )
    }

    // MARK: - Reading

    func state(for documentID: UUID) -> MarkdownParseState {
        states[documentID] ?? .idle
    }

    func lastSuccessfulOutput(for documentID: UUID) -> MarkdownParseOutput? {
        bookkeeping[documentID]?.lastSuccess
    }

    // MARK: - Requests

    /// Requests a parse of `revision`. The newest revision wins; a request for
    /// an older revision than one already seen is ignored.
    func request(
        documentID: UUID,
        identityGeneration: UInt64,
        revision: UInt64,
        source: String,
        enableAutolinks: Bool = true
    ) {
        var book = bookkeeping[documentID] ?? Bookkeeping()
        guard !book.closed else { return }

        if identityGeneration != book.identityGeneration {
            // A new identity invalidates every result from the old one. A
            // waiter from the old identity will never be published, so it is
            // resumed now instead of leaking until the session ends.
            book.identityGeneration = identityGeneration
            book.lastSuccess = nil
            book.lastEnableAutolinks = nil
            book.pending = nil
            book.worker?.cancel()
            book.worker = nil
            states[documentID] = .idle
            let stale = book.awaiters
            book.awaiters.removeAll()
            bookkeeping[documentID] = book
            for awaiter in stale {
                awaiter.continuation.resume(returning: .idle)
            }
        }
        guard revision >= book.latestRevision else {
            bookkeeping[documentID] = book
            return
        }
        book.latestRevision = revision

        if case .ready(let output)? = states[documentID],
           output.revision == revision,
           output.documentID == documentID,
           book.lastEnableAutolinks == enableAutolinks {
            bookkeeping[documentID] = book
            return
        }

        let request = Request(
            identityGeneration: identityGeneration,
            revision: revision,
            source: source,
            enableAutolinks: enableAutolinks
        )
        book.pending = request
        states[documentID] = .parsing(revision: revision)
        bookkeeping[documentID] = book
        startWorker(documentID)
    }

    /// Waits until the state for `revision` (or a newer one) is settled.
    /// Returns `nil` when the document is released first, and `.idle` when
    /// the request is abandoned or the wait is cancelled. Cancellation must
    /// resume the continuation: a caller with its own deadline (an export,
    /// a link probe) would otherwise hold it for the session.
    func awaitSettled(
        documentID: UUID,
        revision: UInt64
    ) async -> MarkdownParseState? {
        if let state = states[documentID],
           let settled = state.revision,
           settled >= revision,
           !state.isParsing {
            return state
        }
        // A document parked by `giveUp` or reset by a new identity is idle
        // with no pending request; nothing will publish a revision for it, so
        // suspending here would leak the continuation for the rest of the
        // session.
        if case .idle? = states[documentID],
           bookkeeping[documentID]?.pending == nil {
            return .idle
        }
        let awaiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .idle)
                    return
                }
                var book = bookkeeping[documentID] ?? Bookkeeping()
                book.awaiters.append(
                    Awaiter(
                        id: awaiterID,
                        revision: revision,
                        continuation: continuation
                    )
                )
                bookkeeping[documentID] = book
                if Task.isCancelled {
                    cancelAwaiter(awaiterID, documentID: documentID)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelAwaiter(awaiterID, documentID: documentID)
            }
        }
    }

    private func cancelAwaiter(_ awaiterID: UUID, documentID: UUID) {
        guard var book = bookkeeping[documentID],
              let index = book.awaiters.firstIndex(
                  where: { $0.id == awaiterID }
              ) else {
            return
        }
        let awaiter = book.awaiters.remove(at: index)
        bookkeeping[documentID] = book
        awaiter.continuation.resume(returning: .idle)
    }

    func release(documentID: UUID) {
        guard var book = bookkeeping.removeValue(forKey: documentID) else {
            return
        }
        book.closed = true
        book.worker?.cancel()
        book.worker = nil
        states.removeValue(forKey: documentID)
        for awaiter in book.awaiters {
            awaiter.continuation.resume(returning: nil)
        }
        book.awaiters.removeAll()
        releaseOperation(documentID)
    }

    // MARK: - Observation

    @discardableResult
    func addObserver(
        for documentID: UUID,
        _ observer: @escaping (MarkdownParseState) -> Void
    ) -> UUID {
        let token = UUID()
        var book = bookkeeping[documentID] ?? Bookkeeping()
        book.observers[token] = observer
        bookkeeping[documentID] = book
        return token
    }

    func removeObserver(_ token: UUID, for documentID: UUID) {
        bookkeeping[documentID]?.observers.removeValue(forKey: token)
    }

    // MARK: - Worker

    private func startWorker(_ documentID: UUID) {
        guard bookkeeping[documentID]?.worker == nil else { return }
        var book = bookkeeping[documentID] ?? Bookkeeping()
        book.workerToken &+= 1
        let token = book.workerToken
        let task = Task { @MainActor [weak self] in
            await self?.drain(documentID)
            self?.workerDidFinish(documentID, token: token)
        }
        book.worker = task
        bookkeeping[documentID] = book
    }

    /// Only the worker that is still current may clear the handle or start a
    /// replacement. A cancelled worker can outlive its cancellation while an
    /// in-flight parse ignores it; without the token it would clear a newer
    /// worker's handle and allow concurrent drains.
    private func workerDidFinish(_ documentID: UUID, token: UInt64) {
        guard var book = bookkeeping[documentID],
              book.workerToken == token else {
            return
        }
        book.worker = nil
        bookkeeping[documentID] = book
        // A request that arrived between the last drain and this line must
        // not be left without a worker.
        if book.pending != nil, !book.closed {
            startWorker(documentID)
        }
    }

    private func drain(_ documentID: UUID) async {
        outer: while !Task.isCancelled {
            guard var book = bookkeeping[documentID],
                  !book.closed,
                  let request = book.pending else {
                return
            }
            book.pending = nil
            bookkeeping[documentID] = book

            var attempt = 0
            while !Task.isCancelled {
                let input = MarkdownParseInput(
                    documentID: documentID,
                    revision: request.revision,
                    source: request.source,
                    enableAutolinks: request.enableAutolinks
                )
                let output = await parseOperation(input)
                if Task.isCancelled { return }
                guard let current = bookkeeping[documentID],
                      !current.closed else {
                    return
                }
                // A newer request supersedes this attempt.
                if current.pending != nil { continue outer }

                if let output,
                   output.documentID == documentID,
                   output.revision == request.revision {
                    if current.identityGeneration
                        == request.identityGeneration {
                        publish(
                            output,
                            for: documentID,
                            enableAutolinks: request.enableAutolinks
                        )
                    } else {
                        // The document identity moved while the parse ran
                        // and no newer request replaced this one. The
                        // publication is refused; leaving `.parsing` behind
                        // would strand the spinner and every waiter.
                        resetStale(documentID)
                    }
                    continue outer
                }

                attempt += 1
                if attempt >= maximumAttempts {
                    giveUp(documentID)
                    continue outer
                }
                let delay = min(
                    maximumRetryDelay,
                    initialRetryDelay * pow(2, Double(attempt))
                )
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func publish(
        _ output: MarkdownParseOutput,
        for documentID: UUID,
        enableAutolinks: Bool
    ) {
        guard var book = bookkeeping[documentID] else { return }
        let state: MarkdownParseState
        if output.parsed.exceededNestingLimit {
            // The last successful output survives a refusal.
            state = .refused(.nestingLimit, revision: output.revision)
        } else {
            book.lastSuccess = output
            book.lastEnableAutolinks = enableAutolinks
            state = .ready(output)
        }
        states[documentID] = state
        let observers = Array(book.observers.values)
        let ready = book.awaiters.filter { $0.revision <= output.revision }
        book.awaiters.removeAll { $0.revision <= output.revision }
        bookkeeping[documentID] = book
        for observer in observers {
            observer(state)
        }
        for awaiter in ready {
            awaiter.continuation.resume(returning: state)
        }
    }

    /// A dropped parse is retried a bounded number of times. After that the
    /// state returns to `idle` so the next edit (or view appearance) asks
    /// again instead of leaving a spinner forever.
    private func giveUp(_ documentID: UUID) {
        guard var book = bookkeeping[documentID] else { return }
        states[documentID] = .idle
        let awaiters = book.awaiters
        book.awaiters.removeAll()
        bookkeeping[documentID] = book
        for awaiter in awaiters {
            awaiter.continuation.resume(returning: .idle)
        }
    }

    /// A result that cannot be published (its identity was superseded) must
    /// still settle the state and its waiters. Otherwise `states` stays
    /// `.parsing` with no pending work, and `awaitSettled` suspends forever.
    private func resetStale(_ documentID: UUID) {
        guard var book = bookkeeping[documentID] else { return }
        states[documentID] = .idle
        let awaiters = book.awaiters
        book.awaiters.removeAll()
        bookkeeping[documentID] = book
        for awaiter in awaiters {
            awaiter.continuation.resume(returning: .idle)
        }
    }
}
