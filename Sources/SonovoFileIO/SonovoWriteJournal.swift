import Foundation

/// Paths Sonovo itself just wrote.
///
/// The project watcher receives FSEvents for every write, including the
/// autosave that Sonovo performed. A full rescan for each of our own writes
/// is pure cost; the project asks this journal before scheduling one. The
/// window is short, and at its expiry the watcher re-stats the suppressed
/// paths: a genuine external write inside the window changes the file's size
/// or modification date and still triggers the rescan, while an untouched own
/// write does not.
public enum SonovoWriteJournal {
    /// How long a recorded write suppresses the project watcher.
    public static let recentWriteWindow: TimeInterval = 1.5

    private struct Entry {
        let recordedAt: Date
        /// Metadata at the moment Sonovo finished writing. Compared at the
        /// window's expiry to tell an own write from an external one.
        let size: Int64?
        let modified: Date?
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var writes: [String: Entry] = [:]
    }

    private static let state = State()

    /// Entries outlive the suppression window. The watcher rechecks at
    /// `recentWriteWindow + 0.2 s`; retaining for twice the window means a
    /// later `record()` can never prune the entry the recheck is about to
    /// read. Suppression itself still ends at `recentWriteWindow`.
    private static let retention: TimeInterval = recentWriteWindow * 2

    /// Records a successful Sonovo write to `path`.
    public static func record(path: String) {
        let normalized = normalize(path)
        let now = Date()
        let metadata = self.metadata(for: normalized)
        state.lock.lock()
        // Drop entries past the recheck horizon so the map stays bounded by
        // the writes of one window.
        state.writes = state.writes.filter {
            now.timeIntervalSince($0.value.recordedAt) <= retention
        }
        state.writes[normalized] = Entry(
            recordedAt: now,
            size: metadata?.size,
            modified: metadata?.modified
        )
        state.lock.unlock()
    }

    /// Whether Sonovo wrote `path` within `recentWriteWindow`. The entry is
    /// not removed here: the expiry recheck still needs its metadata.
    public static func wasRecentlyWritten(path: String) -> Bool {
        let normalized = normalize(path)
        let now = Date()
        state.lock.lock()
        defer { state.lock.unlock() }
        guard let entry = state.writes[normalized] else { return false }
        return now.timeIntervalSince(entry.recordedAt) <= recentWriteWindow
    }

    /// Whether the file no longer matches what Sonovo recorded when it wrote.
    ///
    /// The watcher calls this once the suppression window has expired. A match
    /// means the event was Sonovo's own write; a mismatch — or a file that is
    /// now missing or unreadable — means an external writer touched it and the
    /// project index must rescan.
    public static func changedSinceRecorded(path: String) -> Bool {
        let normalized = normalize(path)
        state.lock.lock()
        let entry = state.writes[normalized]
        state.lock.unlock()
        guard let entry else { return false }
        guard let current = metadata(for: normalized) else { return true }
        guard let size = entry.size, let modified = entry.modified else {
            return true
        }
        return current.size != size || current.modified != modified
    }

    /// Test seam: forgets every recorded write.
    public static func reset() {
        state.lock.lock()
        state.writes.removeAll()
        state.lock.unlock()
    }

    /// Whether `path` names one of the store's hidden transactional files
    /// (`.name.sonovo-tmp-…`, `.sonovo-new-…`, `.sonovo-displaced-…`). Those
    /// writes are Sonovo's own and never change the project index.
    public static func isInternalArtifact(path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent.contains(".sonovo-")
    }

    private static func metadata(
        for path: String
    ) -> (size: Int64?, modified: Date?)? {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else {
            return nil
        }
        return (
            values.fileSize.map(Int64.init),
            values.contentModificationDate
        )
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
