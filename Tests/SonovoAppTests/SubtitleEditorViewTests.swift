import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class SubtitleEditorViewTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-subtitle-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private let srt = """
    1
    00:00:01,000 --> 00:00:03,000
    Hello

    2
    00:00:04,000 --> 00:00:06,000
    World
    """

    func testHighlighterMutesTimingAndKeepsTextStrong() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srt.utf8).write(to: url)
        let document = try SubtitleDocument(loading: url)

        let storage = NSTextStorage(string: srt)
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes(
            [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.monospacedSystemFont(
                    ofSize: AppTheme.Reading.sourceSize,
                    weight: .regular
                )
            ],
            range: full
        )

        SubtitleHighlighter(
            format: .srt,
            parsed: document.parsed,
            affectedRange: full,
            text: srt
        ).apply(to: storage)

        let timing = try XCTUnwrap(document.parsed.cues[0].timingLineRange)
        let timingColor = storage.attribute(
            .foregroundColor,
            at: timing.lowerBound,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(timingColor, NSColor(AppTheme.Palette.secondaryLabel))

        let text = document.parsed.cues[0].textRange
        let textColor = storage.attribute(
            .foregroundColor,
            at: text.lowerBound,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(textColor, NSColor(AppTheme.Palette.label))
    }

    func testSourceControllerMirrorsDocumentAndRecordsUndo() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srt.utf8).write(to: url)
        let document = try SubtitleDocument(loading: url)
        let controller = SubtitleSourceEditorController(document: document)

        XCTAssertEqual(controller.textView.string, document.source)

        controller.textView.string = srt.replacingOccurrences(
            of: "Hello",
            with: "Hi"
        )
        controller.textDidChange(
            Notification(
                name: NSText.didChangeNotification,
                object: controller.textView
            )
        )
        XCTAssertTrue(document.source.contains("Hi"))
        XCTAssertTrue(document.isDirty)

        document.undoManager.undo()
        XCTAssertEqual(document.source, srt)
        let synced = await waitUntil {
            controller.textView.string == document.source
        }
        XCTAssertTrue(synced)
    }

    func testDisplayNameUsesTheOpenSubtitleFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("captions.srt")
        try Data(srt.utf8).write(to: url)

        let state = AppState()
        let document = try XCTUnwrap(state.subtitles.open(url: url))
        state.showSubtitleWorkspace()
        let tab = try XCTUnwrap(state.selectedTab)
        XCTAssertEqual(tab.kind, .subtitle)
        XCTAssertEqual(
            state.displayName(for: tab),
            document.fileURL.lastPathComponent
        )
    }
}
