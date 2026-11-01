import SonovoWorkspaceHost
@testable import SonovoSubtitleFeature
import SonovoDesignSystem
import AppKit
import XCTest
@testable import Sonovo
import SonovoMarkdownEngine
import SonovoSubtitleEngine

@MainActor
final class SubtitleTabHostIntegrationTests: XCTestCase {
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
