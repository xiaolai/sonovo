import Foundation

package struct DestinationLease: Equatable {

    package init(
        path: String,
        owner: UUID,
        operationID: UUID
    ) {
        self.path = path
        self.owner = owner
        self.operationID = operationID
    }

    package let path: String
    package let owner: UUID
    fileprivate let operationID: UUID
}

package enum DestinationWriteOutcome {
    case completed
    case uncertain
}

/// No timer, project teardown or cancellation automatically releases a lease.
/// Only a matching operation's definitive write outcome may do so.
@MainActor
package final class DestinationLeaseRegistry {
    private var leases: [String: DestinationLease] = [:]
    private let isPathOwned: (String, UUID) -> Bool

    package init(isPathOwned: @escaping (String, UUID) -> Bool) {
        self.isPathOwned = isPathOwned
    }

    package func reserve(_ path: String, owner: UUID) -> DestinationLease? {
        guard !isPathOwned(path, owner) else { return nil }
        if let existing = leases[path] {
            return existing.owner == owner ? existing : nil
        }
        let lease = DestinationLease(path: path, owner: owner, operationID: UUID())
        leases[path] = lease
        return lease
    }

    package func contains(_ path: String) -> Bool { leases[path] != nil }

    package func finish(_ lease: DestinationLease, outcome: DestinationWriteOutcome) {
        guard leases[lease.path] == lease else { return }
        switch outcome {
        case .uncertain:
            break
        case .completed:
            leases.removeValue(forKey: lease.path)
        }
    }
}
