import Foundation
import SonovoCore
import XCTest
@testable import Sonovo

@MainActor
final class CodeReviewQueueTests: XCTestCase {
    private var support: CodeTestSupport!
    private var root: URL!
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        support = CodeTestSupport()
        root = try? support.makeRoot(files: [:])
    }

    override func tearDown() {
        support.tearDown()
        support = nil
        super.tearDown()
    }

    private func write(_ text: String, to relative: String) throws {
        try support.write(
            Data(text.utf8),
            to: root.appendingPathComponent(relative)
        )
    }

    private func baselineScan() -> CodeReviewScan {
        CodeReviewInventory.scan(
            root: root,
            cursors: [:],
            decisions: [],
            establishesBaseline: true,
            now: date
        )
    }

    private func cursors(
        from scan: CodeReviewScan,
        hasContent: Bool = true
    ) -> [String: CodeReviewCursor] {
        Dictionary(
            uniqueKeysWithValues: scan.baselines.map {
                (
                    $0.path,
                    CodeReviewCursor(
                        path: $0.path,
                        hash: $0.snapshot.sha256,
                        capturedAt: date,
                        hasContent: hasContent
                    )
                )
            }
        )
    }

    func testInventoryIsExplicitAboutCoverage() throws {
        try write("let a = 1\n", to: "Sources/a.swift")
        try write("print(1)\n", to: "b.py")
        try write("note\n", to: "notes.txt")
        try write("readme\n", to: "README")
        try write("png", to: "image.png")
        try write("hidden\n", to: ".hidden.swift")
        try write("ignored\n", to: "node_modules/c.js")
        try write("build\n", to: ".build/d.swift")

        let (files, truncated) = CodeReviewInventory.files(in: root)
        XCTAssertEqual(
            files.map(\.lastPathComponent).sorted(),
            ["a.swift", "b.py", "notes.txt"]
        )
        XCTAssertFalse(truncated)
    }

    func testFirstScanEstablishesTheBaseline() throws {
        try write("let a = 1\n", to: "a.swift")
        try write("let b = 1\n", to: "b.swift")
        let scan = baselineScan()
        XCTAssertTrue(scan.establishedBaseline)
        XCTAssertTrue(scan.items.isEmpty)
        XCTAssertEqual(scan.baselines.count, 2)
        XCTAssertEqual(scan.coveredFiles, 2)
        XCTAssertTrue(scan.baselines.allSatisfy { $0.bytes != nil })
    }

    func testAChangedFileBecomesUnreviewed() throws {
        try write("let a = 1\n", to: "a.swift")
        try write("let b = 1\n", to: "b.swift")
        let baselines = cursors(from: baselineScan())
        try write("let a = 2\n", to: "a.swift")

        let scan = CodeReviewInventory.scan(
            root: root,
            cursors: baselines,
            decisions: [],
            establishesBaseline: false,
            now: date
        )
        XCTAssertEqual(scan.items.map(\.path), ["a.swift"])
        XCTAssertEqual(scan.items.first?.status, .unreviewed)
        XCTAssertNotNil(scan.items.first?.baseline)
        XCTAssertEqual(scan.items.first?.currentHash,
                       DiskSnapshot(bytes: Data("let a = 2\n".utf8)).sha256)
    }

    func testADecisionTurnsTheItemSeenAndThenStale() throws {
        try write("let a = 1\n", to: "a.swift")
        let baselines = cursors(from: baselineScan())
        try write("let a = 2\n", to: "a.swift")
        let current = DiskSnapshot(bytes: Data("let a = 2\n".utf8))
        let decision = StoredReviewDecision(
            CodeReviewDecision(
                path: "a.swift",
                leftLabel: "Last reviewed",
                rightLabel: "Current",
                leftHash: baselines["a.swift"]!.hash,
                rightHash: current.sha256,
                disposition: .seen,
                note: "",
                reference: "a.swift:1:1",
                createdAt: date
            )
        )
        let seen = CodeReviewInventory.scan(
            root: root,
            cursors: baselines,
            decisions: [decision],
            establishesBaseline: false,
            now: date
        )
        XCTAssertEqual(seen.items.first?.status, .seen)

        try write("let a = 3\n", to: "a.swift")
        let stale = CodeReviewInventory.scan(
            root: root,
            cursors: baselines,
            decisions: [decision],
            establishesBaseline: false,
            now: date
        )
        XCTAssertEqual(stale.items.first?.status, .stale)
        XCTAssertEqual(stale.items.first?.decision, decision)
    }

    func testAddedAndDeletedFilesAreReported() throws {
        try write("let a = 1\n", to: "a.swift")
        try write("let b = 1\n", to: "b.swift")
        let baselines = cursors(from: baselineScan())
        try write("let c = 1\n", to: "c.swift")
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("b.swift")
        )

        let scan = CodeReviewInventory.scan(
            root: root,
            cursors: baselines,
            decisions: [],
            establishesBaseline: false,
            now: date
        )
        XCTAssertEqual(scan.items.map(\.path).sorted(), ["b.swift", "c.swift"])
        XCTAssertEqual(
            scan.items.first { $0.path == "c.swift" }?.status,
            .unreviewed
        )
        XCTAssertNil(
            scan.items.first { $0.path == "c.swift" }?.baseline
        )
        XCTAssertEqual(
            scan.items.first { $0.path == "b.swift" }?.status,
            .deleted
        )
    }

    func testAnEmptyProjectStillEstablishesABaseline() async throws {
        let ledger = try support.makeRoot()
        let workspace = CodeWorkspace(readsDemoEnvironment: false)
        workspace.reviewStoreFactory = { workspaceRoot in
            CodeReviewStore(root: workspaceRoot, directory: ledger)
        }
        workspace.setWorkspaceRoot(root)
        await workspace.refreshReviewQueue()
        XCTAssertEqual(workspace.reviewQueue?.establishedBaseline, true)
        await workspace.refreshReviewQueue()
        XCTAssertEqual(workspace.reviewQueue?.establishedBaseline, false)
        XCTAssertEqual(workspace.reviewQueue?.items.count, 0)
    }

    func testTheWorkspaceEstablishesReviewsAndPersists() async throws {
        try write("let a = 1\n", to: "a.swift")
        let ledger = try support.makeRoot()
        let workspace = CodeWorkspace(readsDemoEnvironment: false)
        workspace.reviewStoreFactory = { workspaceRoot in
            CodeReviewStore(root: workspaceRoot, directory: ledger)
        }
        workspace.setWorkspaceRoot(root)
        await workspace.refreshReviewQueue()
        XCTAssertEqual(workspace.reviewQueue?.establishedBaseline, true)
        XCTAssertEqual(workspace.reviewQueue?.coveredFiles, 1)

        try write("let a = 2\n", to: "a.swift")
        await workspace.refreshReviewQueue()
        let item = try XCTUnwrap(workspace.reviewQueue?.items.first)
        XCTAssertEqual(item.path, "a.swift")
        XCTAssertEqual(item.status, .unreviewed)

        let opened = await workspace.beginQueueReview(item)
        XCTAssertTrue(opened)
        let document = try XCTUnwrap(workspace.selectedDocument)
        XCTAssertEqual(document.reviewedDiff?.leftLabel, "Last reviewed")
        XCTAssertEqual(document.reviewedDiff?.rightLabel, "Current")

        let decision = try XCTUnwrap(
            document.makeReviewDecision(
                .changesRequested,
                note: "rename it",
                path: item.path,
                reference: "\(item.path):1:1"
            )
        )
        XCTAssertTrue(workspace.recordReview(decision, in: document))
        await workspace.refreshReviewQueue()
        let reviewed = try XCTUnwrap(workspace.reviewQueue?.items.first)
        XCTAssertEqual(reviewed.status, .changesRequested)

        // Reopening the item must show the exact pair the decision was made
        // against, not a larger baseline diff.
        let possiblePair = await workspace.reviewPair(for: reviewed)
        let reopenedPair = try XCTUnwrap(possiblePair)
        XCTAssertEqual(reopenedPair.left.sha256, decision.leftHash)
        XCTAssertEqual(reopenedPair.right.sha256, decision.rightHash)
        _ = await workspace.beginQueueReview(reviewed)
        XCTAssertEqual(document.reviewDecision, decision)

        let reloaded = CodeReviewStore(root: root, directory: ledger)
        XCTAssertEqual(
            reloaded.latestDecision(for: item.path)?.note,
            "rename it"
        )
        XCTAssertEqual(reloaded.latestDecision(for: item.path)?.leftHash,
                       decision.leftHash)
    }
}
