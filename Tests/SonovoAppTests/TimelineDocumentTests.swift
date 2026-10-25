import CoreMedia
import XCTest
@testable import Sonovo

final class ProjectTimelineValidationTests: XCTestCase {
    func testRoundTripPreservesCanonicalTime() throws {
        var timeline = ProjectTimeline(name: "Episode")
        timeline.videoTrack.clips = [
            makeClip(
                id: "video-1",
                path: "video.mov",
                start: 1.25,
                duration: 2.5,
                timelineStart: 0
            )
        ]
        timeline.voiceTrack.clips = [
            makeClip(
                id: "voice-1",
                path: "voice.wav",
                start: 0.5,
                duration: 3,
                timelineStart: 0.25
            )
        ]
        let directory = try makeDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("Episode.timeline.json")
        let store = TimelineFileStore(url: url)
        try store.save(timeline)

        let loaded = try store.load()
        XCTAssertEqual(loaded, timeline)
        XCTAssertEqual(
            loaded.videoTrack.clips[0].sourceStart.cmTime,
            CMTime(seconds: 1.25, preferredTimescale: 600_000)
        )
        XCTAssertEqual(
            loaded.voiceTrack.clips[0].timelineStart.seconds,
            0.25,
            accuracy: 0.0001
        )
    }

    func testOverlapAndUnsafePathAreRejected() {
        var timeline = ProjectTimeline(name: "Episode")
        timeline.videoTrack.clips = [
            makeClip(
                id: "one",
                path: "a.mov",
                start: 0,
                duration: 2,
                timelineStart: 0
            ),
            makeClip(
                id: "two",
                path: "b.mov",
                start: 0,
                duration: 2,
                timelineStart: 1
            )
        ]
        XCTAssertThrowsError(try timeline.validate()) { error in
            XCTAssertEqual(
                error as? TimelineValidationError,
                .overlappingClips("video")
            )
        }

        timeline.videoTrack.clips = [
            makeClip(
                id: "one",
                path: "../outside.mov",
                start: 0,
                duration: 2,
                timelineStart: 0
            )
        ]
        XCTAssertThrowsError(try timeline.validate()) { error in
            guard case .invalidPath = error as? TimelineValidationError else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testGainAndFadesAreBounded() {
        var timeline = ProjectTimeline(name: "Episode")
        var clip = makeClip(
            id: "voice",
            path: "voice.wav",
            start: 0,
            duration: 1,
            timelineStart: 0
        )
        clip.gain = 1.2
        timeline.voiceTrack.clips = [clip]
        XCTAssertThrowsError(try timeline.validate())

        clip.gain = 1
        clip = makeClip(
            id: "voice",
            path: "voice.wav",
            start: 0,
            duration: 1,
            timelineStart: 0,
            fadeIn: 0.8,
            fadeOut: 0.8
        )
        timeline.voiceTrack.clips = [clip]
        XCTAssertThrowsError(try timeline.validate())
    }

    private func makeClip(
        id: String,
        path: String,
        start: Double,
        duration: Double,
        timelineStart: Double,
        fadeIn: Double = 0,
        fadeOut: Double = 0
    ) -> TimelineClip {
        TimelineClip(
            id: id,
            assetID: id,
            relativePath: path,
            sourceStart: time(start),
            sourceDuration: time(duration),
            timelineStart: time(timelineStart),
            gain: 1,
            fadeIn: time(fadeIn),
            fadeOut: time(fadeOut)
        )
    }

    private func time(_ seconds: Double) -> TimelineTimeDTO {
        TimelineTimeDTO(
            CMTime(seconds: seconds, preferredTimescale: 600_000)
        )
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "timeline-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}

@MainActor
final class TimelineDocumentTests: XCTestCase {
    func testMutationUndoRedoAndAutosave() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Episode.timeline.json")
        let document = TimelineDocument(url: url)
        defer { document.close() }
        try document.create(ProjectTimeline(name: "Episode"))

        let clip = makeClip(
            id: "video",
            path: "video.mov",
            start: 0,
            duration: 2,
            timelineStart: 0
        )
        try document.mutate { timeline in
            timeline.videoTrack.clips.append(clip)
        }
        XCTAssertTrue(document.hasUnsavedChanges)
        XCTAssertTrue(document.canUndo)
        try await Task.sleep(for: .milliseconds(1_300))
        XCTAssertEqual(document.status, .saved)
        XCTAssertFalse(document.hasUnsavedChanges)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        XCTAssertTrue(document.undo())
        XCTAssertTrue(document.timeline?.videoTrack.clips.isEmpty == true)
        XCTAssertTrue(document.redo())
        XCTAssertEqual(document.timeline?.videoTrack.clips.count, 1)
    }

    func testFailedSaveStaysDirtyAndVisible() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Episode.timeline.json")
        let failingStore = TimelineFileStore(
            url: url,
            writeData: { _, _ in
                throw CocoaError(.fileWriteNoPermission)
            }
        )
        let document = TimelineDocument(url: url, store: failingStore)
        defer { document.close() }
        try document.create(ProjectTimeline(name: "Episode"))
        XCTAssertThrowsError(try document.save()) { error in
            XCTAssertTrue(error is CocoaError)
        }
        XCTAssertTrue(document.hasUnsavedChanges)
        guard case .failed = document.status else {
            return XCTFail("status should be failed")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func makeClip(
        id: String,
        path: String,
        start: Double,
        duration: Double,
        timelineStart: Double
    ) -> TimelineClip {
        TimelineClip(
            id: id,
            assetID: id,
            relativePath: path,
            sourceStart: TimelineTimeDTO(
                CMTime(seconds: start, preferredTimescale: 600_000)
            ),
            sourceDuration: TimelineTimeDTO(
                CMTime(seconds: duration, preferredTimescale: 600_000)
            ),
            timelineStart: TimelineTimeDTO(
                CMTime(seconds: timelineStart, preferredTimescale: 600_000)
            ),
            gain: 1,
            fadeIn: TimelineTimeDTO(
                CMTime(seconds: 0, preferredTimescale: 600_000)
            ),
            fadeOut: TimelineTimeDTO(
                CMTime(seconds: 0, preferredTimescale: 600_000)
            )
        )
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "timeline-doc-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
