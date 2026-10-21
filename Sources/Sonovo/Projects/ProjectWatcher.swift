import CoreServices
import Foundation

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
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let source = Unmanaged<FSEventSource>
                .fromOpaque(info)
                .takeUnretainedValue()
            source.onChange()
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
}
