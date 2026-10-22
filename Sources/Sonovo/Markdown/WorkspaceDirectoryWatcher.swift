import Foundation

/// Watches a folder tree for changes that affect the workspace index.
///
/// A directory file descriptor reports only changes to its own entries, so a
/// nested folder could gain or lose Markdown files without notice. FSEvents
/// reports the whole tree. The callback fires on a private queue and may fire
/// repeatedly for one change; the workspace debounces and rescans off-main.
final class WorkspaceDirectoryWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(
        label: "sonovo.workspace-directory-watcher"
    )
    private var stream: FSEventStreamRef?
    private var active = false

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        guard !active, stream == nil else { return active }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorkspaceDirectoryWatcher>
                .fromOpaque(info)
                .takeUnretainedValue()
            watcher.onChange()
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
            )
        ) else {
            return false
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        active = true
        return true
    }

    func stop() {
        guard let stream else { return }
        active = false
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
