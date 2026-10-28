import Foundation
import Observation

/// How a document is currently presented.
public enum MarkdownDocumentMode: String, Sendable, Equatable {
    case source
    case rendered
}

/// The autosave policy: one short idle delay with a hard ceiling.
public enum Autosave {
    public static let idleDelay: TimeInterval = 1.0
    public static let maxDelay: TimeInterval = 5.0

    /// The delay before the next autosave, or `nil` when nothing is pending.
    public static func delay(
        lastEdit: Date,
        firstPendingEdit: Date,
        now: Date
    ) -> TimeInterval? {
        guard now >= lastEdit else { return idleDelay }
        let byIdle = lastEdit.addingTimeInterval(idleDelay)
        let byCeiling = firstPendingEdit.addingTimeInterval(maxDelay)
        let due = min(byIdle, byCeiling)
        return max(0, due.timeIntervalSince(now))
    }
}

/// The disk changed underneath a dirty document.
public struct ExternalConflict: Sendable, Equatable {
    public let diskSnapshot: DiskSnapshot
    public let diskText: String
}

/// What an external-change check found.
public enum ExternalChange: Sendable, Equatable {
    case none
    case adopted
    case deleted
    case conflict(ExternalConflict)
}

/// A resolved external-change decision.
public enum ExternalResolution: Sendable, Equatable {
    case reload
    case keepLocal
}

/// Why a close could not finish.
public enum CloseBlocker: Sendable, Equatable {
    case untitled
    case saveFailed(String)
}

/// The result of a close/quit flush.
public enum CloseOutcome: Sendable, Equatable {
    case closed
    case needsDecision(CloseBlocker)
}

public enum MarkdownRestoreError: Error, Equatable {
    case unsupportedEncoding
    case tooLarge
    case staleDisk
    case readOnly
    case untitled
    case closed
}

public enum DocumentError: Error, Equatable {
    case readOnly
    case untitled
    case closed
    case readFailed(String)
    case staleCompletion
    case editTooLarge
}

/// Why a document is forced to Source mode.
public enum ForcedSourceReason: String, Sendable, Equatable {
    /// The file was admitted read-only above the editable threshold.
    case large
    /// The open buffer grew past the editable threshold through editing.
    case largeBuffer
    /// A snapshot above the editable threshold was restored editable for
    /// this session. Rendered/parse stays off, but the buffer is not
    /// read-only: commit, undo, and the ordinary save path all apply.
    case largeRestored
    /// The parser refused the container nesting.
    case nestingLimit
    /// The live buffer exceeded the read cap or line cap.
    case bufferCap
}

/// The external file's state while the document stays open.
public enum MarkdownDiskState: Sendable, Equatable {
    case readable
    case tooLarge
    case unreadable(String)
}

/// One open Markdown document.
///
/// The document owns the canonical source, the raw disk snapshot, encoding,
/// revision, selection, mode, and the undo stack. The editor view is a
/// projection of this state and never a second owner of it.
@MainActor
@Observable
public final class MarkdownDocument: Identifiable {
    public let id = UUID()
    public let undoManager = UndoManager()

    public private(set) var fileURL: URL?
    /// Bumped whenever document identity changes (Save As).
    public private(set) var identityGeneration: UInt64 = 0

    public private(set) var source: String
    /// `source`'s length in UTF-16 units, kept beside it so the editor can
    /// test "the text view still holds this source" in O(1). A whole-source
    /// `String ==` costs ~90 ms per megabyte (canonical equivalence walks
    /// graphemes), and the editor asks this on every keystroke.
    public private(set) var sourceUTF16Count: Int
    public private(set) var revision: UInt64 = 0
    public private(set) var savedRevision: UInt64 = 0

    public private(set) var diskSnapshot: DiskSnapshot?
    public private(set) var lineEnding: LineEnding
    public private(set) var hasBOM: Bool
    public private(set) var isReadOnly: Bool
    public private(set) var isLarge: Bool
    /// A visible reason for Source-only presentation. `nil` when Rendered is
    /// eligible.
    public private(set) var forcedSourceReason: ForcedSourceReason?
    /// The external file's state while this document stays open.
    public private(set) var diskState: MarkdownDiskState = .readable
    /// The file this document was loaded from is gone from disk.
    public private(set) var isMissingOnDisk = false
    /// The workspace discarded this document. Queued saves must not run.
    public private(set) var isClosed = false

    public var mode: MarkdownDocumentMode = .source
    public var selection: Range<Int>?

    public private(set) var conflict: ExternalConflict?
    public private(set) var lastSaveArtifacts: SaveArtifacts?
    public private(set) var lastError: String?

    private let store: MarkdownFileStore
    private var firstPendingEdit: Date?
    private var lastEdit: Date?
    /// The first edit made while a save was in flight. It was not part of the
    /// bytes that save wrote, so the five-second ceiling restarts from here.
    private var firstEditDuringSave: Date?
    private let saveSlot = SaveSlot()
    private var pendingArtifactsToClean: [URL] = []
    /// A conflict decision waits for the save slot. It is bound to the disk
    /// snapshot the user reviewed so it cannot authorize overwriting a newer
    /// conflict that appeared while it waited.
    private var pendingResolution: PendingResolution?

    private struct PendingResolution {
        let resolution: ExternalResolution
        let snapshot: DiskSnapshot?
    }

    public var isDirty: Bool {
        revision != savedRevision || (fileURL == nil && revision > 0)
    }

    /// Source is the only eligible surface: a size state, a live-buffer
    /// growth, or a parse refusal.
    public var isSourceOnly: Bool {
        isLarge || forcedSourceReason != nil
    }

    // MARK: - Construction

    public init(
        untitledWith store: MarkdownFileStore = MarkdownFileStore()
    ) {
        self.store = store
        self.source = ""
        self.sourceUTF16Count = 0
        self.lineEnding = .lf
        self.hasBOM = false
        self.isReadOnly = false
        self.isLarge = false
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = DocumentHistoryLimits.undoLevels
    }

    public init(
        loading url: URL,
        store: MarkdownFileStore = MarkdownFileStore()
    ) throws {
        let loaded = try store.read(url)
        self.store = store
        self.fileURL = url
        self.source = loaded.contents.canonicalText
        self.sourceUTF16Count = loaded.contents.canonicalText.utf16.count
        self.diskSnapshot = loaded.snapshot
        self.lineEnding = loaded.contents.lineEnding
        self.hasBOM = loaded.contents.hasBOM
        self.isReadOnly = loaded.isLarge
        self.isLarge = loaded.isLarge
        self.forcedSourceReason = loaded.isLarge ? .large : nil
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = DocumentHistoryLimits.undoLevels
    }

    // MARK: - Editing

    /// Replaces the whole source. Commands and the editor both use this path.
    public func replaceSource(_ newSource: String, actionName: String = "Edit") throws {
        guard !isReadOnly else { throw DocumentError.readOnly }
        let newBytes = newSource.utf8.count
        guard newBytes <= DocumentHistoryLimits.maxReplacementBytes else {
            throw DocumentError.editTooLarge
        }
        // Length settles inequality for every insert, delete, and paste, so
        // the comparison runs only for a same-length replacement. It must be
        // exact code-unit equality: Swift's `String ==` uses canonical
        // equivalence, so writing a precomposed "é" over a decomposed one
        // would compare equal and be discarded, leaving the file unchanged.
        let newLength = newSource.utf16.count
        guard newLength != sourceUTF16Count
                || !(newSource as NSString).isEqual(to: source) else {
            return
        }

        let oldSource = source
        // The reader refuses a file with more than `maxSourceLines` newlines
        // no matter how few bytes it has. A document that could be saved but
        // never reopened is a trap, so the same counting applies here. The
        // byte floor keeps the scan off the per-keystroke path: a string
        // with more newlines than the cap must have at least that many
        // bytes.
        if newBytes > MarkdownLimits.maxSourceLines {
            let newLines = newlineCount(newSource)
            if newLines > MarkdownLimits.maxSourceLines,
               newLines > newlineCount(oldSource) {
                throw DocumentError.editTooLarge
            }
        }
        // A value freshly bridged from Cocoa (the editor's text storage)
        // materialises inside the @Observable setter at O(n) with a bad
        // constant — 50 ms per megabyte on the E2E Mac, ~100 ms on the
        // workstation in release — while a natively decoded copy stores for
        // free. Take the copy here, where the path already pays O(n).
        let ownedSource = Self.nativeCopy(newSource)
        // `groupsByEvent` is off so tests and commands are deterministic;
        // each edit therefore opens its own explicit undo group.
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { document in
            try? document.replaceSource(oldSource, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()

        source = ownedSource
        sourceUTF16Count = newLength
        updateLiveBufferState(byteCount: newBytes)
        revision += 1
        lastEdit = Date()
        if firstPendingEdit == nil {
            firstPendingEdit = lastEdit
        }
        if saveSlot.isHeld, firstEditDuringSave == nil {
            firstEditDuringSave = lastEdit
        }
    }

    /// Applies an external change decision.
    public func resolveExternalChange(_ resolution: ExternalResolution) {
        guard !saveSlot.isHeld else {
            // Applying a reload while a save is in flight could interleave
            // the two disk states. Queue it until the save releases the slot,
            // bound to the conflict the user actually reviewed.
            pendingResolution = PendingResolution(
                resolution: resolution,
                snapshot: conflict?.diskSnapshot
            )
            return
        }
        switch resolution {
        case .reload:
            guard let conflict else { return }
            isMissingOnDisk = false
            source = conflict.diskText
            sourceUTF16Count = conflict.diskText.utf16.count
            diskSnapshot = conflict.diskSnapshot
            if let contents = try? MarkdownEncoding.decode(conflict.diskSnapshot.bytes) {
                lineEnding = contents.lineEnding
                hasBOM = contents.hasBOM
            }
            applySize(for: conflict.diskSnapshot)
            // Undo must not resurrect pre-change whole-source snapshots.
            undoManager.removeAllActions()
            revision += 1
            savedRevision = revision
            firstPendingEdit = nil
            self.conflict = nil
        case .keepLocal:
            guard let conflict else { return }
            isMissingOnDisk = false
            diskSnapshot = conflict.diskSnapshot
            self.conflict = nil
        }
    }

    // MARK: - Autosave

    /// The delay until this document should autosave, or `nil` when clean.
    public func autosaveDelay(now: Date = Date()) -> TimeInterval? {
        guard isDirty, fileURL != nil, !isReadOnly else { return nil }
        guard let lastEdit, let firstPendingEdit else { return nil }
        return Autosave.delay(
            lastEdit: lastEdit,
            firstPendingEdit: firstPendingEdit,
            now: now
        )
    }

    // MARK: - Save

    /// Saves the document to its current identity.
    ///
    /// Returns `nil` when the document was clean and no write was needed.
    @discardableResult
    public func save(
        mode: SaveMode = .automatic,
        hooks: SaveHooks? = nil
    ) async throws -> SaveOutcome? {
        guard !isClosed else { throw DocumentError.closed }
        guard fileURL != nil else { throw DocumentError.untitled }
        guard !isReadOnly else { throw DocumentError.readOnly }
        if !isDirty, diskSnapshot != nil {
            return nil
        }

        try await acquireSaveSlot()
        defer { releaseSaveSlot() }

        guard !isClosed else { throw DocumentError.closed }

        // Read identity only after the slot is held. A Save As that ran while
        // this call waited has changed both the destination and generation;
        // using a destination captured before the wait would write the new
        // identity's content to the old path.
        guard let destination = fileURL else { throw DocumentError.untitled }
        guard !isReadOnly else { throw DocumentError.readOnly }
        if !isDirty, diskSnapshot != nil {
            return nil
        }

        let generation = identityGeneration
        let revisionAtStart = revision
        // Edits from here on are outside this save's snapshot.
        firstEditDuringSave = nil
        let data = MarkdownEncoding.encode(
            source,
            hasBOM: hasBOM,
            lineEnding: lineEnding
        )

        let request = SaveRequest(
            documentID: id,
            identityGeneration: generation,
            sourceRevision: revisionAtStart,
            destination: destination,
            expectedDisk: diskSnapshot,
            data: data,
            mode: mode,
            hooks: hooks
        )

        do {
            let outcome = try await runSave(request)
            guard identityGeneration == generation else {
                throw DocumentError.staleCompletion
            }

            diskSnapshot = outcome.snapshot
            isMissingOnDisk = false
            adoptSaveOutcome(outcome, revisionAtStart: revisionAtStart)
            return outcome
        } catch let error as SaveError {
            if case let .diskChanged(artifacts) = error {
                lastSaveArtifacts = artifacts
                // After a swap the destination holds our bytes. The external
                // writer's bytes were moved aside, so read the artifact.
                let conflictURL = artifacts.displaced.flatMap {
                    FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
                }
                conflict = try? readConflict(at: conflictURL)
            }
            lastError = String(describing: error)
            throw error
        } catch {
            lastError = String(describing: error)
            throw error
        }
    }

    /// Saves to a new destination and only then switches identity.
    @discardableResult
    public func saveAs(
        to url: URL,
        mode: SaveMode = .explicitOverwrite,
        hooks: SaveHooks? = nil
    ) async throws -> SaveOutcome {
        guard !isClosed else { throw DocumentError.closed }
        try await acquireSaveSlot()
        defer { releaseSaveSlot() }
        guard !isClosed else { throw DocumentError.closed }

        let revisionAtStart = revision
        firstEditDuringSave = nil
        let data = MarkdownEncoding.encode(
            source,
            hasBOM: hasBOM,
            lineEnding: lineEnding
        )
        let expected = try store.diskSnapshot(at: url)
        let request = SaveRequest(
            documentID: id,
            identityGeneration: identityGeneration,
            sourceRevision: revisionAtStart,
            destination: url,
            expectedDisk: expected,
            data: data,
            mode: mode,
            hooks: hooks
        )

        let outcome = try await runSave(request)

        fileURL = url
        identityGeneration += 1
        diskSnapshot = outcome.snapshot
        isMissingOnDisk = false
        // Save As adopts a destination, not a foreign file: the buffer keeps
        // the admission it already had. Marking a live-grown buffer
        // read-only here would trap undo and every shrinking edit, and an
        // edit made during the write could no longer be saved. The state
        // follows the buffer as it stands now, not the bytes written at the
        // start of the save.
        updateLiveBufferState(byteCount: source.utf8.count)
        conflict = nil
        adoptSaveOutcome(outcome, revisionAtStart: revisionAtStart)
        return outcome
    }

    /// Replaces the buffer with a snapshot's exact bytes and saves through
    /// the compare-and-swap path, in one undo group covering text, BOM/EOL
    /// metadata, selection, and admission state.
    ///
    /// `expectedDiskBytes` is the disk content the caller believes is
    /// current. When the disk no longer matches, the restore refuses before
    /// mutation.
    @discardableResult
    public func restore(
        rawBytes: Data,
        expectedDiskBytes: Data?,
        selection: Range<Int>? = nil
    ) async throws -> SaveOutcome? {
        guard !isClosed else { throw MarkdownRestoreError.closed }
        guard fileURL != nil else { throw MarkdownRestoreError.untitled }
        guard !isReadOnly else { throw MarkdownRestoreError.readOnly }
        guard Self.hasLoneCarriageReturn(rawBytes) == false else {
            throw MarkdownRestoreError.unsupportedEncoding
        }
        guard let contents = try? MarkdownEncoding.decode(rawBytes),
              !contents.hadMixedLineEndings else {
            throw MarkdownRestoreError.unsupportedEncoding
        }
        let newlineCount = rawBytes.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        guard rawBytes.count <= MarkdownLimits.maxReadBytes,
              newlineCount <= MarkdownLimits.maxSourceLines else {
            throw MarkdownRestoreError.tooLarge
        }
        guard let url = fileURL,
              let current = try store.diskSnapshot(at: url) else {
            throw MarkdownRestoreError.staleDisk
        }
        if let expectedDiskBytes, expectedDiskBytes != current.bytes {
            throw MarkdownRestoreError.staleDisk
        }

        diskSnapshot = current
        let large = rawBytes.count > MarkdownLimits.maxEditableDocumentBytes
        applyRestoredState(
            text: contents.canonicalText,
            hasBOM: contents.hasBOM,
            lineEnding: contents.lineEnding,
            selection: selection,
            forcedReason: large ? .largeRestored : nil,
            isLarge: large,
            actionName: "Restore Snapshot"
        )
        return try await save(mode: .explicitOverwrite)
    }

    private static func hasLoneCarriageReturn(_ data: Data) -> Bool {
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x0D {
                let next = data.index(after: index)
                if next >= data.endIndex || data[next] != 0x0A {
                    return true
                }
            }
            index = data.index(after: index)
        }
        return false
    }

    /// Registers the previous text, metadata, selection, and admission as one
    /// undo step, then applies the new state. Undo of this state registers the
    /// reverse, so redo works through the same path.
    private func applyRestoredState(
        text: String,
        hasBOM: Bool,
        lineEnding: LineEnding,
        selection: Range<Int>?,
        forcedReason: ForcedSourceReason?,
        isLarge: Bool,
        actionName: String
    ) {
        let previousText = source
        let previousBOM = self.hasBOM
        let previousLineEnding = self.lineEnding
        let previousSelection = self.selection
        let previousForced = forcedSourceReason
        let previousLarge = self.isLarge

        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { document in
            document.applyRestoredState(
                text: previousText,
                hasBOM: previousBOM,
                lineEnding: previousLineEnding,
                selection: previousSelection,
                forcedReason: previousForced,
                isLarge: previousLarge,
                actionName: actionName
            )
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()

        source = text
        sourceUTF16Count = text.utf16.count
        self.hasBOM = hasBOM
        self.lineEnding = lineEnding
        self.selection = selection
        forcedSourceReason = forcedReason
        self.isLarge = isLarge
        revision += 1
        lastEdit = Date()
        if firstPendingEdit == nil {
            firstPendingEdit = lastEdit
        }
    }

    /// Marks the document as no longer owned by a workspace.
    public func markClosed() {
        isClosed = true
    }

    /// Flushes pending edits before a tab or window closes.
    public func flushForClose() async -> CloseOutcome {
        guard isDirty else { return .closed }
        guard fileURL != nil else { return .needsDecision(.untitled) }
        do {
            try await save(mode: .automatic)
            return isDirty ? .needsDecision(.saveFailed("save did not clear dirty")) : .closed
        } catch {
            return .needsDecision(.saveFailed(String(describing: error)))
        }
    }

    // MARK: - External changes

    /// Revalidates the disk. Watcher events are hints; this is authoritative.
    public func checkExternalChange() async throws -> ExternalChange {
        // Serialize with saves: a check that reads the destination while a
        // detached save is between its rename and verification would observe
        // an intermediate state. Capture identity only after the slot is
        // held, so a Save As that completed while waiting is reflected.
        try await acquireSaveSlot()
        defer { releaseSaveSlot() }

        guard let url = fileURL, let snapshot = diskSnapshot else {
            return .none
        }

        enum DiskReadResult: Sendable {
            case missing
            case failure
            case unchanged
            case changed(
                DiskSnapshot,
                MarkdownFileContents,
                matchesSource: Bool,
                matchesPrevious: Bool
            )
        }

        // File I/O, decoding, and the text comparisons can all be slow; keep
        // them off the main actor and apply only their conclusions here.
        let sourceText = source
        let snapshotBytes = snapshot.bytes
        let result = await Task.detached(priority: .userInitiated) {
            () -> DiskReadResult in
            let data: Data
            do {
                data = try MarkdownFileStore.readBoundedData(at: url)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoSuchFileError
                    || error.code == NSFileNoSuchFileError) {
                return .missing
            } catch {
                return .failure
            }
            if data == snapshotBytes {
                return .unchanged
            }
            guard let contents = try? MarkdownEncoding.decode(data) else {
                return .failure
            }
            let matchesSource = MarkdownEncoding.softEqual(
                contents.canonicalText,
                sourceText
            )
            let matchesPrevious = (try? MarkdownEncoding.decode(snapshotBytes))
                .map {
                    MarkdownEncoding.softEqual(
                        contents.canonicalText,
                        $0.canonicalText
                    )
                } ?? false
            return .changed(
                // Hash off-main as well; constructing the snapshot is part
                // of the disk read's cost.
                DiskSnapshot(bytes: data),
                contents,
                matchesSource: matchesSource,
                matchesPrevious: matchesPrevious
            )
        }.value

        let current: DiskSnapshot
        let contents: MarkdownFileContents
        let matchesSource: Bool
        let matchesPrevious: Bool
        switch result {
        case .missing:
            isMissingOnDisk = true
            return .deleted
        case .failure:
            throw DocumentError.readFailed(url.lastPathComponent)
        case .unchanged:
            // The disk matches the baseline, so any earlier conflict is
            // obsolete.
            isMissingOnDisk = false
            conflict = nil
            return .none
        case let .changed(snapshot, decoded, sourceMatch, previousMatch):
            current = snapshot
            contents = decoded
            matchesSource = sourceMatch
            matchesPrevious = previousMatch
        }

        isMissingOnDisk = false

        if matchesSource {
            // A sync tool rewrote EOL/BOM; not an edit.
            diskSnapshot = current
            lineEnding = contents.lineEnding
            hasBOM = contents.hasBOM
            applySize(for: current)
            conflict = nil
            return .none
        }

        // A formatting-only rewrite of the original disk content is not a
        // conflict even while local edits are pending.
        if matchesPrevious {
            diskSnapshot = current
            lineEnding = contents.lineEnding
            hasBOM = contents.hasBOM
            applySize(for: current)
            conflict = nil
            return .none
        }

        if !isDirty {
            source = contents.canonicalText
            sourceUTF16Count = contents.canonicalText.utf16.count
            revision += 1
            savedRevision = revision
            diskSnapshot = current
            lineEnding = contents.lineEnding
            hasBOM = contents.hasBOM
            applySize(for: current)
            undoManager.removeAllActions()
            firstPendingEdit = nil
            return .adopted
        }

        let conflict = ExternalConflict(
            diskSnapshot: current,
            diskText: contents.canonicalText
        )
        self.conflict = conflict
        return .conflict(conflict)
    }

    // MARK: - Internals

    private func runSave(_ request: SaveRequest) async throws -> SaveOutcome {
        let store = self.store
        return try await Task.detached(priority: .userInitiated) {
            try store.save(request)
        }.value
    }

    /// Shared completion bookkeeping for `save` and `saveAs`.
    ///
    /// A new save supersedes the previous retained new-content copy. Edits
    /// made while the write was pending were not in the encoded data, so only
    /// the revision that was actually written becomes clean.
    private func adoptSaveOutcome(
        _ outcome: SaveOutcome,
        revisionAtStart: UInt64
    ) {
        for url in pendingArtifactsToClean {
            try? FileManager.default.removeItem(at: url)
        }
        pendingArtifactsToClean.removeAll()

        lastSaveArtifacts = outcome.artifacts
        if let newContent = outcome.artifacts.newContent {
            pendingArtifactsToClean.append(newContent)
        }
        if let displaced = outcome.artifacts.displaced {
            // Retain one superseded displaced copy, not an unbounded pile.
            pendingArtifactsToClean.append(displaced)
        }

        if revision == revisionAtStart {
            savedRevision = revisionAtStart
            firstPendingEdit = nil
        } else {
            // The five-second ceiling restarts from the first edit that was
            // not included in this save, not from the most recent keystroke.
            firstPendingEdit = firstEditDuringSave ?? lastEdit
        }
        firstEditDuringSave = nil
        conflict = nil
        lastError = nil
    }

    /// Newlines, not lines: the same convention `MarkdownFileStore.read`
    /// uses when it enforces `maxSourceLines`.
    /// A native copy of `text`, decoded from its UTF-16 code units. Reading
    /// them in one `getCharacters` call copies out of either representation
    /// (a Cocoa bridge or a native UTF-8 buffer), and `String(decoding:)`
    /// builds native storage. Storing that copy in the observed `source`
    /// property is free; storing the fresh bridge is not.
    private static func nativeCopy(_ text: String) -> String {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return "" }
        var units = [unichar](repeating: 0, count: length)
        ns.getCharacters(&units, range: NSRange(location: 0, length: length))
        return String(decoding: units, as: UTF16.self)
    }

    private func newlineCount(_ text: String) -> Int {
        // A per-keystroke scan over a megabyte document. The text the editor
        // hands us is bridged from Cocoa, whose UTF-16 code units are the
        // storage's own: reading them in chunks is a copy from the native
        // buffer. Asking a `String` view for contiguous storage instead
        // either materialises a transcode or fails into a scalar walk —
        // 30 ms per megabyte, measured on the E2E Mac.
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return 0 }
        let chunkSize = 1 << 16
        var count = 0
        var location = 0
        var buffer = [unichar](repeating: 0, count: chunkSize)
        buffer.withUnsafeMutableBufferPointer { units in
            guard let base = units.baseAddress else { return }
            while location < length {
                let chunk = min(chunkSize, length - location)
                ns.getCharacters(
                    base,
                    range: NSRange(location: location, length: chunk)
                )
                for index in 0..<chunk where base[index] == 0x000A {
                    count += 1
                }
                location += chunk
            }
        }
        return count
    }

    private func readConflict(at url: URL? = nil) throws -> ExternalConflict {
        guard let url = url ?? fileURL else {
            throw DocumentError.untitled
        }
        let data = try MarkdownFileStore.readBoundedData(at: url)
        let contents = try MarkdownEncoding.decode(data)
        return ExternalConflict(
            diskSnapshot: DiskSnapshot(bytes: data),
            diskText: contents.canonicalText
        )
    }

    /// A file can cross the editable-size threshold while it is open. The
    /// size-dependent state must follow the bytes that were actually adopted.
    private func applySize(for snapshot: DiskSnapshot) {
        isLarge = snapshot.byteCount > MarkdownLimits.maxEditableDocumentBytes
        isReadOnly = isLarge
        forcedSourceReason = isLarge ? .large : nil
    }

    /// Live growth is not a read-only transition: turning a dirty buffer
    /// read-only would trap undo and any shrinking edit. Rendered/parse is
    /// disabled, but editing and saving remain available.
    private func updateLiveBufferState(byteCount: Int) {
        if byteCount > MarkdownLimits.maxEditableDocumentBytes {
            isLarge = true
            if forcedSourceReason == nil || forcedSourceReason == .largeBuffer {
                forcedSourceReason = .largeBuffer
            }
        } else {
            isLarge = isReadOnly
            if forcedSourceReason == .largeBuffer {
                forcedSourceReason = nil
            }
        }
    }

    /// The parser reports a nesting refusal. It is a separate reason from
    /// size and clears only on a successful current-revision parse.
    public func setNestingLimit(_ exceeded: Bool) {
        if exceeded {
            forcedSourceReason = .nestingLimit
        } else if forcedSourceReason == .nestingLimit {
            forcedSourceReason = isLarge ? .largeBuffer : nil
        }
    }

    /// The watcher reports that the file on disk became too large or
    /// unreadable. The open document is not replaced.
    public func setDiskState(_ state: MarkdownDiskState) {
        diskState = state
    }

    private func acquireSaveSlot() async throws {
        try await saveSlot.acquire()
    }

    /// Test seam: simulates a save that owns the slot without blocking a
    /// thread. `flushForClose` sees exactly this state, and the test can
    /// measure its bounded wait deterministically.
    func holdSaveSlotForTesting() async throws {
        try await saveSlot.acquire()
    }

    func releaseSaveSlotForTesting() {
        saveSlot.release()
    }

    private func releaseSaveSlot() {
        saveSlot.release()

        if let pending = pendingResolution {
            pendingResolution = nil
            // The conflict may have been replaced while the decision waited.
            // Applying the old decision to the new bytes would silently
            // authorize an overwrite the user never saw.
            if let snapshot = pending.snapshot,
               snapshot == conflict?.diskSnapshot {
                resolveExternalChange(pending.resolution)
            }
        }
    }
}
