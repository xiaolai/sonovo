import AppKit
import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class SubtitleWorkspaceTests: XCTestCase {
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

    func testSourceControllerAccessorDoesNotPublishOnRepeat() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srt.utf8).write(to: url)

        let workspace = SubtitleWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        _ = workspace.sourceController(for: document)

        let invalidated = SubtitleObservationFlag()
        withObservationTracking {
            _ = workspace.sourceController(for: document)
        } onChange: {
            invalidated.raise()
        }
        XCTAssertFalse(
            invalidated.isRaised,
            "a source-editor cache hit invalidated the view body"
        )
    }

    func testOpenDeduplicatesCanonicalPaths() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srt.utf8).write(to: url)
        let link = directory.appendingPathComponent("alias.srt")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: url
        )

        let workspace = SubtitleWorkspace()
        let first = try XCTUnwrap(workspace.open(url: url))
        let second = try XCTUnwrap(workspace.open(url: link))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(workspace.documents.count, 1)
        XCTAssertEqual(workspace.selectedDocument?.id, first.id)
    }

    func testSaveAndClose() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srt.utf8).write(to: url)

        let workspace = SubtitleWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        try document.replaceSource(
            srt.replacingOccurrences(of: "Hello", with: "Hi"),
            actionName: "Edit"
        )
        await workspace.saveSelected()
        XCTAssertFalse(document.isDirty)
        XCTAssertTrue(
            try String(contentsOf: url, encoding: .utf8).contains("Hi")
        )

        await workspace.close(document)
        XCTAssertTrue(workspace.documents.isEmpty)
        XCTAssertNil(workspace.selectedDocument)
    }

    func testFlushAllForTermination() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srt.utf8).write(to: url)

        let workspace = SubtitleWorkspace()
        _ = workspace.open(url: url)
        try workspace.selectedDocument?.replaceSource(
            srt.replacingOccurrences(of: "World", with: "Bye"),
            actionName: "Edit"
        )

        let canTerminate = await workspace.flushAllForTermination()
        XCTAssertTrue(canTerminate)
        XCTAssertTrue(
            try String(contentsOf: url, encoding: .utf8).contains("Bye")
        )
    }

    func testExternalEditReloadsThroughWatcher() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srt.utf8).write(to: url)

        let workspace = SubtitleWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        let external = srt.replacingOccurrences(of: "World", with: "External")
        try Data(external.utf8).write(to: url)

        let adopted = await waitUntil {
            document.source == external
        }
        XCTAssertTrue(adopted)
        XCTAssertFalse(document.isDirty)
        XCTAssertNotNil(workspace.reloadNotice)

        // A cue edit after the external write targets the external ranges.
        let result = try await document.apply(
            .setText(ordinal: 1, text: "Local")
        )
        XCTAssertTrue(result.source.contains("Local"))
        XCTAssertTrue(result.source.contains("Hello"))
        await workspace.saveSelected()
        XCTAssertTrue(
            try String(contentsOf: url, encoding: .utf8).contains("Local")
        )
    }

    func testMediaAttachmentIsPerDocument() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srt.utf8).write(to: url)
        let media = directory.appendingPathComponent("preview.m4a")
        try Data().write(to: media)

        let workspace = SubtitleWorkspace()
        let document = try XCTUnwrap(workspace.open(url: url))
        workspace.attachMedia(media, to: document)
        XCTAssertEqual(
            workspace.mediaURL(for: document),
            media.standardizedFileURL
        )
        _ = await waitUntil { workspace.player.url != nil }
        XCTAssertEqual(workspace.player.url, media.standardizedFileURL)

        workspace.detachMedia(for: document)
        XCTAssertNil(workspace.mediaURL(for: document))
        XCTAssertNil(workspace.player.url)
    }

    func testPreviewIsCollapsedByDefaultAndToggles() {
        let key = "sonovo.subtitlePreviewMode"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let workspace = SubtitleWorkspace()
        XCTAssertEqual(workspace.previewMode, .collapsed)
        workspace.togglePreviewMode()
        XCTAssertEqual(workspace.previewMode, .expanded)
        workspace.togglePreviewMode()
        XCTAssertEqual(workspace.previewMode, .collapsed)

        UserDefaults.standard.set("stage", forKey: key)
        XCTAssertEqual(SubtitleWorkspace().previewMode, .expanded)
        UserDefaults.standard.set("mini", forKey: key)
        XCTAssertEqual(SubtitleWorkspace().previewMode, .collapsed)
    }

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

    func testInvalidMediaFailsWithoutCrashing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing.mov")

        let player = SubtitleMediaPlayer()
        await player.open(url: missing)
        XCTAssertFalse(player.isReady)
        XCTAssertNotNil(player.errorMessage)
        XCTAssertNil(player.player.currentItem)

        player.close()
        XCTAssertNil(player.url)
        XCTAssertNil(player.errorMessage)
    }
}

/// A one-way flag for `withObservationTracking` callbacks, which are
/// `@Sendable`; the write happens synchronously on the main thread.
private final class SubtitleObservationFlag: @unchecked Sendable {
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
