import AppKit
import Observation
import SonovoCore

/// Owns review-comment state for every open Markdown document.
///
/// Comments live only in the sidecar beside the document; the canonical
/// source is never edited. Every write is atomic and compare-and-swap against
/// the sidecar state this controller last read, so a second app instance
/// cannot silently overwrite threads. A corrupt sidecar is refused rather
/// than replaced: those comments cannot be reconstructed from source.
@MainActor
@Observable
final class ReviewCommentsController {
    struct DocumentState {
        var review = ReviewDocument(
            documentName: "",
            documentIdentity: ""
        )
        var sidecar: ReviewSidecarState = .missing
        var loadedPath: URL?
        var didLoad = false
        var isLoading = false
        /// A load or save failure shown in the panel.
        var error: String?
        /// The sidecar exists but cannot be parsed or is a newer format.
        /// Normal saves refuse until the user deletes or repairs the file.
        var isCorrupt = false
        /// The sidecar changed on disk after this controller loaded it.
        /// `pending` holds the local edit that could not be written.
        var externalChange = false
        var pending: ReviewDocument?
        /// The disk state the pending edit was computed against. Saving the
        /// pending edit must compare against this baseline, not against a
        /// later reload's fingerprint, or the compare-and-swap would succeed
        /// while silently discarding the external threads that reload read.
        var pendingBaseline: ReviewSidecarState?
        /// True only after the sidecar decoded successfully at
        /// `loadedPath`. Ordinary writes require it: a fingerprint obtained
        /// by a failed read would let a save replace threads that were never
        /// seen.
        var isWritable = false
        /// Bumped when a load or write starts. A completion installs its
        /// result only if no newer operation has started since, so a closed
        /// document or a Save As cannot resurrect stale state.
        var generation: UInt64 = 0
    }

    /// The comment author recorded in new threads. The environment override
    /// exists so a scripted run does not sign comments with the login name.
    let author: String

    var isVisible = false
    /// The thread the panel should highlight after a reveal.
    var selectedThreadID: UUID?

    private(set) var states: [UUID: DocumentState] = [:]
    /// Documents with a mutation in flight. A second mutation would race the
    /// first's detached sidecar write and overwrite its state on completion.
    @ObservationIgnored private var mutating: Set<UUID> = []

    init(
        author: String? = nil,
        environment: [String: String] =
            ProcessInfo.processInfo.environment
    ) {
        self.author = author ?? Self.defaultAuthor(
            environment: environment
        )
    }

    // MARK: - Reading

    func state(for document: MarkdownDocument) -> DocumentState {
        if let state = states[document.id] {
            return state
        }
        var state = DocumentState()
        state.review.documentName =
            document.fileURL?.lastPathComponent ?? ""
        return state
    }

    /// Loads the sidecar once per document path. A document that moved
    /// through Save As reloads from its new location instead of carrying the
    /// old file's threads.
    @discardableResult
    func load(
        _ document: MarkdownDocument,
        force: Bool = false
    ) async -> Bool {
        guard !document.isClosed else { return false }
        var state = state(for: document)
        guard let url = document.fileURL.map(MarkdownSecurity.canonical)
        else {
            state.didLoad = true
            state.loadedPath = nil
            state.error = "Comments need a saved document."
            state.isCorrupt = false
            states[document.id] = state
            return false
        }
        if !force,
           state.didLoad,
           state.loadedPath?.path == url.path,
           !state.externalChange {
            return state.isWritable
        }
        guard !state.isLoading else { return false }
        state.isLoading = true
        state.error = nil
        state.generation &+= 1
        let generation = state.generation
        let loadingPath = state.loadedPath?.path
        states[document.id] = state

        let identity = ReviewAnchorResolver.documentIdentity(
            of: document.source
        )
        let result: Result<ReviewSidecarLoad, Error> = await Task.detached(
            priority: .userInitiated
        ) {
            Result {
                try ReviewSidecar.load(
                    for: url,
                    documentIdentity: identity
                )
            }
        }.value

        // Re-read: the document may have been closed, moved (Save As), or
        // reloaded while the disk read ran. The old path's threads must not
        // install under the moved document, and a superseded load must not
        // overwrite the newer state.
        guard var current = states[document.id],
              current.generation == generation,
              !document.isClosed,
              document.fileURL
                  .map(MarkdownSecurity.canonical)?.path == url.path else {
            if var stale = states[document.id],
               stale.generation == generation {
                stale.isLoading = false
                states[document.id] = stale
            }
            return false
        }
        let samePath = loadingPath == url.path
        current.isLoading = false
        switch result {
        case let .success(loaded):
            current.review = loaded.document
            current.sidecar = loaded.state
            current.loadedPath = url
            current.didLoad = true
            current.isCorrupt = false
            current.isWritable = true
            current.error = nil
            // A local edit survives an ordinary reload of the same file: it
            // is still not on disk, so it stays pending until the user
            // chooses Overwrite or Reload. A forced reload and a Save As
            // discard it deliberately.
            if force || !samePath {
                current.pending = nil
                current.pendingBaseline = nil
                current.externalChange = false
            } else {
                current.externalChange = current.pending != nil
            }
            states[document.id] = current
            return true
        case let .failure(error):
            current.didLoad = true
            current.loadedPath = url
            current.error = Self.message(for: error)
            current.isCorrupt = Self.failsClosed(error)
            // A sidecar that could not be decoded has unknown content, so
            // no write may adopt this read as its baseline.
            current.isWritable = false
            if force || !samePath {
                current.pending = nil
                current.pendingBaseline = nil
                current.externalChange = false
            }
            states[document.id] = current
            return false
        }
    }

    func placements(for document: MarkdownDocument) -> [ReviewThreadPlacement] {
        let review = state(for: document).review
        if let cache = placementCache[document.id],
           cache.revision == document.revision,
           cache.review == review {
            return cache.placements
        }
        let placements = review.placements(in: document.source)
        placementCache[document.id] = PlacementCache(
            revision: document.revision,
            review: review,
            placements: placements
        )
        return placements
    }

    private struct PlacementCache {
        let revision: UInt64
        let review: ReviewDocument
        let placements: [ReviewThreadPlacement]
    }

    /// Placements are recomputed whenever the source or the comments change;
    /// the ruler and the reveal path ask for them repeatedly within one
    /// revision. The cache is internal work state, not observable state.
    @ObservationIgnored
    private var placementCache: [UUID: PlacementCache] = [:]

    func openCount(for document: MarkdownDocument) -> Int {
        state(for: document).review.openThreadCount
    }

    // MARK: - Mutating

    @discardableResult
    func addComment(
        to document: MarkdownDocument,
        selection: Range<Int>?,
        body: String
    ) async -> Bool {
        guard document.fileURL != nil else {
            setError("Comments need a saved document.", for: document)
            return false
        }
        guard let selection, !selection.isEmpty else {
            setError("Select text to comment on.", for: document)
            return false
        }
        guard let anchor = ReviewAnchorResolver.makeAnchor(
            source: document.source,
            selection: selection
        ) else {
            setError("The selection has no commentable text.", for: document)
            return false
        }
        return await mutate(document) { review in
            review.addThread(
                anchor: anchor,
                author: self.author,
                body: body
            ) != nil
        }
    }

    @discardableResult
    func reply(
        to threadID: UUID,
        in document: MarkdownDocument,
        body: String
    ) async -> Bool {
        await mutate(document) { review in
            review.reply(
                to: threadID,
                author: self.author,
                body: body
            ) != nil
        }
    }

    @discardableResult
    func setResolved(
        _ resolved: Bool,
        threadID: UUID,
        in document: MarkdownDocument
    ) async -> Bool {
        await mutate(document) { review in
            review.setResolved(resolved, threadID: threadID)
        }
    }

    @discardableResult
    func delete(
        threadID: UUID,
        from document: MarkdownDocument
    ) async -> Bool {
        let removed = await mutate(document) { review in
            review.removeThread(threadID)
        }
        if removed, selectedThreadID == threadID {
            selectedThreadID = nil
        }
        return removed
    }

    /// Discards the unsaved local edit and reloads whatever is on disk.
    @discardableResult
    func reload(_ document: MarkdownDocument) async -> Bool {
        // Serialized with mutations and overwrites: a reload that ran beside
        // a write could install a state the write then overwrites, or drop
        // the edit that write is committing.
        guard !mutating.contains(document.id) else {
            setError(
                "Another comment change is still saving.",
                for: document
            )
            return false
        }
        mutating.insert(document.id)
        defer { mutating.remove(document.id) }
        return await load(document, force: true)
    }

    /// Writes the local edit over the external change, deliberately. Any
    /// writer that changes the file again before this save still wins: the
    /// overwrite is compare-and-swap against the bytes read here.
    @discardableResult
    func overwrite(_ document: MarkdownDocument) async -> Bool {
        // Serialized with ordinary mutations: an overwrite that ran beside a
        // newer comment edit would write the older snapshot and drop it.
        guard !mutating.contains(document.id) else {
            setError(
                "Another comment change is still saving.",
                for: document
            )
            return false
        }
        mutating.insert(document.id)
        defer { mutating.remove(document.id) }
        guard var state = states[document.id],
              let pending = state.pending,
              let url = document.fileURL.map(MarkdownSecurity.canonical)
        else {
            return false
        }
        state.generation &+= 1
        let generation = state.generation
        states[document.id] = state
        var review = pending
        review.documentName = url.lastPathComponent
        review.documentIdentity = ReviewAnchorResolver.documentIdentity(
            of: document.source
        )
        do {
            let current = try await Task.detached(priority: .userInitiated) {
                try ReviewSidecar.currentState(for: url)
            }.value
            // A close or Save As while the state was read invalidates the
            // target: the old file's comments must not install under a moved
            // document.
            guard let latest = states[document.id],
                  latest.generation == generation,
                  !document.isClosed,
                  document.fileURL
                      .map(MarkdownSecurity.canonical)?.path == url.path
            else {
                return false
            }
            let snapshot = review
            let newState = try await Task.detached(priority: .userInitiated) {
                try ReviewSidecar.save(
                    snapshot,
                    for: url,
                    ifUnchangedSince: current
                )
            }.value
            guard var settled = states[document.id],
                  settled.generation == generation,
                  !document.isClosed else {
                return false
            }
            settled.review = review
            settled.sidecar = newState
            settled.pending = nil
            settled.pendingBaseline = nil
            settled.externalChange = false
            settled.error = nil
            settled.isCorrupt = false
            settled.didLoad = true
            settled.loadedPath = url
            states[document.id] = settled
            return true
        } catch {
            guard var latest = states[document.id],
                  latest.generation == generation,
                  !document.isClosed,
                  document.fileURL
                      .map(MarkdownSecurity.canonical)?.path == url.path
            else {
                return false
            }
            latest.error = Self.message(for: error)
            states[document.id] = latest
            return false
        }
    }

    /// Forgets a closed document. The sidecar stays on disk.
    func discard(documentID: UUID) {
        states.removeValue(forKey: documentID)
        placementCache.removeValue(forKey: documentID)
        if selectedThreadID != nil,
           !states.values.contains(where: { state in
               state.review.threads.contains { $0.id == selectedThreadID }
           }) {
            selectedThreadID = nil
        }
    }

    func discardAll() {
        states.removeAll()
        placementCache.removeAll()
        selectedThreadID = nil
    }

    // MARK: - Internals

    private func mutate(
        _ document: MarkdownDocument,
        change: (inout ReviewDocument) -> Bool
    ) async -> Bool {
        guard !mutating.contains(document.id) else {
            setError(
                "Another comment change is still saving.",
                for: document
            )
            return false
        }
        mutating.insert(document.id)
        defer { mutating.remove(document.id) }
        // A pending local edit survives an external-change conflict until the
        // user explicitly reloads. Reloading here would silently drop it.
        if states[document.id]?.pending == nil {
            let loaded = await load(document)
            guard loaded else {
                // A load still running owns this state's generation; a load
                // that failed leaves no writable baseline. Advancing the
                // generation here would invalidate the in-flight load and
                // let a later mutation run against incomplete state.
                var current = states[document.id] ?? DocumentState()
                if current.isLoading {
                    current.error = "Comments are still loading."
                } else if current.error == nil {
                    current.error = "Comments could not be loaded."
                }
                states[document.id] = current
                return false
            }
        }
        guard var state = states[document.id],
              let url = document.fileURL.map(MarkdownSecurity.canonical)
        else {
            return false
        }
        guard state.isWritable else {
            state.error = state.error ?? "The comments file cannot be read."
            states[document.id] = state
            return false
        }
        state.generation &+= 1
        let generation = state.generation
        states[document.id] = state
        var review = state.pending ?? state.review
        let before = review
        guard change(&review) else {
            state.error = "The comment is empty."
            states[document.id] = state
            return false
        }
        guard review != before else {
            state.error = "Nothing changed."
            states[document.id] = state
            return false
        }
        review.documentName = url.lastPathComponent
        review.documentIdentity = ReviewAnchorResolver.documentIdentity(
            of: document.source
        )
        // A pending edit keeps the fingerprint it was computed against: a
        // reload may have refreshed `sidecar` to the external state, and
        // saving the older pending document against that fingerprint would
        // overwrite the external threads without an explicit Overwrite.
        let expected = state.pending != nil
            ? (state.pendingBaseline ?? state.sidecar)
            : state.sidecar
        do {
            let snapshot = review
            let newState = try await Task.detached(priority: .userInitiated) {
                try ReviewSidecar.save(
                    snapshot,
                    for: url,
                    ifUnchangedSince: expected
                )
            }.value
            guard var current = states[document.id],
                  current.generation == generation,
                  !document.isClosed,
                  document.fileURL
                      .map(MarkdownSecurity.canonical)?.path == url.path
            else {
                return false
            }
            current.review = review
            current.sidecar = newState
            current.pending = nil
            current.pendingBaseline = nil
            current.externalChange = false
            current.error = nil
            states[document.id] = current
            return true
        } catch ReviewSidecarError.externalChange {
            guard var current = states[document.id],
                  current.generation == generation else {
                return false
            }
            current.pending = review
            current.pendingBaseline = expected
            current.externalChange = true
            current.error = Self.message(for: ReviewSidecarError.externalChange)
            states[document.id] = current
            return false
        } catch {
            // Keep the edit for a retry; the panel's text may already be
            // cleared, and a permission or disk error must not lose it.
            guard var current = states[document.id],
                  current.generation == generation else {
                return false
            }
            current.pending = review
            current.pendingBaseline = expected
            current.error = Self.message(for: error)
            states[document.id] = current
            return false
        }
    }

    private func setError(_ message: String, for document: MarkdownDocument) {
        var state = state(for: document)
        state.error = message
        states[document.id] = state
    }

    private static func failsClosed(_ error: Error) -> Bool {
        switch error {
        case ReviewSidecarError.corrupt,
             ReviewSidecarError.unsupportedVersion:
            return true
        default:
            return false
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case let ReviewSidecarError.corrupt(name):
            return "\(name) is not a readable comments file. "
                + "It is left untouched; move or delete it to start over."
        case let ReviewSidecarError.unsupportedVersion(version):
            return "The comments file uses format \(version), "
                + "which this build cannot write. It is left untouched."
        case let ReviewSidecarError.unreadable(name):
            return "Cannot read \(name)."
        case ReviewSidecarError.externalChange:
            return "The comments file changed on disk. "
                + "Reload it or overwrite it with your local edit."
        case let ReviewSidecarError.writeFailed(detail):
            return "Could not write comments: \(detail)"
        default:
            return String(describing: error)
        }
    }

    private static func defaultAuthor(
        environment: [String: String]
    ) -> String {
        if let override = environment["SONOVO_REVIEW_AUTHOR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        let full = NSFullUserName()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !full.isEmpty { return full }
        let short = NSUserName()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return short.isEmpty ? "Anonymous" : short
    }
}
