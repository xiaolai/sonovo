import Foundation
import XCTest
@testable import Sonovo

@MainActor
final class CodeReviewTests: XCTestCase {
    private var support: CodeTestSupport!

    override func setUp() {
        super.setUp()
        support = CodeTestSupport()
    }

    override func tearDown() {
        support.tearDown()
        support = nil
        super.tearDown()
    }

    private func makeDocument(
        _ data: Data,
        name: String = "file.swift"
    ) async throws -> (CodeDocument, URL) {
        let root = try support.makeRoot(files: [name: data])
        let url = root.appendingPathComponent(name)
        let document = CodeDocument(url: url)
        await document.load()
        return (document, url)
    }

    func testDecisionBindsTheExactPair() async throws {
        let (document, _) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        let pair = try XCTUnwrap(document.displayedDiffPair)
        XCTAssertEqual(pair.leftLabel, "Saved")
        XCTAssertEqual(pair.rightLabel, "Buffer")

        let decision = try XCTUnwrap(
            document.makeReviewDecision(
                .changesRequested,
                note: "  rename a  ",
                path: "file.swift",
                reference: "file.swift:1:1",
                now: Date(timeIntervalSince1970: 100)
            )
        )
        XCTAssertEqual(decision.leftHash, pair.left.sha256)
        XCTAssertEqual(decision.rightHash, pair.right.sha256)
        XCTAssertEqual(decision.note, "rename a")
        XCTAssertTrue(document.recordReview(decision))
        XCTAssertEqual(document.reviewDecision, decision)
        XCTAssertFalse(document.reviewDecisionIsStale)
    }

    func testAChangedPairMakesTheDecisionStale() async throws {
        let (document, _) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        let decision = try XCTUnwrap(
            document.makeReviewDecision(
                .seen,
                note: "",
                path: "file.swift",
                reference: "file.swift:1:1"
            )
        )
        XCTAssertTrue(document.recordReview(decision))
        XCTAssertFalse(document.reviewDecisionIsStale)

        try document.replaceSource("let a = 3\n")
        XCTAssertTrue(document.reviewDecisionIsStale)
        XCTAssertEqual(
            document.reviewDecision,
            decision,
            "staleness describes the pair; it does not rewrite the decision"
        )
    }

    func testADecisionForAnotherPairCannotBeRecorded() async throws {
        let (document, _) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        let decision = try XCTUnwrap(
            document.makeReviewDecision(
                .changesRequested,
                note: "fix",
                path: "file.swift",
                reference: "file.swift:1:1"
            )
        )
        try document.replaceSource("let a = 3\n")
        XCTAssertFalse(document.recordReview(decision))
        XCTAssertNil(document.reviewDecision)
    }

    func testRecordingADecisionDoesNotMoveTheSaveBaselines() async throws {
        let (document, _) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        let savedRevision = document.savedRevision
        let acknowledged = document.lastAcknowledged
        let baseline = document.bufferBaseline

        let decision = try XCTUnwrap(
            document.makeReviewDecision(
                .seen,
                note: "",
                path: "file.swift",
                reference: "file.swift:1:1"
            )
        )
        XCTAssertTrue(document.recordReview(decision))
        XCTAssertEqual(document.savedRevision, savedRevision)
        XCTAssertEqual(document.lastAcknowledged, acknowledged)
        XCTAssertEqual(document.bufferBaseline, baseline)
    }

    func testAnUnavailablePairCannotBeReviewed() async throws {
        let (document, _) = try await makeDocument(
            Data(repeating: 0x61, count: CodeLimits.editableBytes + 1)
        )
        XCTAssertNil(document.displayedDiffPair)
        XCTAssertNil(
            document.makeReviewDecision(
                .seen,
                note: "",
                path: "large.swift",
                reference: "large.swift:1:1"
            )
        )
    }

    func testInstructionCarriesThePairDecisionAndNote() {
        let decision = CodeReviewDecision(
            path: "src/a.swift",
            leftLabel: "Acknowledged",
            rightLabel: "Disk",
            leftHash: "aaaaaaaaaaaaaaaa",
            rightHash: "bbbbbbbbbbbbbbbb",
            disposition: .changesRequested,
            note: "Rename the\nvariable",
            reference: "src/a.swift:3:5",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let text = CodeReviewInstruction.text(for: decision)
        XCTAssertTrue(text.contains("Review of src/a.swift"))
        XCTAssertTrue(
            text.contains("Pair: Acknowledged → Disk (aaaaaaa → bbbbbbb)")
        )
        XCTAssertTrue(text.contains("Decision: changes requested"))
        XCTAssertTrue(text.contains("Reference: src/a.swift:3:5"))
        XCTAssertTrue(text.contains("Rename the\nvariable"))

        let oneLine = CodeReviewInstruction.oneLine(for: decision)
        XCTAssertTrue(
            oneLine.hasPrefix("src/a.swift:3:5 — review "),
            "the one-line payload must lead with the reference"
        )
        XCTAssertFalse(oneLine.contains("\n"))
        XCTAssertTrue(oneLine.contains("Rename the variable"))
        XCTAssertTrue(oneLine.contains("changes requested"))
    }

    func testAnEmptyNoteIsOmitted() {
        let decision = CodeReviewDecision(
            path: "a.swift",
            leftLabel: "Saved",
            rightLabel: "Buffer",
            leftHash: "aaaaaaaa",
            rightHash: "bbbbbbbb",
            disposition: .seen,
            note: "   ",
            reference: "a.swift:1:1",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let text = CodeReviewInstruction.text(for: decision)
        XCTAssertFalse(text.contains("Note:"))
        XCTAssertEqual(text.components(separatedBy: "\n").count, 4)
        XCTAssertFalse(
            CodeReviewInstruction.oneLine(for: decision).hasSuffix("— ")
        )
    }
}
