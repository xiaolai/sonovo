import Foundation
import Observation

public enum SubtitleDocumentError: Error, Equatable {
    case readOnly
    case closed
    case readFailed(String)
    case staleCompletion
}

/// How the subtitle document is presented.
public enum SubtitleDocumentMode: String, Sendable, Equatable {
    case cues
    case source
}

/// One open subtitle document.
///
/// The canonical source is the file itself; `parsed` is a projection stamped
/// with the revision that produced it. Cue edits replace minimal ranges and
/// then become ordinary source edits, so one undo path serves both surfaces.
@MainActor
@Observable
public final class SubtitleDocument: Identifiable {
    public let id = UUID()
    public let undoManager = UndoManager()
    public let fileURL: URL
    public let format: SubtitleFormat

    public private(set) var source: String
    public private(set) var revision: UInt64 = 0
    public private(set) var savedRevision: UInt64 = 0

    /// The parse projection for `parsedRevision`; may briefly trail `revision`
    /// while a background parse runs.
    public private(set) var parsed: SubtitleParseResult
    public private(set) var parsedRevision: UInt64 = 0
    /// Cue text joined for metadata and word counts, computed off-main.
    public private(set) var plainText: String

    public private(set) var diskSnapshot: DiskSnapshot
    public private(set) var encoding: SubtitleTextEncoding
    public private(set) var lineEnding: LineEnding
    public private(set) var hadMixedLineEndings: Bool
    public private(set) var isReadOnly: Bool
    public private(set) var isLarge: Bool
    public private(set) var isMissingOnDisk = false
    public private(set) var isClosed = false

    public private(set) var conflict: ExternalConflict?
    public private(set) var lastSaveArtifacts: SaveArtifacts?
    public private(set) var lastError: String?

    public var mode: SubtitleDocumentMode = .cues

    private let store: SubtitleFileStore
    private let parseService: SubtitleParseService
    private var parseTask: Task<Void, Never>?
    private var parseRequestID: UInt64 = 0
    private var firstPendingEdit: Date?
    private var lastEdit: Date?
    private var saveInFlight = false
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingArtifactsToClean: [URL] = []
    private var pendingResolution: ExternalResolution?

    public var isDirty: Bool {
        revision != savedRevision
    }

    public var cueCount: Int {
        parsed.cues.count
    }

    public var durationMilliseconds: Int {
        parsed.timeline.durationMilliseconds
    }

    // MARK: - Construction

    public init(
        loading url: URL,
        store: SubtitleFileStore = SubtitleFileStore(),
        parseService: SubtitleParseService = SubtitleParseService()
    ) throws {
        let loaded = try store.read(url)
        self.store = store
        self.parseService = parseService
        self.fileURL = url
        self.format = loaded.format
        self.source = loaded.contents.text
        self.encoding = loaded.contents.encoding
        self.lineEnding = loaded.contents.lineEnding
        self.hadMixedLineEndings = loaded.contents.hadMixedLineEndings
        self.diskSnapshot = loaded.snapshot
        self.isReadOnly = loaded.isLarge
        self.isLarge = loaded.isLarge
        let parsed = SubtitleParser.parse(
            loaded.contents.text,
            format: loaded.format
        )
        self.parsed = parsed
        self.plainText = SubtitleText.plainText(
            for: parsed.cues,
            format: loaded.format
        )
        undoManager.groupsByEvent = false
    }

    // MARK: - Editing

    /// Replaces the whole source. The source editor and cue edits both use
    /// this path, so there is exactly one undo history.
    public func replaceSource(
        _ newSource: String,
        actionName: String = "Edit"
    ) throws {
        guard !isReadOnly else { throw SubtitleDocumentError.readOnly }
        guard !isClosed else { throw SubtitleDocumentError.closed }
        guard newSource != source else { return }

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
        scheduleParse()
    }

    /// Applies a cue edit against a parse of the current source.
    @discardableResult
    public func apply(_ edit: SubtitleEdit) async throws -> SubtitleEditResult {
        guard !isReadOnly else { throw SubtitleDocumentError.readOnly }
        guard !isClosed else { throw SubtitleDocumentError.closed }

        let parse = await parseResultForCurrentSource()
        let result = try SubtitleEditor.apply(edit, to: parse, source: source)
        if result.source != source {
            try replaceSource(result.source, actionName: result.actionName)
        }
        return result
    }

    // MARK: - Parsing

    /// Waits for the background parse of the current revision, falling back
    /// to a synchronous parse when the coalesced request was superseded.
    public func parseResultForCurrentSource() async -> SubtitleParseResult {
        if parsedRevision == revision {
            return parsed
        }
        await awaitParse()
        if parsedRevision == revision {
            return parsed
        }
        let revision = self.revision
        let result = SubtitleParser.parse(source, format: format)
        adopt(
            result,
            plainText: SubtitleText.plainText(
                for: result.cues,
                format: format
            ),
            revision: revision
        )
        return result
    }

    private func awaitParse() async {
        var attempts = 0
        while parsedRevision != revision, attempts < 8 {
            attempts += 1
            let request = parseRequestID
            guard let task = parseTask else { return }
            await task.value
            if parsedRevision == revision {
                return
            }
            if parseRequestID == request {
                return
            }
        }
    }

    private func scheduleParse() {
        parseTask?.cancel()
        parseRequestID += 1
        let request = parseRequestID
        let revision = self.revision
        let source = self.source
        let format = self.format
        let documentID = self.id
        let service = parseService

        parseTask = Task { [weak self] in
            await service.markLatest(
                documentID: documentID,
                generation: revision
            )
            guard !Task.isCancelled else { return }

            let outcome = await Task.detached(
                priority: .userInitiated
            ) { () -> (SubtitleParseResult, String)? in
                guard let parsed = await service.parse(
                    documentID: documentID,
                    generation: revision,
                    source: source,
                    format: format
                ) else {
                    return nil
                }
                let plain = SubtitleText.plainText(
                    for: parsed.cues,
                    format: format
                )
                return (parsed, plain)
            }.value

            guard !Task.isCancelled,
                  let self,
                  self.parseRequestID == request,
                  self.revision == revision,
                  let outcome else {
                return
            }
            self.adopt(
                outcome.0,
                plainText: outcome.1,
                revision: revision
            )
        }
    }

    private func adopt(
        _ result: SubtitleParseResult,
        plainText: String,
        revision: UInt64
    ) {
        parsed = result
        parsedRevision = revision
        self.plainText = plainText
    }

    // MARK: - External changes

    public func resolveExternalChange(_ resolution: ExternalResolution) {
        guard !saveInFlight else {
            pendingResolution = resolution
            return
        }
        switch resolution {
        case .reload:
            guard let conflict else { return }
            isMissingOnDisk = false
            source = conflict.diskText
            diskSnapshot = conflict.diskSnapshot
            if let contents = try? SubtitleEncoding.decode(
                conflict.diskSnapshot.bytes
            ) {
                encoding = contents.encoding
                lineEnding = contents.lineEnding
                hadMixedLineEndings = contents.hadMixedLineEndings
            }
            applySize(for: conflict.diskSnapshot)
            undoManager.removeAllActions()
            revision += 1
            savedRevision = revision
            firstPendingEdit = nil
            self.conflict = nil
            scheduleParse()
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
        guard isDirty, !isReadOnly else { return nil }
        guard let lastEdit, let firstPendingEdit else { return nil }
        return Autosave.delay(
            lastEdit: lastEdit,
            firstPendingEdit: firstPendingEdit,
            now: now
        )
    }

    // MARK: - Save

    /// Saves to the opened file. Returns `nil` when the document was clean.
    @discardableResult
    public func save(
        mode: SaveMode = .automatic,
        hooks: SaveHooks? = nil
    ) async throws -> SaveOutcome? {
        guard !isClosed else { throw SubtitleDocumentError.closed }
        guard !isReadOnly else { throw SubtitleDocumentError.readOnly }
        if !isDirty {
            return nil
        }

        await acquireSaveSlot()
        defer { releaseSaveSlot() }

        guard !isClosed else { throw SubtitleDocumentError.closed }
        guard !isReadOnly else { throw SubtitleDocumentError.readOnly }
        if !isDirty {
            return nil
        }

        let revisionAtStart = revision
        let request: SaveRequest
        do {
            let data = try SubtitleEncoding.encode(
                source,
                encoding: encoding,
                lineEnding: lineEnding
            )
            request = SaveRequest(
                documentID: id,
                identityGeneration: 0,
                sourceRevision: revisionAtStart,
                destination: fileURL,
                expectedDisk: diskSnapshot,
                data: data,
                mode: mode,
                hooks: hooks
            )
        } catch {
            lastError = String(describing: error)
            throw error
        }

        do {
            let outcome = try await runSave(request)
            diskSnapshot = outcome.snapshot
            isMissingOnDisk = false
            adoptSaveOutcome(outcome, revisionAtStart: revisionAtStart)
            return outcome
        } catch let error as SaveError {
            if case let .diskChanged(artifacts) = error {
                lastSaveArtifacts = artifacts
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

    /// Saves pending edits before a tab or window closes. Subtitle documents
    /// always have a file, so there is no untitled decision.
    public func flushForClose() async -> CloseOutcome {
        guard isDirty else { return .closed }
        do {
            try await save(mode: .automatic)
            return isDirty
                ? .needsDecision(.saveFailed("save did not clear dirty"))
                : .closed
        } catch {
            return .needsDecision(.saveFailed(String(describing: error)))
        }
    }

    public func markClosed() {
        isClosed = true
        parseTask?.cancel()
        parseTask = nil
        let documentID = self.id
        let service = parseService
        Task { await service.forget(documentID: documentID) }
    }

    // MARK: - External changes

    /// Revalidates the disk. Watcher events are hints; this is authoritative.
    public func checkExternalChange() async throws -> ExternalChange {
        await acquireSaveSlot()
        defer { releaseSaveSlot() }

        guard !isClosed else { throw SubtitleDocumentError.closed }

        enum DiskReadResult: Sendable {
            case missing
            case failure
            case unchanged
            case changed(
                DiskSnapshot,
                SubtitleFileContents,
                matchesSource: Bool,
                matchesPrevious: Bool
            )
        }

        let url = fileURL
        let sourceText = source
        let snapshotBytes = diskSnapshot.bytes
        let result = await Task.detached(priority: .userInitiated) {
            () -> DiskReadResult in
            let data: Data
            do {
                data = try Data(contentsOf: url)
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
            guard let contents = try? SubtitleEncoding.decode(data) else {
                return .failure
            }
            let matchesSource = contents.text == sourceText
            let matchesPrevious = (try? SubtitleEncoding.decode(snapshotBytes))
                .map { $0.text == contents.text } ?? false
            return .changed(
                DiskSnapshot(bytes: data),
                contents,
                matchesSource: matchesSource,
                matchesPrevious: matchesPrevious
            )
        }.value

        let current: DiskSnapshot
        let contents: SubtitleFileContents
        let matchesSource: Bool
        let matchesPrevious: Bool
        switch result {
        case .missing:
            isMissingOnDisk = true
            return .deleted
        case .failure:
            throw SubtitleDocumentError.readFailed(url.lastPathComponent)
        case .unchanged:
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
            diskSnapshot = current
            encoding = contents.encoding
            lineEnding = contents.lineEnding
            hadMixedLineEndings = contents.hadMixedLineEndings
            applySize(for: current)
            conflict = nil
            return .none
        }

        if matchesPrevious {
            diskSnapshot = current
            encoding = contents.encoding
            lineEnding = contents.lineEnding
            hadMixedLineEndings = contents.hadMixedLineEndings
            applySize(for: current)
            conflict = nil
            return .none
        }

        if !isDirty {
            source = contents.text
            revision += 1
            savedRevision = revision
            diskSnapshot = current
            encoding = contents.encoding
            lineEnding = contents.lineEnding
            hadMixedLineEndings = contents.hadMixedLineEndings
            applySize(for: current)
            undoManager.removeAllActions()
            firstPendingEdit = nil
            scheduleParse()
            return .adopted
        }

        let conflict = ExternalConflict(
            diskSnapshot: current,
            diskText: contents.text
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
            pendingArtifactsToClean.append(displaced)
        }

        if revision == revisionAtStart {
            savedRevision = revisionAtStart
            firstPendingEdit = nil
        } else {
            firstPendingEdit = lastEdit
        }
        conflict = nil
        lastError = nil
    }

    private func readConflict(at url: URL? = nil) throws -> ExternalConflict {
        let url = url ?? fileURL
        let data = try Data(contentsOf: url)
        let contents = try SubtitleEncoding.decode(data)
        return ExternalConflict(
            diskSnapshot: DiskSnapshot(bytes: data),
            diskText: contents.text
        )
    }

    private func applySize(for snapshot: DiskSnapshot) {
        isLarge = snapshot.byteCount > SubtitleLimits.maxEditableBytes
        isReadOnly = isLarge
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

        if let pending = pendingResolution {
            pendingResolution = nil
            resolveExternalChange(pending)
        }
    }
}
