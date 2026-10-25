import Foundation
import XCTest
@testable import Sonovo

@MainActor
final class SampleAudioTests: XCTestCase {
    func testDemoAudioAssetUsesARealPreparedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SampleAudioTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent(
            "destination",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        let seed = source.appendingPathComponent("vo-take-03.wav")
        try Data([0, 1, 2, 3]).write(to: seed)

        let project = Project.demo(
            production: .sample,
            markdown: MarkdownWorkspace(readsDemoEnvironment: false),
            subtitles: SubtitleWorkspace(readsDemoEnvironment: false),
            models: Model3DWorkspace(opensDemoModel: false),
            terminalSessions: TerminalSessionsStore(),
            sampleDocuments: SampleProjectDocuments(
                sourceDirectory: source,
                destinationDirectory: destination
            )
        )

        let asset = try XCTUnwrap(
            project.sampleAudioAsset(for: "vo-take-03")
        )

        XCTAssertEqual(asset.kind, .audio)
        XCTAssertEqual(asset.name, "vo-take-03.wav")
        XCTAssertEqual(asset.relativePath, "vo-take-03.wav")
        XCTAssertEqual(asset.size, 4)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: asset.url.path)
        )
        XCTAssertEqual(asset.url.deletingLastPathComponent(), destination)
    }
}
