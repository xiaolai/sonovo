import Foundation
import Observation

// MARK: - Results and selections

enum TmuxActionOutcome: Sendable, Equatable {
    case ended
    case absent
    case skipped(reason: String)
    case refused(reason: String)
    case uncertain(reason: String)
    case notAttempted(reason: String)

    var isSuccess: Bool {
        switch self {
        case .ended, .absent: true
        default: false
        }
    }
}

struct TmuxObservedAuthorization: Sendable, Equatable {
    let process: ProcessObservation
    let sharedWindows: Bool
    let ownershipFingerprint: String
    let tier: TmuxCandidateTier

    init(
        observation: TmuxSessionObservation,
        tier: TmuxCandidateTier
    ) {
        process = observation.process
        sharedWindows = observation.sharedWindows
        ownershipFingerprint = observation.ownership.fingerprint
        self.tier = tier
    }
}

struct TmuxBulkSelection: Sendable, Equatable {
    let identity: TmuxSessionIdentity
    let name: String
    let authorization: TmuxObservedAuthorization
}

@MainActor
final class TmuxBulkCancellation {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

struct TmuxCaptureCommit: Sendable, Equatable {
    let verdict: TmuxCaptureVerdict
    let committed: Bool
    let captureID: UUID?
    let reason: String?
    var paneIDs: Set<String> = []
}

struct TmuxActionGenerations: Sendable, Equatable {
    let policy: UInt64
    let workspace: UInt64
    let boot: BootIdentity
}

// MARK: - Uncertain store

struct TmuxUncertainEntry: Codable, Equatable, Sendable {
    let socketPath: String
    let serverPID: Int
    let sessionID: String
    let name: String
    let reason: String
    let recordedAt: Date
}

struct TmuxUncertainFile: Codable, Equatable {
    var version: Int = 1
    var entries: [TmuxUncertainEntry] = []
}

@MainActor
final class TmuxUncertainStore {
    private(set) var entries: [TmuxSessionIdentity: TmuxUncertainEntry] = [:]
    private(set) var isCorrupt = false
    /// A write that failed may have lost a block. Treat the store as
    /// unreliable until a later write succeeds.
    private(set) var persistenceFailed = false
    private let url: URL?

    static func defaultURL() -> URL? {
        HygieneFile.supportDirectory()?
            .appendingPathComponent("tmux-uncertain.json")
    }

    init(url: URL? = TmuxUncertainStore.defaultURL()) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        guard let file = HygieneFile.read(TmuxUncertainFile.self, from: url),
              file.version == 1 else {
            isCorrupt = true
            return
        }
        for entry in file.entries {
            let identity = TmuxSessionIdentity(
                server: TmuxServerIdentity(
                    socketPath: entry.socketPath,
                    pid: entry.serverPID
                ),
                sessionID: entry.sessionID
            )
            entries[identity] = entry
        }
    }

    /// A corrupt store fails closed: every identity is treated as uncertain
    /// until the file is repaired or removed.
    func contains(_ identity: TmuxSessionIdentity) -> Bool {
        isCorrupt || persistenceFailed || entries[identity] != nil
    }

    func record(
        _ identity: TmuxSessionIdentity,
        name: String,
        reason: String,
        now: Date
    ) {
        entries[identity] = TmuxUncertainEntry(
            socketPath: identity.server.socketPath,
            serverPID: identity.server.pid,
            sessionID: identity.sessionID,
            name: name,
            reason: reason,
            recordedAt: now
        )
        persist()
    }

    func remove(_ identity: TmuxSessionIdentity) {
        // A corrupt store stays fail-closed. Recovering one identity cannot
        // prove the entries that were lost, so ordinary removal never clears
        // the global corruption flag.
        guard !isCorrupt else { return }
        guard entries.removeValue(forKey: identity) != nil else { return }
        persist()
    }

    private func persist() {
        // A corrupt file is the only evidence of the lost blocks. Overwriting
        // it with the empty in-memory set would unblock those identities on
        // the next launch.
        guard !isCorrupt else { return }
        guard let url else { return }
        persistenceFailed = !HygieneFile.write(
            TmuxUncertainFile(entries: Array(entries.values)),
            to: url
        )
    }
}

// MARK: - Coordinator

/// The single path for End, bulk End, capture, rename, adoption, and
/// automatic cleanup. It serializes dispatch, binds every mutation to a
/// session identity, and persists uncertainty so a possibly delivered
/// mutation can never be repeated automatically.
@MainActor
@Observable
final class TmuxActionCoordinator {
    @ObservationIgnored let transport: any TmuxHygieneServicing
    @ObservationIgnored let archive: TmuxArchiveStore?
    @ObservationIgnored let uncertainStore: TmuxUncertainStore
    @ObservationIgnored let boot: BootIdentity
    @ObservationIgnored let registry: TmuxOwnershipRegistryStore?
    @ObservationIgnored let ledger: ObservedIdleLedgerStore?
    /// Test seam for capture-and-end; nil uses the live capture and archive.
    @ObservationIgnored var captureProvider:
        (@MainActor (TmuxSessionObservation) async -> TmuxCaptureCommit)?
    @ObservationIgnored var killSwitchProvider: () -> Bool = { false }
    /// True when the archive is enabled. Automatic End then captures and
    /// commits immediately before the guarded kill.
    @ObservationIgnored var captureRequiredProvider: () -> Bool = { true }
    /// Re-reads automatic eligibility after a workspace change. The
    /// scheduler's frozen attribute may predate a project opening.
    @ObservationIgnored var automaticEligibilityProvider:
        (TmuxSessionIdentity) -> Bool = { _ in true }
    /// Test seam: runs on the main actor immediately before a dispatch.
    @ObservationIgnored var beforeDispatch: (@MainActor () -> Void)?
    /// Called after an action so the hygiene layer can invalidate an
    /// in-flight scan and request a fresh one.
    @ObservationIgnored var onActionCompleted: (@MainActor () -> Void)?

    private(set) var uncertain: Set<TmuxSessionIdentity> = []
    private(set) var lastResults: [TmuxSessionIdentity: TmuxActionOutcome] = [:]
    private(set) var lastCapture: TmuxCaptureCommit?
    private(set) var workspaceGeneration: UInt64 = 0
    private(set) var policyGeneration: UInt64 = 0

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var reservations: Set<TmuxSessionIdentity> = []

    init(
        transport: any TmuxHygieneServicing,
        boot: BootIdentity,
        archive: TmuxArchiveStore? = nil,
        uncertainStore: TmuxUncertainStore = TmuxUncertainStore(),
        registry: TmuxOwnershipRegistryStore? = nil,
        ledger: ObservedIdleLedgerStore? = nil
    ) {
        self.transport = transport
        self.boot = boot
        self.archive = archive
        self.uncertainStore = uncertainStore
        self.registry = registry
        self.ledger = ledger
        if uncertainStore.isCorrupt {
            uncertain = []
        } else {
            uncertain = Set(uncertainStore.entries.keys)
        }
    }

    var hasCorruptUncertainty: Bool {
        uncertainStore.isCorrupt || uncertainStore.persistenceFailed
    }

    var isKillSwitchEngaged: Bool { killSwitchProvider() }

    func isUncertain(_ identity: TmuxSessionIdentity) -> Bool {
        uncertain.contains(identity)
            || uncertainStore.isCorrupt
            || uncertainStore.persistenceFailed
    }

    func isUncertain(name: String) -> Bool {
        uncertainStore.isCorrupt
            || uncertainStore.persistenceFailed
            || uncertainStore.entries.values.contains { $0.name == name }
    }

    func invalidateWorkspace() {
        workspaceGeneration &+= 1
    }

    func invalidatePolicy() {
        policyGeneration &+= 1
    }

    /// Explicit reconciliation by session id. Nothing else clears a block.
    func reconcile(_ identity: TmuxSessionIdentity) {
        uncertainStore.remove(identity)
        uncertain.remove(identity)
    }

    // MARK: Serial queue

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private var currentGenerations: TmuxActionGenerations {
        TmuxActionGenerations(
            policy: policyGeneration,
            workspace: workspaceGeneration,
            boot: boot
        )
    }

    private func stillValid(_ captured: TmuxActionGenerations) -> Bool {
        captured == currentGenerations
    }

    // MARK: Snapshots

    private func freshSnapshot() async -> TmuxSnapshot {
        let transport = transport
        let boot = boot
        let registry = registry?.snapshotForTransport() ?? [:]
        let now = Date()
        return await Task.detached(priority: .userInitiated) {
            transport.snapshot(now: now, boot: boot, registry: registry)
        }.value
    }

    // MARK: Manual End (tab context menu and Sessions window row)

    /// Ends one named Sonovo session. Manual End is explicit, so an attached
    /// or busy session is allowed; the guarded identity checks still apply.
    func endSession(named name: String) async -> TmuxActionOutcome {
        let captured = currentGenerations
        await acquire()
        defer { release() }
        guard stillValid(captured) else {
            return .skipped(
                reason: "Workspace or settings changed while queued."
            )
        }
        guard transport.isAvailable else {
            return .uncertain(reason: "tmux is unavailable.")
        }
        guard TmuxNaming.parsesSessionName(name) else {
            return .refused(reason: "The session name is not a Sonovo name.")
        }
        let snapshot = await freshSnapshot()
        guard stillValid(captured) else {
            return .skipped(reason: "Workspace or settings changed.")
        }
        guard let observation = snapshot.session(named: name) else {
            return snapshot.completeness.isComplete
                ? .absent
                : .uncertain(
                    reason: "The session could not be verified absent."
                )
        }
        let outcome = await kill(
            observation,
            generations: captured
        )
        record(outcome, for: observation)
        onActionCompleted?()
        return outcome
    }

    /// Ends the exact session identified before confirmation. A name reused
    /// by another session is skipped, never killed.
    func end(
        identity: TmuxSessionIdentity,
        name: String
    ) async -> TmuxActionOutcome {
        let captured = currentGenerations
        await acquire()
        defer { release() }
        guard stillValid(captured) else {
            return .skipped(
                reason: "Workspace or settings changed while queued."
            )
        }
        guard transport.isAvailable else {
            return .uncertain(reason: "tmux is unavailable.")
        }
        let snapshot = await freshSnapshot()
        guard stillValid(captured) else {
            return .skipped(reason: "Workspace or settings changed.")
        }
        if let current = snapshot.session(named: name) {
            guard current.identity == identity else {
                return .skipped(
                    reason: "The name now belongs to a different session."
                )
            }
            let outcome = await kill(current, generations: captured)
            record(outcome, for: current)
            onActionCompleted?()
            return outcome
        }
        if let current = snapshot.session(identity) {
            return .skipped(
                reason: "The session was renamed to \(current.name)."
            )
        }
        return absenceOutcome(snapshot)
    }

    /// Ends one observed session from the Sessions window.
    func end(
        attribute: TmuxSessionAttributes
    ) async -> TmuxActionOutcome {
        let captured = currentGenerations
        await acquire()
        defer { release() }
        guard stillValid(captured) else {
            return .skipped(
                reason: "Workspace or settings changed while queued."
            )
        }
        guard transport.isAvailable else {
            return .uncertain(reason: "tmux is unavailable.")
        }
        let snapshot = await freshSnapshot()
        guard stillValid(captured) else {
            return .skipped(reason: "Workspace or settings changed.")
        }
        guard let current = snapshot.session(attribute.identity) else {
            return absenceOutcome(snapshot)
        }
        let outcome = await kill(current, generations: captured)
        record(outcome, for: current)
        onActionCompleted?()
        return outcome
    }

    // MARK: Bulk End

    /// The complete transition matrix. Every selected row yields exactly one
    /// typed result; the run stops at uncertain or transport failure, and a
    /// row that changed since selection is skipped rather than mutated.
    func endBulk(
        selections: [TmuxBulkSelection],
        cancellation: TmuxBulkCancellation
    ) async -> [TmuxSessionIdentity: TmuxActionOutcome] {
        let captured = currentGenerations
        await acquire()
        defer { release() }
        var results: [TmuxSessionIdentity: TmuxActionOutcome] = [:]
        defer {
            lastResults = results
            reservations.subtract(selections.map(\.identity))
            onActionCompleted?()
        }
        if let failure = await bulkPreflight(captured: captured) {
            for selection in selections {
                results[selection.identity] = failure
            }
            return results
        }

        var stop = false
        for selection in selections {
            if stop {
                results[selection.identity] = .notAttempted(
                    reason: "An earlier row stopped the run."
                )
                continue
            }
            let result = await runBulkRow(
                selection,
                captured: captured,
                cancellation: cancellation
            )
            results[selection.identity] = result.outcome
            stop = stop || result.stopsRun
        }
        return results
    }

    /// The run-level checks: generations and the pre-run scan. A row still
    /// revalidates itself immediately before dispatch.
    private func bulkPreflight(
        captured: TmuxActionGenerations
    ) async -> TmuxActionOutcome? {
        guard stillValid(captured) else {
            return .notAttempted(
                reason: "Workspace or settings changed while queued."
            )
        }
        let snapshot = await freshSnapshot()
        guard snapshot.completeness.isComplete else {
            return .notAttempted(
                reason: snapshot.completeness.reason
                    ?? "The pre-run scan was not complete."
            )
        }
        guard stillValid(captured) else {
            return .notAttempted(reason: "Workspace or settings changed.")
        }
        return nil
    }

    private struct BulkRowResult {
        let outcome: TmuxActionOutcome
        let stopsRun: Bool
    }

    private func runBulkRow(
        _ selection: TmuxBulkSelection,
        captured: TmuxActionGenerations,
        cancellation: TmuxBulkCancellation
    ) async -> BulkRowResult {
        if cancellation.isCancelled {
            return BulkRowResult(
                outcome: .notAttempted(reason: "The run was cancelled."),
                stopsRun: true
            )
        }
        guard stillValid(captured) else {
            return BulkRowResult(
                outcome: .skipped(reason: "Workspace or settings changed."),
                stopsRun: true
            )
        }
        guard !reservations.contains(selection.identity) else {
            return BulkRowResult(
                outcome: .skipped(reason: "Another action is in progress."),
                stopsRun: false
            )
        }
        reservations.insert(selection.identity)

        // Re-observe this row immediately before its mutation. The pre-run
        // scan authorized the run; this scan authorizes the row.
        let snapshot = await freshSnapshot()
        if cancellation.isCancelled {
            return BulkRowResult(
                outcome: .notAttempted(reason: "The run was cancelled."),
                stopsRun: true
            )
        }
        guard stillValid(captured) else {
            return BulkRowResult(
                outcome: .skipped(reason: "Workspace or settings changed."),
                stopsRun: true
            )
        }
        guard snapshot.completeness.isComplete else {
            return BulkRowResult(
                outcome: .notAttempted(
                    reason: "The row rescan was not complete."
                ),
                stopsRun: true
            )
        }
        guard let current = snapshot.session(selection.identity) else {
            applyOutcome(
                .absent,
                identity: selection.identity,
                name: selection.name
            )
            return BulkRowResult(outcome: .absent, stopsRun: false)
        }
        if let failure = validationFailure(
            for: selection,
            current: current
        ) {
            return BulkRowResult(outcome: failure, stopsRun: false)
        }
        let outcome = await kill(current, generations: captured)
        applyOutcome(
            outcome,
            identity: current.identity,
            name: current.name
        )
        let stopsRun: Bool
        switch outcome {
        case .uncertain, .notAttempted:
            stopsRun = true
        case .ended, .absent, .skipped, .refused:
            stopsRun = false
        }
        return BulkRowResult(outcome: outcome, stopsRun: stopsRun)
    }

    // MARK: Capture and End

    func captureAndEnd(
        attribute: TmuxSessionAttributes,
        acknowledgedIncomplete: Bool
    ) async -> TmuxActionOutcome {
        let captured = currentGenerations
        await acquire()
        defer { release() }
        guard stillValid(captured) else {
            return .skipped(
                reason: "Workspace or settings changed while queued."
            )
        }
        lastCapture = nil
        guard transport.isAvailable else {
            return .uncertain(reason: "tmux is unavailable.")
        }
        let snapshot = await freshSnapshot()
        guard stillValid(captured) else {
            return .skipped(reason: "Workspace or settings changed.")
        }
        guard let current = snapshot.session(attribute.identity) else {
            return absenceOutcome(snapshot)
        }
        let commit: TmuxCaptureCommit
        if let captureProvider {
            commit = await captureProvider(current)
        } else {
            commit = await defaultCaptureAndCommit(current)
        }
        lastCapture = commit
        if !(commit.committed && commit.verdict == .complete),
           !acknowledgedIncomplete {
            return .skipped(
                reason: "The capture was not committed complete."
            )
        }
        let outcome = await kill(current, generations: captured)
        record(outcome, for: current)
        onActionCompleted?()
        return outcome
    }

    private func defaultCaptureAndCommit(
        _ observation: TmuxSessionObservation
    ) async -> TmuxCaptureCommit {
        guard let archive, archive.isEnabled else {
            return TmuxCaptureCommit(
                verdict: .failed,
                committed: false,
                captureID: nil,
                reason: "The archive is off."
            )
        }
        let transport = transport
        let identity = observation.identity
        let panes = await Task.detached(priority: .userInitiated) {
            transport.panes(for: identity)
        }.value
        guard let panes, !panes.isEmpty else {
            return TmuxCaptureCommit(
                verdict: .failed,
                committed: false,
                captureID: nil,
                reason: "The pane list could not be read."
            )
        }
        let request = TmuxCaptureRequest(
            identity: observation.identity,
            panes: panes.map(\.address),
            maxBytes: TmuxCaptureBudget.maxBytes,
            maxLines: TmuxCaptureBudget.maxLines,
            maxPanes: TmuxCaptureBudget.maxPanes,
            deadline: Date().addingTimeInterval(
                TmuxCaptureBudget.timeout
            )
        )
        let capture = await Task.detached(priority: .userInitiated) {
            transport.capture(request)
        }.value
        let metadata = TmuxCaptureMetadata(
            captureID: UUID(),
            session: observation.identity,
            sessionName: observation.name,
            ownershipPath: observation.ownership.verifiedProjectPath,
            ownershipFingerprint: observation.ownership.fingerprint,
            capturedAt: Date(),
            reason: .captureAndEnd,
            paneLabels: panes.map(\.label),
            truncated: capture.verdict == .truncated,
            contentOutcome: capture.verdict,
            byteCount: capture.totalBytes
        )
        let result = await Task.detached(priority: .userInitiated) {
            archive.commit(metadata: metadata, capture: capture)
        }.value
        return TmuxCaptureCommit(
            verdict: capture.verdict,
            committed: result.isCommitted,
            captureID: metadata.captureID,
            reason: result.reason,
            paneIDs: Set(panes.map(\.paneID))
        )
    }

    // MARK: Automatic End

    func performAutomaticEnd(
        attribute: TmuxSessionAttributes
    ) async -> TmuxActionOutcome {
        let captured = currentGenerations
        await acquire()
        defer { release() }
        guard !Task.isCancelled else {
            return .notAttempted(reason: "The run was cancelled.")
        }
        guard stillValid(captured) else {
            return .skipped(
                reason: "Workspace or settings changed while queued."
            )
        }
        guard !killSwitchProvider() else {
            return .refused(reason: "The kill switch is engaged.")
        }
        guard !isUncertain(attribute.identity) else {
            return .refused(reason: "The session has an unresolved action.")
        }
        guard attribute.autoEligibility.eligible,
              automaticEligibilityProvider(attribute.identity) else {
            return .refused(
                reason: attribute.autoEligibility.reasons
                    .joined(separator: " ")
            )
        }
        let fresh = await freshSnapshot()
        guard stillValid(captured) else {
            return .skipped(reason: "Settings or workspace changed.")
        }
        guard fresh.completeness.isComplete else {
            return .skipped(reason: "The dispatch rescan was incomplete.")
        }
        guard let current = fresh.session(attribute.identity) else {
            return .absent
        }
        guard current.attachedClients == 0,
              !current.sharedWindows,
              current.process == .noCommandDetected,
              current.ownership.fingerprint
                == attribute.observation.ownership.fingerprint else {
            return .skipped(reason: "The session changed since the scan.")
        }
        let observationBeforeCapture = current
        var expectedPaneIDs: Set<String> = []
        if captureRequiredProvider() {
            let commit: TmuxCaptureCommit
            if let captureProvider {
                commit = await captureProvider(current)
            } else {
                commit = await defaultCaptureAndCommit(current)
            }
            lastCapture = commit
            expectedPaneIDs = commit.paneIDs
            guard commit.committed, commit.verdict == .complete else {
                return .refused(
                    reason: "Automatic End requires a committed complete capture."
                )
            }
        }
        guard !Task.isCancelled else {
            return .notAttempted(reason: "The run was cancelled.")
        }
        guard !killSwitchProvider() else {
            return .refused(
                reason: "Automatic dispatch was disarmed during capture."
            )
        }
        // Capture can take seconds. Revalidate the process and pane
        // inventory before the kill; the guarded command checks identity,
        // attachment, and window count, not foreground work.
        let after = await freshSnapshot()
        guard stillValid(captured) else {
            return .skipped(reason: "Settings or workspace changed.")
        }
        guard after.completeness.isComplete else {
            return .skipped(reason: "The post-capture scan was incomplete.")
        }
        guard let refreshed = after.session(attribute.identity),
              refreshed.attachedClients == 0,
              !refreshed.sharedWindows,
              refreshed.process == .noCommandDetected,
              refreshed.windows == observationBeforeCapture.windows,
              refreshed.paneCount == observationBeforeCapture.paneCount,
              refreshed.ownership.fingerprint
                == attribute.observation.ownership.fingerprint else {
            return .skipped(reason: "The session changed during capture.")
        }
        if !expectedPaneIDs.isEmpty {
            let transport = transport
            let panes = await Task.detached(priority: .userInitiated) {
                transport.panes(for: attribute.identity)
            }.value
            guard let panes,
                  Set(panes.map(\.paneID)) == expectedPaneIDs else {
                return .skipped(
                    reason: "The pane inventory changed during capture."
                )
            }
        }
        let outcome = await kill(refreshed, generations: captured)
        record(outcome, for: current)
        onActionCompleted?()
        return outcome
    }

    // MARK: Rename / adoption

    func rename(
        observation: TmuxSessionObservation,
        newName: String,
        newProjectPath: String
    ) async -> TmuxRenameOutcome {
        let captured = currentGenerations
        await acquire()
        defer { release() }
        guard stillValid(captured) else {
            return .skipped(
                reason: "Workspace or settings changed while queued."
            )
        }
        guard transport.isAvailable else {
            return .uncertain(reason: "tmux is unavailable.")
        }
        let snapshot = await freshSnapshot()
        guard stillValid(captured) else {
            return .skipped(reason: "Workspace or settings changed.")
        }
        guard snapshot.completeness.isComplete else {
            return .skipped(reason: "The rename rescan was incomplete.")
        }
        guard let current = snapshot.session(observation.identity) else {
            return .absent
        }
        guard current.name == observation.name else {
            return .skipped(reason: "The session was renamed elsewhere.")
        }
        guard current.attachedClients == 0 else {
            return .skipped(reason: "The session became attached.")
        }
        guard !current.sharedWindows else {
            return .skipped(reason: "The session gained a shared window.")
        }
        guard current.ownership.fingerprint
                == observation.ownership.fingerprint else {
            return .skipped(reason: "The session ownership changed.")
        }
        guard !isUncertain(current.identity) else {
            return .skipped(
                reason: "The session has an unresolved action."
            )
        }
        let transport = transport
        let request = TmuxGuardedRename(
            identity: current.identity,
            currentName: current.name,
            newName: newName,
            newProjectPath: newProjectPath
        )
        let outcome = await Task.detached(priority: .userInitiated) {
            transport.guardedRename(request)
        }.value
        if case let .uncertain(reason) = outcome {
            uncertainStore.record(
                current.identity,
                name: current.name,
                reason: reason,
                now: Date()
            )
            uncertain.insert(current.identity)
        }
        onActionCompleted?()
        if case .renamed = outcome {
            let newIdentity = TmuxSessionIdentity(
                server: current.identity.server,
                sessionID: current.identity.sessionID
            )
            registry?.update(
                identity: newIdentity,
                projectPath: newProjectPath
            )
            ledger?.updateOwnership(
                identity: newIdentity,
                projectPath: newProjectPath
            )
            uncertainStore.remove(current.identity)
            uncertain.remove(current.identity)
        }
        return outcome
    }

    // MARK: Mutation

    /// Carries the parent task's cancellation into a detached transport call.
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func set() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private func kill(
        _ observation: TmuxSessionObservation,
        generations: TmuxActionGenerations
    ) async -> TmuxActionOutcome {
        guard !Task.isCancelled else {
            return .notAttempted(reason: "The action was cancelled.")
        }
        guard stillValid(generations) else {
            return .skipped(reason: "Settings or workspace changed.")
        }
        beforeDispatch?()
        let request = TmuxGuardedKill(
            identity: observation.identity,
            name: observation.name,
            expectedAttachedClients: observation.attachedClients,
            expectedWindows: observation.windows
        )
        let transport = transport
        let flag = CancellationFlag()
        let outcome = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                transport.guardedKill(
                    request,
                    isCancelled: { flag.isCancelled }
                )
            }.value
        } onCancel: {
            flag.set()
        }
        return outcome
    }

    private func record(
        _ outcome: TmuxActionOutcome,
        for observation: TmuxSessionObservation
    ) {
        applyOutcome(
            outcome,
            identity: observation.identity,
            name: observation.name
        )
        lastResults[observation.identity] = outcome
    }

    /// One bookkeeping path for single and bulk results, so the two cannot
    /// drift on uncertainty or ledger cleanup.
    private func applyOutcome(
        _ outcome: TmuxActionOutcome,
        identity: TmuxSessionIdentity,
        name: String
    ) {
        switch outcome {
        case let .uncertain(reason):
            uncertainStore.record(
                identity,
                name: name,
                reason: reason,
                now: Date()
            )
            uncertain.insert(identity)
        case .ended, .absent:
            uncertainStore.remove(identity)
            uncertain.remove(identity)
            ledger?.discardConversation(for: identity)
        case .skipped, .refused, .notAttempted:
            break
        }
    }

    private func absenceOutcome(_ snapshot: TmuxSnapshot) -> TmuxActionOutcome {
        snapshot.completeness.isComplete
            ? .absent
            : .uncertain(reason: "The session could not be verified absent.")
    }

    private func validationFailure(
        for selection: TmuxBulkSelection,
        current: TmuxSessionObservation
    ) -> TmuxActionOutcome? {
        if current.name != selection.name {
            return .skipped(reason: "The session was renamed.")
        }
        if current.attachedClients > 0 {
            return .skipped(reason: "The session became attached.")
        }
        if current.sharedWindows {
            return .skipped(reason: "The session gained a shared window.")
        }
        if current.ownership.fingerprint
            != selection.authorization.ownershipFingerprint {
            return .skipped(reason: "The session ownership changed.")
        }
        if selection.authorization.tier == .idleBulk,
           current.process != .noCommandDetected {
            return .skipped(reason: "The session is no longer idle.")
        }
        return nil
    }
}

enum TmuxCaptureBudget {
    static let maxBytes = 2 * 1024 * 1024
    static let maxLines = 20_000
    static let maxPanes = 32
    static let timeout: TimeInterval = 15
}
