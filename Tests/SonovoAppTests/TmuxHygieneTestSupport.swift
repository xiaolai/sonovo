import Foundation
import XCTest
@testable import Sonovo

enum TmuxTestData {
    static let socket = "/tmp/sonovo-tests.sock"
    static let boot = BootIdentity(
        launchID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    static func server(pid: Int = 501) -> TmuxServerIdentity {
        TmuxServerIdentity(socketPath: socket, pid: pid)
    }

    static func identity(
        sessionID: String = "$1",
        pid: Int = 501
    ) -> TmuxSessionIdentity {
        TmuxSessionIdentity(
            server: server(pid: pid),
            sessionID: sessionID
        )
    }

    static func observation(
        name: String = "sonovo-demo-ab12cd34-1",
        sessionID: String = "$1",
        pid: Int = 501,
        attached: Int = 0,
        process: ProcessObservation = .noCommandDetected,
        shared: Bool = false,
        windows: Int = 1,
        ownership: Ownership = .verified(projectPath: "/tmp/project"),
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        activity: Date = Date(timeIntervalSince1970: 1_800_000_100),
        activePath: String? = "/tmp/project",
        paneCount: Int = 1
    ) -> TmuxSessionObservation {
        TmuxSessionObservation(
            name: name,
            sessionID: sessionID,
            server: server(pid: pid),
            attachedClients: attached,
            windows: windows,
            sharedWindows: shared,
            createdAt: createdAt,
            lastActivity: activity,
            activePath: activePath,
            ownership: ownership,
            process: process,
            paneCount: paneCount
        )
    }

    static func snapshot(
        _ sessions: [TmuxSessionObservation],
        completeness: Completeness = .complete,
        now: Date = Date(timeIntervalSince1970: 1_800_001_000),
        boot: BootIdentity = boot
    ) -> TmuxSnapshot {
        TmuxSnapshot(
            sessions: sessions,
            completeness: completeness,
            scannedAt: now,
            boot: boot
        )
    }

    static func pane(
        id: String = "%1",
        window: Int = 0,
        pid: Int32 = 42,
        command: String = "zsh",
        path: String? = "/tmp/project",
        active: Bool = true,
        dead: Bool = false
    ) -> TmuxPaneObservation {
        TmuxPaneObservation(
            paneID: id,
            windowIndex: window,
            pid: pid,
            command: command,
            path: path,
            isActive: active,
            isDead: dead
        )
    }
}

final class FakeHygieneService: TmuxHygieneServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var availableStorage = true
    private var sessionsStorage: [TmuxSessionObservation]
    private var completenessStorage: Completeness
    private var panesStorage: [TmuxSessionIdentity: [TmuxPaneObservation]]
    private var killRequestsStorage: [TmuxGuardedKill] = []
    private var renameRequestsStorage: [TmuxGuardedRename] = []
    private var captureRequestsStorage: [TmuxCaptureRequest] = []
    private var killOutcomeStorage: TmuxActionOutcome?
    private var renameOutcomeStorage: TmuxRenameOutcome?
    private var renameQueueStorage: [TmuxRenameOutcome] = []
    private var renameAppliedOnUncertainStorage = false
    private var captureStorage: TmuxCaptureResult
    private var snapshotProviderStorage: (() -> TmuxSnapshot)?
    private var snapshotCallsStorage = 0
    private var snapshotDelayStorage: TimeInterval = 0
    private var onKillStorage: (() -> Void)?

    init(
        sessions: [TmuxSessionObservation] = [],
        completeness: Completeness = .complete
    ) {
        sessionsStorage = sessions
        completenessStorage = completeness
        panesStorage = [:]
        captureStorage = TmuxCaptureResult(
            panes: [],
            totalBytes: 0,
            verdict: .complete
        )
    }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return availableStorage
    }

    var sessions: [TmuxSessionObservation] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return sessionsStorage
        }
        set {
            lock.lock()
            sessionsStorage = newValue
            lock.unlock()
        }
    }

    var completeness: Completeness {
        get {
            lock.lock()
            defer { lock.unlock() }
            return completenessStorage
        }
        set {
            lock.lock()
            completenessStorage = newValue
            lock.unlock()
        }
    }

    var killRequests: [TmuxGuardedKill] {
        lock.lock()
        defer { lock.unlock() }
        return killRequestsStorage
    }

    var renameRequests: [TmuxGuardedRename] {
        lock.lock()
        defer { lock.unlock() }
        return renameRequestsStorage
    }

    var captureRequests: [TmuxCaptureRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captureRequestsStorage
    }

    var killOutcome: TmuxActionOutcome? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return killOutcomeStorage
        }
        set {
            lock.lock()
            killOutcomeStorage = newValue
            lock.unlock()
        }
    }

    var renameOutcome: TmuxRenameOutcome? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return renameOutcomeStorage
        }
        set {
            lock.lock()
            renameOutcomeStorage = newValue
            lock.unlock()
        }
    }

    var renameOutcomes: [TmuxRenameOutcome] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return renameQueueStorage
        }
        set {
            lock.lock()
            renameQueueStorage = newValue
            lock.unlock()
        }
    }

    var renameAppliedOnUncertain: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return renameAppliedOnUncertainStorage
        }
        set {
            lock.lock()
            renameAppliedOnUncertainStorage = newValue
            lock.unlock()
        }
    }

    var captureResult: TmuxCaptureResult {
        get {
            lock.lock()
            defer { lock.unlock() }
            return captureStorage
        }
        set {
            lock.lock()
            captureStorage = newValue
            lock.unlock()
        }
    }

    var snapshotProvider: (() -> TmuxSnapshot)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return snapshotProviderStorage
        }
        set {
            lock.lock()
            snapshotProviderStorage = newValue
            lock.unlock()
        }
    }

    var snapshotCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshotCallsStorage
    }

    var snapshotDelay: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return snapshotDelayStorage
        }
        set {
            lock.lock()
            snapshotDelayStorage = newValue
            lock.unlock()
        }
    }

    var onKill: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return onKillStorage
        }
        set {
            lock.lock()
            onKillStorage = newValue
            lock.unlock()
        }
    }

    func setAvailable(_ value: Bool) {
        lock.lock()
        availableStorage = value
        lock.unlock()
    }

    func setPanes(
        _ panes: [TmuxPaneObservation],
        for identity: TmuxSessionIdentity
    ) {
        lock.lock()
        panesStorage[identity] = panes
        lock.unlock()
    }

    func snapshot(
        now: Date,
        boot: BootIdentity,
        registry: [TmuxSessionIdentity: TmuxRegistryEntry]
    ) -> TmuxSnapshot {
        lock.lock()
        snapshotCallsStorage += 1
        let provider = snapshotProviderStorage
        let sessions = sessionsStorage
        let completeness = completenessStorage
        let delay = snapshotDelayStorage
        lock.unlock()
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        if let provider {
            return provider()
        }
        return TmuxTestData.snapshot(
            sessions,
            completeness: completeness,
            now: now,
            boot: boot
        )
    }

    func panes(
        for identity: TmuxSessionIdentity
    ) -> [TmuxPaneObservation]? {
        lock.lock()
        defer { lock.unlock() }
        return panesStorage[identity]
    }

    func guardedKill(_ request: TmuxGuardedKill) -> TmuxActionOutcome {
        lock.lock()
        killRequestsStorage.append(request)
        let outcome = killOutcomeStorage
        let hook = onKillStorage
        if outcome == nil {
            sessionsStorage.removeAll { $0.identity == request.identity }
        }
        lock.unlock()
        hook?()
        return outcome ?? .ended
    }

    func guardedRename(_ request: TmuxGuardedRename) -> TmuxRenameOutcome {
        lock.lock()
        renameRequestsStorage.append(request)
        let queued = renameQueueStorage.isEmpty
            ? nil
            : renameQueueStorage.removeFirst()
        let outcome = queued ?? renameOutcomeStorage
        let applyAnyway = renameAppliedOnUncertainStorage
        let shouldApply = outcome == nil
            || (applyAnyway && outcome == .uncertain(reason: "reply lost"))
        if shouldApply,
           let index = sessionsStorage.firstIndex(where: {
               $0.identity == request.identity
           }) {
            let old = sessionsStorage[index]
            sessionsStorage[index] = TmuxSessionObservation(
                name: request.newName,
                sessionID: old.sessionID,
                server: old.server,
                attachedClients: old.attachedClients,
                windows: old.windows,
                sharedWindows: old.sharedWindows,
                createdAt: old.createdAt,
                lastActivity: old.lastActivity,
                activePath: old.activePath,
                ownership: request.newProjectPath.map {
                    .verified(projectPath: $0)
                } ?? old.ownership,
                process: old.process,
                paneCount: old.paneCount
            )
        }
        lock.unlock()
        return outcome ?? .renamed
    }

    func capture(_ request: TmuxCaptureRequest) -> TmuxCaptureResult {
        lock.lock()
        captureRequestsStorage.append(request)
        let result = captureStorage
        lock.unlock()
        return result
    }
}

enum TmuxTestFiles {
    static func temporaryDirectory(
        _ name: String = UUID().uuidString
    ) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sonovo-tmux-tests-\(name)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
