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

    private func hash(_ text: String) -> String {
        DiskSnapshot(bytes: Data(text.utf8)).sha256
    }

    private func baselineScan() -> CodeReviewScan {
        CodeReviewInventory.scan(
            root: root,
            cursors: [:],
            decisions: [],
            retained: [],
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
                        hash: $0.hash,
                        capturedAt: date,
                        hasContent: hasContent
                    )
                )
            }
        )
    }

    private func decision(
        path: String,
        left: String,
        right: String,
        disposition: CodeReviewDisposition = .seen,
        createdAt: Date? = nil
    ) -> StoredReviewDecision {
        StoredReviewDecision(
            CodeReviewDecision(
                path: path,
                leftLabel: "Last reviewed",
                rightLabel: "Current",
                leftHash: left,
                rightHash: right,
                disposition: disposition,
                note: "",
                reference: "\(path):1:1",
                createdAt: createdAt ?? date.addingTimeInterval(1)
            )
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

        let (files, truncated, complete) = CodeReviewInventory.files(in: root)
        XCTAssertEqual(
            files.map(\.lastPathComponent).sorted(),
            ["a.swift", "b.py", "notes.txt"]
        )
        XCTAssertFalse(truncated)
        XCTAssertTrue(complete)
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
        XCTAssertTrue(scan.coverageComplete)
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
            retained: [],
            establishesBaseline: false,
            now: date
        )
        XCTAssertEqual(scan.items.map(\.path), ["a.swift"])
        XCTAssertEqual(scan.items.first?.status, .unreviewed)
        XCTAssertNotNil(scan.items.first?.baseline)
        XCTAssertEqual(scan.items.first?.currentHash, hash("let a = 2\n"))
    }

    func testADecisionTurnsTheItemSeenAndThenStale() throws {
        try write("let a = 1\n", to: "a.swift")
        let baselines = cursors(from: baselineScan())
        try write("let a = 2\n", to: "a.swift")
        let current = hash("let a = 2\n")
        let decision = decision(
            path: "a.swift",
            left: baselines["a.swift"]!.hash,
            right: current
        )
        let seen = CodeReviewInventory.scan(
            root: root,
            cursors: baselines,
            decisions: [decision],
            retained: [decision.leftHash, decision.rightHash],
            establishesBaseline: false,
            now: date
        )
        XCTAssertEqual(seen.items.first?.status, .seen)
        XCTAssertEqual(seen.items.first?.canReviewContent, true)

        try write("let a = 3\n", to: "a.swift")
        let stale = CodeReviewInventory.scan(
            root: root,
            cursors: baselines,
            decisions: [decision],
            retained: [decision.leftHash, decision.rightHash],
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
            retained: [],
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
        XCTAssertEqual(scan.coverageComplete, true)
    }

    func testAnInaccessibleFileIsNotReportedDeleted() throws {
        try write("let a = 1\n", to: "sub/a.swift")
        let baselines = cursors(from: baselineScan())
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: sub.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: sub.path
            )
        }

        let scan = CodeReviewInventory.scan(
            root: root,
            cursors: baselines,
            decisions: [],
            retained: [],
            establishesBaseline: false,
            now: date
        )
        XCTAssertFalse(scan.coverageComplete)
        XCTAssertTrue(scan.items.isEmpty, "an unreadable folder is not a deletion")
        XCTAssertEqual(scan.unavailableFiles, 1)
    }

    func testADeletedDirectoryReportsItsFilesAsDeleted() throws {
        try write("let a = 1\n", to: "sub/a.swift")
        let baselines = cursors(from: baselineScan())
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("sub")
        )

        let scan = CodeReviewInventory.scan(
            root: root,
            cursors: baselines,
            decisions: [],
            retained: [],
            establishesBaseline: false,
            now: date
        )
        XCTAssertTrue(scan.coverageComplete)
        XCTAssertEqual(scan.items.map(\.status), [.deleted])
        XCTAssertEqual(scan.unavailableFiles, 0)
    }

    func testAnAddedFileCanBeSeenAndThenStale() throws {
        try write("let a = 1\n", to: "a.swift")
        let baselines = cursors(from: baselineScan())
        try write("let b = 1\n", to: "b.swift")
        let empty = DiskSnapshot(bytes: Data()).sha256
        let first = decision(
            path: "b.swift",
            left: empty,
            right: hash("let b = 1\n")
        )
        let seen = CodeReviewInventory.scan(
            root: root,
            cursors: baselines,
            decisions: [first],
            retained: [first.leftHash, first.rightHash],
            establishesBaseline: false,
            now: date
        )
        XCTAssertEqual(seen.items.first?.status, .seen)
        XCTAssertEqual(seen.items.first?.canReviewContent, true)

        try write("let b = 2\n", to: "b.swift")
        let second = decision(
            path: "b.swift",
            left: first.rightHash,
            right: hash("let b = 2\n"),
            disposition: .changesRequested
        )
        let requested = CodeReviewInventory.scan(
            root: root,
            cursors: baselines,
            decisions: [first, second],
            retained: [first.rightHash, second.rightHash],
            establishesBaseline: false,
            now: date
        )
        XCTAssertEqual(requested.items.first?.status, .changesRequested)

        try write("let b = 3\n", to: "b.swift")
        let stale = CodeReviewInventory.scan(
            root: root,
            cursors: baselines,
            decisions: [first, second],
            retained: [first.rightHash, second.rightHash],
            establishesBaseline: false,
            now: date
        )
        XCTAssertEqual(stale.items.first?.status, .stale)
    }

    func testAnOlderDecisionDoesNotOverrideAnAdvancedBaseline() throws {
        // Baseline advanced to B, current is C, and the only decision is the
        // older A→C. C is current, but the decision was not made against the
        // active baseline, so the item must not report Seen.
        let older = date.addingTimeInterval(-60)
        let baseline = hash("B\n")
        let decision = decision(
            path: "a.swift",
            left: hash("A\n"),
            right: hash("C\n"),
            createdAt: older
        )
        try write("C\n", to: "a.swift")
        let scan = CodeReviewInventory.scan(
            root: root,
            cursors: [
                "a.swift": CodeReviewCursor(
                    path: "a.swift",
                    hash: baseline,
                    capturedAt: date,
                    hasContent: true
                )
            ],
            decisions: [decision],
            retained: [
                decision.leftHash, decision.rightHash, baseline
            ],
            establishesBaseline: false,
            now: date
        )
        XCTAssertEqual(scan.items.first?.status, .stale)
    }

    func testADecisionOlderThanTheCursorIsNotSeen() throws {
        // A→B was decided, then the baseline was set to A again. The decision
        // describes the same bytes but predates the cursor, so B is new work.
        let decision = decision(
            path: "a.swift",
            left: hash("A\n"),
            right: hash("B\n"),
            createdAt: date.addingTimeInterval(-60)
        )
        try write("B\n", to: "a.swift")
        let scan = CodeReviewInventory.scan(
            root: root,
            cursors: [
                "a.swift": CodeReviewCursor(
                    path: "a.swift",
                    hash: hash("A\n"),
                    capturedAt: date,
                    hasContent: true
                )
            ],
            decisions: [decision],
            retained: [decision.leftHash, decision.rightHash],
            establishesBaseline: false,
            now: date
        )
        XCTAssertEqual(scan.items.first?.status, .stale)
    }

    func testAHashOnlyBaselineCanStillReviewRetainedDecisionEvidence() throws {
        try write("let a = 1\n", to: "a.swift")
        let baselines = cursors(from: baselineScan(), hasContent: false)
        try write("let a = 2\n", to: "a.swift")
        let decision = decision(
            path: "a.swift",
            left: baselines["a.swift"]!.hash,
            right: hash("let a = 2\n")
        )
        let scan = CodeReviewInventory.scan(
            root: root,
            cursors: baselines,
            decisions: [decision],
            retained: [decision.leftHash, decision.rightHash],
            establishesBaseline: false,
            now: date
        )
        XCTAssertEqual(scan.items.first?.status, .seen)
        XCTAssertEqual(
            scan.items.first?.canReviewContent,
            true,
            "retained decision evidence makes the pair reviewable"
        )

        let withoutEvidence = CodeReviewInventory.scan(
            root: root,
            cursors: baselines,
            decisions: [decision],
            retained: [],
            establishesBaseline: false,
            now: date
        )
        XCTAssertEqual(withoutEvidence.items.first?.canReviewContent, false)
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
        XCTAssertTrue(item.canReviewContent)

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
        let outcome = await workspace.recordReview(decision, in: document)
        XCTAssertEqual(outcome, .saved)
        await workspace.refreshReviewQueue()
        let reviewed = try XCTUnwrap(workspace.reviewQueue?.items.first)
        XCTAssertEqual(reviewed.status, .changesRequested)
        XCTAssertTrue(reviewed.canReviewContent)

        // The queue reopens the exact pair the decision was made against,
        // not a larger baseline diff.
        let possiblePair = await workspace.reviewPair(for: reviewed)
        let reopenedPair = try XCTUnwrap(possiblePair)
        XCTAssertEqual(reopenedPair.left.sha256, decision.leftHash)
        XCTAssertEqual(reopenedPair.right.sha256, decision.rightHash)

        let reloaded = CodeReviewStore(root: root, directory: ledger)
        let loadedDecision = await reloaded.latestDecision(for: item.path)
        XCTAssertEqual(loadedDecision?.note, "rename it")
        XCTAssertEqual(loadedDecision?.leftHash, decision.leftHash)
    }

    func testTheQueueRestoresTheDecisionAfterASecondEditRoundTrip() async throws {
        try write("let a = 1\n", to: "a.swift")
        let ledger = try support.makeRoot()
        let workspace = CodeWorkspace(readsDemoEnvironment: false)
        workspace.reviewStoreFactory = { workspaceRoot in
            CodeReviewStore(root: workspaceRoot, directory: ledger)
        }
        workspace.setWorkspaceRoot(root)
        await workspace.refreshReviewQueue()

        // A → B: record the first decision.
        try write("let a = 2\n", to: "a.swift")
        await workspace.refreshReviewQueue()
        let firstItem = try XCTUnwrap(workspace.reviewQueue?.items.first)
        let firstOpened = await workspace.beginQueueReview(firstItem)
        XCTAssertTrue(firstOpened)
        let firstDocument = try XCTUnwrap(workspace.selectedDocument)
        let firstDecision = try XCTUnwrap(
            firstDocument.makeReviewDecision(
                .seen,
                note: "",
                path: firstItem.path,
                reference: "\(firstItem.path):1:1"
            )
        )
        let firstOutcome = await workspace.recordReview(
            firstDecision,
            in: firstDocument
        )
        XCTAssertEqual(firstOutcome, .saved)
        let firstClosed = await workspace.close(firstDocument)
        XCTAssertTrue(firstClosed)

        // B → C: a fresh document must not inherit the A→B decision when a
        // different pair is shown.
        try write("let a = 3\n", to: "a.swift")
        await workspace.refreshReviewQueue()
        let secondItem = try XCTUnwrap(workspace.reviewQueue?.items.first)
        XCTAssertEqual(secondItem.status, .stale)
        let secondPossiblePair = await workspace.reviewPair(for: secondItem)
        let secondPair = try XCTUnwrap(secondPossiblePair)
        XCTAssertEqual(secondPair.left.sha256, firstDecision.rightHash)
        XCTAssertEqual(secondPair.right.sha256, hash("let a = 3\n"))
        let secondOpened = await workspace.beginQueueReview(secondItem)
        XCTAssertTrue(secondOpened)
        let secondDocument = try XCTUnwrap(workspace.selectedDocument)
        XCTAssertFalse(secondDocument === firstDocument)
        XCTAssertNil(
            secondDocument.reviewDecision,
            "the A→B decision must not be restored onto B→C"
        )

        let secondDecision = try XCTUnwrap(
            secondDocument.makeReviewDecision(
                .changesRequested,
                note: "narrow it",
                path: secondItem.path,
                reference: "\(secondItem.path):1:1"
            )
        )
        let secondOutcome = await workspace.recordReview(
            secondDecision,
            in: secondDocument
        )
        XCTAssertEqual(secondOutcome, .saved)
        let secondClosed = await workspace.close(secondDocument)
        XCTAssertTrue(secondClosed)

        // Reopening restores the B→C decision, not the older one.
        await workspace.refreshReviewQueue()
        let finalItem = try XCTUnwrap(workspace.reviewQueue?.items.first)
        let finalOpened = await workspace.beginQueueReview(finalItem)
        XCTAssertTrue(finalOpened)
        let reopened = try XCTUnwrap(workspace.selectedDocument)
        XCTAssertFalse(reopened === secondDocument)
        XCTAssertEqual(reopened.reviewDecision, secondDecision)
    }

    func testAMissingDecisionBlobIsUnavailableWithoutFallback() async throws {
        try write("let a = 1\n", to: "a.swift")
        let ledger = try support.makeRoot()
        let workspace = CodeWorkspace(readsDemoEnvironment: false)
        workspace.reviewStoreFactory = { workspaceRoot in
            CodeReviewStore(root: workspaceRoot, directory: ledger)
        }
        workspace.setWorkspaceRoot(root)
        await workspace.refreshReviewQueue()

        try write("let a = 2\n", to: "a.swift")
        await workspace.refreshReviewQueue()
        let item = try XCTUnwrap(workspace.reviewQueue?.items.first)
        let lostOpened = await workspace.beginQueueReview(item)
        XCTAssertTrue(lostOpened)
        let document = try XCTUnwrap(workspace.selectedDocument)
        let decision = try XCTUnwrap(
            document.makeReviewDecision(
                .seen,
                note: "",
                path: item.path,
                reference: "\(item.path):1:1"
            )
        )
        let outcome = await workspace.recordReview(decision, in: document)
        XCTAssertEqual(outcome, .saved)

        try FileManager.default.removeItem(
            at: ledger
                .appendingPathComponent("objects")
                .appendingPathComponent(decision.leftHash)
        )
        await workspace.refreshReviewQueue()
        let lost = try XCTUnwrap(workspace.reviewQueue?.items.first)
        XCTAssertEqual(lost.status, .seen)
        XCTAssertFalse(lost.canReviewContent)
        let pair = await workspace.reviewPair(for: lost)
        XCTAssertNil(
            pair,
            "a missing decision blob is unavailable, never a fallback pair"
        )
    }

    func testADecisionBoundToAnotherPathIsRejected() async throws {
        try write("let a = 1\n", to: "a.swift")
        let ledger = try support.makeRoot()
        let workspace = CodeWorkspace(readsDemoEnvironment: false)
        workspace.reviewStoreFactory = { workspaceRoot in
            CodeReviewStore(root: workspaceRoot, directory: ledger)
        }
        workspace.setWorkspaceRoot(root)
        await workspace.refreshReviewQueue()
        try write("let a = 2\n", to: "a.swift")
        await workspace.refreshReviewQueue()
        let item = try XCTUnwrap(workspace.reviewQueue?.items.first)
        let opened = await workspace.beginQueueReview(item)
        XCTAssertTrue(opened)
        let document = try XCTUnwrap(workspace.selectedDocument)

        // The same bytes at a new identity are a different review. A capture
        // made before Save As must not reinstall the old path's decision.
        let stale = try XCTUnwrap(
            document.makeReviewDecision(
                .seen,
                note: "",
                path: "other.swift",
                reference: "other.swift:1:1"
            )
        )
        let outcome = await workspace.recordReview(stale, in: document)
        XCTAssertEqual(outcome, .pairChanged)
        XCTAssertNil(document.reviewDecision)
    }
}
