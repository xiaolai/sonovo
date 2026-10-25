import CoreMedia
import XCTest
@testable import Sonovo

final class TimelineSourceTests: XCTestCase {
    func testMissingWrongKindAndChangedSourcesAreExplicit() {
        let video = asset(path: "video.mov", kind: .video, revision: "new")
        let voice = asset(
            path: "voice.wav",
            kind: .audio,
            revision: "voice-revision"
        )
        let image = asset(
            path: "stills.png",
            kind: .image,
            revision: "image-revision"
        )
        var timeline = ProjectTimeline(name: "Episode")
        timeline.videoTrack.clips = [
            clip(id: "video", path: "video.mov", revision: "old")
        ]
        timeline.voiceTrack.clips = [
            clip(
                id: "voice",
                path: "voice.wav",
                revision: voice.revision.token
            ),
            clip(
                id: "wrong",
                path: "stills.png",
                revision: image.revision.token
            )
        ]

        let issues = timeline.sourceIssues(assets: [video, voice, image])
        XCTAssertEqual(
            Set(issues.map { "\($0.clipID):\($0.reason.rawValue)" }),
            ["video:changed", "wrong:wrongKind"]
        )
        XCTAssertFalse(issues.contains { $0.clipID == "voice" })
    }

    func testMissingPathIsReported() {
        var timeline = ProjectTimeline(name: "Episode")
        timeline.voiceTrack.clips = [
            clip(id: "voice", path: "missing.wav")
        ]
        let issues = timeline.sourceIssues(assets: [])
        XCTAssertEqual(issues.map(\.reason), [.missing])
    }

    func testRelinkRequiresKindAndCoveredRange() throws {
        var timeline = ProjectTimeline(name: "Episode")
        timeline.voiceTrack.clips = [
            clip(id: "voice", path: "old.wav", start: 1, duration: 2)
        ]
        let replacement = asset(
            path: "new.wav",
            kind: .audio,
            revision: "replacement"
        )
        XCTAssertThrowsError(
            try timeline.relink(
                clipID: "voice",
                to: replacement,
                sourceDuration: seconds(2.9)
            )
        ) { error in
            XCTAssertEqual(error as? TimelineRelinkError, .rangeBeyondSource)
        }
        XCTAssertThrowsError(
            try timeline.relink(
                clipID: "voice",
                to: asset(path: "new.mov", kind: .video, revision: "video"),
                sourceDuration: seconds(10)
            )
        ) { error in
            XCTAssertEqual(error as? TimelineRelinkError, .wrongKind)
        }

        try timeline.relink(
            clipID: "voice",
            to: replacement,
            sourceDuration: seconds(3)
        )
        let relinked = try XCTUnwrap(timeline.voiceTrack.clips.first)
        XCTAssertEqual(relinked.relativePath, "new.wav")
        XCTAssertEqual(relinked.sourceRevision, replacement.revision.token)
        XCTAssertEqual(relinked.sourceStart.seconds, 1, accuracy: 0.0001)
        XCTAssertEqual(relinked.sourceDuration.seconds, 2, accuracy: 0.0001)
        XCTAssertTrue(timeline.sourceIssues(assets: [replacement]).isEmpty)
    }

    private func clip(
        id: String,
        path: String,
        revision: String? = nil,
        start: Double = 0,
        duration: Double = 1
    ) -> TimelineClip {
        TimelineClip(
            id: id,
            assetID: path,
            relativePath: path,
            sourceStart: time(start),
            sourceDuration: time(duration),
            timelineStart: time(0),
            gain: 1,
            fadeIn: time(0),
            fadeOut: time(0),
            sourceRevision: revision
        )
    }

    private func asset(
        path: String,
        kind: AssetKind,
        revision: String
    ) -> ProjectAsset {
        ProjectAsset(
            id: path,
            url: URL(fileURLWithPath: "/tmp/\(path)"),
            name: (path as NSString).lastPathComponent,
            relativePath: path,
            kind: kind,
            size: 1,
            modified: nil,
            revision: AssetRevision(
                fileIdentifier: revision,
                size: 1,
                modified: nil
            )
        )
    }

    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600_000)
    }

    private func time(_ seconds: Double) -> TimelineTimeDTO {
        TimelineTimeDTO(
            CMTime(seconds: seconds, preferredTimescale: 600_000)
        )
    }
}

@MainActor
final class TimelineWorkspaceTests: XCTestCase {
    func testWorkspaceFlushesAndReleasesOnClose() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Episode.timeline.json")
        let workspace = TimelineWorkspace()
        try workspace.create(url: url, timeline: ProjectTimeline(name: "Episode"))
        XCTAssertTrue(workspace.hasDirtyDocuments)

        let closed = await workspace.close()
        XCTAssertTrue(closed)
        XCTAssertNil(workspace.document)
        XCTAssertFalse(workspace.hasDirtyDocuments)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        workspace.open(url: url)
        XCTAssertEqual(workspace.document?.timeline?.name, "Episode")
        XCTAssertFalse(workspace.hasDirtyDocuments)
    }

    func testExternalChangeRefusesOverwrite() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Episode.timeline.json")
        let document = TimelineDocument(url: url)
        defer { document.close() }
        try document.create(ProjectTimeline(name: "Episode"))
        try await document.flush()

        var externallyChanged = ProjectTimeline(name: "Other writer")
        externallyChanged.id = "other"
        let store = TimelineFileStore(url: url)
        try store.save(externallyChanged)
        try document.mutate { timeline in
            timeline.name = "Mine"
        }

        XCTAssertThrowsError(try document.save()) { error in
            XCTAssertEqual(
                error as? TimelineDocument.DocumentError,
                .externalChange
            )
        }
        XCTAssertTrue(document.hasUnsavedChanges)

        try document.reload()
        XCTAssertEqual(document.timeline?.name, "Other writer")
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "timeline-workspace-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
