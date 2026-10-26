import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MarkdownDisplayModeTests: XCTestCase {
    private func sourceRange(_ offsets: Range<Int>) -> SourceRange {
        SourceRange(
            start: SourcePosition(
                line: 1,
                column: offsets.lowerBound,
                offset: offsets.lowerBound
            ),
            end: SourcePosition(
                line: 1,
                column: offsets.upperBound,
                offset: offsets.upperBound
            )
        )
    }

    private func blocks() -> [Block] {
        [
            .paragraph(
                inlines: [.text("a", range: nil)],
                range: sourceRange(0..<10)
            ),
            .heading(
                level: 2,
                inlines: [.text("h", range: nil)],
                range: sourceRange(11..<20)
            ),
            .paragraph(
                inlines: [.text("b", range: nil)],
                range: sourceRange(21..<30)
            ),
        ]
    }

    private func makeController(
        _ source: String
    ) throws -> (
        workspace: MarkdownWorkspace,
        document: MarkdownDocument,
        controller: MarkdownEditorController,
        directory: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-display-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("display.md")
        try Data(source.utf8).write(to: url)
        let workspace = MarkdownWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        return (
            workspace,
            document,
            workspace.controller(for: document),
            directory
        )
    }

    func testFocusDimsOnlyOutsideTheCaretBlock() {
        let dim = NSColor(AppTheme.MarkdownChrome.Focus.dim)
        let insideMiddle = MarkdownFocus.decorations(
            sourceLength: 30,
            caret: 15,
            blocks: blocks(),
            dim: dim
        )
        XCTAssertEqual(
            insideMiddle.map(\.range),
            [NSRange(location: 0, length: 11),
             NSRange(location: 20, length: 10)]
        )
        XCTAssertTrue(insideMiddle.allSatisfy {
            $0.layer == .focus && $0.attributes[.foregroundColor] as? NSColor
                == dim
        })

        let first = MarkdownFocus.decorations(
            sourceLength: 30,
            caret: 5,
            blocks: blocks(),
            dim: dim
        )
        XCTAssertEqual(first.map(\.range), [NSRange(location: 10, length: 20)])

        let last = MarkdownFocus.decorations(
            sourceLength: 30,
            caret: 25,
            blocks: blocks(),
            dim: dim
        )
        XCTAssertEqual(last.map(\.range), [NSRange(location: 0, length: 21)])

        XCTAssertTrue(
            MarkdownFocus.decorations(
                sourceLength: 30,
                caret: 35,
                blocks: blocks(),
                dim: dim
            ).isEmpty
        )
    }

    func testFocusUsesTheBlockEndAsItsOwn() {
        let dim = NSColor(AppTheme.MarkdownChrome.Focus.dim)
        let decorations = MarkdownFocus.decorations(
            sourceLength: 30,
            caret: 10,
            blocks: blocks(),
            dim: dim
        )
        XCTAssertEqual(
            decorations.map(\.range),
            [NSRange(location: 10, length: 20)]
        )
    }

    func testTypewriterTargetAndJitter() {
        XCTAssertEqual(
            MarkdownTypewriter.scrollTarget(
                viewportMinY: 100,
                viewportHeight: 500,
                caretLineTop: 150
            ),
            -50
        )
        XCTAssertNil(
            MarkdownTypewriter.scrollTarget(
                viewportMinY: 100,
                viewportHeight: 500,
                caretLineTop: 300
            )
        )
        XCTAssertNil(
            MarkdownTypewriter.scrollTarget(
                viewportMinY: 100,
                viewportHeight: 500,
                caretLineTop: 307
            )
        )
        XCTAssertNil(
            MarkdownTypewriter.scrollTarget(
                viewportMinY: 0,
                viewportHeight: 0,
                caretLineTop: 300
            )
        )
    }

    func testLineNumbersCountNewlines() throws {
        let (_, _, controller, directory) = try makeController(
            "one\ntwo\nthree\n"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(controller.lineNumber(at: 0), 1)
        XCTAssertEqual(controller.lineNumber(at: 3), 1)
        XCTAssertEqual(controller.lineNumber(at: 4), 2)
        XCTAssertEqual(controller.lineNumber(at: 8), 3)
        // The trailing newline starts an empty fourth line, as in any editor.
        XCTAssertEqual(controller.lineNumber(at: 100), 4)
    }

    func testWrappedVisualLinesShareTheSourceLineNumber() throws {
        let long = String(repeating: "word ", count: 80)
        let (_, _, controller, directory) = try makeController(
            long + "\nsecond\n"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        controller.scrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: 320,
            height: 400
        )
        controller.textView.frame = controller.scrollView.contentView.bounds
        controller.textView.textContainer?.widthTracksTextView = false
        controller.textView.textContainer?.containerSize = NSSize(
            width: 240,
            height: CGFloat.greatestFiniteMagnitude
        )
        controller.textView.layoutSubtreeIfNeeded()
        let lines = controller.textView.visibleCodeLines()
        guard lines.count >= 2 else {
            XCTFail("the long line did not wrap into visual lines")
            return
        }
        XCTAssertEqual(
            controller.lineNumber(at: lines[0].documentOffset),
            1
        )
        XCTAssertEqual(
            controller.lineNumber(at: lines[1].documentOffset),
            1
        )
        XCTAssertGreaterThan(
            lines[1].rect.minY,
            lines[0].rect.minY
        )
    }

    func testRulerThicknessFollowsLineNumbers() {
        let ruler = ReviewMarkerRulerView()
        XCTAssertEqual(
            ruler.ruleThickness,
            AppTheme.MarkdownChrome.Comments.gutterWidth
        )
        ruler.showsLineNumbers = true
        XCTAssertEqual(
            ruler.ruleThickness,
            AppTheme.Code.lineNumberWidth
                + AppTheme.MarkdownChrome.Comments.gutterWidth
        )
        ruler.showsLineNumbers = false
        XCTAssertEqual(
            ruler.ruleThickness,
            AppTheme.MarkdownChrome.Comments.gutterWidth
        )
    }
}
