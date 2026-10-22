import Foundation
import XCTest
@testable import Sonovo

@MainActor
final class CodeAutosaveTests: XCTestCase {
    private enum FakeFailure: Error {
        case failed
    }

    @MainActor
    private final class FakeDocument: Autosaveable {
        let id = UUID()
        var hasUnresolvedConflict = false
        var isDirty = true
        var attempts = 0
        var shouldSucceed = false

        func autosaveDelay(now: Date) -> TimeInterval? { 0 }

        func autosave() async throws {
            attempts += 1
            guard shouldSucceed else { throw FakeFailure.failed }
            isDirty = false
        }

        func isClosedError(_ error: Error) -> Bool { false }
    }

    func testAutosaveBacksOffAndRetriesAfterAFailure() async throws {
        let document = FakeDocument()
        var errors: [String] = []
        let driver = AutosaveDriver<FakeDocument>(
            tick: .milliseconds(20),
            documents: { [document] },
            reportsError: { errors.append($0) }
        )
        driver.start()
        defer { driver.forget(document.id) }

        // The first attempt fails; the driver must report it and not hammer
        // the same failing write every tick.
        let firstFailure = await waitUntil {
            document.attempts == 1 && !errors.isEmpty
        }
        XCTAssertTrue(firstFailure)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(
            document.attempts,
            1,
            "the failing write must back off, not retry every tick"
        )

        // The backoff is two seconds; after it expires the write is retried.
        document.shouldSucceed = true
        let retried = await waitUntil(timeout: 4) {
            document.attempts >= 2 && !document.isDirty
        }
        XCTAssertTrue(retried)
        XCTAssertGreaterThanOrEqual(document.attempts, 2)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
