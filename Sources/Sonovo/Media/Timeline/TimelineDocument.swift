import Foundation
import Observation
import SonovoCore

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
        let data = try Data(contentsOf: url)
        let timeline = try decoder.decode(ProjectTimeline.self, from: data)
        try timeline.validate()
        return timeline
    }

    func save(_ timeline: ProjectTimeline) throws {
        try timeline.validate()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(timeline)
        try writeData(data, url)
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

    let url: URL
    private let store: TimelineFileStore
    private(set) var timeline: ProjectTimeline?
    private(set) var status: Status = .idle
    private(set) var hasUnsavedChanges = false

    private var undoStack: [ProjectTimeline] = []
    private var redoStack: [ProjectTimeline] = []
    private var autosaveTask: Task<Void, Never>?
    private var saveGeneration: UInt64 = 0

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
            timeline = try store.load()
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
        try timeline.validate()
        self.timeline = timeline
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
            try store.save(timeline)
            status = .saved
            hasUnsavedChanges = false
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
}
