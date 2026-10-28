import Foundation
import Observation
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

    /// `CodeSourceView.updateNSView` calls `syncFromDocument`, which used to
    /// write the text view's selection back on every update. `setSelectedRange`
    /// posts `NSTextView.didChangeSelectionNotification`, SwiftUI observes it
    /// and re-enters the update, and the document never finishes opening: the
    /// 0.10.0 hang on every code document, JSON included. A sync that changes
    /// nothing must post nothing.
    func testSyncFromDocumentDoesNotPostSelectionChangesWhenNothingChanged() async throws {
        let root = try support.makeRoot(files: [
            "data.json": CodeTestData.utf8("{\n  \"a\": 1\n}\n")
        ])
        let document = CodeDocument(
            url: root.appendingPathComponent("data.json")
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
        XCTAssertFalse(controller.textView.hasMarkedText())

        // Make the sync's selection write observable: restoreSelection used to
        // republish the document selection. It no longer writes document
        // state at all; the delegate publishes real user changes.
        document.selection = nil
        let posts = NotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: controller.textView,
            queue: nil
        ) { _ in
            posts.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        controller.syncFromDocument()
        XCTAssertNil(
            document.selection,
            "the sync path published document selection state"
        )
        XCTAssertEqual(
            posts.count,
            0,
            "sync reposted the selection change inside updateNSView; SwiftUI loops"
        )

        // Canary: a real selection change must still post, or the assertion
        // above cannot fail.
        controller.textView.setSelectedRange(
            NSRange(location: 1, length: 0)
        )
        XCTAssertGreaterThan(
            posts.count,
            0,
            "the selection notification harness is not live"
        )
    }

    /// The controller is `@Observable`, so a write to any stored property can
    /// invalidate a view that touched the object. `syncFromDocument` runs from
    /// `updateNSView`, and while the first lex is pending it schedules one on
    /// every call; writing the task re-entered the update and the document
    /// never finished opening. Scheduling work is implementation state, not
    /// view state, and must not be observable.
    func testSchedulingAHighlightIsNotObservableState() async throws {
        let root = try support.makeRoot(files: [
            "data.json": CodeTestData.utf8("{\n  \"a\": 1\n}\n")
        ])
        let document = CodeDocument(
            url: root.appendingPathComponent("data.json")
        )
        await document.load()
        let controller = CodeEditorController(
            document: document,
            settings: CodeEditorSettings()
        )

        let invalidated = ObservationFlag()
        withObservationTracking {
            _ = controller.highlightTask
        } onChange: {
            invalidated.raise()
        }
        controller.attach()
        XCTAssertFalse(
            invalidated.isRaised,
            "scheduling published internal work state; SwiftUI would re-enter"
        )
    }

    /// `updateNSView` writes document state. Every write it performs must be
    /// either unobservable or deferred past the update; a synchronous write
    /// invalidates the view SwiftUI is currently updating and re-enters the
    /// update. A second sync after a programmatic selection move covers the
    /// restore path.
    func testSyncFromDocumentPublishesNoObservableState() async throws {
        let root = try support.makeRoot(files: [
            "data.json": CodeTestData.utf8("{\n  \"a\": 1\n}\n")
        ])
        let document = CodeDocument(
            url: root.appendingPathComponent("data.json")
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

        func track(_ body: () -> Void) -> Bool {
            let invalidated = ObservationFlag()
            withObservationTracking {
                _ = controller.cursorLine
                _ = controller.cursorColumn
                _ = controller.selectionLength
                _ = controller.symbolName
                _ = controller.symbolScanCount
                _ = controller.highlightSnapshot
                _ = controller.lastCommandError
                body()
            } onChange: {
                invalidated.raise()
            }
            return invalidated.isRaised
        }

        XCTAssertFalse(
            track { controller.syncFromDocument() },
            "a no-op sync published observable state synchronously"
        )

        // A programmatic selection move first publishes through the delegate
        // (a real change), then the sync must publish nothing of its own.
        controller.textView.setSelectedRange(
            NSRange(location: 2, length: 0)
        )
        XCTAssertFalse(
            track { controller.syncFromDocument() },
            "a sync after a selection restore published observable state"
        )

        // The deferred publication still reaches the status bar.
        try await waitUntil("the deferred cursor state") {
            controller.cursorLine == 2 || controller.cursorColumn > 1
        }
    }

    /// Cursor movement within one revision must not schedule a symbol scan per
    /// move. The first move schedules one lookup; the rest ride on it, and the
    /// lookup reads the settled caret when it runs.
    func testOneHundredCursorMovesInOneRevisionScheduleOneScan() async throws {
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
        controller.attach()
        try await waitUntil("the first symbol scan") {
            controller.symbolName != nil
        }
        let scans = controller.symbolScanCount
        let secondLine = (document.source as NSString)
            .range(of: "func second").location

        for index in 0..<100 {
            let location = index.isMultiple(of: 2) ? 0 : secondLine
            controller.textView.setSelectedRange(
                NSRange(location: location, length: 0)
            )
            controller.textViewDidChangeSelection(
                Notification(
                    name: NSTextView.didChangeSelectionNotification
                )
            )
        }
        try await waitUntil("a settled symbol") {
            controller.symbolName != nil
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(
            controller.symbolScanCount,
            scans,
            "one revision ran more than one symbol scan"
        )
    }

    /// A stream of requests faster than the debounce must not cancel every
    /// pass. The old code replaced the task on each call; this one triggers
    /// every millisecond and still expects a completed lex.
    func testRepeatedHighlightRequestsStillCompleteAPass() async throws {
        let root = try support.makeRoot(files: [
            "data.swift": CodeTestData.utf8("let value = 1\n")
        ])
        let document = CodeDocument(
            url: root.appendingPathComponent("data.swift")
        )
        await document.load()
        let controller = CodeEditorController(
            document: document,
            settings: CodeEditorSettings()
        )
        controller.attach()
        try await waitUntil("the first lex") {
            controller.highlightPassCount > 0
        }
        let before = controller.highlightPassCount

        for _ in 0..<500 {
            controller.scheduleHighlight(editedLine: 0)
            try await Task.sleep(for: .milliseconds(1))
        }
        try await waitUntil("a pass under sustained requests") {
            controller.highlightPassCount > before
        }
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

/// A one-way flag for observation callbacks, which are `@Sendable`; the
/// write happens synchronously on the main thread, but the compiler cannot
/// see that.
private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}

/// A counter for notification callbacks, which are `@Sendable`; delivery is
/// synchronous when the observer registers with a nil queue, but the compiler
/// cannot see that.
private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
