import AVFoundation
import Foundation
import XCTest
@testable import Sonovo

@MainActor
final class MediaPlaybackModelTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        files = []
        super.tearDown()
    }

    func testAudioLoadsSeeksAndReportsMetadata() async throws {
        let url = try makeTone(duration: 1)
        let model = MediaPlaybackModel()
        model.load(url: url)
        let ready = await waitUntil { model.state == .ready }
        XCTAssertTrue(ready, "state was \(model.state)")

        XCTAssertEqual(model.duration, 1, accuracy: 0.05)
        XCTAssertTrue(model.hasAudio)
        XCTAssertFalse(model.hasVideo)
        XCTAssertGreaterThan(model.fileSize, 0)

        await model.seek(to: 0.5)
        XCTAssertEqual(model.elapsed, 0.5, accuracy: 0.05)

        model.play()
        let started = await waitUntil { model.isPlaying }
        XCTAssertTrue(started, "the transport must reflect playback")
        model.pause()
        let stopped = await waitUntil { !model.isPlaying }
        XCTAssertTrue(stopped)
    }

    func testUnsupportedFileIsNotReportedAsReady() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SonovoBad-\(UUID().uuidString).mp4")
        files.append(url)
        try Data("this is not a media file".utf8).write(to: url)

        let model = MediaPlaybackModel()
        model.load(url: url)
        let settled = await waitUntil {
            switch model.state {
            case .unsupported, .failed: true
            default: false
            }
        }
        XCTAssertTrue(settled, "state was \(model.state)")
    }

    func testRapidSourceChangesUseTheLastFile() async throws {
        let first = try makeTone(duration: 0.2)
        let second = try makeTone(duration: 0.6)
        let model = MediaPlaybackModel()
        model.load(url: first)
        model.load(url: second)
        let ready = await waitUntil { model.state == .ready }
        XCTAssertTrue(ready, "state was \(model.state)")
        XCTAssertEqual(model.url, second)
        XCTAssertEqual(model.duration, 0.6, accuracy: 0.05)
        model.pause()
    }

    func testOverlappingSeeksKeepTheNewestCompletion() async throws {
        let url = try makeTone(duration: 2)
        let model = MediaPlaybackModel()
        model.load(url: url)
        let ready = await waitUntil { model.state == .ready }
        XCTAssertTrue(ready, "state was \(model.state)")

        // Start the first seek and let it issue its player request, then
        // issue the newer one. The order is explicit because actor task
        // scheduling does not guarantee that `async let` bodies start in
        // source order.
        let first = Task { @MainActor in
            await model.seek(to: 0.25)
        }
        await Task.yield()
        let second = Task { @MainActor in
            await model.seek(to: 1.5)
        }
        await second.value
        await first.value
        XCTAssertEqual(model.elapsed, 1.5, accuracy: 0.1)
        model.pause()
    }

    // MARK: - Helpers

    private func makeTone(duration: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoPlayback-\(UUID().uuidString).wav"
            )
        files.append(url)
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            throw PlaybackTestError.format
        }
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ), let channel = buffer.floatChannelData?[0] else {
            throw PlaybackTestError.buffer
        }
        buffer.frameLength = frameCount
        for index in 0..<Int(frameCount) {
            channel[index] = 0.4 * sin(
                2 * .pi * 440 * Float(index) / Float(sampleRate)
            )
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testAuditionLoopsTheSelectionAndStopsOnPause() async throws {
        let url = try makeTone(duration: 1)
        let model = MediaPlaybackModel()
        model.load(url: url)
        let ready = await waitUntil { model.state == .ready }
        XCTAssertTrue(ready, "state was \(model.state)")

        model.startAudition(range: 0.2 ... 0.4)
        XCTAssertEqual(model.auditionRange, 0.2 ... 0.4)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNotNil(model.auditionRange)
        XCTAssertLessThan(
            model.elapsed,
            0.5,
            "the boundary observer must have looped before the item ended"
        )

        model.pause()
        XCTAssertNil(model.auditionRange)
        XCTAssertFalse(model.isAuditioning)
    }

    func testAuditionSelectionEndingAtItemEndLoops() async throws {
        let url = try makeTone(duration: 1)
        let model = MediaPlaybackModel()
        model.load(url: url)
        let ready = await waitUntil { model.state == .ready }
        XCTAssertTrue(ready, "state was \(model.state)")

        model.startAudition(range: 0.6 ... 1.0)
        XCTAssertNotNil(model.auditionRange)
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertNotNil(model.auditionRange)
        XCTAssertLessThan(
            model.elapsed,
            0.95,
            "a selection ending at the item end must loop, not stall"
        )
        model.pause()
    }

    func testStoppingAnInactiveAuditionDoesNotPausePlayback() async throws {
        let url = try makeTone(duration: 2)
        let model = MediaPlaybackModel()
        model.load(url: url)
        let ready = await waitUntil { model.state == .ready }
        XCTAssertTrue(ready, "state was \(model.state)")

        await model.seek(to: 0.2)
        model.play()
        let started = await waitUntil { model.isPlaying }
        XCTAssertTrue(started, "the transport must reflect playback")

        model.stopAudition()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(
            model.isPlaying,
            "stopping a non-audition must not stop ordinary playback"
        )
        model.pause()
    }

    func testAuditionRejectsAWorkspaceThatCannotLoop() async throws {
        let url = try makeTone(duration: 1)
        let model = MediaPlaybackModel()
        model.load(url: url)
        let ready = await waitUntil { model.state == .ready }
        XCTAssertTrue(ready, "state was \(model.state)")

        model.startAudition(range: 0.2 ... 0.2)
        XCTAssertNil(model.auditionRange)
        model.stopAudition()
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private enum PlaybackTestError: Error {
    case format
    case buffer
}
