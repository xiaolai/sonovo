import XCTest
@testable import Sonovo

final class MediaSilenceDetectorTests: XCTestCase {
    private let settings = MediaSilenceSettings(
        thresholdDBFS: -35,
        minimumPause: 0.30
    )

    func testDetectorKeepsShortSpeechBetweenPauses() {
        var buckets: [(Float?, Int)] = []
        buckets += silence(seconds: 0.4)
        buckets += tone(seconds: 0.1, dBFS: -20)
        buckets += silence(seconds: 0.4)
        let data = makeData(buckets)

        let candidates = MediaSilenceDetector.detect(
            data: data,
            settings: settings,
            sourceDuration: data.duration,
            keepRanges: [MediaTimeRange(start: 0, duration: data.duration)]
        )

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].start, 0.05, accuracy: 0.006)
        XCTAssertEqual(candidates[0].end, 0.35, accuracy: 0.006)
        XCTAssertEqual(candidates[1].start, 0.55, accuracy: 0.006)
        XCTAssertEqual(candidates[1].end, 0.85, accuracy: 0.006)
        for candidate in candidates {
            XCTAssertFalse(candidate.start < 0.5 && candidate.end > 0.4)
        }
    }

    func testGuardPaddingIsAppliedBeforeTheMinimumPauseCheck() {
        let short = makeData(silence(seconds: 0.35))
        XCTAssertTrue(
            MediaSilenceDetector.detect(
                data: short,
                settings: settings,
                sourceDuration: short.duration,
                keepRanges: [MediaTimeRange(start: 0, duration: short.duration)]
            ).isEmpty
        )

        let long = makeData(silence(seconds: 0.42))
        XCTAssertEqual(
            MediaSilenceDetector.detect(
                data: long,
                settings: settings,
                sourceDuration: long.duration,
                keepRanges: [MediaTimeRange(start: 0, duration: long.duration)]
            ).count,
            1
        )
    }

    func testHysteresisKeepsANearThresholdBridgeInOneRun() {
        var buckets: [(Float?, Int)] = []
        buckets += silence(seconds: 0.2)
        buckets += tone(seconds: 0.1, dBFS: -32)
        buckets += silence(seconds: 0.2)
        let bridged = makeData(buckets)
        let bridgedCandidates = MediaSilenceDetector.detect(
            data: bridged,
            settings: settings,
            sourceDuration: bridged.duration,
            keepRanges: [
                MediaTimeRange(start: 0, duration: bridged.duration)
            ]
        )
        XCTAssertEqual(bridgedCandidates.count, 1)
        XCTAssertEqual(bridgedCandidates[0].duration, 0.4, accuracy: 0.01)

        var loudBuckets: [(Float?, Int)] = []
        loudBuckets += silence(seconds: 0.2)
        loudBuckets += tone(seconds: 0.1, dBFS: -20)
        loudBuckets += silence(seconds: 0.2)
        let split = makeData(loudBuckets)
        XCTAssertTrue(
            MediaSilenceDetector.detect(
                data: split,
                settings: settings,
                sourceDuration: split.duration,
                keepRanges: [MediaTimeRange(start: 0, duration: split.duration)]
            ).isEmpty
        )
    }

    func testMissingAudioBucketsAreNeverProposed() {
        var buckets: [(Float?, Int)] = []
        buckets += Array(repeating: (nil, 0), count: 100)
        buckets += silence(seconds: 0.5)
        let data = makeData(buckets)
        let candidates = MediaSilenceDetector.detect(
            data: data,
            settings: settings,
            sourceDuration: data.duration,
            keepRanges: [MediaTimeRange(start: 0, duration: data.duration)]
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertGreaterThanOrEqual(candidates[0].start, 0.55)
        XCTAssertFalse(candidates[0].start < 0.5)
    }

    func testCandidatesAreIntersectedWithKeepRanges() {
        let data = makeData(silence(seconds: 10))
        let candidates = MediaSilenceDetector.detect(
            data: data,
            settings: settings,
            sourceDuration: 10,
            keepRanges: [
                MediaTimeRange(start: 0, duration: 2),
                MediaTimeRange(start: 4, duration: 2)
            ]
        )
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].start, 0.05, accuracy: 0.006)
        XCTAssertEqual(candidates[0].end, 1.95, accuracy: 0.006)
        XCTAssertEqual(candidates[1].start, 4.05, accuracy: 0.006)
        XCTAssertEqual(candidates[1].end, 5.95, accuracy: 0.006)
        XCTAssertFalse(
            candidates.contains { $0.start < 4 && $0.end > 2 }
        )
    }

    func testAllMissingAudioProducesNoCandidates() {
        let data = makeData(Array(repeating: (nil, 0), count: 200))
        XCTAssertTrue(
            MediaSilenceDetector.detect(
                data: data,
                settings: settings,
                sourceDuration: data.duration,
                keepRanges: [MediaTimeRange(start: 0, duration: data.duration)]
            ).isEmpty
        )
    }

    func testRealVoiceTakesFindPausesAtTheDefaultSensitivity() async throws {
        let expected: [String: Int] = [
            "vo-take-02": 2,
            "vo-take-03": 2
        ]
        for (name, count) in expected {
            let url = try XCTUnwrap(
                Bundle.module.url(
                    forResource: name,
                    withExtension: "wav",
                    subdirectory: "Fixtures"
                )
            )
            let data = try await WaveformExtractor.extract(url: url)
            let candidates = MediaSilenceDetector.detect(
                data: data,
                settings: MediaSilenceSettings(
                    thresholdDBFS: -35,
                    minimumPause: 0.30
                ),
                sourceDuration: data.duration,
                keepRanges: [
                    MediaTimeRange(start: 0, duration: data.duration)
                ]
            )
            XCTAssertEqual(candidates.count, count, name)
            for candidate in candidates {
                XCTAssertGreaterThanOrEqual(
                    candidate.duration,
                    0.30,
                    name
                )
                XCTAssertGreaterThan(candidate.start, 0, name)
                XCTAssertLessThan(candidate.end, data.duration, name)
            }
        }
    }

    func testInvalidSettingsFallBackToDefaults() {
        let data = makeData(silence(seconds: 1))
        let candidates = MediaSilenceDetector.detect(
            data: data,
            settings: MediaSilenceSettings(
                thresholdDBFS: .nan,
                minimumPause: .infinity
            ),
            sourceDuration: data.duration,
            keepRanges: [MediaTimeRange(start: 0, duration: data.duration)]
        )
        XCTAssertEqual(candidates.count, 1)
    }

    private func silence(seconds: Double) -> [(Float?, Int)] {
        Array(repeating: (-60, 5), count: bucketCount(seconds))
    }

    private func tone(seconds: Double, dBFS: Double) -> [(Float?, Int)] {
        Array(repeating: (Float(dBFS), 5), count: bucketCount(seconds))
    }

    private func bucketCount(_ seconds: Double) -> Int {
        max(1, Int((seconds * 1000 / 5).rounded()))
    }

    private func makeData(
        _ buckets: [(Float?, Int)]
    ) -> WaveformData {
        let sampleRate = 1000.0
        let bucketFrames = 5
        let peaks = buckets.map { bucket -> Float in
            guard let dBFS = bucket.0, bucket.1 > 0 else { return 0 }
            return Float(pow(10, Double(dBFS) / 20))
        }
        let counts = buckets.map { $0.1 }
        let sums = peaks.enumerated().map { index, peak in
            peak * peak * Float(max(counts[index], 0))
        }
        let duration = Double(buckets.count * bucketFrames) / sampleRate
        return WaveformData(
            peaks: peaks,
            sumSquares: sums,
            bucketFrameCounts: counts,
            bucketFrames: bucketFrames,
            totalFrames: counts.reduce(0, +),
            sampleRate: sampleRate,
            channelCount: 1,
            bucketsPerSecond: 200,
            duration: duration
        )
    }
}
