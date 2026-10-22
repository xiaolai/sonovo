import Foundation
import SonovoCore
import XCTest
@testable import Sonovo

final class CodeDiffTests: XCTestCase {
    private func snapshot(_ text: String) -> DiskSnapshot {
        DiskSnapshot(bytes: Data(text.utf8))
    }

    private func pair(_ left: String, _ right: String) -> CodeDiffPair {
        CodeDiffPair(
            leftLabel: "A",
            rightLabel: "B",
            left: snapshot(left),
            right: snapshot(right)
        )
    }

    func testInsertHunkIsHandAuthored() {
        let model = CodeDiffModel.compare(
            pair("a\nb\n", "a\nx\nb\n")
        )
        XCTAssertEqual(model.addedCount, 1)
        XCTAssertEqual(model.removedCount, 0)
        XCTAssertEqual(model.hunks.count, 1)
        let changed = model.rows.filter { $0.kind != .equal }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed[0].kind, .insert)
        XCTAssertEqual(changed[0].right?.text, "x")
        XCTAssertEqual(changed[0].right?.number, 2)
        XCTAssertNil(changed[0].left)
    }

    func testDeleteHunkIsHandAuthored() {
        let model = CodeDiffModel.compare(
            pair("a\nx\nb\n", "a\nb\n")
        )
        XCTAssertEqual(model.addedCount, 0)
        XCTAssertEqual(model.removedCount, 1)
        let changed = model.rows.filter { $0.kind != .equal }
        XCTAssertEqual(changed[0].kind, .delete)
        XCTAssertEqual(changed[0].left?.text, "x")
        XCTAssertNil(changed[0].right)
    }

    func testReplaceKeepsDeleteAndInsertRows() {
        let model = CodeDiffModel.compare(
            pair("a\nb\nc\n", "a\nB\nc\n")
        )
        XCTAssertEqual(model.removedCount, 1)
        XCTAssertEqual(model.addedCount, 1)
        let changed = model.rows.filter { $0.kind != .equal }
        XCTAssertEqual(changed.map(\.kind), [.delete, .insert])
        XCTAssertEqual(changed[0].left?.text, "b")
        XCTAssertEqual(changed[1].right?.text, "B")
    }

    func testRepeatedLinesDiffOneOccurrence() {
        let model = CodeDiffModel.compare(
            pair("a\na\na\n", "a\na\n")
        )
        XCTAssertEqual(model.removedCount, 1)
        XCTAssertEqual(model.addedCount, 0)
        XCTAssertEqual(model.rows.filter { $0.kind == .equal }.count, 2)
    }

    func testCRLFAndLFAreDifferentLines() {
        let model = CodeDiffModel.compare(
            pair("a\r\nb\r\n", "a\nb\n")
        )
        XCTAssertEqual(model.removedCount, 2)
        XCTAssertEqual(model.addedCount, 2)
        let removed = model.rows.filter { $0.kind == .delete }
        XCTAssertEqual(
            removed.map { $0.left?.terminator },
            [.crlf, .crlf]
        )
        let inserted = model.rows.filter { $0.kind == .insert }
        XCTAssertEqual(
            inserted.map { $0.right?.terminator },
            [.lf, .lf]
        )
    }

    func testNoFinalNewlineIsAChange() {
        let model = CodeDiffModel.compare(
            pair("a\n", "a")
        )
        XCTAssertEqual(model.removedCount, 1)
        XCTAssertEqual(model.addedCount, 1)
        XCTAssertEqual(
            model.rows.first { $0.kind == .delete }?.left?.terminator,
            .lf
        )
        XCTAssertEqual(
            model.rows.first { $0.kind == .insert }?.right?.terminator,
            CodeLineTerminator.none
        )
    }

    func testEOLOnlyChangeIsVisible() {
        let model = CodeDiffModel.compare(
            pair("a\nb\n", "a\r\nb\r\n")
        )
        XCTAssertEqual(model.removedCount, 2)
        XCTAssertEqual(model.addedCount, 2)
    }

    func testUnicodeCanonicalEquivalentsAreDifferent() {
        let composed = "caf\u{00E9}\n"
        let decomposed = "cafe\u{0301}\n"
        XCTAssertEqual(composed, decomposed, "Swift String equality folds them")
        let model = CodeDiffModel.compare(
            pair(composed, decomposed)
        )
        XCTAssertEqual(
            model.removedCount,
            1,
            "byte comparison must not fold canonical equivalents"
        )
        XCTAssertEqual(model.addedCount, 1)
    }

    func testLineSplittingKeepsTerminators() {
        let lines = CodeDiffModel.lines(
            in: Data("a\r\nb\nc".utf8)
        )
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].text, "a")
        XCTAssertEqual(lines[0].terminator, .crlf)
        XCTAssertEqual(lines[1].text, "b")
        XCTAssertEqual(lines[1].terminator, .lf)
        XCTAssertEqual(lines[2].text, "c")
        XCTAssertEqual(lines[2].terminator, .none)
        XCTAssertTrue(CodeDiffModel.lines(in: Data()).isEmpty)
    }

    func testOverCapNamesTheSide() {
        let tooManyLines = DiskSnapshot(
            bytes: Data(
                String(repeating: "a\n", count: 50_001).utf8
            )
        )
        let availability = CodeDiffModel.availability(
            left: tooManyLines,
            right: snapshot("a\n"),
            leftLabel: "Acknowledged",
            rightLabel: "Disk"
        )
        guard case .unavailable(let reason) = availability else {
            return XCTFail("expected an over-cap state")
        }
        XCTAssertTrue(reason.contains("Acknowledged"))
        XCTAssertTrue(reason.contains("50,000"))

        let tooLarge = DiskSnapshot(
            bytes: Data(
                repeating: 0x61,
                count: CodeLimits.diffBytesPerSide + 1
            )
        )
        let sizeAvailability = CodeDiffModel.availability(
            left: snapshot("a\n"),
            right: tooLarge,
            leftLabel: "Acknowledged",
            rightLabel: "Disk"
        )
        guard case .unavailable(let sizeReason) = sizeAvailability else {
            return XCTFail("expected an over-cap state")
        }
        XCTAssertTrue(sizeReason.contains("Disk"))
        XCTAssertTrue(sizeReason.contains("2 MB"))
    }

    func testUnifiedTextContainsHunkHeaders() {
        let model = CodeDiffModel.compare(
            pair("a\nb\n", "a\nB\n")
        )
        let text = model.unifiedText
        XCTAssertTrue(text.contains("--- A"))
        XCTAssertTrue(text.contains("+++ B"))
        XCTAssertTrue(text.contains("@@ -1,2 +1,2 @@"))
        XCTAssertTrue(text.contains("-b"))
        XCTAssertTrue(text.contains("+B"))
    }

    func testUnequalMiddleLengthsDoNotCrash() {
        let model = CodeDiffModel.compare(
            pair("a\nb\n", "x\ny\nz\n")
        )
        XCTAssertEqual(model.removedCount, 2)
        XCTAssertEqual(model.addedCount, 3)
        XCTAssertEqual(
            model.rows.filter { $0.kind != .equal }.count,
            5
        )
    }

    func testShiftedMatchingLinesKeepTheirEquality() {
        let model = CodeDiffModel.compare(
            pair("a\nb\nc\n", "b\nc\nd\n")
        )
        XCTAssertEqual(model.removedCount, 1)
        XCTAssertEqual(model.addedCount, 1)
        XCTAssertEqual(
            model.rows.filter { $0.kind == .equal }.count,
            2
        )
    }

    func testATrailingLoneCRIsContent() {
        let lines = CodeDiffModel.lines(in: Data("a\r".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].content, Data("a\r".utf8))
        XCTAssertEqual(lines[0].terminator, .none)

        let model = CodeDiffModel.compare(
            pair("a\r", "a")
        )
        XCTAssertEqual(model.removedCount, 1)
        XCTAssertEqual(model.addedCount, 1)
    }

    func testUnifiedTextCarriesNoNewlineMarker() {
        let model = CodeDiffModel.compare(
            pair("a\n", "a")
        )
        XCTAssertTrue(
            model.unifiedText.contains(
                "\\ No newline at end of file"
            )
        )
    }

    func testUnifiedTextPreservesCRLFTerminators() {
        let model = CodeDiffModel.compare(
            pair("a\r\nb\r\n", "a\r\nB\r\n")
        )
        let text = model.unifiedText
        XCTAssertTrue(text.contains("-b\r\n"))
        XCTAssertTrue(text.contains("+B\r\n"))
    }

    func testHunkContextIsThreeLines() {
        var left = (0..<20).map { "line\($0)" }
        left[10] = "changed"
        let right = (0..<20).map { "line\($0)" }
        let model = CodeDiffModel.compare(
            pair(
                left.joined(separator: "\n") + "\n",
                right.joined(separator: "\n") + "\n"
            )
        )
        XCTAssertEqual(model.hunks.count, 1)
        XCTAssertEqual(model.hunks[0].rows.count, 8)
        XCTAssertEqual(model.hunks[0].leftStart, 8)
        XCTAssertEqual(model.hunks[0].rightStart, 8)
    }
}
