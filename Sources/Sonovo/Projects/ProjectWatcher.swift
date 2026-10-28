import CoreServices
import Foundation
import SonovoCore

/// The watch seam. Production uses FSEvents; tests inject a source they can
/// trigger manually, so reconciliation is testable without waiting on the
/// filesystem notification daemon.
protocol ProjectWatching: AnyObject {
    /// True only after the underlying stream actually started. A failed
    /// start must be visible so the project can retry instead of assuming
    /// it will receive events.
    var isRunning: Bool { get }
    func start()
    func stop()
}

typealias ProjectWatchFactory = (
    _ root: URL,
    _ onChange: @escaping @Sendable () -> Void
) -> ProjectWatching

/// Any event batch is a hint, not a patch. The project layer debounces and
/// runs a bounded full rescan, so dropped events and directory renames cannot
/// leave a stale index.
final class FSEventSource: ProjectWatching, @unchecked Sendable {
    private let path: String
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "sonovo.project-watch")
    private var stream: FSEventStreamRef?
    private(set) var isRunning = false
    private let recheckLock = NSLock()
    private var recheckScheduled = false
    private var pendingRecheckPaths: Set<String> = []

    init(root: URL, onChange: @escaping @Sendable () -> Void) {
        path = root.path
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let source = Unmanaged<FSEventSource>
                .fromOpaque(info)
                .takeUnretainedValue()
            let paths = eventPaths.assumingMemoryBound(
                to: UnsafePointer<CChar>?.self
            )
            var sawExternalChange = false
            var suppressed: [String] = []
            for index in 0..<count {
                guard let raw = paths[index] else {
                    sawExternalChange = true
                    break
                }
                let eventPath = String(cString: raw)
                if FSEventSource.shouldIgnore(path: eventPath) {
                    suppressed.append(eventPath)
                } else {
                    sawExternalChange = true
                    break
                }
            }
            if sawExternalChange {
                source.onChange()
            } else if !suppressed.isEmpty {
                // The batch was Sonovo's own writes. Re-stat them once the
                // suppression window has expired: an external write that
                // landed inside it changed the file and must still rescan.
                source.scheduleJournalRecheck(suppressed)
            }
        }
        let paths = [path] as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            UInt32(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot
            )
        ) else {
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            // Release the failed stream so a later start() can try again.
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            isRunning = false
            return
        }
        isRunning = true
    }

    func stop() {
        defer { isRunning = false }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    /// Sonovo's own writes are not project changes. A save records its
    /// destination; the store's hidden transactional files are internal by
    /// name. Anything else is external and schedules a rescan.
    static func shouldIgnore(path: String) -> Bool {
        SonovoWriteJournal.isInternalArtifact(path: path)
            || SonovoWriteJournal.wasRecentlyWritten(path: path)
    }

    /// Runs one stat comparison after the journal window closes. Coalesced so
    /// a burst of own-write events schedules at most one check, while every
    /// path in the burst is still examined.
    private func scheduleJournalRecheck(_ paths: [String]) {
        recheckLock.lock()
        pendingRecheckPaths.formUnion(paths)
        if recheckScheduled {
            recheckLock.unlock()
            return
        }
        recheckScheduled = true
        recheckLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + SonovoWriteJournal.recentWriteWindow + 0.2
        ) { [weak self] in
            guard let self else { return }
            self.recheckLock.lock()
            self.recheckScheduled = false
            let checked = self.pendingRecheckPaths
            self.pendingRecheckPaths.removeAll()
            self.recheckLock.unlock()
            if checked.contains(where: {
                SonovoWriteJournal.changedSinceRecorded(path: $0)
            }) {
                self.onChange()
            }
        }
    }
}
