import AVFoundation
import CoreMedia
import XCTest
@testable import Sonovo

@MainActor
final class TimelineExportTests: XCTestCase {
    func testExportCreatesPlayableMovieWithoutChangingSources() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "timeline-export-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let voice = try fixtureAsset(
            "vo-take-02.wav",
            relativePath: "voice.wav",
            kind: .audio
        )
        let video = try fixtureAsset(
            "cfr.mov",
            relativePath: "b-roll.mov",
            kind: .video
        )
        let voiceDuration = try await AVURLAsset(url: voice.url)
            .load(.duration)
        let videoDuration = try await AVURLAsset(url: video.url)
            .load(.duration)
        let before = try sourceTimestamps([voice, video])

        var timeline = ProjectTimeline(name: "Episode")
        try timeline.addClip(
            asset: voice,
            track: .voice,
            at: time(0),
            duration: min(voiceDuration, time(2))
        )
        try timeline.addClip(
            asset: video,
            track: .video,
            at: time(0.5),
            duration: min(videoDuration, time(1.5))
        )

        let result = try await TimelineExportService.export(
            timeline: timeline,
            assets: [voice, video],
            destinationDirectory: directory
        ) { _ in }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.url.path)
        )
        XCTAssertEqual(result.url.pathExtension, "mov")
        XCTAssertGreaterThan(result.peak, 0)
        XCTAssertLessThanOrEqual(result.peak, 1)
        XCTAssertEqual(
            result.duration.seconds,
            timeline.duration.seconds,
            accuracy: 0.001
        )

        let output = AVURLAsset(url: result.url)
        let playable = try await output.load(.isPlayable)
        XCTAssertTrue(playable)
        let duration = try await output.load(.duration)
        XCTAssertEqual(
            duration.seconds,
            timeline.duration.seconds,
            accuracy: 0.15
        )
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        XCTAssertFalse(videoTracks.isEmpty)
        XCTAssertFalse(audioTracks.isEmpty)
        XCTAssertEqual(before, try sourceTimestamps([voice, video]))
    }

    func testPeakPolicyRefusesAFullScaleMix() {
        // The service measures the actual mix; this pins the threshold and
        // message path without fabricating a clipped source fixture.
        XCTAssertEqual(
            TimelineExportError.peakOverFullScale(1.2)
                .errorDescription?.contains("Lower a clip gain"),
            true
        )
    }

    private func sourceTimestamps(
        _ assets: [ProjectAsset]
    ) throws -> [String: Date] {
        var result: [String: Date] = [:]
        for asset in assets {
            let values = try asset.url.resourceValues(
                forKeys: [.contentModificationDateKey]
            )
            result[asset.relativePath] = values.contentModificationDate
        }
        return result
    }

    private func fixtureAsset(
        _ name: String,
        relativePath: String,
        kind: AssetKind
    ) throws -> ProjectAsset {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: (name as NSString).deletingPathExtension,
                withExtension: (name as NSString).pathExtension,
                subdirectory: "Fixtures"
            )
        )
        return ProjectAsset(
            id: relativePath,
            url: url,
            name: name,
            relativePath: relativePath,
            kind: kind,
            size: 1,
            modified: nil,
            revision: AssetRevision(
                fileIdentifier: name,
                size: 1,
                modified: nil
            )
        )
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600_000)
    }
}
