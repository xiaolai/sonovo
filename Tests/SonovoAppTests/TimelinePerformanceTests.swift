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

final class TimelineBudgetTests: XCTestCase {
    func testOpenTrimAndScrubBudgetsScaleTo500Clips() throws {
        for count in [10, 100, 500] {
            let timeline = try makeTimeline(count: count)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "timeline-budget-\(count)-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("Episode.timeline.json")
            let store = TimelineFileStore(url: url)

            let saveStart = ContinuousClock.now
            try store.save(timeline)
            let saveElapsed = ContinuousClock.now - saveStart
            let loadStart = ContinuousClock.now
            _ = try store.load()
            let loadElapsed = ContinuousClock.now - loadStart

            let trimStart = ContinuousClock.now
            var trimmed = timeline
            let firstID = try XCTUnwrap(trimmed.allClips.first?.id)
            try trimmed.trimEnd(
                id: firstID,
                to: trimmed.clip(id: firstID)!.timelineStart.cmTime
                    + CMTime(seconds: 0.5, preferredTimescale: 600_000)
            )
            let trimElapsed = ContinuousClock.now - trimStart

            let candidates = timeline.allClips.flatMap {
                [$0.timelineStart.cmTime, $0.timelineEnd]
            }
            let scrubStart = ContinuousClock.now
            for index in 0..<1_000 {
                _ = timeline.snap(
                    CMTime(
                        seconds: Double(index) * 0.37,
                        preferredTimescale: 600_000
                    ),
                    candidates: candidates,
                    tolerance: CMTime(
                        seconds: 0.05,
                        preferredTimescale: 600_000
                    )
                )
            }
            let scrubElapsed = ContinuousClock.now - scrubStart

            let budget = budget(for: count)
            XCTAssertLessThan(
                saveElapsed,
                budget.open,
                "\(count)-clip save exceeded budget (actual \(saveElapsed))"
            )
            XCTAssertLessThan(
                loadElapsed,
                budget.open,
                "\(count)-clip open exceeded budget (actual \(loadElapsed))"
            )
            XCTAssertLessThan(
                trimElapsed,
                budget.edit,
                "\(count)-clip trim exceeded budget (actual \(trimElapsed))"
            )
            XCTAssertLessThan(
                scrubElapsed,
                budget.scrub,
                "\(count)-clip scrub exceeded budget (actual \(scrubElapsed))"
            )
        }
    }

    func testFiveHundredClipModelMemoryGrowth() throws {
        let before = footprint()
        _ = try makeTimeline(count: 500)
        let after = footprint()
        let growth = after > before ? after - before : 0
        XCTAssertLessThan(
            growth,
            256 * 1_024 * 1_024,
            "500-clip model grew by \(growth) bytes"
        )
    }

    private struct Budget {
        let open: Duration
        let edit: Duration
        let scrub: Duration
    }

    private func budget(for count: Int) -> Budget {
        switch count {
        case 10:
            Budget(
                open: .seconds(0.5),
                edit: .seconds(0.2),
                scrub: .seconds(0.5)
            )
        case 100:
            Budget(
                open: .seconds(1),
                edit: .seconds(0.3),
                scrub: .seconds(0.75)
            )
        default:
            Budget(
                open: .seconds(2.5),
                edit: .seconds(0.6),
                scrub: .seconds(1.5)
            )
        }
    }

    private func makeTimeline(count: Int) throws -> ProjectTimeline {
        let asset = ProjectAsset(
            id: "music.wav",
            url: URL(fileURLWithPath: "/tmp/music.wav"),
            name: "music.wav",
            relativePath: "music.wav",
            kind: .audio,
            size: 1,
            modified: nil,
            revision: AssetRevision(
                fileIdentifier: "music",
                size: 1,
                modified: nil
            )
        )
        var timeline = ProjectTimeline(name: "Budget")
        for index in 0..<count {
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
        return timeline
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
