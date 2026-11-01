import Foundation
import XCTest
@testable import SonovoDocumentSupport

@MainActor
final class DestinationLeaseTests: XCTestCase {
    func testUncertainWriteRetainsLeaseUntilDefinitiveCompletion() throws {
        let registry = DestinationLeaseRegistry(isPathOwned: { _, _ in false })
        let path = "/fixture/destination.swift"
        let first = try XCTUnwrap(registry.reserve(path, owner: UUID()))
        registry.finish(first, outcome: .uncertain)
        XCTAssertTrue(registry.contains(path))
        XCTAssertNil(registry.reserve(path, owner: UUID()))
        registry.finish(first, outcome: .completed)
        XCTAssertFalse(registry.contains(path))
    }

    func testStaleCompletionCannotReleaseNewLeaseEvenForTheSameDocument() throws {
        let registry = DestinationLeaseRegistry(isPathOwned: { _, _ in false })
        let owner = UUID()
        let first = try XCTUnwrap(registry.reserve("/fixture/a.md", owner: owner))
        registry.finish(first, outcome: .completed)
        let second = try XCTUnwrap(registry.reserve("/fixture/a.md", owner: owner))
        XCTAssertNotEqual(first, second)
        registry.finish(first, outcome: .completed)
        XCTAssertTrue(registry.contains("/fixture/a.md"))
        registry.finish(second, outcome: .completed)
        XCTAssertFalse(registry.contains("/fixture/a.md"))
    }

    func testExistingOtherDocumentOwnershipRefusesReservation() {
        let other = UUID()
        let registry = DestinationLeaseRegistry(isPathOwned: { path, owner in
            path == "/fixture/a.md" && owner != other
        })
        XCTAssertNil(registry.reserve("/fixture/a.md", owner: UUID()))
        XCTAssertNotNil(registry.reserve("/fixture/a.md", owner: other))
    }
}
