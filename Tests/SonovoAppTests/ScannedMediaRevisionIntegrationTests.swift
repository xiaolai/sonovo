import AVFoundation
import Foundation
import XCTest
import SonovoDomainTypes
import SonovoWorkspaceHost
import SonovoTestFixtures
import SonovoMediaEngine
import SonovoMediaFeature
@testable import Sonovo

@MainActor final class ScannedMediaRevisionIntegrationTests: XCTestCase {
    func testScannedMediaRevisionIsAcceptedByTheRealProjectExporter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(SonovoTestFixtures.bundle.url(forResource: "vo-take-02", withExtension: "wav", subdirectory: "Fixtures"))
        let source = root.appendingPathComponent("voice.wav")
        try FileManager.default.copyItem(at: fixture, to: source)
        let before = try Data(contentsOf: source)
        let project = Project(folderURL: root, watchFactory: { _, _ in UXTestWatcher() }, terminalEnvironment: .disabled)
        defer { project.prepareForTermination() }
        await project.load(); await project.awaitScanSettled()
        let asset = try XCTUnwrap(project.assets.first { $0.name == "voice.wav" })
        XCTAssertEqual(asset.revision, MediaStorage.revision(for: source))
        XCTAssertTrue(MediaStorage.matches(asset.revision, url: source))
        let document = project.mediaEdits.document(for: asset)
        document.prepare(sourceDuration: try await AVURLAsset(url: source).load(.duration).seconds)
        XCTAssertTrue(document.setSelection(start: 1, end: 2))
        XCTAssertTrue(document.deleteSelection())
        let result = try await project.exportMedia(document, mode: .newTake)
        XCTAssertNotEqual(result.url, source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertTrue(MediaStorage.matches(result.revision, url: result.url))
    }

    func testSampleMediaUsesTheSameRevisionAuthority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(SonovoTestFixtures.bundle.url(forResource: "vo-take-02", withExtension: "wav", subdirectory: "Fixtures"))
        let support = ProjectUXTestSupport()
        defer { support.tearDown() }
        let project = Project.demo(production: .sample, markdown: .init(readsDemoEnvironment: false),
            subtitles: .init(readsDemoEnvironment: false), models: .init(opensDemoModel: false),
            terminalSessions: .init(workingDirectory: "~", terminalEnvironment: .disabled),
            sampleDocuments: SampleProjectDocuments(sourceDirectory: fixture.deletingLastPathComponent(), destinationDirectory: root))
        defer { project.prepareForTermination() }
        let asset = try XCTUnwrap(project.sampleAudioAsset(for: "vo-take-02"))
        XCTAssertEqual(asset.revision, MediaStorage.revision(for: asset.url))
        XCTAssertTrue(MediaStorage.matches(asset.revision, url: asset.url))
    }
}
