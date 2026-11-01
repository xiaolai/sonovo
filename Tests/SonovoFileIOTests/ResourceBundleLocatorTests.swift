import Foundation
import XCTest
@testable import SonovoFileIO

final class ResourceBundleLocatorTests: XCTestCase {
    func testMissingAndNonBasenameBundleNamesReturnNilWithoutTrapping() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(ResourceBundleLocator.find(named: "MissingFixture", searchRoots: [root]))
        XCTAssertNil(ResourceBundleLocator.find(named: "../outside", searchRoots: [root]))
    }

    func testExplicitRootResolvesBundleWithoutGeneratedModuleAccessor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Fixture.bundle")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleIdentifier": "test.sonovo.resources",
            "CFBundlePackageType": "BNDL"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try Data("fixture".utf8).write(to: resources.appendingPathComponent("fixture.txt"))
        let found = try XCTUnwrap(ResourceBundleLocator.find(named: "Fixture", searchRoots: [root]))
        XCTAssertNotNil(found.url(forResource: "fixture", withExtension: "txt"))
    }
}
