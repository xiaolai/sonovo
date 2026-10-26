import AppKit
import SwiftUI
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MarkdownBlockProjectionTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-block-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

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

    private func makeWorkspace(
        _ source: String
    ) throws -> (URL, MarkdownWorkspace, MarkdownDocument) {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("doc.md")
        try Data(source.utf8).write(to: url)
        let workspace = MarkdownWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        return (url, workspace, document)
    }

    func testCommitReplacesOnlyTheBlockAndRestoresTheSelection() throws {
        let source = "First line.\n\nSecond *paragraph* 😀.\n\nThird.\n"
        let (url, workspace, document) = try makeWorkspace(source)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ns = source as NSString
        let target = ns.range(of: "Second *paragraph* 😀.")
        let range = sourceRange(target.location..<(target.location + target.length))
        let expected = ns.substring(with: target)
        let replacement = "Second *changed* paragraph 🚀.\nWith a second line."

        let committed = workspace.commitBlockEdit(
            range: range,
            expectedSlice: expected,
            replacement: replacement,
            in: document
        )
        XCTAssertTrue(committed)
        XCTAssertEqual(
            document.source,
            "First line.\n\nSecond *changed* paragraph 🚀.\n"
                + "With a second line.\n\nThird.\n"
        )
        XCTAssertEqual(
            document.selection,
            target.location..<(target.location + (replacement as NSString).length)
        )
        XCTAssertEqual(
            try Data(contentsOf: url),
            Data(source.utf8),
            "the commit must not save until the document does"
        )

        document.undoManager.undo()
        XCTAssertEqual(document.source, source)
    }

    func testCommitRefusesWhenTheBlockMovedOrChanged() throws {
        let source = "First line.\n\nSecond line.\n\nThird.\n"
        let (url, workspace, document) = try makeWorkspace(source)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ns = source as NSString
        let target = ns.range(of: "Second line.")
        let range = sourceRange(target.location..<(target.location + target.length))

        try document.replaceSource("Inserted before.\n\n" + source)
        let moved = document.source
        let committed = workspace.commitBlockEdit(
            range: range,
            expectedSlice: "Second line.",
            replacement: "Nope.",
            in: document
        )
        XCTAssertFalse(committed)
        XCTAssertEqual(document.source, moved)
        XCTAssertTrue(workspace.lastError?.contains("changed") == true)

        // The same range with a slice the document no longer holds refuses.
        let changed = "First line.\n\nSecond LINE.\n\nThird.\n"
        try document.replaceSource(changed)
        XCTAssertFalse(
            workspace.commitBlockEdit(
                range: range,
                expectedSlice: "Second line.",
                replacement: "Nope.",
                in: document
            )
        )
        XCTAssertEqual(document.source, changed)
    }

    func testCommitSurvivesAModeSwitch() throws {
        let source = "First.\n\nSecond.\n"
        let (url, workspace, document) = try makeWorkspace(source)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ns = source as NSString
        let target = ns.range(of: "Second.")
        let range = sourceRange(target.location..<(target.location + target.length))

        document.mode = .rendered
        workspace.setMode(.source, for: document)
        workspace.setMode(.rendered, for: document)
        XCTAssertEqual(document.mode, .rendered)
        let committed = workspace.commitBlockEdit(
            range: range,
            expectedSlice: "Second.",
            replacement: "SECOND.",
            in: document
        )
        XCTAssertTrue(committed)
        XCTAssertEqual(document.source, "First.\n\nSECOND.\n")
        XCTAssertEqual(document.mode, .rendered)
    }

    func testEditorModelRefusesWhileComposingAndOnStaleCommit() {
        var committedText: String?
        let model = BlockProjectionEditorModel(text: "draft") { text in
            committedText = text
            return true
        }
        model.hasMarkedText = true
        XCTAssertFalse(model.save())
        XCTAssertNil(committedText)
        XCTAssertTrue(model.error?.contains("composing") == true)

        model.hasMarkedText = false
        XCTAssertTrue(model.save())
        XCTAssertEqual(committedText, "draft")
        XCTAssertNil(model.error)

        let refusing = BlockProjectionEditorModel(text: "x") { _ in false }
        XCTAssertFalse(refusing.save())
        XCTAssertTrue(refusing.error?.contains("changed") == true)
    }

    func testProjectionEditorLaysOut() {
        let view = BlockProjectionEditor(
            title: "Edit Block",
            model: BlockProjectionEditorModel(text: "A paragraph.") { _ in true },
            onCancel: {}
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 200)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
    }
}
