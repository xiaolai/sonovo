import AVFoundation
import CoreMedia
import XCTest
@testable import Sonovo

@MainActor
final class TimelineExportLifecycleTests: XCTestCase {
    func testCancelingWorkspaceJobsStopsAnExport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "timeline-job-cancel-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let voice = try fixtureAsset("vo-take-02.wav", kind: .audio)
        let video = try fixtureAsset("long.mov", kind: .video)
        var timeline = ProjectTimeline(name: "Cancel jobs")
        try timeline.addClip(
            asset: voice,
            track: .voice,
            at: CMTime(seconds: 0, preferredTimescale: 600_000),
            duration: CMTime(seconds: 1, preferredTimescale: 600_000)
        )
        try timeline.addClip(
            asset: video,
            track: .video,
            at: CMTime(seconds: 0, preferredTimescale: 600_000),
            duration: CMTime(seconds: 10, preferredTimescale: 600_000)
        )
        let workspace = TimelineWorkspace()
        let task = Task {
            try await workspace.exportTimeline(
                timeline: timeline,
                assets: [voice, video],
                destinationDirectory: directory
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        workspace.cancelJobs()
        do {
            _ = try await task.value
            XCTFail("canceling workspace jobs must stop the export")
        } catch is CancellationError {
            // expected
        }
        XCTAssertFalse(workspace.isExporting)
        let outputs = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ).filter { $0.hasPrefix("Timeline-") }
        XCTAssertTrue(outputs.isEmpty)
    }

    private func fixtureAsset(
        _ name: String,
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
            id: name,
            url: url,
            name: name,
            relativePath: name,
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
}
