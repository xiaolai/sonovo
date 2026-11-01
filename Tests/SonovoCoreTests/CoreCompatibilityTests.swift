import Foundation
import XCTest
import SonovoCore

final class CoreCompatibilityTests: XCTestCase {
    func testLegacyInitializerPreservesAtomicStoreOptions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("captions.srt")
        let original = Data("1\n00:00:00,000 --> 00:00:01,000\nBefore\n".utf8)
        try original.write(to: url)
        let store = SubtitleFileStore(fileStore: MarkdownFileStore(options: FileStoreOptions(supportsAtomicSwap: false)))
        XCTAssertThrowsError(try store.save(SaveRequest(documentID: UUID(), identityGeneration: 0, sourceRevision: 0,
            destination: url, expectedDisk: DiskSnapshot(bytes: original), data: Data("changed".utf8), mode: .automatic))) {
            XCTAssertEqual($0 as? SaveError, .swapUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testLegacyStoreInitializerRemainsAvailableThroughThePublicFacade() {
        let markdown = MarkdownFileStore()
        _ = SubtitleFileStore(fileStore: markdown)
        XCTAssertEqual(SonovoCore.minimumMacOSVersion, "27.0")
    }
}
