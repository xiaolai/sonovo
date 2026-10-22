import Foundation
import XCTest
@testable import Sonovo

@MainActor
final class CodeEditorControllerTests: XCTestCase {
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

    /// Save As can change the language without changing the text or the
    /// revision. The controller must still relex, or Python keeps Swift
    /// colors until the next keystroke.
    func testSaveAsToANewLanguageRelexesWithoutAnEdit() async throws {
        let root = try support.makeRoot(files: [
            "notes.txt": CodeTestData.utf8(
                "def run():\n    pass\n# comment\n"
            )
        ])
        let url = root.appendingPathComponent("notes.txt")
        let document = CodeDocument(url: url)
        await document.load()
        let controller = CodeEditorController(
            document: document,
            settings: CodeEditorSettings()
        )
        controller.attach()
        try await waitUntil("the first lex") {
            controller.highlightLanguage == document.language
        }
        XCTAssertNil(
            controller.symbolName,
            "plain text has no outline"
        )

        let destination = root.appendingPathComponent("notes.py")
        _ = try await document.saveAs(to: destination)
        XCTAssertEqual(document.language, .python)
        try await waitUntil("the language-change relex") {
            controller.highlightLanguage == .python
        }
        try await waitUntil("the language-change symbol scan") {
            controller.symbolName == "run"
        }

        let snapshot = try XCTUnwrap(controller.highlightSnapshot)
        let comment = snapshot.tokens(
            intersecting: snapshot.range(ofLine: 3)!
        )
        XCTAssertTrue(
            comment.contains { $0.kind == .comment },
            "Python's # comment is tokenized after the language change"
        )

        // A second Save As back to plain text clears the outline; the cache
        // must not keep serving Python symbols.
        let plain = root.appendingPathComponent("notes.log")
        _ = try await document.saveAs(to: plain)
        XCTAssertEqual(document.language, .plainText)
        try await waitUntil("the plain-text outline clear") {
            controller.symbolName == nil
        }
        try await waitUntil("the plain-text relex") {
            controller.highlightLanguage == .plainText
        }
    }

    func testSyncFromDocumentAdoptsADifferentNormalization() async throws {
        let composed = "caf\u{E9}\n"
        let decomposed = "cafe\u{301}\n"
        XCTAssertEqual(composed, decomposed, "Swift treats these as equal")
        let root = try support.makeRoot(files: [
            "notes.swift": CodeTestData.utf8(composed)
        ])
        let document = CodeDocument(
            url: root.appendingPathComponent("notes.swift")
        )
        await document.load()
        let controller = CodeEditorController(
            document: document,
            settings: CodeEditorSettings()
        )
        controller.attach()
        try await waitUntil("the first lex") {
            controller.highlightSnapshot != nil
        }

        // Byte-different but canonically equal text must still reach the
        // text view, or the document and the editor disagree on the bytes
        // that will be saved.
        try document.replaceSource(decomposed)
        try await waitUntil("the normalization update") {
            controller.textView.string.utf8.elementsEqual(decomposed.utf8)
        }
    }

    func testCursorMovementReusesTheSymbolScan() async throws {
        let root = try support.makeRoot(files: [
            "symbols.swift": CodeTestData.utf8(
                "func first() {}\n\nfunc second() {}\n"
            )
        ])
        let document = CodeDocument(
            url: root.appendingPathComponent("symbols.swift")
        )
        await document.load()
        let controller = CodeEditorController(
            document: document,
            settings: CodeEditorSettings()
        )
        // The initial selection after the source copy sits at the end; put
        // the caret on the first declaration before attaching.
        controller.textView.setSelectedRange(
            NSRange(location: 0, length: 0)
        )
        controller.attach()
        try await waitUntil("the first symbol scan") {
            controller.symbolName == "first"
        }
        let scans = controller.symbolScanCount

        // Move the caret to the second declaration. The scan is still valid
        // for this revision, so the symbol changes without another pass.
        let secondLine = (document.source as NSString)
            .range(of: "func second").location
        controller.textView.setSelectedRange(
            NSRange(location: secondLine, length: 0)
        )
        controller.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification)
        )
        XCTAssertEqual(controller.symbolName, "second")
        XCTAssertEqual(
            controller.symbolScanCount,
            scans,
            "a cache hit must not run another scan"
        )

        // An edit invalidates the cache; the next scan is a new pass.
        try document.replaceSource(
            "func first() {}\n\nfunc third() {}\n"
        )
        controller.syncFromDocument()
        try await waitUntil("the post-edit symbol scan") {
            controller.symbolName == "third"
        }
        XCTAssertGreaterThan(controller.symbolScanCount, scans)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail(
                    "timed out waiting for \(description)",
                    file: file,
                    line: line
                )
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
