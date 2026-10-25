import AVFoundation
import CoreMedia
import XCTest
@testable import Sonovo

final class TimelineCompositionTests: XCTestCase {
    func testBuildsOneVideoAndTwoAudioTracksWithMix() async throws {
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
        let music = try fixtureAsset(
            "vo-take-03.wav",
            relativePath: "music.wav",
            kind: .audio
        )
        let voiceDuration = try await AVURLAsset(url: voice.url)
            .load(.duration)
        let videoDuration = try await AVURLAsset(url: video.url)
            .load(.duration)
        let musicDuration = try await AVURLAsset(url: music.url)
            .load(.duration)

        var timeline = ProjectTimeline(name: "Episode")
        try timeline.addClip(
            asset: voice,
            track: .voice,
            at: time(0),
            duration: voiceDuration
        )
        try timeline.addClip(
            asset: video,
            track: .video,
            at: time(1),
            duration: min(videoDuration, time(1.5))
        )
        try timeline.addClip(
            asset: music,
            track: .music,
            at: time(0.5),
            duration: min(musicDuration, time(2)),
            gain: 0.35,
            fadeIn: time(0.25),
            fadeOut: time(0.5)
        )

        let built = try await ProjectTimelineCompositionBuilder.build(
            timeline: timeline,
            assets: [voice, video, music]
        )
        XCTAssertEqual(
            built.composition.tracks(withMediaType: .video).count,
            1
        )
        XCTAssertEqual(
            built.composition.tracks(withMediaType: .audio).count,
            2
        )
        XCTAssertEqual(
            built.duration.seconds,
            timeline.duration.seconds,
            accuracy: 0.001
        )
        XCTAssertEqual(
            built.composition.duration.seconds,
            timeline.duration.seconds,
            accuracy: 0.02
        )
        let mix = try XCTUnwrap(built.audioMix)
        XCTAssertEqual(mix.inputParameters.count, 2)
        let videoComposition = try XCTUnwrap(built.videoComposition)
        XCTAssertEqual(videoComposition.renderSize.width, 1920)
        XCTAssertEqual(videoComposition.renderSize.height, 1080)
        XCTAssertFalse(videoComposition.instructions.isEmpty)
        let peak = try await TimelineAudioPeak.measure(
            asset: built.composition,
            audioMix: built.audioMix
        )
        XCTAssertGreaterThan(peak, 0)
        XCTAssertLessThanOrEqual(peak, 1)
    }

    func testMissingSourceBlocksComposition() async throws {
        var timeline = ProjectTimeline(name: "Episode")
        let voice = try fixtureAsset(
            "vo-take-02.wav",
            relativePath: "voice.wav",
            kind: .audio
        )
        try timeline.addClip(
            asset: voice,
            track: .voice,
            at: time(0),
            duration: time(2)
        )
        do {
            _ = try await ProjectTimelineCompositionBuilder.build(
                timeline: timeline,
                assets: []
            )
            XCTFail("a missing source must block composition")
        } catch let error as TimelineCompositionError {
            guard case let .sourceIssues(issues) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(issues.count, 1)
            XCTAssertEqual(issues[0].clipID, timeline.voiceTrack.clips[0].id)
            XCTAssertEqual(issues[0].reason, .missing)
        }
    }

    func testAspectFitLetterboxesWithoutDistortion() {
        let transform = ProjectTimelineCompositionBuilder.aspectFitTransform(
            naturalSize: CGSize(width: 1080, height: 1920),
            preferredTransform: .identity,
            canvas: CGSize(width: 1920, height: 1080)
        )
        let rect = CGRect(
            origin: .zero,
            size: CGSize(width: 1080, height: 1920)
        ).applying(transform)
        XCTAssertEqual(rect.height, 1080, accuracy: 0.1)
        XCTAssertLessThan(rect.width, 1920)
        XCTAssertEqual(rect.midX, 960, accuracy: 0.1)
        XCTAssertEqual(rect.midY, 540, accuracy: 0.1)
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
