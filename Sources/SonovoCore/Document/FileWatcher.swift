import Darwin
import Foundation

/// Watches the *parent directory* of a document.
///
/// Watching the path's directory, not the file descriptor, keeps the watch
/// attached through replace, delete, and recreate: a save that swaps the inode
/// does not detach it. If the directory itself is replaced, the watcher
/// reopens it.
public final class MarkdownFileWatcher: @unchecked Sendable {
    private let fileURL: URL
    private let directory: URL
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "sonovo.markdown-file-watcher")
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var active = false

    public init(fileURL: URL, handler: @escaping @Sendable () -> Void) {
        self.fileURL = fileURL
        self.directory = fileURL.deletingLastPathComponent()
        self.handler = handler
        queue.setSpecific(
            key: Self.queueKey,
            value: ObjectIdentifier(self)
        )
    }

    public func start() {
        onQueue {
            guard !active else { return }
            active = true
            openDirectory()
        }
    }

    public func stop() {
        onQueue {
            active = false
            closeDirectory()
            closeFile()
        }
    }

    /// Runs lifecycle work directly when the caller is already on the watcher
    /// queue. A handler is delivered on this queue, so `stop()` or `start()`
    /// from inside it would otherwise dispatch-sync onto the queue it is
    /// executing on and deadlock.
    private func onQueue(_ body: () -> Void) {
        // Compare the instance identity, not just the key: every watcher
        // shares the static key, and another watcher's queue must not be
        // mistaken for this one.
        if DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self) {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    deinit {
        source?.cancel()
        fileSource?.cancel()
    }

    private func openDirectory(notifyAfterAttach: Bool = false) {
        guard active, source == nil else { return }

        let fd = Darwin.open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleReopen()
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.handleEvent()
        }
        src.setCancelHandler {
            Darwin.close(fd)
        }

        descriptor = fd
        source = src
        src.resume()
        openFileIfPresent()

        if notifyAfterAttach, active {
            // Recovery can reattach to a directory whose file already
            // changed while the watch was down. No later event is
            // guaranteed, so tell the consumer to revalidate now.
            handler()
        }
    }

    private func closeDirectory() {
        source?.cancel()
        source = nil
        descriptor = -1
        closeFile()
    }

    private func openFileIfPresent() {
        guard active, fileSource == nil else { return }

        let fd = Darwin.open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.handleFileEvent()
        }
        src.setCancelHandler {
            Darwin.close(fd)
        }

        fileDescriptor = fd
        fileSource = src
        src.resume()
    }

    private func closeFile() {
        fileSource?.cancel()
        fileSource = nil
        fileDescriptor = -1
    }

    private func handleEvent() {
        guard active else { return }

        handler()

        var descriptorInfo = stat()
        var pathInfo = stat()
        let descriptorOK = descriptor >= 0 && fstat(descriptor, &descriptorInfo) == 0
        let pathOK = stat(directory.path, &pathInfo) == 0

        if !pathOK {
            closeDirectory()
            scheduleReopen()
            return
        }

        if descriptorOK,
           (descriptorInfo.st_dev != pathInfo.st_dev
            || descriptorInfo.st_ino != pathInfo.st_ino) {
            closeDirectory()
            openDirectory(notifyAfterAttach: true)
            return
        }

        refreshFileSource()
    }

    private func handleFileEvent() {
        guard active else { return }

        handler()
        refreshFileSource()
    }

    private func refreshFileSource() {
        guard active else { return }

        var pathInfo = stat()
        guard stat(fileURL.path, &pathInfo) == 0 else {
            closeFile()
            return
        }

        var fileInfo = stat()
        if fileDescriptor < 0 || fstat(fileDescriptor, &fileInfo) != 0
            || fileInfo.st_dev != pathInfo.st_dev
            || fileInfo.st_ino != pathInfo.st_ino {
            closeFile()
            openFileIfPresent()
        }
    }

    private func scheduleReopen() {
        guard active else { return }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.active, self.source == nil else { return }
            self.openDirectory(notifyAfterAttach: true)
        }
    }
}
