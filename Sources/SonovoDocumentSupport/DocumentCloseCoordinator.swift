/// The feature adapter supplies operations; the coordinator does not know any
/// document format, project model or UI framework.
@MainActor
package struct CloseFlushParticipant {

    package init(
        isDirty: @escaping () -> Bool,
        flush: @escaping () async -> Bool,
        revealFailure: @escaping () -> Void
    ) {
        self.isDirty = isDirty
        self.flush = flush
        self.revealFailure = revealFailure
    }

    package let isDirty: () -> Bool
    package let flush: () async -> Bool
    package let revealFailure: () -> Void
}

@MainActor
package final class DocumentCloseCoordinator {
    package init() {}

    package func flush(
        participants: () -> [CloseFlushParticipant],
        allClean: () -> Bool,
        maximumPasses: Int = 3
    ) async -> Bool {
        guard maximumPasses > 0 else { return false }
        for _ in 0..<maximumPasses {
            for participant in participants() where participant.isDirty() {
                guard await participant.flush() else {
                    participant.revealFailure()
                    return false
                }
            }
            if allClean() { return true }
        }
        return false
    }
}
