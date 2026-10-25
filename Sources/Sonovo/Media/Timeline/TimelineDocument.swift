import CryptoKit
import Darwin
import Foundation
import Observation
import SonovoCore

enum TimelineStoreError: LocalizedError, Equatable {
    case externalChange
    case existingFile
    case lockFailed

    var errorDescription: String? {
        switch self {
        case .externalChange:
            "The timeline changed on disk. Reload it before saving."
        case .existingFile:
            "A timeline file already exists at this path."
        case .lockFailed:
            "The timeline file could not be locked for writing."
        }
    }
}

struct TimelineFileStore: Sendable {
    let url: URL
    var writeData: @Sendable (Data, URL) throws -> Void

    init(
        url: URL,
        writeData: @escaping @Sendable (Data, URL) throws -> Void = {
            data, target in
            try data.write(to: target, options: .atomic)
        }
    ) {
        self.url = url
        self.writeData = writeData
    }

    func load() throws -> ProjectTimeline {
        try loadSnapshot().timeline
    }

    /// Reads and hashes one byte range, so a writer that replaces the file
    /// between two independent reads cannot become an acknowledged baseline
    /// without its contents being decoded.
    func loadSnapshot() throws -> (
        timeline: ProjectTimeline,
        checksum: String
    ) {
        let data = try Data(contentsOf: url)
        let timeline = try decoder.decode(ProjectTimeline.self, from: data)
        try timeline.validate()
        return (timeline, Self.checksum(data))
    }

    /// Unconditional write for tests and fixtures. The document uses the
    /// checksum-guarded overload below.
    func save(_ timeline: ProjectTimeline) throws {
        try timeline.validate()
        try prepareDirectory()
        try writeData(try encoder.encode(timeline), url)
    }

    /// Compare-and-swap save under an exclusive lock shared by every
    /// TimelineDocument writing this path. `expected == nil` means the file
    /// must not exist yet.
    @discardableResult
    func save(
        _ timeline: ProjectTimeline,
        expectedChecksum: String?
    ) throws -> String {
        try timeline.validate()
        try prepareDirectory()
        let data = try encoder.encode(timeline)
        let lockURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw TimelineStoreError.lockFailed
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw TimelineStoreError.lockFailed
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        let exists = FileManager.default.fileExists(atPath: url.path)
        let current: Data?
        if exists {
            do {
                current = try Data(contentsOf: url)
            } catch {
                // An existing but unreadable file is not absent. Writing over
                // it would destroy bytes the document could not inspect.
                throw TimelineStoreError.externalChange
            }
        } else {
            current = nil
        }
        let currentChecksum = current.map(Self.checksum)
        if let expectedChecksum {
            guard currentChecksum == expectedChecksum else {
                throw TimelineStoreError.externalChange
            }
        } else if exists {
            throw TimelineStoreError.existingFile
        }
        try writeData(data, url)
        return Self.checksum(data)
    }

    static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    private var decoder: JSONDecoder { JSONDecoder() }
}

@MainActor
@Observable
final class TimelineDocument {
    enum Status: Equatable {
        case idle
        case loading
        case saving
        case saved
        case failed(String)
    }

    enum DocumentError: LocalizedError, Equatable {
        case externalChange
        case alreadyExists

        var errorDescription: String? {
            switch self {
            case .externalChange:
                "The timeline changed on disk. Reload it before saving."
            case .alreadyExists:
                "A timeline file already exists at this path."
            }
        }
    }

    let url: URL
    private let store: TimelineFileStore
    private(set) var timeline: ProjectTimeline?
    private(set) var status: Status = .idle
    private(set) var hasUnsavedChanges = false
    var hasExternalChanges: Bool {
        if let diskChecksum {
            return checksum() != diskChecksum
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var undoStack: [ProjectTimeline] = []
    private var redoStack: [ProjectTimeline] = []
    private var autosaveTask: Task<Void, Never>?
    private var saveGeneration: UInt64 = 0
    /// The content hash this document last read or wrote. A save refuses to
    /// overwrite bytes that another writer changed, even when size and
    /// modification time would look identical.
    private var diskChecksum: String?

    init(url: URL, store: TimelineFileStore? = nil) {
        self.url = url
        self.store = store ?? TimelineFileStore(url: url)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var errorMessage: String? {
        if case let .failed(message) = status { return message }
        return nil
    }

    func load() throws {
        status = .loading
        do {
            let snapshot = try store.loadSnapshot()
            timeline = snapshot.timeline
            diskChecksum = snapshot.checksum
            status = .saved
            hasUnsavedChanges = false
            undoStack.removeAll()
            redoStack.removeAll()
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    func create(_ timeline: ProjectTimeline) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw DocumentError.alreadyExists
        }
        try timeline.validate()
        self.timeline = timeline
        diskChecksum = nil
        hasUnsavedChanges = true
        status = .idle
        undoStack.removeAll()
        redoStack.removeAll()
        scheduleAutosave()
    }

    func mutate(
        _ change: (inout ProjectTimeline) throws -> Void
    ) throws {
        guard var next = timeline else {
            throw TimelineValidationError.invalidTime("document")
        }
        let previous = next
        try change(&next)
        try next.validate()
        undoStack.append(previous)
        trimHistory(&undoStack)
        redoStack.removeAll()
        timeline = next
        hasUnsavedChanges = true
        status = .idle
        scheduleAutosave()
    }

    @discardableResult
    func undo() -> Bool {
        guard let current = timeline,
              let previous = undoStack.popLast() else {
            return false
        }
        redoStack.append(current)
        trimHistory(&redoStack)
        timeline = previous
        hasUnsavedChanges = true
        status = .idle
        scheduleAutosave()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let current = timeline,
              let next = redoStack.popLast() else {
            return false
        }
        undoStack.append(current)
        trimHistory(&undoStack)
        timeline = next
        hasUnsavedChanges = true
        status = .idle
        scheduleAutosave()
        return true
    }

    func save() throws {
        guard let timeline else { return }
        autosaveTask?.cancel()
        autosaveTask = nil
        saveGeneration &+= 1
        status = .saving
        do {
            diskChecksum = try store.save(
                timeline,
                expectedChecksum: diskChecksum
            )
            status = .saved
            hasUnsavedChanges = false
        } catch TimelineStoreError.externalChange,
                TimelineStoreError.existingFile {
            status = .failed(
                TimelineDocument.DocumentError.externalChange
                    .localizedDescription
            )
            hasUnsavedChanges = true
            throw TimelineDocument.DocumentError.externalChange
        } catch {
            // A failed write never clears dirty state or claims Saved.
            status = .failed(error.localizedDescription)
            hasUnsavedChanges = true
            throw error
        }
    }

    func flush() async throws {
        autosaveTask?.cancel()
        autosaveTask = nil
        if hasUnsavedChanges {
            try save()
        }
    }

    /// Discards the in-memory timeline and reads the canonical file again.
    /// Used after a conflict, where saving over the new bytes is forbidden.
    func reload() throws {
        autosaveTask?.cancel()
        autosaveTask = nil
        try load()
    }

    func close() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let generation = saveGeneration
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled,
                  let self,
                  generation == self.saveGeneration,
                  self.hasUnsavedChanges else {
                return
            }
            try? self.save()
        }
    }

    private func trimHistory(_ history: inout [ProjectTimeline]) {
        let limit = DocumentHistoryLimits.undoLevels
        if history.count > limit {
            history.removeFirst(history.count - limit)
        }
    }

    private func checksum() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return TimelineFileStore.checksum(data)
    }
}
