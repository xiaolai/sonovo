import Foundation

// MARK: - Resumable continuation

/// A continuation that can be resumed from either the completion handler or
/// the timeout task, at most once. Both callers run on the main actor.
@MainActor
package final class OnceContinuation<Value: Sendable> {
    package init() {}
    private var continuation: CheckedContinuation<Value, Error>?

    package func install(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    package func resume(returning value: Value) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    package func resume(throwing error: Error) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(throwing: error)
        return true
    }
}
