import Foundation
import XCTest
import SonovoDomainTypes
import SonovoFeatureAPI
@testable import SonovoWorkspaceHost

final class ScannerRevisionFallbackTests: XCTestCase {
    func testFailedFreshRevisionProbeKeepsEnumeratedFileWithoutPartialMerge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.custom")
        try Data("fixture".utf8).write(to: file)
        let catalogue = try DocumentRecognitionCatalogue([DocumentProviderDescriptor(
            id: "test.custom.editor", featureID: "test.custom", kind: .other, selectors: [.fileExtension("custom")])])
        let scan = ProjectScanner(catalogue: catalogue, readRevision: { _ in nil }).scan(root: root)
        XCTAssertFalse(scan.isPartial)
        let asset = try XCTUnwrap(scan.assets.first)
        XCTAssertEqual(asset.name, "fixture.custom")
        XCTAssertEqual(asset.size, 7)
        XCTAssertNotNil(asset.revision.fileIdentifier)
        XCTAssertNotNil(asset.modified)
    }
}
