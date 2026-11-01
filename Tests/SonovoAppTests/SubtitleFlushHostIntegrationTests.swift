import SonovoWorkspaceHost
@testable import SonovoSubtitleFeature
import AppKit
import XCTest
@testable import Sonovo
import SonovoMarkdownEngine
import SonovoSubtitleEngine

@MainActor
final class SubtitleFlushHostIntegrationTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-subtitles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
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

    func testFlushAllBeforeCloseSavesBothWorkspaces() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subtitleURL = directory.appendingPathComponent("demo.srt")
        let markdownURL = directory.appendingPathComponent("demo.md")
        try Data(srt.utf8).write(to: subtitleURL)
        try Data("one\n".utf8).write(to: markdownURL)

        let state = AppState()
        let subtitle = try XCTUnwrap(state.subtitles.open(url: subtitleURL))
        let markdown = try XCTUnwrap(state.markdown.open(url: markdownURL))
        try subtitle.replaceSource(
            srt.replacingOccurrences(of: "Hello", with: "Hi"),
            actionName: "Edit"
        )
        try markdown.replaceSource("two\n")

        let allowed = await state.flushAllBeforeClose()
        XCTAssertTrue(allowed)
        XCTAssertFalse(subtitle.isDirty)
        XCTAssertFalse(markdown.isDirty)
        XCTAssertTrue(
            try String(contentsOf: subtitleURL, encoding: .utf8).contains("Hi")
        )
        XCTAssertEqual(
            try String(contentsOf: markdownURL, encoding: .utf8),
            "two\n"
        )
    }
}
