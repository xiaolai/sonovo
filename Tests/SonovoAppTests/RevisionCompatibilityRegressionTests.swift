import AVFoundation
import CoreMedia
import Darwin
import Foundation
import XCTest
import SonovoDomainTypes
import SonovoFileIO
import SonovoMediaEngine
import SonovoTimelineFeature
import SonovoWorkspaceHost
import SonovoTestFixtures
@testable import Sonovo

@MainActor final class RevisionCompatibilityRegressionTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // This is the released scanner's persisted identity contract, deliberately
    // independent of AssetRevision.read so an incompatible migration is caught.
    private func releasedRevision(_ url: URL) throws -> AssetRevision {
        let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey])
        return AssetRevision(fileIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
                             size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
    }

    func testReleasedTimelineJSONStillBuildsAgainstTheCurrentScanner() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("voice.wav")
        let fixture = try XCTUnwrap(SonovoTestFixtures.bundle.url(forResource: "vo-take-02", withExtension: "wav", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: source)
        let revision = try releasedRevision(source)
        let oldAsset = ProjectAsset(id: source.path, url: source, name: "voice.wav", relativePath: "voice.wav", kind: .audio,
                                    size: revision.size, modified: revision.modified, revision: revision)
        for fingerprint in [nil, try TimelineAssetProbe.fingerprint(for: source)] {
            var original = ProjectTimeline(name: "Released timeline")
            try original.addClip(asset: oldAsset, track: .voice, at: .zero,
                                 duration: CMTime(seconds: 1, preferredTimescale: 600_000), sourceFingerprint: fingerprint)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(original)
            let timeline = try JSONDecoder().decode(ProjectTimeline.self, from: data)
            let scan = ProjectScanner().scan(root: directory)
            XCTAssertTrue(timeline.sourceIssues(assets: scan.assets).isEmpty)
            let built = try await ProjectTimelineCompositionBuilder.build(timeline: timeline, assets: scan.assets)
            XCTAssertEqual(built.duration.seconds, 1, accuracy: 0.001)
            XCTAssertEqual(try encoder.encode(timeline), data, "opening must not rewrite persisted revision tokens")
        }
    }

    func testMetadataOnlyChangesKeepScannedIdentityAndMediaEditState() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("voice.wav")
        try Data([1, 2, 3]).write(to: source)
        let before = try XCTUnwrap(ProjectScanner().scan(root: directory).assets.first)
        let edit = MediaEditDocument(asset: before)
        edit.prepare(sourceDuration: 3)
        XCTAssertTrue(edit.setSelection(start: 1, end: 2))
        let bytes = Array("test-tag".utf8)
        XCTAssertEqual(bytes.withUnsafeBytes { setxattr(source.path, "com.sonovo.revision-test", $0.baseAddress, $0.count, 0, 0) }, 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        let after = try XCTUnwrap(ProjectScanner().scan(root: directory).assets.first)
        XCTAssertEqual(before.revision.token, after.revision.token)
        XCTAssertEqual(before.revision, after.revision)
        XCTAssertEqual(Set([before.revision, after.revision]).count, 1)
        edit.observe(asset: after)
        XCTAssertFalse(edit.isStale)
        XCTAssertEqual(edit.selection?.start, 1)
    }

    func testStrongMediaCheckStillRejectsSameSizeSameMtimeInPlaceRewrite() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("voice.wav")
        try Data([1, 2, 3]).write(to: source)
        let expected = try XCTUnwrap(MediaStorage.revision(for: source))
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date)
        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: Data([3, 2, 1])); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
        XCTAssertFalse(MediaStorage.matches(expected, url: source))
    }
}
