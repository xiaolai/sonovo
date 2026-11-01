import XCTest
import SonovoDomainTypes
@testable import SonovoWorkspaceHost

final class RecognitionPrecedenceTests: XCTestCase {
    private let json = DocumentProviderDescriptor(
        id: "test.json", featureID: "test.code", kind: .code,
        selectors: [.fileExtension("json")]
    )
    private let timeline = DocumentProviderDescriptor(
        id: "test.timeline", featureID: "test.timeline", kind: .timeline,
        selectors: [.fileSuffix(".timeline.json")], overrides: ["test.json"]
    )

    func testDeclaredOverrideIsIndependentOfRegistrationOrder() throws {
        for descriptors in [[json, timeline], [timeline, json]] {
            let catalogue = try DocumentRecognitionCatalogue(descriptors)
            XCTAssertEqual(catalogue.resolve("Edit.TIMELINE.JSON")?.id, "test.timeline")
            XCTAssertEqual(catalogue.resolve("other.json")?.id, "test.json")
            XCTAssertNil(catalogue.resolve("unrecognized.xyz"))
        }
    }

    func testUndeclaredOverlapAndDuplicateProviderIDsAreAssemblyErrors() {
        let duplicate = DocumentProviderDescriptor(
            id: "test.other", featureID: "test.other", kind: .other,
            selectors: [.fileExtension("JSON")]
        )
        XCTAssertThrowsError(try DocumentRecognitionCatalogue([json, duplicate]))
        XCTAssertThrowsError(try DocumentRecognitionCatalogue([json, json]))
    }

    func testMalformedMetadataUnknownOverrideAndOverrideCycleAreRejected() {
        let invalid = DocumentProviderDescriptor(id: "invalid", featureID: "test.feature", kind: .other, selectors: [])
        XCTAssertThrowsError(try DocumentRecognitionCatalogue([invalid]))
        XCTAssertThrowsError(try DocumentRecognitionCatalogue([timeline]))
        let first = DocumentProviderDescriptor(id: "test.one", featureID: "test.feature", kind: .other,
                                              selectors: [.fileExtension("a")], overrides: ["test.two"])
        let second = DocumentProviderDescriptor(id: "test.two", featureID: "test.feature", kind: .other,
                                               selectors: [.fileExtension("a")], overrides: ["test.one"])
        XCTAssertThrowsError(try DocumentRecognitionCatalogue([first, second]))
    }

    func testCatalogueCanBeReadOffMainActorWithoutCreatingSessions() async throws {
        let catalogue = try DocumentRecognitionCatalogue([json, timeline])
        let count = await Task.detached {
            (0..<10_000).filter { catalogue.resolve("file\($0).timeline.json")?.id == "test.timeline" }.count
        }.value
        XCTAssertEqual(count, 10_000)
    }
}
