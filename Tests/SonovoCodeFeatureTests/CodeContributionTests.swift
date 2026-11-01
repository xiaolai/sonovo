import Foundation
import Observation
import XCTest
import SonovoFeatureAPI
@testable import SonovoCodeFeature

@MainActor final class CodeContributionTests: XCTestCase {
    func testContributionObservesTheRealCodeDirtyState() async throws {
        let support = CodeTestSupport()
        defer { support.tearDown() }
        let root = try support.makeRoot(files: ["a.swift": Data("let a = 1\n".utf8)])
        let workspace = CodeWorkspace(readsDemoEnvironment: false)
        defer { workspace.prepareForTermination() }
        let document = try XCTUnwrap(workspace.open(url: root.appendingPathComponent("a.swift")))
        for _ in 0..<200 {
            if document.isReady { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(document.isReady)
        let contribution = CodeFeature.documentWorkspace(workspace)
        let witness = ObservationWitness()
        withObservationTracking {
            XCTAssertFalse(contribution.hasDirtyDocuments)
        } onChange: { witness.mark() }
        try document.replaceSource("let a = 2\n")
        XCTAssertTrue(witness.wasMarked)
        XCTAssertTrue(contribution.hasDirtyDocuments)
        XCTAssertEqual(contribution.selectedDocument?.id, document.id)
    }
}
private final class ObservationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    func mark() { lock.lock(); marked = true; lock.unlock() }
    var wasMarked: Bool { lock.lock(); defer { lock.unlock() }; return marked }
}
