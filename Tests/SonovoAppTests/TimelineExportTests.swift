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

    func testSourceChangeAfterExportIsRefused() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "timeline-source-change-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try XCTUnwrap(
            Bundle.module.url(
                forResource: "vo-take-02",
                withExtension: "wav",
                subdirectory: "Fixtures"
            )
        )
        let copy = directory.appendingPathComponent("voice.wav")
        try FileManager.default.copyItem(at: source, to: copy)
        let asset = ProjectAsset(
            id: "voice.wav",
            url: copy,
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
        let video = try fixtureAsset(
            "cfr.mov",
            relativePath: "video.mov",
            kind: .video
        )
        var timeline = ProjectTimeline(name: "Source change")
        try timeline.addClip(
            asset: asset,
            track: .voice,
            at: time(0),
            duration: time(1)
        )
        try timeline.addClip(
            asset: video,
            track: .video,
            at: time(0),
            duration: time(0.3)
        )
        do {
            _ = try await TimelineExportService.export(
                timeline: timeline,
                assets: [asset, video],
                destinationDirectory: directory,
                beforeInstall: {
                    try await Task.sleep(for: .milliseconds(300))
                    let handle = try FileHandle(forWritingTo: copy)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data([0]))
                    try handle.close()
                },
                progress: { _ in }
            )
            XCTFail("a changed source must not install an asset")
        } catch {
            XCTAssertEqual(error as? TimelineExportError, .sourceChanged)
        }
        let outputs = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ).filter { $0.hasPrefix("Timeline-") }
        XCTAssertTrue(outputs.isEmpty)
    }

    func testUnwritableDestinationLeavesNoAsset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "timeline-install-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try XCTUnwrap(
            Bundle.module.url(
                forResource: "vo-take-02",
                withExtension: "wav",
                subdirectory: "Fixtures"
            )
        )
        let asset = ProjectAsset(
            id: "voice.wav",
            url: source,
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
        let video = try fixtureAsset(
            "cfr.mov",
            relativePath: "video.mov",
            kind: .video
        )
        var timeline = ProjectTimeline(name: "Install")
        try timeline.addClip(
            asset: asset,
            track: .voice,
            at: time(0),
            duration: time(1)
        )
        try timeline.addClip(
            asset: video,
            track: .video,
            at: time(0),
            duration: time(0.3)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directory.path
        )
        do {
            _ = try await TimelineExportService.export(
                timeline: timeline,
                assets: [asset, video],
                destinationDirectory: directory
            ) { _ in }
            XCTFail("an unwritable destination must fail")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        let outputs = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ).filter { $0.hasPrefix("Timeline-") }
        XCTAssertTrue(outputs.isEmpty)
    }

    func testOverFullScaleMixIsRefused() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "timeline-overload-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let loud = directory.appendingPathComponent("loud.wav")
        try writeTone(to: loud, amplitude: 0.99)
        let asset = ProjectAsset(
            id: "loud.wav",
            url: loud,
            name: "loud.wav",
            relativePath: "loud.wav",
            kind: .audio,
            size: 1,
            modified: nil,
            revision: AssetRevision(
                fileIdentifier: "loud",
                size: 1,
                modified: nil
            )
        )
        var timeline = ProjectTimeline(name: "Overload")
        try timeline.addClip(
            asset: asset,
            track: .voice,
            at: time(0),
            duration: time(1)
        )
        try timeline.addClip(
            asset: asset,
            track: .music,
            at: time(0),
            duration: time(1)
        )
        do {
            _ = try await TimelineExportService.export(
                timeline: timeline,
                assets: [asset],
                destinationDirectory: directory
            ) { _ in }
            XCTFail("a mix above full scale must be refused")
        } catch let error as TimelineExportError {
            guard case .peakOverFullScale = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        let outputs = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ).filter { $0.hasPrefix("Timeline-") }
        XCTAssertTrue(outputs.isEmpty)
    }

    func testCancellationLeavesNoAsset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "timeline-cancel-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try XCTUnwrap(
            Bundle.module.url(
                forResource: "vo-take-02",
                withExtension: "wav",
                subdirectory: "Fixtures"
            )
        )
        let asset = ProjectAsset(
            id: "voice.wav",
            url: source,
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
        let video = try fixtureAsset(
            "long.mov",
            relativePath: "video.mov",
            kind: .video
        )
        var timeline = ProjectTimeline(name: "Cancel")
        try timeline.addClip(
            asset: asset,
            track: .voice,
            at: time(0),
            duration: time(2)
        )
        try timeline.addClip(
            asset: video,
            track: .video,
            at: time(0),
            duration: time(2)
        )
        let task = Task {
            try await TimelineExportService.export(
                timeline: timeline,
                assets: [asset, video],
                destinationDirectory: directory,
                beforeInstall: {
                    try await Task.sleep(for: .seconds(10))
                },
                progress: { _ in }
            )
        }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled export must throw")
        } catch is CancellationError {
            // expected
        }
        let outputs = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ).filter { $0.hasPrefix("Timeline-") }
        XCTAssertTrue(outputs.isEmpty)
    }

    func testAudioOnlyTimelineExportsM4A() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "timeline-audio-export-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try XCTUnwrap(
            Bundle.module.url(
                forResource: "vo-take-02",
                withExtension: "wav",
                subdirectory: "Fixtures"
            )
        )
        let asset = ProjectAsset(
            id: "voice.wav",
            url: source,
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
        var timeline = ProjectTimeline(name: "Audio only")
        try timeline.addClip(
            asset: asset,
            track: .voice,
            at: time(0),
            duration: time(1)
        )
        let result = try await TimelineExportService.export(
            timeline: timeline,
            assets: [asset],
            destinationDirectory: directory
        ) { _ in }
        XCTAssertEqual(result.url.pathExtension, "m4a")
        let output = AVURLAsset(url: result.url)
        let playable = try await output.load(.isPlayable)
        XCTAssertTrue(playable)
        let audio = try await output.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audio.isEmpty)
    }

    private func writeTone(to url: URL, amplitude: Float) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: 22_050,
                channels: 1
            )
        )
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings
        )
        let frames = AVAudioFrameCount(44_100)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frames
            )
        )
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = amplitude
                * sin(2 * .pi * 440 * Float(index) / 22_050)
        }
        try file.write(from: buffer)
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
