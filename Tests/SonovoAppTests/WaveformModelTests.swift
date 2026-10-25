import AVFoundation
import Foundation
import XCTest
@testable import Sonovo

@MainActor
final class WaveformModelTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        files = []
        super.tearDown()
    }

    func testExtractsPeaksAndSumsFromATone() async throws {
        let url = try makeTone(amplitude: 0.5, duration: 1)
        let data = try await WaveformExtractor.extract(url: url)

        XCTAssertFalse(data.peaks.isEmpty)
        XCTAssertEqual(data.sampleRate, 44_100)
        XCTAssertEqual(data.channelCount, 1)
        XCTAssertEqual(data.bucketsPerSecond, 200)
        let peak = try XCTUnwrap(data.peaks.max())
        XCTAssertGreaterThan(peak, 0.45)
        XCTAssertLessThanOrEqual(peak, 0.51)

        let middle = data.peaks.count / 2
        let rms = try XCTUnwrap(data.rms(at: middle))
        XCTAssertEqual(rms, 0.3536, accuracy: 0.02)
        XCTAssertEqual(data.bucketFrames, 221)
    }

    func testCacheReusesTheSameRevision() async throws {
        let url = try makeTone(amplitude: 0.5, duration: 0.2)
        let revision = AssetRevision(
            fileIdentifier: "fixture",
            size: 1,
            modified: Date(timeIntervalSince1970: 1)
        )
        let cache = WaveformCache(byteBudget: 10_000_000)
        let model = WaveformModel(cache: cache)
        model.load(url: url, revision: revision)
        let ready = await waitUntil { model.state == .ready }
        XCTAssertTrue(ready)
        XCTAssertTrue(cache.contains(url: url, revision: revision))
        let first = model.data

        model.load(url: url, revision: revision)
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.data, first)
    }

    func testVideoWithoutAudioReportsNoAudio() async throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "cfr",
                withExtension: "mov",
                subdirectory: "Fixtures"
            )
        )
        let model = WaveformModel()
        model.load(url: url, revision: .empty)
        let settled = await waitUntil { model.state == .noAudio }
        XCTAssertTrue(settled, "state was \(model.state)")
        XCTAssertNil(model.data)
    }

    func testCacheEvictsUnderItsBudget() {
        // One entry costs 160 bytes: 10 peaks + 10 sum-of-squares as Float
        // (80) plus 10 bucket counts as Int (80). A 200-byte budget holds
        // exactly one, so the second store must evict the first.
        let cache = WaveformCache(byteBudget: 200)
        let firstURL = URL(fileURLWithPath: "/tmp/sonovo-waveform-a")
        let secondURL = URL(fileURLWithPath: "/tmp/sonovo-waveform-b")
        let data = WaveformData(
            peaks: Array(repeating: 0, count: 10),
            sumSquares: Array(repeating: 0, count: 10),
            bucketFrameCounts: Array(repeating: 1, count: 10),
            bucketFrames: 1,
            totalFrames: 10,
            sampleRate: 44_100,
            channelCount: 1,
            bucketsPerSecond: 200,
            duration: 0.05
        )
        let revision = AssetRevision.empty
        cache.store(data, for: firstURL, revision: revision)
        cache.store(data, for: secondURL, revision: revision)

        XCTAssertFalse(cache.contains(url: firstURL, revision: revision))
        XCTAssertTrue(cache.contains(url: secondURL, revision: revision))
        XCTAssertLessThanOrEqual(cache.cachedByteCount, 200)
    }

    func testViewWidthIsNotPartOfTheAnalysis() async throws {
        let url = try makeTone(amplitude: 0.4, duration: 0.05)
        let data = try await WaveformExtractor.extract(url: url)
        XCTAssertEqual(data.peaks.count, data.bucketFrameCounts.count)
        XCTAssertGreaterThan(data.peaks.count, 0)
        XCTAssertEqual(
            data.bucketFrameCounts.reduce(0, +),
            data.totalFrames
        )
    }

    // MARK: - Helpers

    private func makeTone(
        amplitude: Float,
        duration: Double
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoWaveform-\(UUID().uuidString).wav"
            )
        files.append(url)
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            throw WaveformTestError.format
        }
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ), let channel = buffer.floatChannelData?[0] else {
            throw WaveformTestError.buffer
        }
        buffer.frameLength = frameCount
        for index in 0..<Int(frameCount) {
            channel[index] = amplitude * sin(
                2 * .pi * 440 * Float(index) / Float(sampleRate)
            )
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
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

private enum WaveformTestError: Error {
    case format
    case buffer
}
