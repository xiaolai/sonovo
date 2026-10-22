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
        support.tearDown()
        support = nil
        super.tearDown()
    }

    private func makeStore() -> CodeReviewStore {
        CodeReviewStore(root: root, directory: ledger)
    }

    func testBaselineAndDecisionPersist() throws {
        let before = Data("let a = 1\n".utf8)
        let after = Data("let a = 2\n".utf8)
        let store = makeStore()
        try store.recordBaseline(
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
        try store.record(decision, before: before, after: after)

        let reloaded = makeStore()
        XCTAssertNil(reloaded.lastError)
        XCTAssertEqual(
            reloaded.cursor(for: "a.swift")?.hash,
            DiskSnapshot(bytes: before).sha256,
            "a decision does not move the baseline"
        )
        XCTAssertEqual(reloaded.latestDecision(for: "a.swift")?.reviewDecision,
                       decision)
        XCTAssertEqual(reloaded.content(for: decision.leftHash), before)
        XCTAssertEqual(reloaded.content(for: decision.rightHash), after)
    }

    func testUnreferencedObjectsArePruned() throws {
        let store = makeStore()
        let snapshot = DiskSnapshot(bytes: Data("old\n".utf8))
        try store.recordBaseline(path: "a.swift", snapshot: snapshot)
        let object = ledger
            .appendingPathComponent("objects")
            .appendingPathComponent(snapshot.sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path))

        try store.remove(path: "a.swift")
        XCTAssertFalse(FileManager.default.fileExists(atPath: object.path))
    }

    func testABaselineAboveTheEditingCapKeepsHashOnly() throws {
        let snapshot = DiskSnapshot(
            bytes: Data(repeating: 0x61, count: CodeLimits.editableBytes + 1)
        )
        let store = makeStore()
        try store.recordBaseline(path: "large.swift", snapshot: snapshot)
        let cursor = try XCTUnwrap(store.cursor(for: "large.swift"))
        XCTAssertFalse(cursor.hasContent)
        XCTAssertNil(store.content(for: cursor.hash))
    }

    func testMissingEvidenceIsVisibleNotInvented() throws {
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
        try store.record(decision, before: before, after: after)
        try FileManager.default.removeItem(
            at: ledger
                .appendingPathComponent("objects")
                .appendingPathComponent(decision.rightHash)
        )

        let reloaded = makeStore()
        XCTAssertEqual(
            reloaded.latestDecision(for: "a.swift")?.rightHash,
            decision.rightHash
        )
        XCTAssertFalse(reloaded.hasContent(for: decision.rightHash))
    }

    func testACorruptManifestIsPreserved() throws {
        try FileManager.default.createDirectory(
            at: ledger,
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(
            to: ledger.appendingPathComponent("manifest.json")
        )
        let store = makeStore()
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.cursors.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: ledger.path
        )
        XCTAssertTrue(
            names.contains { $0.hasPrefix("manifest.corrupt-") }
        )
    }
}
