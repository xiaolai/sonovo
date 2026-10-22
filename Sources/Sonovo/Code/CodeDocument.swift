import Foundation
import Observation
import SonovoCore

/// How the code surface is presented.
enum CodeViewMode: String, CaseIterable, Sendable, Identifiable {
    case source
    case unifiedDiff
    case splitDiff

    var id: String { rawValue }

    var label: String {
        switch self {
        case .source: "Source"
        case .unifiedDiff: "Unified"
        case .splitDiff: "Side by Side"
        }
    }

    var isDiff: Bool { self != .source }
}

/// A destination whose overwrite the user already confirmed. The captured
/// bytes are the precondition; a destination that changed after the
/// confirmation is refused rather than silently replaced.
struct CodeOverwriteConfirmation: Equatable, Sendable {
    let url: URL
    let expected: DiskSnapshot
}

/// A disk change that conflicts with a dirty buffer.
struct CodeConflict: Equatable, Sendable {
    /// The disk bytes, when they could be captured within the read cap. When
    /// `diskIsExact` is false this is the last known snapshot, kept only so
    /// the model always has a comparison baseline; it is not the disk's
    /// current content.
    let diskSnapshot: DiskSnapshot
    let diskText: String?
    let detail: String
    /// Whether `diskSnapshot` is the exact current disk content. A binary or
    /// over-cap file cannot be captured; Keep Mine then overwrites without a
    /// compare-and-swap instead of looping on a stale expectation.
    let diskIsExact: Bool

    init(
        diskSnapshot: DiskSnapshot,
        diskText: String?,
        detail: String,
        diskIsExact: Bool = true
    ) {
        self.diskSnapshot = diskSnapshot
        self.diskText = diskText
        self.detail = detail
        self.diskIsExact = diskIsExact
    }
}

/// What the next save may assume about the bytes on disk.
enum CodeSaveBaseline: Equatable, Sendable {
    /// The exact bytes the buffer's text is based on; save compares against
    /// them.
    case exact(DiskSnapshot)
    /// The disk could not be captured within the read cap, and the user chose
    /// Keep Mine. The next save overwrites without a compare-and-swap when
    /// the file is replaceable within the cap; a destination above the cap is
    /// refused in place with a Save As suggestion, never read without a
    /// bound.
    case unknown
}

enum CodeExternalChange: Equatable, Sendable {
    case none
    /// Clean and visible: the buffer followed the disk.
    case adopted
    /// Clean and hidden: the disk advanced, the acknowledged baseline did
    /// not. The tab offers A→C when the project becomes visible.
    case pendingReview
    case conflict(CodeConflict)
    case deleted
}

enum CodeResolution: Equatable, Sendable {
    case reload
    case keepLocal
}

enum CodeDocumentError: Error, Equatable {
    case readOnly
    case closed
    case notReady
    case staleCompletion
    case overwriteConfirmationRequired(URL, DiskSnapshot)
    case destinationChanged
    case diskChangedDuringRevert
    case readFailed(String)
}

/// One open code document.
///
/// Three exact baselines are kept independently: the bytes the user last saw
/// or accepted (`lastAcknowledged`), the bytes of the last successful save
/// (`lastSaved`), and the current disk bytes (`diskSnapshot`). None of them is
/// a revision number; comparing them is byte equality.
@MainActor
@Observable
final class CodeDocument: Identifiable {
    enum State: Equatable, Sendable {
        case loading
        case ready
        case refused(CodeRefusal)
    }

    let id = UUID()
    let undoManager = UndoManager()

    private(set) var fileURL: URL
    /// The path this document had before its most recent successful Save As.
    /// The project uses it to move the tab from the old identity.
    private(set) var previousFileURL: URL?
    private(set) var language: CodeLanguage
    private(set) var state: State = .loading
    private(set) var source = ""
    private(set) var revision: UInt64 = 0
    private(set) var savedRevision: UInt64 = 0
    private(set) var identityGeneration: UInt64 = 0

    private(set) var diskSnapshot: DiskSnapshot?
    private(set) var lastAcknowledged: DiskSnapshot?
    private(set) var lastSaved: DiskSnapshot?
    /// The disk bytes the buffer's text is actually based on. Reviewing a
    /// hidden change advances `lastAcknowledged`, but the buffer is still
    /// based on the older bytes until it is reloaded; saves must compare
    /// against this baseline, not against what the user merely viewed.
    private(set) var bufferBaseline: CodeSaveBaseline?

    private(set) var lineEnding: LineEnding = .lf
    private(set) var hasBOM = false
    private(set) var readOnlyReason: CodeReadOnlyReason?
    private(set) var conflict: CodeConflict?
    private(set) var isMissingOnDisk = false
    /// The disk advanced while the project was hidden. The source and the
    /// acknowledged baseline did not move.
    private(set) var pendingReview = false
    private(set) var isClosed = false
    private(set) var lastError: String?

    var selection: Range<Int>?
    var viewMode: CodeViewMode = .source
    /// The A→C pair captured when the user opened the review diff.
    private(set) var reviewedDiff: CodeDiffPair?

    private let store: MarkdownFileStore
    private let reader: CodeFileReader
    private var firstPendingEdit: Date?
    private var lastEdit: Date?
    private var saveInFlight = false
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingArtifactsToClean: [URL] = []
    private var queuedResolution: Task<Void, Never>?
    private var queuedResolutionGeneration: UInt64 = 0

    init(
        url: URL,
        store: MarkdownFileStore = MarkdownFileStore(),
        reader: CodeFileReader = CodeFileReader()
    ) {
        fileURL = url
        language = CodeLanguage.language(for: url)
        self.store = store
        self.reader = reader
        undoManager.groupsByEvent = false
    }

    // MARK: - Loading

    /// Reads the file through the bounded reader. The read, decode, and hash
    /// run off the main actor; only the bounded result is applied here.
    func load() async {
        guard state == .loading, !isClosed else { return }
        let url = fileURL
        let reader = self.reader
        do {
            let outcome = try await Task.detached(priority: .userInitiated) {
                try reader.read(url: url)
            }.value
            guard !isClosed else { return }
            apply(outcome)
        } catch {
            guard !isClosed else { return }
            state = .refused(
                .unreadable("Cannot open \(url.lastPathComponent): \(error)")
            )
            lastError = "Cannot open \(url.lastPathComponent): \(error)"
        }
    }

    private func apply(_ outcome: CodeFileReadOutcome) {
        switch outcome {
        case .refused(let refusal):
            state = .refused(refusal)
            readOnlyReason = nil
        case .loaded(let read):
            // The reader bounds the allocation; this second check protects
            // the model from a snapshot that changed between read and apply.
            guard read.byteCount <= CodeLimits.maximumReadBytes else {
                refuse(.tooLarge(byteCount: Int64(read.byteCount)))
                return
            }
            state = .ready
            source = read.contents.canonicalText
            diskSnapshot = read.snapshot
            // The diff baseline is retained only at or below the editable
            // cap; a read-only large file has no diff.
            let retainsBaseline = read.byteCount <= CodeLimits.editableBytes
            lastAcknowledged = retainsBaseline ? read.snapshot : nil
            lastSaved = retainsBaseline ? read.snapshot : nil
            bufferBaseline = .exact(read.snapshot)
            lineEnding = read.contents.lineEnding
            hasBOM = read.contents.hasBOM
            readOnlyReason = read.readOnlyReason
                ?? (Self.permissionsReadOnly(read.url) ? .permissions : nil)
            revision = 1
            savedRevision = 1
            conflict = nil
            pendingReview = false
        }
    }

    /// Replaces the contents with a refused state, for a file that grew past
    /// the read cap while it was open.
    private func refuse(_ reason: CodeRefusal) {
        state = .refused(reason)
        readOnlyReason = nil
        source = ""
        diskSnapshot = nil
        lastAcknowledged = nil
        lastSaved = nil
        bufferBaseline = nil
        conflict = nil
        pendingReview = false
    }

    func markClosed() {
        isClosed = true
    }

    // MARK: - State

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var refusal: CodeRefusal? {
        if case .refused(let refusal) = state { return refusal }
        return nil
    }

    var isReadOnly: Bool {
        !isReady || readOnlyReason != nil
    }

    var isEditable: Bool {
        isReady && readOnlyReason == nil && !isClosed
    }

    /// A permission read-only file may become writable; the save attempt
    /// re-checks instead of freezing the command forever.
    var canAttemptSave: Bool {
        isReady && !isClosed
            && (readOnlyReason == nil || readOnlyReason == .permissions)
    }

    var isDirty: Bool {
        isReady && revision != savedRevision
    }

    var displayName: String {
        fileURL.lastPathComponent
    }

    var hasDiffBaseline: Bool {
        lastAcknowledged != nil && diskSnapshot != nil
    }

    /// The diff pair offered by the viewer. A pending hidden change keeps the
    /// acknowledged baseline until the user views the diff; a dirty buffer
    /// offers its own text against the disk baseline.
    var availableDiff: CodeDiffAvailability {
        if let reviewed = reviewedDiff {
            return .available(reviewed)
        }
        if isDirty {
            let buffer = DiskSnapshot(bytes: encodeSource())
            if let saved = lastSaved {
                return CodeDiffModel.availability(
                    left: saved,
                    right: buffer,
                    leftLabel: "Saved",
                    rightLabel: "Buffer"
                )
            }
            guard let disk = diskSnapshot else {
                return .unavailable("No disk baseline is available.")
            }
            return CodeDiffModel.availability(
                left: disk,
                right: buffer,
                leftLabel: "Disk",
                rightLabel: "Buffer"
            )
        }
        guard let left = lastAcknowledged, let right = diskSnapshot else {
            return .unavailable(
                "Diff is unavailable: this file was opened above the 2 MB "
                    + "editing limit."
            )
        }
        return CodeDiffModel.availability(
            left: left,
            right: right,
            leftLabel: "Acknowledged",
            rightLabel: "Disk"
        )
    }

    /// Captures the current A→C pair, then advances the acknowledged
    /// baseline. The pair stays visible until the user leaves the diff.
    func captureReviewDiff() {
        // A dirty buffer's diff is Saved→Buffer, computed on demand; it
        // must not advance the acknowledged disk baseline.
        guard !isDirty else { return }
        guard let left = lastAcknowledged, let right = diskSnapshot else {
            return
        }
        guard case .available = CodeDiffModel.availability(
            left: left,
            right: right,
            leftLabel: "Acknowledged",
            rightLabel: "Disk"
        ) else {
            return
        }
        reviewedDiff = CodeDiffPair(
            leftLabel: "Acknowledged",
            rightLabel: "Disk",
            left: left,
            right: right
        )
        lastAcknowledged = right
        pendingReview = false
    }

    func clearReviewedDiff() {
        reviewedDiff = nil
    }

    // MARK: - Editing

    func replaceSource(
        _ newSource: String,
        actionName: String = "Edit"
    ) throws {
        guard isEditable else {
            if isReady {
                throw CodeDocumentError.readOnly
            }
            throw CodeDocumentError.notReady
        }
        guard newSource.utf8.elementsEqual(source.utf8) == false else {
            return
        }

        let oldSource = source
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { document in
            try? document.replaceSource(oldSource, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()

        source = newSource
        revision += 1
        lastEdit = Date()
        if firstPendingEdit == nil {
            firstPendingEdit = lastEdit
        }
        // A local edit invalidates a captured review pair; the next diff is
        // computed from the current baselines.
        reviewedDiff = nil
    }

    func autosaveDelay(now: Date = Date()) -> TimeInterval? {
        guard isDirty, isEditable, state == .ready else { return nil }
        guard let lastEdit, let firstPendingEdit else { return nil }
        return Autosave.delay(
            lastEdit: lastEdit,
            firstPendingEdit: firstPendingEdit,
            now: now
        )
    }

    // MARK: - Saving

    @discardableResult
    func save(
        mode: SaveMode = .automatic,
        hooks: SaveHooks? = nil
    ) async throws -> SaveOutcome? {
        guard !isClosed else { throw CodeDocumentError.closed }
        guard isReady else { throw CodeDocumentError.notReady }
        if readOnlyReason == .permissions {
            // A previous save may have failed because the file was locked;
            // re-check before refusing, so restoring permission recovers.
            if Self.permissionsReadOnly(fileURL) {
                throw CodeDocumentError.readOnly
            }
            readOnlyReason = nil
        } else if readOnlyReason != nil {
            throw CodeDocumentError.readOnly
        }
        if !isDirty, diskSnapshot != nil { return nil }

        await acquireSaveSlot()
        defer { releaseSaveSlot() }
        guard !isClosed else { throw CodeDocumentError.closed }
        guard isReady else { throw CodeDocumentError.notReady }
        if !isDirty, diskSnapshot != nil { return nil }

        let destination = fileURL
        if Self.permissionsReadOnly(destination) {
            readOnlyReason = .permissions
            throw CodeDocumentError.readOnly
        }
        if bufferBaseline == .unknown,
           let size = try? destination.resourceValues(
               forKeys: [.fileSizeKey]
           ).fileSize,
           size > CodeLimits.maximumReadBytes {
            // Keep Mine accepted a disk that could not be captured. Replacing
            // a file this large would require reading and preserving it
            // without a bound; Save As is the safe route.
            throw CodeDocumentError.readFailed(
                "The file on disk is now too large to replace safely; "
                    + "use Save As."
            )
        }

        let generation = identityGeneration
        let revisionAtStart = revision
        let data = encodeSource()
        // The expected bytes are the bytes this buffer was based on. After a
        // hidden external change those are `lastAcknowledged`, not the newer
        // disk bytes; the save must detect the difference rather than
        // overwrite an unreviewed version. An unknown baseline exists only
        // after an explicit Keep Mine against a disk that could not be
        // captured, and only that decision authorizes an overwrite.
        let effectiveMode: SaveMode = bufferBaseline == .unknown
            ? .explicitOverwrite
            : mode
        let request = SaveRequest(
            documentID: id,
            identityGeneration: generation,
            sourceRevision: revisionAtStart,
            destination: destination,
            expectedDisk: expectedDisk,
            data: data,
            mode: effectiveMode,
            hooks: hooks,
            maximumReplacedBytes: CodeLimits.maximumReadBytes
        )

        do {
            let outcome = try await runSave(request)
            guard !isClosed else { throw CodeDocumentError.closed }
            guard identityGeneration == generation else {
                throw CodeDocumentError.staleCompletion
            }
            adoptSave(outcome, revisionAtStart: revisionAtStart)
            return outcome
        } catch let error as SaveError {
            if case .diskChanged(let artifacts) = error {
                let conflictURL = artifacts.displaced.flatMap {
                    FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
                } ?? destination
                conflict = await readConflict(at: conflictURL)
            }
            lastError = String(describing: error)
            throw error
        } catch {
            lastError = String(describing: error)
            throw error
        }
    }

    /// Saves to a new destination and only then switches identity.
    ///
    /// The destination contract is explicit:
    /// - the same path uses this document's own baseline;
    /// - a new path that exists requires a confirmation carrying the exact
    ///   bytes that were shown to the user;
    /// - a new path that does not exist is created exclusively.
    @discardableResult
    func saveAs(
        to url: URL,
        overwrite: CodeOverwriteConfirmation? = nil,
        hooks: SaveHooks? = nil
    ) async throws -> SaveOutcome {
        guard !isClosed else { throw CodeDocumentError.closed }
        guard isReady else { throw CodeDocumentError.notReady }
        guard readOnlyReason == nil || readOnlyReason == .permissions else {
            throw CodeDocumentError.readOnly
        }

        let target = MarkdownSecurity.canonical(url.standardizedFileURL)

        await acquireSaveSlot()
        defer { releaseSaveSlot() }
        guard !isClosed, isReady else { throw CodeDocumentError.closed }
        // A watcher may have adopted a mixed-ending, lone-CR, or otherwise
        // unsupported representation while this call waited for the slot.
        // Encoding the canonical text would then replace that exact form.
        guard readOnlyReason == nil || readOnlyReason == .permissions else {
            throw CodeDocumentError.readOnly
        }

        // Every identity-dependent decision is made after the slot. A Save
        // As that ran while this call waited has already changed fileURL.
        let destinationExists = FileManager.default.fileExists(
            atPath: target.path
        )
        if destinationExists {
            if Self.permissionsReadOnly(target) {
                throw CodeDocumentError.readFailed(
                    "The destination is not writable."
                )
            }
        } else if !FileManager.default.isWritableFile(
            atPath: target.deletingLastPathComponent().path
        ) {
            throw CodeDocumentError.readFailed(
                "The destination folder is not writable."
            )
        }
        let samePath = MarkdownSecurity.canonical(fileURL).path
            == target.path

        let expected: DiskSnapshot?
        let mode: SaveMode
        if samePath {
            // The document's baseline, not a fresh read of the destination.
            guard bufferBaseline != nil || diskSnapshot != nil else {
                throw CodeDocumentError.notReady
            }
            expected = expectedDisk
            mode = .explicitOverwrite
        } else {
            let reader = self.reader
            let inspected = try await Task.detached(
                priority: .userInitiated
            ) {
                try reader.boundedData(at: target)
            }.value
            switch inspected {
            case .absent:
                expected = nil
                mode = .automatic
            case .tooLarge:
                throw CodeDocumentError.readFailed(
                    "The destination is above the 8 MB limit."
                )
            case .notRegular:
                throw CodeDocumentError.readFailed(
                    "The destination is not a regular file."
                )
            case .data(let data):
                let current = DiskSnapshot(bytes: data)
                guard let overwrite else {
                    throw CodeDocumentError.overwriteConfirmationRequired(
                        target,
                        current
                    )
                }
                guard overwrite.url == target,
                      overwrite.expected == current else {
                    throw CodeDocumentError.destinationChanged
                }
                expected = current
                mode = .explicitOverwrite
            }
        }

        let revisionAtStart = revision
        let data = encodeSource()
        let request = SaveRequest(
            documentID: id,
            identityGeneration: identityGeneration,
            sourceRevision: revisionAtStart,
            destination: target,
            expectedDisk: expected,
            data: data,
            mode: mode,
            hooks: hooks,
            maximumReplacedBytes: CodeLimits.maximumReadBytes
        )
        let outcome = try await runSave(request)
        // A close during the write must not resurrect the document's
        // identity or install a new file URL.
        guard !isClosed else { throw CodeDocumentError.closed }

        previousFileURL = fileURL
        fileURL = target
        language = CodeLanguage.language(for: target)
        identityGeneration += 1
        isMissingOnDisk = false
        reviewedDiff = nil
        adoptSave(outcome, revisionAtStart: revisionAtStart)
        refreshReadOnlyPolicy()
        return outcome
    }

    /// Discards the buffer and reloads the exact disk bytes. Refused while a
    /// conflict is unresolved; a disk that changes during the operation is
    /// read again, and one that keeps changing aborts. The save slot is held
    /// for the whole operation so a save, Save As, or edit cannot interleave.
    func revertToDisk() async throws {
        guard conflict == nil else { throw CodeDocumentError.readFailed(
            "Resolve the conflict before reverting."
        ) }
        guard !isClosed, isReady else { throw CodeDocumentError.notReady }

        await acquireSaveSlot()
        defer { releaseSaveSlot() }
        guard !isClosed, isReady else { throw CodeDocumentError.closed }
        // A watcher can establish a conflict while this call waits for the
        // slot; reverting would then discard edits the user has not resolved.
        guard conflict == nil else { throw CodeDocumentError.readFailed(
            "Resolve the conflict before reverting."
        ) }

        let generation = identityGeneration
        let revisionAtStart = revision
        let url = fileURL
        let expected = diskSnapshot
        let first = try await readDisk(at: url)
        var read = first
        if let expected, first.snapshot != expected {
            let second = try await readDisk(at: url)
            guard second.snapshot == first.snapshot else {
                throw CodeDocumentError.diskChangedDuringRevert
            }
            read = second
        }
        guard !isClosed,
              identityGeneration == generation,
              fileURL == url,
              revision == revisionAtStart else {
            throw CodeDocumentError.staleCompletion
        }
        applyDisk(read)
    }

    /// The close flush: save pending edits, or report why a decision is
    /// needed. Mirrors Markdown's contract.
    func flushForClose(hooks: SaveHooks? = nil) async -> CloseOutcome {
        // A queued conflict decision is pending work: let it land before
        // deciding that a clean buffer can close without saving.
        await waitForQueuedConflictResolution()
        guard isDirty else { return .closed }
        do {
            try await save(mode: .automatic, hooks: hooks)
            return isDirty
                ? .needsDecision(.saveFailed("save did not clear dirty"))
                : .closed
        } catch {
            return .needsDecision(.saveFailed(String(describing: error)))
        }
    }

    // MARK: - External changes

    /// Revalidates the disk. Exact bytes, not soft text equality: a BOM, line
    /// ending, or final-newline change is a conflict while dirty.
    func checkExternalChange(projectVisible: Bool) async -> CodeExternalChange {
        await acquireSaveSlot()
        defer { releaseSaveSlot() }
        guard !isClosed, isReady else { return .none }

        let url = fileURL
        let reader = self.reader
        let outcome: CodeFileReadOutcome
        do {
            outcome = try await Task.detached(priority: .userInitiated) {
                try reader.readSnapshot(url: url)
            }.value
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoSuchFileError
                || nsError.code == NSFileNoSuchFileError {
                isMissingOnDisk = true
                return .deleted
            }
            lastError = "Cannot re-read \(url.lastPathComponent): \(error)"
            return .none
        }

        switch outcome {
        case .refused(.tooLarge):
            // The file crossed the read cap. Keep the buffer editable so the
            // user can save elsewhere, and name the state. The disk bytes
            // cannot be captured, so Keep Mine overwrites unconditionally.
            let conflict = CodeConflict(
                diskSnapshot: diskSnapshot ?? DiskSnapshot(bytes: Data()),
                diskText: nil,
                detail: "The file on disk is now above the 8 MB read limit.",
                diskIsExact: false
            )
            self.conflict = conflict
            return .conflict(conflict)
        case .refused(let refusal):
            // Binary or an encoding this viewer refuses. The bytes are still
            // within the cap, so capture them exactly; Reload stays disabled
            // because there is no text to install.
            let bounded = try? await Task.detached(priority: .userInitiated) {
                try reader.boundedData(at: url)
            }.value
            let snapshot: DiskSnapshot
            let diskIsExact: Bool
            if case .data(let data)? = bounded {
                snapshot = DiskSnapshot(bytes: data)
                diskIsExact = true
            } else {
                snapshot = diskSnapshot ?? DiskSnapshot(bytes: Data())
                diskIsExact = false
            }
            let conflict = CodeConflict(
                diskSnapshot: snapshot,
                diskText: nil,
                detail: refusal.explanation,
                diskIsExact: diskIsExact
            )
            self.conflict = conflict
            return .conflict(conflict)
        case .loaded(let read):
            isMissingOnDisk = false
            // The disk matches the bytes the buffer is based on: whatever
            // conflict or review existed is moot.
            if let baseline = exactBaseline, read.snapshot == baseline {
                conflict = nil
                return .none
            }
            if read.snapshot == diskSnapshot {
                // An unchanged disk must not dismiss a pending review, nor a
                // conflict a failed save established against the buffer's
                // older baseline. Only the user resolves those.
                return .none
            }

            if isDirty {
                // Any exact-byte difference is a conflict while dirty.
                let conflict = CodeConflict(
                    diskSnapshot: read.snapshot,
                    diskText: read.contents.canonicalText,
                    detail: "This file changed on disk. Reload or keep mine."
                )
                self.conflict = conflict
                return .conflict(conflict)
            }

            if projectVisible {
                applyDisk(read)
                return .adopted
            } else {
                // Only the disk advances. A→C stays available because the
                // acknowledged baseline did not move.
                diskSnapshot = read.snapshot
                pendingReview = true
                return .pendingReview
            }
        }
    }

    func resolveConflict(_ resolution: CodeResolution) async {
        // Serialize with saves and Save As. A resolution that runs while a
        // write is in flight would base itself on a conflict the write is
        // about to invalidate — or install text the write then replaces
        // while the buffer looks clean. After the slot, the conflict is
        // read again; a save that resolved it already makes this a no-op.
        await acquireSaveSlot()
        defer { releaseSaveSlot() }
        applyConflictResolution(resolution)
    }

    /// Test seam: fires just before the queued path waits for the slot, so a
    /// test can prove it entered the wait instead of racing the write.
    @ObservationIgnored
    var conflictResolutionWaitHook: (() -> Void)?

    /// Applies a resolution without waiting when no write is in flight.
    /// Returns false when the caller must queue it behind the save slot.
    /// The banner uses this path so its decision takes effect before the
    /// click returns and cannot be lost to a close or termination.
    @discardableResult
    func resolveConflictImmediately(_ resolution: CodeResolution) -> Bool {
        guard !saveInFlight else { return false }
        applyConflictResolution(resolution)
        return true
    }

    /// Whether a decision is waiting for the slot. Close and termination
    /// treat it like unsaved work: dropping it would discard an explicit
    /// Keep Mine or Reload.
    var hasQueuedConflictResolution: Bool { queuedResolution != nil }

    /// Queues a resolution behind the current slot holder and retains the
    /// task so a close can wait for the decision to land. A new decision
    /// chains after the previous one: replacing the handle outright could
    /// leave the older task untracked and let a close overtake it.
    func queueConflictResolution(_ resolution: CodeResolution) {
        let previous = queuedResolution
        queuedResolutionGeneration &+= 1
        let generation = queuedResolutionGeneration
        queuedResolution = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            self.conflictResolutionWaitHook?()
            await self.resolveConflict(resolution)
            if self.queuedResolutionGeneration == generation {
                self.queuedResolution = nil
            }
        }
    }

    /// Waits for every queued decision, including one queued while an
    /// earlier one was landing. The task itself waits for the slot, so a
    /// close cannot overtake it.
    func waitForQueuedConflictResolution() async {
        while let task = queuedResolution {
            await task.value
        }
    }

    private func applyConflictResolution(_ resolution: CodeResolution) {
        guard !isClosed, let conflict else { return }
        switch resolution {
        case .reload:
            // Only an exact, decodable disk state can become the buffer.
            guard conflict.diskIsExact, let text = conflict.diskText else {
                // The disk cannot be decoded as text; reloading would replace
                // the buffer with an empty editor. Keep the conflict open.
                return
            }
            source = text
            lineEnding = (try? MarkdownEncoding.decode(
                conflict.diskSnapshot.bytes
            ))?.lineEnding ?? lineEnding
            hasBOM = (try? MarkdownEncoding.decode(
                conflict.diskSnapshot.bytes
            ))?.hasBOM ?? hasBOM
            diskSnapshot = conflict.diskSnapshot
            lastAcknowledged = conflict.diskSnapshot
            lastSaved = conflict.diskSnapshot
            bufferBaseline = .exact(conflict.diskSnapshot)
            revision += 1
            savedRevision = revision
            firstPendingEdit = nil
            undoManager.removeAllActions()
            self.conflict = nil
            pendingReview = false
            reviewedDiff = nil
            refreshReadOnlyPolicy()
        case .keepLocal:
            // The buffer becomes the acknowledged version; the next save
            // compares against the disk bytes the conflict captured. A clean
            // buffer is now unsaved relative to that disk, so it must be
            // marked dirty or the next Save would be a no-op. An
            // uncapturable disk (binary or over the read cap) becomes an
            // unconditional overwrite: an exact expectation that we do not
            // have would only reproduce the same conflict.
            diskSnapshot = conflict.diskSnapshot
            lastAcknowledged = conflict.diskSnapshot
            bufferBaseline = conflict.diskIsExact
                ? .exact(conflict.diskSnapshot)
                : .unknown
            if !isDirty {
                savedRevision = revision > 0 ? revision - 1 : 0
                firstPendingEdit = Date()
                lastEdit = firstPendingEdit
            }
            self.conflict = nil
            pendingReview = false
        }
    }

    /// Applies a reload that the user requested for a hidden change.
    func reloadPendingDiskChange() async throws {
        guard pendingReview else { return }
        try await revertToDisk()
    }

    // MARK: - Reference

    /// A one-line reference for the current selection or caret.
    func reference(relativeTo root: URL?) -> String {
        let offset = selection?.lowerBound ?? 0
        let location = lineColumn(at: offset)
        let path: String
        if let root,
           MarkdownSecurity.contains(fileURL, in: root) {
            let rootPath = MarkdownSecurity.canonical(root).path
            let full = MarkdownSecurity.canonical(fileURL).path
            path = String(full.dropFirst(rootPath.count + 1))
        } else {
            path = fileURL.path
        }
        return "\(path):\(location.line):\(location.column)"
    }

    func lineColumn(at offset: Int) -> (line: Int, column: Int) {
        let ns = source as NSString
        let clamped = min(max(0, offset), ns.length)
        var line = 1
        var lineStart = 0
        var index = 0
        while index < clamped {
            if ns.character(at: index) == 0x0A {
                line += 1
                lineStart = index + 1
            }
            index += 1
        }
        return (line, clamped - lineStart + 1)
    }

    /// The UTF-16 offset of a 1-based line and column.
    func offset(line: Int, column: Int) -> Int {
        let ns = source as NSString
        var currentLine = 1
        var index = 0
        while currentLine < line, index < ns.length {
            if ns.character(at: index) == 0x0A {
                currentLine += 1
            }
            index += 1
        }
        let columnOffset = max(0, column - 1)
        return min(ns.length, index + columnOffset)
    }

    // MARK: - Internals

    /// The bytes the buffer is based on, when they are known exactly.
    private var exactBaseline: DiskSnapshot? {
        if case .exact(let snapshot) = bufferBaseline { return snapshot }
        return nil
    }

    /// The bytes the next save compares against. `nil` means unconditional,
    /// which only an explicit Keep Mine against an uncapturable disk
    /// produces; it is never a fallback for an unknown baseline.
    private var expectedDisk: DiskSnapshot? {
        switch bufferBaseline {
        case .exact(let snapshot): return snapshot
        case .unknown: return nil
        case nil: return diskSnapshot
        }
    }

    private func encodeSource() -> Data {
        MarkdownEncoding.encode(
            source,
            hasBOM: hasBOM,
            lineEnding: lineEnding
        )
    }

    private func runSave(_ request: SaveRequest) async throws -> SaveOutcome {
        let store = self.store
        return try await Task.detached(priority: .userInitiated) {
            try store.save(request)
        }.value
    }

    private func adoptSave(
        _ outcome: SaveOutcome,
        revisionAtStart: UInt64
    ) {
        diskSnapshot = outcome.snapshot
        lastSaved = outcome.snapshot
        lastAcknowledged = outcome.snapshot
        bufferBaseline = .exact(outcome.snapshot)
        for url in pendingArtifactsToClean {
            try? FileManager.default.removeItem(at: url)
        }
        pendingArtifactsToClean.removeAll()
        if let newContent = outcome.artifacts.newContent {
            pendingArtifactsToClean.append(newContent)
        }
        if let displaced = outcome.artifacts.displaced {
            pendingArtifactsToClean.append(displaced)
        }

        if revision == revisionAtStart {
            savedRevision = revisionAtStart
            firstPendingEdit = nil
        } else {
            firstPendingEdit = lastEdit
        }
        conflict = nil
        pendingReview = false
        lastError = nil
    }

    private func applyDisk(_ read: CodeFileRead) {
        source = read.contents.canonicalText
        lineEnding = read.contents.lineEnding
        hasBOM = read.contents.hasBOM
        diskSnapshot = read.snapshot
        let retainsBaseline = read.byteCount <= CodeLimits.editableBytes
        lastAcknowledged = retainsBaseline ? read.snapshot : nil
        lastSaved = retainsBaseline ? read.snapshot : nil
        bufferBaseline = .exact(read.snapshot)
        revision += 1
        savedRevision = revision
        firstPendingEdit = nil
        undoManager.removeAllActions()
        conflict = nil
        pendingReview = false
        reviewedDiff = nil
        refreshReadOnlyPolicy()
    }

    private func readDisk(at url: URL) async throws -> CodeFileRead {
        let reader = self.reader
        let outcome = try await Task.detached(priority: .userInitiated) {
            try reader.readSnapshot(url: url)
        }.value
        switch outcome {
        case .loaded(let read):
            return read
        case .refused(let refusal):
            throw CodeDocumentError.readFailed(refusal.explanation)
        }
    }

    private func readConflict(at url: URL?) async -> CodeConflict? {
        guard let url else { return nil }
        let reader = self.reader
        let bounded = try? await Task.detached(priority: .userInitiated) {
            try reader.boundedData(at: url)
        }.value
        switch bounded {
        case .data(let data):
            // The same decode rules as the reader: a reload must never
            // install text the reader would have refused to open.
            let text: String?
            var detail = "This file changed on disk. Reload or keep mine."
            switch CodeFileReader.decodeBounded(data) {
            case .text(let contents):
                text = contents.canonicalText
            case .refused(let refusal):
                text = nil
                detail = "This file changed on disk and can no longer be "
                    + "shown. " + refusal.explanation
            }
            return CodeConflict(
                diskSnapshot: DiskSnapshot(bytes: data),
                diskText: text,
                detail: detail,
                diskIsExact: true
            )
        case .tooLarge:
            return CodeConflict(
                diskSnapshot: diskSnapshot ?? DiskSnapshot(bytes: Data()),
                diskText: nil,
                detail: "The changed file is above the 8 MB read limit.",
                diskIsExact: false
            )
        case .absent, .none, .notRegular:
            return nil
        }
    }

    private func refreshReadOnlyPolicy() {
        guard isReady else { return }
        var reason: CodeReadOnlyReason?
        if let snapshot = diskSnapshot,
           snapshot.byteCount > CodeLimits.editableBytes {
            reason = .size(byteCount: snapshot.byteCount)
        } else if let decoded = diskSnapshot.flatMap({
            try? MarkdownEncoding.decode($0.bytes)
        }), decoded.hadMixedLineEndings {
            reason = .mixedLineEndings
        } else if let bytes = diskSnapshot?.bytes,
                  CodeFileReader.hasLoneCarriageReturn(bytes) {
            reason = .loneCarriageReturn
        } else if Self.permissionsReadOnly(fileURL) {
            reason = .permissions
        }
        readOnlyReason = reason
    }

    static func permissionsReadOnly(_ url: URL) -> Bool {
        let manager = FileManager.default
        guard manager.isWritableFile(atPath: url.path) else { return true }
        return !manager.isWritableFile(
            atPath: url.deletingLastPathComponent().path
        )
    }

    private func acquireSaveSlot() async {
        while saveInFlight {
            await withCheckedContinuation { continuation in
                saveWaiters.append(continuation)
            }
        }
        saveInFlight = true
    }

    private func releaseSaveSlot() {
        saveInFlight = false
        let waiters = saveWaiters
        saveWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

// MARK: - Diff support

/// One side pair captured for display. The model never recomputes from a
/// newer revision while a review is on screen.
struct CodeDiffPair: Equatable, Sendable {
    let leftLabel: String
    let rightLabel: String
    let left: DiskSnapshot
    let right: DiskSnapshot
}

enum CodeDiffAvailability: Equatable, Sendable {
    case available(CodeDiffPair)
    case unavailable(String)
}

extension CodeDocument: Autosaveable {
    var hasUnresolvedConflict: Bool { conflict != nil }

    func autosave() async throws {
        _ = try await save(mode: .automatic)
    }

    func isClosedError(_ error: Error) -> Bool {
        (error as? CodeDocumentError) == .closed
    }
}
