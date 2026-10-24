import AVFoundation
import CoreMedia
import XCTest
@testable import Sonovo

private enum ReaderTestError: Error {
    case forced
}

final class MediaReaderTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: "mov",
                subdirectory: "Fixtures"
            )
        )
    }

    private func videoTrack(in url: URL) async throws -> AVAssetTrack {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        return try XCTUnwrap(tracks.first)
    }

    private func timecodeTrack(in url: URL) async throws -> AVAssetTrack {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .timecode)
        return try XCTUnwrap(tracks.first)
    }

    func testFrameTimingVerifiesConstantRateVideo() async throws {
        let url = try fixture("cfr")
        let track = try await videoTrack(in: url)
        let rate = Double(try await track.load(.nominalFrameRate))
        let minFrameDuration = try? await track.load(.minFrameDuration)

        let result = await MediaPlaybackModel.frameTiming(
            url: url,
            trackID: track.trackID,
            nominalRate: rate,
            minFrameDuration: minFrameDuration
        )

        XCTAssertEqual(rate, 30, accuracy: 0.01)
        XCTAssertFalse(result.variable)
        XCTAssertTrue(result.verified)
    }

    func testFrameTimingRejectsVariableRateVideo() async throws {
        let url = try fixture("vfr")
        let track = try await videoTrack(in: url)

        // nil forces the timestamp loop to decide; the production path also
        // reaches it when the track does not declare a minimum duration.
        let result = await MediaPlaybackModel.frameTiming(
            url: url,
            trackID: track.trackID,
            nominalRate: 30,
            minFrameDuration: nil
        )

        XCTAssertTrue(result.variable)
        XCTAssertFalse(result.verified)
    }

    func testScanTimecodeReadsTimecodeTrackThroughProvider() async throws {
        let url = try fixture("timecode")
        let track = try await timecodeTrack(in: url)

        let segments = await MediaPlaybackModel.scanTimecode(
            url: url,
            trackID: track.trackID
        )

        XCTAssertEqual(segments.count, 1)
        let segment = try XCTUnwrap(segments.first)
        XCTAssertEqual(segment.time, 0, accuracy: 0.001)
        XCTAssertEqual(segment.startFrame, 0)
        XCTAssertEqual(segment.frameRate ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(segment.frameQuanta, 30)
        XCTAssertFalse(segment.isDropFrame)
        XCTAssertGreaterThan(segment.duration ?? 0, 0.3)
    }

    func testScanTimecodeStopsWhenSampleReadFails() async throws {
        let url = try fixture("timecode")
        let track = try await timecodeTrack(in: url)

        let segments = await MediaPlaybackModel.scanTimecode(
            url: url,
            trackID: track.trackID,
            nextSample: { throw ReaderTestError.forced }
        )

        XCTAssertTrue(segments.isEmpty)
    }

    func testFrameTimingStopsWhenSampleReadFails() async throws {
        let url = try fixture("cfr")
        let track = try await videoTrack(in: url)

        let result = await MediaPlaybackModel.frameTiming(
            url: url,
            trackID: track.trackID,
            nominalRate: 30,
            minFrameDuration: nil,
            nextSample: { throw ReaderTestError.forced }
        )

        XCTAssertTrue(result.variable)
        XCTAssertFalse(result.verified)
    }

    func testFrameTimingMissingTrackReturnsUnverified() async throws {
        let url = try fixture("cfr")

        let result = await MediaPlaybackModel.frameTiming(
            url: url,
            trackID: 999_999,
            nominalRate: 30,
            minFrameDuration: nil
        )

        XCTAssertTrue(result.variable)
        XCTAssertFalse(result.verified)
    }

    func testFrameTimingCancellationDiscardsAccumulatedTimestamps() async throws {
        let url = try fixture("long")
        let track = try await videoTrack(in: url)
        let trackID = track.trackID

        // Cancelling from inside the per-sample seam lands after the first
        // real sample is appended, so the loop must discard what it read.
        let task = Task {
            await MediaPlaybackModel.frameTiming(
                url: url,
                trackID: trackID,
                nominalRate: 30,
                minFrameDuration: nil,
                onSample: { withUnsafeCurrentTask { $0?.cancel() } }
            )
        }
        let result = await task.value

        XCTAssertTrue(result.variable)
        XCTAssertFalse(result.verified)
    }

    func testScanTimecodeCancellationDiscardsAccumulatedSegments() async throws {
        let url = try fixture("timecode")
        let track = try await timecodeTrack(in: url)
        let trackID = track.trackID

        // The fixture's single segment is accumulated first; cancelling from
        // the seam must still return no partial timecode.
        let task = Task {
            await MediaPlaybackModel.scanTimecode(
                url: url,
                trackID: trackID,
                onSample: { withUnsafeCurrentTask { $0?.cancel() } }
            )
        }

        let segments = await task.value
        XCTAssertTrue(segments.isEmpty)
    }

    @MainActor
    func testRapidVideoReplacementPublishesOnlyTheNewestTiming() async throws {
        let cfr = try fixture("cfr")
        let vfr = try fixture("vfr")
        let model = MediaPlaybackModel()

        model.load(url: cfr)
        model.load(url: vfr)
        let ready = await waitUntil {
            model.state == .ready && model.url == vfr
        }

        XCTAssertTrue(ready, "state was \(model.state)")
        XCTAssertTrue(model.isVariableFrameRate)
        XCTAssertFalse(model.isFrameRateVerified)
        model.unload()
    }

    @MainActor
    func testModelPublishesFrameTimingForVideo() async throws {
        let model = MediaPlaybackModel()

        model.load(url: try fixture("cfr"))
        let cfrReady = await waitUntil { model.state == .ready }
        XCTAssertTrue(cfrReady, "state was \(model.state)")
        XCTAssertTrue(model.isFrameRateVerified)
        XCTAssertFalse(model.isVariableFrameRate)
        model.unload()

        let vfr = try fixture("vfr")
        model.load(url: vfr)
        let vfrReady = await waitUntil {
            model.state == .ready && model.url == vfr
        }
        XCTAssertTrue(vfrReady, "state was \(model.state)")
        XCTAssertFalse(model.isFrameRateVerified)
        XCTAssertTrue(model.isVariableFrameRate)
        model.unload()
    }

    @MainActor
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
