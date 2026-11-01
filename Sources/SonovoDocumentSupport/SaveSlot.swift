import Foundation

/// A bounded, cancellation-aware mutual-exclusion slot for document saves.
///
/// The document stores used to own a bare `saveInFlight` flag and suspended
/// waiters on a checked continuation. A save that never returned therefore
/// blocked every later save, external-change check, and quit indefinitely.
/// The slot gives the wait a deadline and resumes on cancellation; the owner
/// fails closed with a visible save/close error instead of blocking.
public enum SaveSlotError: Error, Equatable, LocalizedError {
    /// The slot did not become free within `SaveSlot.waitTimeout`.
    case timedOut

    public var errorDescription: String? {
        "The document is still saving; the operation timed out."
    }
}

@MainActor
public final class SaveSlot {
    /// How long one caller waits for a save that another operation holds.
    /// Long enough for an ordinary disk write, short enough that a stalled
    /// write cannot block quit.
    public static let waitTimeout: Duration = .seconds(2)

    public private(set) var isHeld = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]

    public init() {}

    /// Acquires the slot, waiting at most `waitTimeout` in total.
    /// Throws `CancellationError` when the caller is cancelled and
    /// `SaveSlotError.timedOut` when the deadline passes.
    public func acquire() async throws {
        let deadline = ContinuousClock.now + Self.waitTimeout
        if isHeld {
            let waiter = UUID()
            let granted = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(returning: false)
                        return
                    }
                    waiters[waiter] = continuation
                    deadlines[waiter] = Task { @MainActor [weak self] in
                        let remaining = deadline - ContinuousClock.now
                        if remaining > .zero {
                            try? await Task.sleep(for: remaining)
                        }
                        guard !Task.isCancelled else { return }
                        self?.settle(waiter, granted: false)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.settle(waiter, granted: false)
                }
            }
            guard granted else {
                if Task.isCancelled { throw CancellationError() }
                throw SaveSlotError.timedOut
            }
            // `release` transferred ownership directly; `isHeld` never
            // dropped, so there is nothing to re-check and no second waiter
            // could have taken the slot.
        } else {
            isHeld = true
        }
        // Cancellation may have arrived after the release resumed us but
        // before this line; hand the slot back rather than proceed.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    public func release() {
        // Hand the slot to exactly one waiter without a free moment. Clearing
        // `isHeld` first let a third caller take the slot between the grant
        // and the grantee's resumption; the grantee then re-waited against its
        // original deadline and could time out spuriously. Ownership transfers
        // directly, so the slot is never momentarily unowned.
        guard let next = waiters.keys.first else {
            isHeld = false
            return
        }
        settle(next, granted: true)
    }

    private func settle(_ id: UUID, granted: Bool) {
        deadlines.removeValue(forKey: id)?.cancel()
        guard let continuation = waiters.removeValue(forKey: id) else {
            return
        }
        continuation.resume(returning: granted)
    }
}
