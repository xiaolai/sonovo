import CoreMedia
import XCTest
@testable import Sonovo

final class TimelinePerformanceTests: XCTestCase {
    func testOneHourTimeModelSurvivesOffsetsAndSplits() throws {
        let timescale: CMTimeScale = 600_000
        let hour = CMTime(seconds: 3600, preferredTimescale: timescale)
        var timeline = ProjectTimeline(name: "One hour")
        let asset = self.asset("voice.wav", .audio)
        try timeline.addClip(
            asset: asset,
            track: .voice,
            at: CMTime(seconds: 0.333, preferredTimescale: timescale),
            duration: hour
        )
        let original = try XCTUnwrap(timeline.voiceTrack.clips.first)
        try timeline.addClip(
            asset: asset,
            track: .music,
            at: CMTime(seconds: 0.001, preferredTimescale: timescale),
            duration: hour
        )

        let splitTime = CMTime(
            seconds: 1234.567,
            preferredTimescale: timescale
        )
        let rightID = try timeline.splitClip(
            id: original.id,
            at: splitTime
        )
        let left = try XCTUnwrap(
            timeline.voiceTrack.clips.first { $0.id == original.id }
        )
        let right = try XCTUnwrap(
            timeline.voiceTrack.clips.first { $0.id == rightID }
        )
        XCTAssertEqual(
            (left.sourceDuration.cmTime + right.sourceDuration.cmTime)
                .seconds,
            hour.seconds,
            accuracy: 0.000001
        )
        XCTAssertEqual(
            left.timelineEnd,
            splitTime
        )
        XCTAssertEqual(
            right.sourceStart.cmTime,
            original.sourceStart.cmTime
                + (splitTime - original.timelineStart.cmTime)
        )
        try timeline.validate()
    }

    func testFiveHundredClipRoundTripAndSourceCheck() throws {
        let asset = self.asset("music.wav", .audio)
        var timeline = ProjectTimeline(name: "Long")
        for index in 0..<500 {
            try timeline.addClip(
                asset: asset,
                track: index.isMultiple(of: 2) ? .voice : .music,
                at: CMTime(
                    seconds: Double(index) * 2,
                    preferredTimescale: 600_000
                ),
                duration: CMTime(
                    seconds: 1,
                    preferredTimescale: 600_000
                )
            )
        }
        XCTAssertEqual(timeline.allClips.count, 500)
        XCTAssertTrue(timeline.sourceIssues(assets: [asset]).isEmpty)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "timeline-long-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Long.timeline.json")
        let store = TimelineFileStore(url: url)
        try store.save(timeline)
        let loaded = try store.load()
        XCTAssertEqual(loaded, timeline)
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
}
