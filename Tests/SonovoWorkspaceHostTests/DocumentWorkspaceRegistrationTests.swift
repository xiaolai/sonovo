import XCTest
import SonovoDomainTypes
import SonovoFeatureAPI
@testable import SonovoWorkspaceHost

@MainActor final class DocumentWorkspaceRegistrationTests: XCTestCase {
    private func adapter(_ name: FeatureID, kind: AssetKind = .other) -> DocumentWorkspaceAdapter {
        DocumentWorkspaceAdapter(featureID: name, kind: kind, documents: { [] }, selected: { nil }, open: { _ in })
    }
    func testFeatureIdentityIsIndependentOfLegacyCategoryAndOrder() throws {
        let first = adapter("test.first"), second = adapter("test.second")
        for entries in [[first, second], [second, first]] {
            let registry = try DocumentWorkspaceRegistry(entries)
            XCTAssertTrue(registry.adapter(for: FeatureID(rawValue: "test.first")) === first)
            XCTAssertTrue(registry.adapter(for: FeatureID(rawValue: "test.second")) === second)
            XCTAssertNil(registry.adapter(for: AssetKind.other))
            let mapped = try DocumentWorkspaceRegistry(entries, legacyDefaults: [.other: "test.second"])
            XCTAssertTrue(mapped.adapter(for: AssetKind.other) === second)
        }
    }
    func testDuplicateIdentityAndInvalidCompatibilityMappingAreRejected() throws {
        let first = adapter("test.first")
        XCTAssertThrowsError(try DocumentWorkspaceRegistry([first, first]))
        XCTAssertThrowsError(try DocumentWorkspaceRegistry([adapter(FeatureID(rawValue: "invalid"))]))
        XCTAssertThrowsError(try DocumentWorkspaceRegistry([first], legacyDefaults: [.code: "test.first"]))
        XCTAssertThrowsError(try DocumentWorkspaceRegistry([first], legacyDefaults: [.other: "test.missing"]))
    }
}
