import XCTest
import SonovoCore
@testable import Sonovo

final class ProjectWatcherFilterTests: XCTestCase {
    override func tearDown() {
        SonovoWriteJournal.reset()
        super.tearDown()
    }

    /// Sonovo's own save must not schedule a rescan. The journal records the
    /// destination only after the swap verified; other paths stay external.
    func testOwnWritesAreIgnoredAndExternalWritesAreNot() {
        SonovoWriteJournal.reset()
        let own = "/tmp/sonovo-project/doc.md"
        SonovoWriteJournal.record(path: own)

        XCTAssertTrue(FSEventSource.shouldIgnore(path: own))
        // The store's transactional siblings are internal by name.
        XCTAssertTrue(
            FSEventSource.shouldIgnore(
                path: "/tmp/sonovo-project/.doc.md.sonovo-tmp-abc"
            )
        )
        XCTAssertFalse(
            FSEventSource.shouldIgnore(path: "/tmp/sonovo-project/other.md")
        )
    }

    /// The window must not hide a real external write. At expiry the watcher
    /// compares the file with what the save recorded and reschedules when it
    /// differs.
    func testExternalWriteInsideTheWindowIsDetectedAtExpiry() throws {
        SonovoWriteJournal.reset()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("doc.md")
        try Data("one".utf8).write(to: path)
        SonovoWriteJournal.record(path: path.path)
        XCTAssertFalse(
            SonovoWriteJournal.changedSinceRecorded(path: path.path),
            "an untouched own write must not rescan"
        )

        try Data("a different body".utf8).write(to: path)
        XCTAssertTrue(
            SonovoWriteJournal.changedSinceRecorded(path: path.path),
            "an external write inside the window must rescan at expiry"
        )
    }

    func testDeletedFileIsDetectedAtExpiry() throws {
        SonovoWriteJournal.reset()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("doc.md")
        try Data("content".utf8).write(to: path)
        SonovoWriteJournal.record(path: path.path)
        try FileManager.default.removeItem(at: path)
        XCTAssertTrue(
            SonovoWriteJournal.changedSinceRecorded(path: path.path),
            "a file deleted inside the window must rescan at expiry"
        )
    }

    /// The entry must survive the suppression window and a concurrent save's
    /// prune. The watcher rechecks at window + 0.2 s; recording another path
    /// in between must not erase the metadata the recheck needs.
    func testEntrySurvivesUntilTheExpiryRecheck() async throws {
        SonovoWriteJournal.reset()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.md")
        let second = directory.appendingPathComponent("second.md")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        SonovoWriteJournal.record(path: first.path)
        try Data("changed".utf8).write(to: first)

        // Past the suppression window, before the recheck horizon.
        try await Task.sleep(for: .seconds(1.6))
        // A record for another path must not prune the first entry.
        SonovoWriteJournal.record(path: second.path)
        XCTAssertTrue(
            SonovoWriteJournal.changedSinceRecorded(path: first.path),
            "the first entry was pruned before the expiry recheck"
        )
        XCTAssertFalse(
            SonovoWriteJournal.wasRecentlyWritten(path: first.path),
            "suppression must still end at the window"
        )
    }
}
