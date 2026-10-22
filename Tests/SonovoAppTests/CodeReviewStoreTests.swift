import Foundation
import SonovoCore
import XCTest
@testable import Sonovo

@MainActor
final class CodeReviewStoreTests: XCTestCase {
    private var support: CodeTestSupport!
    private var root: URL!
    private var ledger: URL!
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        support = CodeTestSupport()
        root = try? support.makeRoot(files: [:])
        ledger = root.appendingPathComponent("ledger", isDirectory: true)
    }

    override func tearDown() {
        // Restore permissions first: a test may have made the ledger
        // read-only to force a save failure.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: ledger.path
        )
        support.tearDown()
        support = nil
        super.tearDown()
    }

    private func makeStore() -> CodeReviewStore {
        CodeReviewStore(root: root, directory: ledger)
    }

    private func objectURL(for hash: String) -> URL {
        ledger
            .appendingPathComponent("objects")
            .appendingPathComponent(hash)
    }

    func testBaselineAndDecisionPersist() async throws {
        let before = Data("let a = 1\n".utf8)
        let after = Data("let a = 2\n".utf8)
        let store = makeStore()
        try await store.recordBaseline(
            path: "a.swift",
            snapshot: DiskSnapshot(bytes: before),
            at: date
        )
        let decision = CodeReviewDecision(
            path: "a.swift",
            leftLabel: "Last reviewed",
            rightLabel: "Current",
            leftHash: DiskSnapshot(bytes: before).sha256,
            rightHash: DiskSnapshot(bytes: after).sha256,
            disposition: .changesRequested,
            note: "rename",
            reference: "a.swift:1:1",
            createdAt: date
        )
        try await store.record(decision, before: before, after: after)

        let reloaded = makeStore()
        let loadError = await reloaded.state().lastError
        XCTAssertNil(loadError)
        let cursor = await reloaded.cursor(for: "a.swift")
        XCTAssertEqual(
            cursor?.hash,
            DiskSnapshot(bytes: before).sha256,
            "a decision does not move the baseline"
        )
        let latest = await reloaded.latestDecision(for: "a.swift")
        XCTAssertEqual(latest?.reviewDecision, decision)
        let left = await reloaded.content(for: decision.leftHash)
        let right = await reloaded.content(for: decision.rightHash)
        XCTAssertEqual(left, before)
        XCTAssertEqual(right, after)
    }

    func testUnreferencedObjectsArePruned() async throws {
        let store = makeStore()
        let snapshot = DiskSnapshot(bytes: Data("old\n".utf8))
        try await store.recordBaseline(path: "a.swift", snapshot: snapshot)
        let object = objectURL(for: snapshot.sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path))

        try await store.remove(path: "a.swift")
        XCTAssertFalse(FileManager.default.fileExists(atPath: object.path))
    }

    func testABaselineAboveTheEditingCapKeepsHashOnly() async throws {
        let snapshot = DiskSnapshot(
            bytes: Data(repeating: 0x61, count: CodeLimits.editableBytes + 1)
        )
        let store = makeStore()
        try await store.recordBaseline(path: "large.swift", snapshot: snapshot)
        let storedCursor = await store.cursor(for: "large.swift")
        let cursor = try XCTUnwrap(storedCursor)
        XCTAssertFalse(cursor.hasContent)
        let content = await store.content(for: cursor.hash)
        XCTAssertNil(content)
    }

    func testMissingEvidenceIsVisibleNotInvented() async throws {
        let before = Data("before\n".utf8)
        let after = Data("after\n".utf8)
        let store = makeStore()
        let decision = CodeReviewDecision(
            path: "a.swift",
            leftLabel: "Last reviewed",
            rightLabel: "Current",
            leftHash: DiskSnapshot(bytes: before).sha256,
            rightHash: DiskSnapshot(bytes: after).sha256,
            disposition: .seen,
            note: "",
            reference: "a.swift:1:1",
            createdAt: date
        )
        try await store.record(decision, before: before, after: after)
        try FileManager.default.removeItem(
            at: objectURL(for: decision.rightHash)
        )

        let reloaded = makeStore()
        let latest = await reloaded.latestDecision(for: "a.swift")
        XCTAssertEqual(latest?.rightHash, decision.rightHash)
        let available = await reloaded.hasContent(for: decision.rightHash)
        XCTAssertFalse(available)
    }

    func testDecisionOrderingSurvivesReload() async throws {
        // Sub-millisecond ordering must survive: string date formats that
        // stop at milliseconds would reload these two as equal.
        let captured = date.addingTimeInterval(0.0001)
        let decided = date.addingTimeInterval(0.0002)
        let store = makeStore()
        let snapshot = DiskSnapshot(bytes: Data("a\n".utf8))
        try await store.recordBaseline(
            path: "a.swift",
            snapshot: snapshot,
            at: captured
        )
        try await store.record(
            CodeReviewDecision(
                path: "a.swift",
                leftLabel: "Last reviewed",
                rightLabel: "Current",
                leftHash: snapshot.sha256,
                rightHash: snapshot.sha256,
                disposition: .seen,
                note: "",
                reference: "a.swift:1:1",
                createdAt: decided
            ),
            before: snapshot.bytes,
            after: snapshot.bytes
        )

        let reloaded = makeStore()
        let cursor = await reloaded.cursor(for: "a.swift")
        let latest = await reloaded.latestDecision(for: "a.swift")
        let storedCursor = try XCTUnwrap(cursor)
        let storedDecision = try XCTUnwrap(latest)
        XCTAssertEqual(
            storedCursor.capturedAt.timeIntervalSince1970,
            captured.timeIntervalSince1970,
            accuracy: 0.000001
        )
        XCTAssertEqual(
            storedDecision.createdAt.timeIntervalSince1970,
            decided.timeIntervalSince1970,
            accuracy: 0.000001
        )
        XCTAssertGreaterThan(storedDecision.createdAt, storedCursor.capturedAt)
    }

    func testACorruptedBlobIsUnavailableNotEvidence() async throws {
        let before = Data("before\n".utf8)
        let store = makeStore()
        let snapshot = DiskSnapshot(bytes: before)
        try await store.recordBaseline(path: "a.swift", snapshot: snapshot)
        try Data("tampered\n".utf8).write(to: objectURL(for: snapshot.sha256))

        let content = await store.content(for: snapshot.sha256)
        XCTAssertNil(content, "bytes that do not hash to their name are not evidence")
        let error = await store.lastError
        XCTAssertNotNil(error)
        let retained = await store.retainedHashes()
        XCTAssertFalse(
            retained.contains(snapshot.sha256),
            "a hash that failed verification is not offered as available"
        )
    }

    func testAdjacentDatesStayDistinctAcrossReload() async throws {
        // Two Dates one representable step apart at this magnitude must not
        // collapse when persisted; Unix seconds would round them together.
        let captured = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let decided = Date(
            timeIntervalSinceReferenceDate: (700_000_000.0).nextUp
        )
        XCTAssertGreaterThan(decided, captured)

        let store = makeStore()
        let snapshot = DiskSnapshot(bytes: Data("a\n".utf8))
        try await store.recordBaseline(
            path: "a.swift",
            snapshot: snapshot,
            at: captured
        )
        try await store.record(
            CodeReviewDecision(
                path: "a.swift",
                leftLabel: "Last reviewed",
                rightLabel: "Current",
                leftHash: snapshot.sha256,
                rightHash: snapshot.sha256,
                disposition: .seen,
                note: "",
                reference: "a.swift:1:1",
                createdAt: decided
            ),
            before: snapshot.bytes,
            after: snapshot.bytes
        )

        let reloaded = makeStore()
        let reloadedCursor = await reloaded.cursor(for: "a.swift")
        let reloadedDecision = await reloaded.latestDecision(for: "a.swift")
        let cursor = try XCTUnwrap(reloadedCursor)
        let latest = try XCTUnwrap(reloadedDecision)
        XCTAssertEqual(cursor.capturedAt, captured)
        XCTAssertEqual(latest.createdAt, decided)
        XCTAssertGreaterThan(latest.createdAt, cursor.capturedAt)
    }

    func testRetainedHashesRejectsTamperedObjectsBeforeUse() async throws {
        let store = makeStore()
        let snapshot = DiskSnapshot(bytes: Data("evidence\n".utf8))
        try await store.recordBaseline(path: "a.swift", snapshot: snapshot)
        try Data("tampered\n".utf8).write(
            to: objectURL(for: snapshot.sha256)
        )

        // A fresh store has never read this object; the availability listing
        // itself must notice the mismatch.
        let reloaded = makeStore()
        let retained = await reloaded.retainedHashes()
        XCTAssertFalse(retained.contains(snapshot.sha256))
        let content = await reloaded.content(for: snapshot.sha256)
        XCTAssertNil(content)
    }

    func testACorruptManifestIsPreserved() async throws {
        try FileManager.default.createDirectory(
            at: ledger,
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(
            to: ledger.appendingPathComponent("manifest.json")
        )
        let store = makeStore()
        _ = await store.state()
        let error = await store.lastError
        XCTAssertNotNil(error)
        let cursors = await store.cursors
        XCTAssertTrue(cursors.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: ledger.path
        )
        XCTAssertTrue(
            names.contains { $0.hasPrefix("manifest.corrupt-") }
        )
    }

    func testAnArchivedManifestKeepsItsEvidence() async throws {
        let store = makeStore()
        let kept = DiskSnapshot(bytes: Data("keep\n".utf8))
        try await store.recordBaseline(path: "keep.swift", snapshot: kept)
        let object = objectURL(for: kept.sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path))

        // Loading archives the unreadable manifest; the evidence it named is
        // still the only copy, so later saves must not prune it.
        try Data("not json".utf8).write(
            to: ledger.appendingPathComponent("manifest.json")
        )
        let reloaded = makeStore()
        _ = await reloaded.state()
        let error = await reloaded.lastError
        XCTAssertNotNil(error)
        try await reloaded.recordBaseline(
            path: "new.swift",
            snapshot: DiskSnapshot(bytes: Data("new\n".utf8))
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: object.path),
            "an archived manifest's evidence must survive the next prune"
        )
    }

    func testPruningIsSkippedWhenArchivesCannotBeListed() async throws {
        let store = makeStore()
        let kept = DiskSnapshot(bytes: Data("keep\n".utf8))
        try await store.recordBaseline(path: "keep.swift", snapshot: kept)
        let object = objectURL(for: kept.sha256)
        try Data("not json".utf8).write(
            to: ledger.appendingPathComponent("manifest.json")
        )
        let loaded = makeStore()
        _ = await loaded.state()

        // Write + execute, no read: the ledger cannot be listed, so the store
        // cannot prove no archive exists. Pruning must fail closed.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o300],
            ofItemAtPath: ledger.path
        )
        try await loaded.recordBaseline(
            path: "new.swift",
            snapshot: DiskSnapshot(bytes: Data("new\n".utf8))
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: ledger.path
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: object.path),
            "unlistable archives must block pruning"
        )
    }

    func testAFailedSaveRollsBackMemory() async throws {
        let store = makeStore()
        _ = await store.state()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: ledger.path
        )
        var failed = false
        do {
            try await store.recordBaseline(
                path: "a.swift",
                snapshot: DiskSnapshot(bytes: Data("a\n".utf8)),
                at: date
            )
        } catch {
            failed = true
        }
        XCTAssertTrue(failed, "a read-only ledger cannot save")
        let cursor = await store.cursor(for: "a.swift")
        XCTAssertNil(cursor, "memory must not claim a baseline the disk lacks")
        let established = await store.baselineEstablishedAt
        XCTAssertNil(established)
    }
}
