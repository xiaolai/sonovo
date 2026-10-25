import CoreMedia
import XCTest
@testable import Sonovo

final class TimelineEditingTests: XCTestCase {
    func testArrangesVoiceVideoAndMusicAndKeepsOrder() throws {
        var timeline = ProjectTimeline(name: "Episode")
        try timeline.addClip(
            asset: asset("voice.wav", .audio),
            track: .voice,
            at: time(0),
            duration: time(4)
        )
        try timeline.addClip(
            asset: asset("b-roll.mov", .video),
            track: .video,
            at: time(1),
            duration: time(3)
        )
        try timeline.addClip(
            asset: asset("music.m4a", .audio),
            track: .music,
            at: time(0),
            duration: time(8),
            gain: 0.3
        )
        try timeline.validate()
        XCTAssertEqual(timeline.voiceTrack.clips.count, 1)
        XCTAssertEqual(timeline.videoTrack.clips.count, 1)
        XCTAssertEqual(timeline.musicTrack.clips.count, 1)
        XCTAssertEqual(timeline.duration.seconds, 8, accuracy: 0.0001)
    }

    func testVideoOverlapIsRejectedButAudioTracksCanOverlap() throws {
        var timeline = ProjectTimeline(name: "Episode")
        let video = asset("a.mov", .video)
        try timeline.addClip(
            asset: video,
            track: .video,
            at: time(0),
            duration: time(3)
        )
        XCTAssertThrowsError(
            try timeline.addClip(
                asset: video,
                track: .video,
                at: time(2),
                duration: time(2)
            )
        ) { error in
            XCTAssertEqual(error as? TimelineEditError, .overlap)
        }
        let voice = asset("voice.wav", .audio)
        try timeline.addClip(
            asset: voice,
            track: .voice,
            at: time(0),
            duration: time(5)
        )
        try timeline.addClip(
            asset: asset("music.m4a", .audio),
            track: .music,
            at: time(0),
            duration: time(5)
        )
        XCTAssertEqual(timeline.voiceTrack.clips.count, 1)
        XCTAssertEqual(timeline.musicTrack.clips.count, 1)
    }

    func testMoveTrimSplitAndDelete() throws {
        var timeline = ProjectTimeline(name: "Episode")
        try timeline.addClip(
            asset: asset("voice.wav", .audio),
            track: .voice,
            at: time(0),
            duration: time(6)
        )
        let id = try XCTUnwrap(timeline.voiceTrack.clips.first?.id)

        try timeline.moveClip(id: id, to: time(2))
        XCTAssertEqual(
            timeline.voiceTrack.clips[0].timelineStart.seconds,
            2,
            accuracy: 0.0001
        )

        try timeline.trimStart(id: id, to: time(3))
        XCTAssertEqual(
            timeline.voiceTrack.clips[0].sourceStart.seconds,
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            timeline.voiceTrack.clips[0].sourceDuration.seconds,
            5,
            accuracy: 0.0001
        )

        try timeline.trimEnd(id: id, to: time(6))
        XCTAssertEqual(
            timeline.voiceTrack.clips[0].sourceDuration.seconds,
            3,
            accuracy: 0.0001
        )

        let rightID = try timeline.splitClip(id: id, at: time(5))
        XCTAssertEqual(timeline.voiceTrack.clips.count, 2)
        XCTAssertEqual(timeline.voiceTrack.clips[1].id, rightID)
        XCTAssertEqual(
            timeline.voiceTrack.clips[1].sourceStart.seconds,
            3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            timeline.voiceTrack.clips[1].sourceDuration.seconds,
            1,
            accuracy: 0.0001
        )

        try timeline.deleteClip(id: rightID)
        XCTAssertEqual(timeline.voiceTrack.clips.count, 1)
        try timeline.validate()
    }

    func testTrimCannotExceedSourceOrCrossAnotherClip() throws {
        var timeline = ProjectTimeline(name: "Episode")
        let asset = asset("voice.wav", .audio)
        try timeline.addClip(
            asset: asset,
            track: .voice,
            at: time(0),
            duration: time(2)
        )
        let first = try XCTUnwrap(timeline.voiceTrack.clips.first?.id)
        try timeline.addClip(
            asset: asset,
            track: .voice,
            at: time(3),
            duration: time(2)
        )
        XCTAssertThrowsError(
            try timeline.trimEnd(id: first, to: time(3.5))
        ) { error in
            XCTAssertEqual(error as? TimelineEditError, .invalidRange)
        }
        XCTAssertThrowsError(
            try timeline.moveClip(id: first, to: time(2))
        ) { error in
            XCTAssertEqual(error as? TimelineEditError, .overlap)
        }

        var one = ProjectTimeline(name: "Episode")
        try one.addClip(
            asset: asset,
            track: .voice,
            at: time(0),
            duration: time(2)
        )
        let clipID = try XCTUnwrap(one.voiceTrack.clips.first?.id)
        XCTAssertThrowsError(
            try one.trimEnd(id: clipID, to: time(3))
        ) { error in
            XCTAssertEqual(error as? TimelineEditError, .invalidRange)
        }
    }

    func testSnapChoosesNearestCandidateInsideTolerance() {
        var timeline = ProjectTimeline(name: "Episode")
        timeline.voiceTrack.clips = [
            clip(
                id: "a",
                path: "a.wav",
                start: 0,
                duration: 1,
                timelineStart: 2
            )
        ]
        let candidates = [time(0), time(2), time(3)]
        XCTAssertEqual(
            timeline.snap(time(1.98), candidates: candidates, tolerance: time(0.05)),
            time(2)
        )
        XCTAssertEqual(
            timeline.snap(time(1.9), candidates: candidates, tolerance: time(0.05)),
            time(1.9)
        )
    }

    private func clip(
        id: String,
        path: String,
        start: Double,
        duration: Double,
        timelineStart: Double
    ) -> TimelineClip {
        TimelineClip(
            id: id,
            assetID: path,
            relativePath: path,
            sourceStart: dto(start),
            sourceDuration: dto(duration),
            timelineStart: dto(timelineStart),
            gain: 1,
            fadeIn: dto(0),
            fadeOut: dto(0)
        )
    }

    private func asset(_ path: String, _ kind: AssetKind) -> ProjectAsset {
        ProjectAsset(
            id: path,
            url: URL(fileURLWithPath: "/tmp/\(path)"),
            name: (path as NSString).lastPathComponent,
            relativePath: path,
            kind: kind,
            size: 1,
            modified: nil,
            revision: AssetRevision(
                fileIdentifier: path,
                size: 1,
                modified: nil
            )
        )
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600_000)
    }

    private func dto(_ seconds: Double) -> TimelineTimeDTO {
        TimelineTimeDTO(time(seconds))
    }
}

final class TimelineClipLevelTests: XCTestCase {
    func testGainAndFadesAreEditedAsOneClipChange() throws {
        var timeline = ProjectTimeline(name: "Levels")
        let asset = ProjectAsset(
            id: "voice.wav",
            url: URL(fileURLWithPath: "/tmp/voice.wav"),
            name: "voice.wav",
            relativePath: "voice.wav",
            kind: .audio,
            size: 1,
            modified: nil,
            revision: AssetRevision(
                fileIdentifier: "voice",
                size: 1,
                modified: nil
            )
        )
        try timeline.addClip(
            asset: asset,
            track: .voice,
            at: time(0),
            duration: time(4)
        )
        let id = try XCTUnwrap(timeline.voiceTrack.clips.first?.id)
        try timeline.setGain(id: id, gain: 0.4)
        try timeline.setFades(
            id: id,
            fadeIn: time(0.25),
            fadeOut: time(0.5)
        )
        let clip = try XCTUnwrap(timeline.clip(id: id))
        XCTAssertEqual(clip.gain, 0.4, accuracy: 0.0001)
        XCTAssertEqual(clip.fadeIn.seconds, 0.25, accuracy: 0.0001)
        XCTAssertEqual(clip.fadeOut.seconds, 0.5, accuracy: 0.0001)
        XCTAssertThrowsError(try timeline.setGain(id: id, gain: 1.5))
        XCTAssertThrowsError(
            try timeline.setFades(
                id: id,
                fadeIn: time(3.9),
                fadeOut: time(0.5)
            )
        )
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600_000)
    }
}

final class TimelineFingerprintEditingTests: XCTestCase {
    func testEditingOperationsPreserveSourceFingerprint() throws {
        var timeline = ProjectTimeline(name: "Fingerprint")
        let asset = ProjectAsset(
            id: "voice.wav",
            url: URL(fileURLWithPath: "/tmp/voice.wav"),
            name: "voice.wav",
            relativePath: "voice.wav",
            kind: .audio,
            size: 1,
            modified: nil,
            revision: AssetRevision(
                fileIdentifier: "voice",
                size: 1,
                modified: nil
            )
        )
        try timeline.addClip(
            asset: asset,
            track: .voice,
            at: time(0),
            duration: time(4),
            sourceFingerprint: "abc123"
        )
        let id = try XCTUnwrap(timeline.voiceTrack.clips.first?.id)
        try timeline.moveClip(id: id, to: time(0.5))
        try timeline.trimStart(id: id, to: time(1))
        try timeline.trimEnd(id: id, to: time(4))
        try timeline.setGain(id: id, gain: 0.5)
        let right = try timeline.splitClip(id: id, at: time(3))
        XCTAssertEqual(timeline.clip(id: id)?.sourceFingerprint, "abc123")
        XCTAssertEqual(timeline.clip(id: right)?.sourceFingerprint, "abc123")
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600_000)
    }
}
