import SonovoTestFixtures
import XCTest
import Foundation
import SonovoDomainTypes
import SonovoFeatureAPI
import SonovoWorkspaceHost
import SonovoViewerFeature
@testable import Sonovo

final class BuiltInRecognitionTests: XCTestCase {
    private struct Row: Decodable { let name: String; let kind: String }
    func testCapturedLegacyCorpusAndRegistrationPermutations() throws {
        let url = try XCTUnwrap(SonovoTestFixtures.bundle.url(forResource: "document-recognition", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: url))
        for descriptors in [BuiltInFeatureComposition.descriptors, BuiltInFeatureComposition.descriptors.reversed()] {
            let catalogue = try DocumentRecognitionCatalogue(Array(descriptors))
            for row in rows {
                XCTAssertEqual(catalogue.resolve(row.name)?.kind.rawValue ?? "nil", row.kind, row.name)
                XCTAssertEqual(ProjectScanner.kind(forFilename: row.name)?.rawValue ?? "nil", row.kind, row.name)
            }
        }
    }
    @MainActor func testOmittingViewerFactoryRetainsRecognitionAndLegacyPreferences() throws {
        let registry = try FeatureEditorRegistry(catalogue: BuiltInFeatureComposition.catalogue, contributions: [])
        let provider = try XCTUnwrap(registry.catalogue.resolve("image.svg"))
        XCTAssertEqual(provider.kind, .image)
        XCTAssertEqual(provider.featureID, ViewerFeature.id)
        XCTAssertNil(registry.contribution(for: provider.id))
    }
    func testTenThousandRecognitionsArePureMetadata() {
        let catalogue = BuiltInFeatureComposition.catalogue
        for index in 0..<10_000 {
            XCTAssertEqual(catalogue.resolve("file-\(index).swift")?.kind, .code)
        }
    }
    func testSpecialFilenameCaseAndPrefixPrecedence() {
        let catalogue = BuiltInFeatureComposition.catalogue
        XCTAssertEqual(catalogue.resolve("Makefile")?.kind, .code)
        XCTAssertNil(catalogue.resolve("MAKEFILE"))
        XCTAssertNil(catalogue.resolve("dockerfile"))
        XCTAssertEqual(catalogue.resolve("Dockerfile.md")?.kind, .code)
        XCTAssertEqual(catalogue.resolve("Dockerfile.jsx")?.kind, .mdx)
        XCTAssertEqual(catalogue.resolve("Dockerfile.timeline.json")?.kind, .timeline)
    }
}
