import XCTest
@testable import SonovoDocumentSupport

@MainActor final class OnceContinuationTests: XCTestCase {
    func testCompletionAndTimeoutCannotResumeTheSameContinuationTwice() async throws {
        let box = OnceContinuation<Int>()
        let value: Int = try await withCheckedThrowingContinuation { continuation in
            box.install(continuation)
            XCTAssertTrue(box.resume(returning: 42))
            XCTAssertFalse(box.resume(throwing: CancellationError()))
            XCTAssertFalse(box.resume(returning: 0))
        }
        XCTAssertEqual(value, 42)
    }
}
