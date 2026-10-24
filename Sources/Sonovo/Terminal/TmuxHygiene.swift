import Foundation
import Observation
import SonovoCore

// MARK: - Persistence helpers

enum HygieneFile {
    static func supportDirectory() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("Sonovo", isDirectory: true)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    @discardableResult
    static func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Association and thresholds

enum TmuxAssociation: String, Sendable, Equatable, Codable {
    case inWorkspace
    case recentlyClosed
    case other
    case sample
    case unknown
}

struct TmuxKnownPaths: Sendable, Equatable {
    var openProjects: Set<String> = []
    var recentClosed: Set<String> = []
    /// The demo session is not a real path and never qualifies for automatic
    /// cleanup. It is kept as a display association only.
    var samplePath = "sample"

    static func canonical(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return MarkdownSecurity.canonical(
            URL(fileURLWithPath: path)
        ).path
    }

    mutating func insertOpen(_ path: String) {
        guard !path.isEmpty else { return }
        openProjects.insert(Self.canonical(path))
    }

    mutating func insertRecentClosed(_ path: String) {
        guard !path.isEmpty else { return }
        recentClosed.insert(Self.canonical(path))
    }

    func association(
        for observation: TmuxSessionObservation
    ) -> TmuxAssociation {
        if observation.name.hasPrefix("sonovo-sample-") {
            return .sample
        }
        return association(for: observation.ownership)
    }

    func association(for ownership: Ownership) -> TmuxAssociation {
        guard let path = ownership.verifiedProjectPath else {
            return .unknown
        }
        if path == samplePath { return .sample }
        let canonical = Self.canonical(path)
        if openProjects.contains(canonical) { return .inWorkspace }
        if recentClosed.contains(canonical) { return .recentlyClosed }
        return .other
    }
}

enum TmuxIdleThreshold {
    static let orphan: TimeInterval = 7 * 24 * 60 * 60
    static let recentClosed: TimeInterval = 14 * 24 * 60 * 60
    static let suggestion: TimeInterval = 30 * 24 * 60 * 60

    static func threshold(for association: TmuxAssociation) -> TimeInterval? {
        switch association {
        case .other: orphan
        case .recentlyClosed: recentClosed
        case .inWorkspace, .sample: suggestion
        case .unknown: nil
        }
    }

    static func isSuggestionOnly(_ association: TmuxAssociation) -> Bool {
        association == .inWorkspace || association == .sample
    }
}

// MARK: - Observed-idle ledger

/// Idle credit is earned only by consecutive complete observations. It is
/// "idle at consecutive observations", never a continuous guarantee.
struct ObservedIdleLedger: Sendable, Equatable {
    struct Entry: Sendable, Equatable, Codable {
        var identity: TmuxSessionIdentity
        var firstObservedIdleAt: Date
        var lastObservedIdleAt: Date
        var lastObservedAt: Date
        var lastState: String
        var ownershipFingerprint: String
        var bootIdentity: BootIdentity
        var scanSequence: UInt64
    }

    static let cadence: TimeInterval = 15 * 60
    static let grace: TimeInterval = 5 * 60
    static let maxGap: TimeInterval = cadence + grace

    var entries: [TmuxSessionIdentity: Entry] = [:]
    var scanSequence: UInt64 = 0
    var lastScanAt: Date?
    var isCorrupt = false

    func observedIdle(
        identity: TmuxSessionIdentity,
        now: Date
    ) -> TimeInterval? {
        guard !isCorrupt,
              let entry = entries[identity],
              now >= entry.lastObservedAt,
              now.timeIntervalSince(entry.lastObservedAt) <= Self.maxGap,
              entry.lastObservedAt >= entry.firstObservedIdleAt else {
            return nil
        }
        return max(0, now.timeIntervalSince(entry.firstObservedIdleAt))
    }

    /// Applies one complete-or-not snapshot. A busy observation resets
    /// credit even when another part of the scan is incomplete; missing
    /// evidence breaks continuity for that identity.
    consuming func applying(
        snapshot: TmuxSnapshot,
        now: Date
    ) -> ObservedIdleLedger {
        var next = isCorrupt ? ObservedIdleLedger() : self
        next.scanSequence &+= 1
        next.lastScanAt = now
        let boot = snapshot.boot

        let currentServers = Set(snapshot.sessions.map(\.server))
        next.entries = next.entries.filter { _, entry in
            entry.bootIdentity == boot
                && currentServers.contains(entry.identity.server)
        }

        let complete = snapshot.completeness.isComplete
        guard complete else {
            // Missing evidence invalidates every open interval, including
            // sessions the incomplete scan happened to include.
            next.entries.removeAll()
            return next
        }
        for observation in snapshot.sessions {
            let identity = observation.identity
            if observation.process == .running {
                // Trustworthy evidence of work resets credit regardless of
                // the rest of the scan.
                next.entries[identity] = nil
                continue
            }
            guard observation.isDetached,
                  observation.process == .noCommandDetected else {
                next.entries[identity] = nil
                continue
            }
            let fingerprint = observation.ownership.fingerprint
            if var entry = next.entries[identity],
               entry.ownershipFingerprint == fingerprint,
               entry.bootIdentity == boot,
               now >= entry.lastObservedAt,
               now.timeIntervalSince(entry.lastObservedAt) <= Self.maxGap {
                entry.lastObservedAt = now
                entry.lastObservedIdleAt = now
                entry.scanSequence = next.scanSequence
                next.entries[identity] = entry
            } else {
                next.entries[identity] = Entry(
                    identity: identity,
                    firstObservedIdleAt: now,
                    lastObservedIdleAt: now,
                    lastObservedAt: now,
                    lastState: "idle",
                    ownershipFingerprint: fingerprint,
                    bootIdentity: boot,
                    scanSequence: next.scanSequence
                )
            }
        }

        if complete {
            let present = Set(snapshot.sessions.map(\.identity))
            next.entries = next.entries.filter {
                present.contains($0.key)
            }
        }
        return next
    }
}

struct IdleLedgerFile: Codable, Equatable {
    var version: Int = 1
    var entries: [ObservedIdleLedger.Entry] = []
    var scanSequence: UInt64 = 0
    var lastScanAt: Date?

    init(ledger: ObservedIdleLedger) {
        entries = Array(ledger.entries.values)
        scanSequence = ledger.scanSequence
        lastScanAt = ledger.lastScanAt
    }

    var ledger: ObservedIdleLedger {
        var value = ObservedIdleLedger()
        value.scanSequence = scanSequence
        value.lastScanAt = lastScanAt
        for entry in entries {
            value.entries[entry.identity] = entry
        }
        return value
    }
}

@MainActor
final class ObservedIdleLedgerStore {
    private(set) var ledger: ObservedIdleLedger
    private let url: URL?

    static func defaultURL() -> URL? {
        HygieneFile.supportDirectory()?
            .appendingPathComponent("tmux-hygiene.json")
    }

    init(url: URL? = ObservedIdleLedgerStore.defaultURL()) {
        self.url = url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            if let file = HygieneFile.read(IdleLedgerFile.self, from: url),
               file.version == 1 {
                ledger = file.ledger
            } else {
                // Corrupt state never grants eligibility. The next complete
                // scan starts fresh intervals from the present.
                var corrupt = ObservedIdleLedger()
                corrupt.isCorrupt = true
                ledger = corrupt
            }
        } else {
            ledger = ObservedIdleLedger()
        }
    }

    func apply(snapshot: TmuxSnapshot, now: Date) {
        ledger = ledger.applying(snapshot: snapshot, now: now)
        if let url {
            HygieneFile.write(IdleLedgerFile(ledger: ledger), to: url)
        }
    }

    func observedIdle(
        identity: TmuxSessionIdentity,
        now: Date
    ) -> TimeInterval? {
        ledger.observedIdle(identity: identity, now: now)
    }

    func discardConversation(for identity: TmuxSessionIdentity) {
        guard ledger.entries[identity] != nil else { return }
        ledger.entries[identity] = nil
        if let url {
            HygieneFile.write(IdleLedgerFile(ledger: ledger), to: url)
        }
    }

    /// Moves an interval to a new identity after a rename. The interval is
    /// preserved because the processes and their last activity are the same.
    func move(
        from old: TmuxSessionIdentity,
        to new: TmuxSessionIdentity
    ) {
        guard var entry = ledger.entries.removeValue(forKey: old) else {
            return
        }
        entry.identity = new
        ledger.entries[new] = entry
        if let url {
            HygieneFile.write(IdleLedgerFile(ledger: ledger), to: url)
        }
    }

    /// Adoption changes ownership without changing the session identity.
    /// Update the fingerprint so the next scan extends the interval instead
    /// of treating the ownership change as a new conversation.
    func updateOwnership(
        identity: TmuxSessionIdentity,
        projectPath: String
    ) {
        guard var entry = ledger.entries[identity] else { return }
        entry.ownershipFingerprint = Ownership.verified(
            projectPath: projectPath
        ).fingerprint
        ledger.entries[identity] = entry
        if let url {
            HygieneFile.write(IdleLedgerFile(ledger: ledger), to: url)
        }
    }
}

// MARK: - Ownership registry

struct OwnershipRegistryFile: Codable, Equatable {
    struct Record: Codable, Equatable {
        let socketPath: String
        let serverPID: Int
        let sessionID: String
        let projectPath: String
        let createdAt: Date?
    }

    var version: Int = 1
    var records: [Record] = []
}

@MainActor
final class TmuxOwnershipRegistryStore {
    private(set) var entries: [TmuxSessionIdentity: TmuxRegistryEntry] = [:]
    private let url: URL?
    private static let cap = 4096

    static func defaultURL() -> URL? {
        HygieneFile.supportDirectory()?
            .appendingPathComponent("tmux-ownership.json")
    }

    init(url: URL? = TmuxOwnershipRegistryStore.defaultURL()) {
        self.url = url
        guard let url,
              let file = HygieneFile.read(OwnershipRegistryFile.self, from: url),
              file.version == 1 else {
            return
        }
        for record in file.records {
            let identity = TmuxSessionIdentity(
                server: TmuxServerIdentity(
                    socketPath: record.socketPath,
                    pid: record.serverPID
                ),
                sessionID: record.sessionID
            )
            entries[identity] = TmuxRegistryEntry(
                projectPath: record.projectPath,
                createdAt: record.createdAt
            )
        }
    }

    func snapshotForTransport() -> [TmuxSessionIdentity: TmuxRegistryEntry] {
        entries
    }

    func merge(snapshot: TmuxSnapshot) {
        var changed = false
        for session in snapshot.sessions {
            guard let path = session.ownership.verifiedProjectPath else {
                continue
            }
            let entry = TmuxRegistryEntry(
                projectPath: path,
                createdAt: session.createdAt
            )
            if entries[session.identity] != entry {
                entries[session.identity] = entry
                changed = true
            }
        }
        if entries.count > Self.cap {
            let overflow = entries.count - Self.cap
            let oldest = entries.sorted {
                ($0.value.createdAt ?? .distantPast)
                    < ($1.value.createdAt ?? .distantPast)
            }.prefix(overflow)
            for (identity, _) in oldest {
                entries[identity] = nil
                changed = true
            }
        }
        if changed {
            persist()
        }
    }

    func update(
        identity: TmuxSessionIdentity,
        projectPath: String
    ) {
        let created = entries[identity]?.createdAt
        entries[identity] = TmuxRegistryEntry(
            projectPath: projectPath,
            createdAt: created
        )
        persist()
    }

    private func persist() {
        guard let url else { return }
        let file = OwnershipRegistryFile(
            records: entries.map { identity, entry in
                OwnershipRegistryFile.Record(
                    socketPath: identity.server.socketPath,
                    serverPID: identity.server.pid,
                    sessionID: identity.sessionID,
                    projectPath: entry.projectPath,
                    createdAt: entry.createdAt
                )
            }
        )
        HygieneFile.write(file, to: url)
    }
}

// MARK: - Permissions

enum TmuxCandidateTier: Int, Sendable, Equatable, Comparable {
    case idleBulk = 1
    case explicitBulk = 2
    case excluded = 3

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TmuxPermissions: Sendable, Equatable {
    let canEnd: Bool
    let canCapture: Bool
    let canOpen: Bool
    let canBulkDefault: Bool
    let canBulkExplicit: Bool
    let canAutoEnd: Bool
    let canAdopt: Bool
    let reasons: [String]
}

struct TmuxAutoEligibility: Sendable, Equatable {
    let eligible: Bool
    let reasons: [String]
}

struct TmuxSessionAttributes: Identifiable, Sendable, Equatable {
    let observation: TmuxSessionObservation
    let association: TmuxAssociation
    let observedIdle: TimeInterval?
    let idleThreshold: TimeInterval?
    let thresholdReached: Bool
    let uncertain: Bool
    let captureCommitted: Bool
    let permissions: TmuxPermissions
    let autoEligibility: TmuxAutoEligibility

    var identity: TmuxSessionIdentity { observation.identity }
    var id: TmuxSessionIdentity { identity }

    var tier: TmuxCandidateTier {
        if permissions.canBulkDefault { return .idleBulk }
        if permissions.canBulkExplicit { return .explicitBulk }
        return .excluded
    }

    var idleLabel: String? {
        guard let observedIdle else { return nil }
        let days = Int(observedIdle / (24 * 60 * 60))
        let hours = Int(observedIdle / (60 * 60)) % 24
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h"
    }
}

enum TmuxPermissionEvaluator {
    static func evaluate(
        observation: TmuxSessionObservation,
        association: TmuxAssociation,
        observedIdle: TimeInterval?,
        completeness: Completeness,
        uncertain: Bool,
        autoMode: AutomaticCleanupMode,
        killSwitchEngaged: Bool
    ) -> (permissions: TmuxPermissions, auto: TmuxAutoEligibility) {
        var reasons: [String] = []
        let complete = completeness.isComplete
        let detached = observation.isDetached
        let shared = observation.sharedWindows
        let verified = observation.ownership.isVerified
        let idle = observation.process == .noCommandDetected

        if !complete {
            reasons.append("The scan is incomplete.")
        }
        if !detached {
            reasons.append("The session is attached.")
        }
        if shared {
            reasons.append("A window is shared with another session.")
        }
        if !verified {
            reasons.append("Ownership is not verified.")
        }
        if observation.process == .running {
            reasons.append("A command is running.")
        } else if observation.process == .unknown {
            reasons.append("The process state is unknown.")
        }
        if uncertain {
            reasons.append("An earlier action is unresolved.")
        }

        let eligibleForDefaultBulk = complete
            && detached
            && !shared
            && verified
            && idle
        let eligibleForExplicitBulk = complete && detached
        let canOpen = verified && association == .inWorkspace
        let canAdopt = verified && association != .sample

        var autoReasons: [String] = []
        if !complete { autoReasons.append("The scan is incomplete.") }
        if !detached { autoReasons.append("The session is attached.") }
        if shared { autoReasons.append("A window is shared.") }
        if !verified { autoReasons.append("Ownership is not verified.") }
        if !idle { autoReasons.append("No idle observation.") }
        if uncertain { autoReasons.append("An action is unresolved.") }
        if association != .other && association != .recentlyClosed {
            autoReasons.append("The project is not an orphan or a recently closed path.")
        }
        if let threshold = TmuxIdleThreshold.threshold(for: association) {
            if (observedIdle ?? 0) < threshold {
                autoReasons.append("The observed-idle threshold is not reached.")
            }
        } else {
            autoReasons.append("No trustworthy association.")
        }
        // Capture is created and committed immediately before an automatic
        // dispatch, so a pre-existing capture is not an eligibility input.
        // The coordinator enforces committed-complete at the gate.
        let autoEligible = autoReasons.isEmpty
        let canAutoEnd = autoEligible
            && autoMode == .kill
            && !killSwitchEngaged

        return (
            TmuxPermissions(
                canEnd: true,
                canCapture: true,
                canOpen: canOpen,
                canBulkDefault: eligibleForDefaultBulk,
                canBulkExplicit: eligibleForExplicitBulk,
                canAutoEnd: canAutoEnd,
                canAdopt: canAdopt,
                reasons: reasons
            ),
            TmuxAutoEligibility(
                eligible: autoEligible,
                reasons: autoReasons
            )
        )
    }
}

// MARK: - Settings

enum AutomaticCleanupMode: String, Codable, Sendable, CaseIterable {
    case off
    case preview
    case kill
}

struct TmuxHygieneSettings: Codable, Equatable, Sendable {
    var version: Int = 1
    var mode: AutomaticCleanupMode = .off
    var riskAcknowledged = false
    var killSwitchEngaged = false
    var captureEnabled = false
    var retentionDays = 30
    var lastAutomaticRunAt: Date?
    var lastAutomaticMode: AutomaticCleanupMode?

    var isArmed: Bool {
        mode == .kill && riskAcknowledged && !killSwitchEngaged
    }
}

final class TmuxHygieneSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "sonovo.tmux.hygiene.settings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var settings: TmuxHygieneSettings {
        get {
            guard let data = defaults.data(forKey: key),
                  let value = try? JSONDecoder().decode(
                      TmuxHygieneSettings.self,
                      from: data
                  ) else {
                return TmuxHygieneSettings()
            }
            return value
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else {
                return
            }
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - Cleanup budget

struct TmuxCleanupBudget: Sendable, Equatable, Codable {
    struct Attempt: Sendable, Equatable, Codable {
        let identityKey: String
        var at: Date
        let runID: UUID
        var outcome: String?
    }

    static let perRunCap = 10
    static let rollingCap = 20
    static let rollingWindow: TimeInterval = 24 * 60 * 60

    var version: Int = 1
    var attempts: [Attempt] = []
    var isCorrupt = false

    func rollingCount(now: Date) -> Int {
        attempts.filter {
            now.timeIntervalSince($0.at) < Self.rollingWindow
        }.count
    }

    func perRunCount(runID: UUID) -> Int {
        attempts.filter { $0.runID == runID }.count
    }

    mutating func prune(now: Date) {
        attempts.removeAll {
            now.timeIntervalSince($0.at) >= Self.rollingWindow
        }
    }

    /// All-or-nothing reservation. A partial reservation would let some
    /// rows dispatch while the caller believes none did.
    mutating func reserve(
        keys: [String],
        runID: UUID,
        now: Date
    ) -> Bool {
        guard !isCorrupt, !keys.isEmpty else { return false }
        prune(now: now)
        guard rollingCount(now: now) + keys.count <= Self.rollingCap,
              perRunCount(runID: runID) + keys.count <= Self.perRunCap else {
            return false
        }
        for key in keys {
            attempts.append(
                Attempt(identityKey: key, at: now, runID: runID)
            )
        }
        return true
    }

    mutating func settle(
        key: String,
        runID: UUID,
        outcome: String,
        now: Date
    ) {
        guard let index = attempts.lastIndex(where: {
            $0.identityKey == key && $0.runID == runID && $0.outcome == nil
        }) else {
            return
        }
        attempts[index].outcome = outcome
        // Every reserved attempt consumes budget. An uncertain attempt is
        // never returned: the mutation may have reached the server.
        attempts[index].at = now
    }

    /// Returns a reservation that never reached dispatch. A stopped run must
    /// not spend budget on rows it did not attempt.
    mutating func release(key: String, runID: UUID) {
        attempts.removeAll {
            $0.identityKey == key
                && $0.runID == runID
                && $0.outcome == nil
        }
    }
}

@MainActor
final class TmuxCleanupBudgetStore {
    private(set) var budget: TmuxCleanupBudget
    private let url: URL?
    static func defaultURL() -> URL? {
        HygieneFile.supportDirectory()?
            .appendingPathComponent("tmux-cleanup-budget.json")
    }

    init(url: URL? = TmuxCleanupBudgetStore.defaultURL()) {
        self.url = url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            if let value = HygieneFile.read(
                TmuxCleanupBudget.self,
                from: url
            ), value.version == 1 {
                budget = value
            } else {
                var corrupt = TmuxCleanupBudget()
                corrupt.isCorrupt = true
                budget = corrupt
            }
        } else {
            budget = TmuxCleanupBudget()
        }
    }

    var isCorrupt: Bool { budget.isCorrupt }

    func beginRun() -> UUID {
        UUID()
    }

    func reserve(keys: [String], runID: UUID, now: Date) -> Bool {
        guard budget.reserve(keys: keys, runID: runID, now: now) else {
            return false
        }
        guard persist() else {
            // The scheduler must not dispatch against accounting it could
            // not make durable.
            budget.isCorrupt = true
            return false
        }
        return true
    }

    func settle(
        key: String,
        runID: UUID,
        outcome: String,
        now: Date
    ) {
        budget.settle(
            key: key,
            runID: runID,
            outcome: outcome,
            now: now
        )
        _ = persist()
    }

    /// Returns reservations for rows that were never dispatched.
    func release(keys: [String], runID: UUID) {
        guard !keys.isEmpty else { return }
        for key in keys {
            budget.release(key: key, runID: runID)
        }
        _ = persist()
    }

    func endRun() {
        _ = persist()
    }

    @discardableResult
    private func persist() -> Bool {
        guard let url else { return true }
        let ok = HygieneFile.write(budget, to: url)
        if !ok {
            budget.isCorrupt = true
        }
        return ok
    }
}

// MARK: - Run reports

struct TmuxCleanupRunReport: Codable, Equatable, Sendable {
    struct Row: Codable, Equatable, Sendable {
        let identityKey: String
        let name: String
        let outcome: String
        let reason: String?
    }

    var version: Int = 1
    var startedAt: Date = .distantPast
    var mode: AutomaticCleanupMode = .off
    var rows: [Row] = []
    var previewNames: [String] = []
    var transportFailure: String?
}

/// One durable JSON report file. Every report store uses the same load/save
/// path, including the persistence-failure flag callers must surface.
final class HygieneReportStore<Report: Codable> {
    private(set) var report: Report?
    private(set) var persistenceFailed = false
    private let url: URL?

    init(url: URL?) {
        self.url = url
        if let url {
            report = HygieneFile.read(Report.self, from: url)
        }
    }

    @discardableResult
    func save(_ report: Report) -> Bool {
        self.report = report
        guard let url else {
            persistenceFailed = false
            return true
        }
        let ok = HygieneFile.write(report, to: url)
        persistenceFailed = !ok
        return ok
    }
}

final class TmuxCleanupReportStore {
    private let storage: HygieneReportStore<TmuxCleanupRunReport>

    static func defaultURL() -> URL? {
        HygieneFile.supportDirectory()?
            .appendingPathComponent("tmux-cleanup-report.json")
    }

    init(url: URL? = TmuxCleanupReportStore.defaultURL()) {
        storage = HygieneReportStore(url: url)
    }

    var report: TmuxCleanupRunReport? { storage.report }
    var persistenceFailed: Bool { storage.persistenceFailed }

    @discardableResult
    func save(_ report: TmuxCleanupRunReport) -> Bool {
        storage.save(report)
    }
}

// MARK: - Hygiene store

/// One scan in flight; a completed scan is the only source of attributes.
/// Filters and labels never change permission; the evaluator is the only
/// place a tier or automatic action is granted.
@MainActor
@Observable
final class TmuxHygieneStore {
    private(set) var snapshot: TmuxSnapshot?
    private(set) var attributes: [TmuxSessionAttributes] = []
    private(set) var isScanning = false
    private(set) var lastScanError: String?
    private(set) var lastAutomaticReport: TmuxCleanupRunReport?
    private(set) var reportPersistenceFailed = false
    private(set) var previewIdentities: Set<TmuxSessionIdentity> = []

    let boot: BootIdentity
    var knownPaths = TmuxKnownPaths()
    var settings: TmuxHygieneSettings {
        didSet {
            settingsStore.settings = settings
            if oldValue.mode != settings.mode
                || oldValue.killSwitchEngaged != settings.killSwitchEngaged {
                onPolicyChanged?()
            }
            recomputeAttributes()
        }
    }

    /// A policy or kill-switch change invalidates queued coordinator work.
    @ObservationIgnored var onPolicyChanged: (() -> Void)?

    @ObservationIgnored let transport: (any TmuxHygieneServicing)?
    @ObservationIgnored let ledgerStore: ObservedIdleLedgerStore
    @ObservationIgnored let registry: TmuxOwnershipRegistryStore
    @ObservationIgnored let settingsStore: TmuxHygieneSettingsStore
    @ObservationIgnored let budgetStore: TmuxCleanupBudgetStore
    @ObservationIgnored let reportStore: TmuxCleanupReportStore
    @ObservationIgnored let archive: TmuxArchiveStore?
    @ObservationIgnored var uncertainProvider: (TmuxSessionIdentity) -> Bool = { _ in false }
    /// Supplies the open-project and recently-closed sets at each scan.
    @ObservationIgnored var knownPathsProvider: () -> TmuxKnownPaths = {
        TmuxKnownPaths()
    }
    /// Test seam for the scan clock. Production uses the wall clock.
    @ObservationIgnored var nowProvider: () -> Date = { Date() }
    @ObservationIgnored private var scanGeneration: UInt64 = 0
    @ObservationIgnored private var appliedScanGeneration: UInt64 = 0
    @ObservationIgnored private var activeScan: Task<Void, Never>?
    @ObservationIgnored private var cadenceTask: Task<Void, Never>?

    init(
        transport: (any TmuxHygieneServicing)?,
        boot: BootIdentity = BootIdentity(
            launchID: UUID(),
            startedAt: Date()
        ),
        ledgerStore: ObservedIdleLedgerStore = ObservedIdleLedgerStore(),
        registry: TmuxOwnershipRegistryStore = TmuxOwnershipRegistryStore(),
        settingsStore: TmuxHygieneSettingsStore = TmuxHygieneSettingsStore(),
        budgetStore: TmuxCleanupBudgetStore = TmuxCleanupBudgetStore(),
        reportStore: TmuxCleanupReportStore = TmuxCleanupReportStore(),
        archive: TmuxArchiveStore? = nil
    ) {
        self.transport = transport
        self.boot = boot
        self.ledgerStore = ledgerStore
        self.registry = registry
        self.settingsStore = settingsStore
        self.budgetStore = budgetStore
        self.reportStore = reportStore
        self.archive = archive
        self.settings = settingsStore.settings
        self.lastAutomaticReport = reportStore.report
    }

    var isAvailable: Bool {
        transport?.isAvailable ?? false
    }

    var completeness: Completeness {
        snapshot?.completeness ?? .unknown
    }

    func startCadence() {
        guard cadenceTask == nil, transport != nil else { return }
        cadenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(
                    for: .seconds(Int(ObservedIdleLedger.cadence))
                )
            }
        }
    }

    func stopCadence() {
        cadenceTask?.cancel()
        cadenceTask = nil
    }

    /// Actions invalidate scans: a result from before the action must not be
    /// applied afterwards. The in-flight task detects the generation change
    /// and a fresh scan owns the scanning flag.
    func invalidateScan() {
        scanGeneration &+= 1
        isScanning = false
    }

    func refresh() async {
        knownPaths = knownPathsProvider()
        guard let transport else { return }
        let baseline = appliedScanGeneration
        let requestedAt = nowProvider()
        // A scan invalidated by an action must not satisfy the request. Try
        // a bounded number of fresh scans and let the coordinator recheck.
        for _ in 0..<3 {
            if let activeScan {
                await activeScan.value
            }
            if appliedScanGeneration > baseline,
               let scannedAt = snapshot?.scannedAt,
               scannedAt >= requestedAt {
                return
            }
            while isScanning {
                if let activeScan {
                    await activeScan.value
                } else {
                    isScanning = false
                    break
                }
            }
            isScanning = true
            scanGeneration &+= 1
            let generation = scanGeneration
            let registrySnapshot = registry.snapshotForTransport()
            let now = nowProvider()
            let boot = boot
            let task = Task { @MainActor [weak self] in
                let result = await Task.detached(priority: .utility) {
                    transport.snapshot(
                        now: now,
                        boot: boot,
                        registry: registrySnapshot
                    )
                }.value
                guard let self else { return }
                self.isScanning = false
                guard generation == self.scanGeneration else { return }
                if let failure = result.completeness.reason,
                   !result.completeness.isComplete {
                    self.lastScanError = failure
                } else {
                    self.lastScanError = nil
                }
                self.apply(snapshot: result)
                self.appliedScanGeneration = generation
            }
            activeScan = task
            await task.value
            guard scanGeneration == generation else {
                continue
            }
            activeScan = nil
            return
        }
    }

    /// Synchronous ingestion point for tests and for the scheduler, which
    /// already has a fresh snapshot in hand.
    func apply(snapshot: TmuxSnapshot) {
        self.snapshot = snapshot
        ledgerStore.apply(snapshot: snapshot, now: snapshot.scannedAt)
        registry.merge(snapshot: snapshot)
        recomputeAttributes()
    }

    func recomputeAttributes() {
        guard let snapshot else {
            attributes = []
            return
        }
        let ledger = ledgerStore.ledger
        var result: [TmuxSessionAttributes] = []
        for observation in snapshot.sessions {
            let identity = observation.identity
            let association = knownPaths.association(for: observation)
            let observedIdle = ledger.observedIdle(
                identity: identity,
                now: snapshot.scannedAt
            )
            let threshold = TmuxIdleThreshold.threshold(
                for: association
            )
            let uncertain = uncertainProvider(identity)
            let captureCommitted = archive?.hasCommittedCompleteCapture(
                identity: identity
            ) ?? false
            let evaluated = TmuxPermissionEvaluator.evaluate(
                observation: observation,
                association: association,
                observedIdle: observedIdle,
                completeness: snapshot.completeness,
                uncertain: uncertain,
                autoMode: settings.mode,
                killSwitchEngaged: settings.killSwitchEngaged
            )
            result.append(
                TmuxSessionAttributes(
                    observation: observation,
                    association: association,
                    observedIdle: observedIdle,
                    idleThreshold: threshold,
                    thresholdReached: threshold.map {
                        (observedIdle ?? 0) >= $0
                    } ?? false,
                    uncertain: uncertain,
                    captureCommitted: captureCommitted,
                    permissions: evaluated.permissions,
                    autoEligibility: evaluated.auto
                )
            )
        }
        attributes = result.sorted { first, second in
            if first.tier != second.tier { return first.tier < second.tier }
            if first.thresholdReached != second.thresholdReached {
                return first.thresholdReached
            }
            let firstIdle = first.observedIdle ?? 0
            let secondIdle = second.observedIdle ?? 0
            if firstIdle != secondIdle { return firstIdle > secondIdle }
            return first.observation.name < second.observation.name
        }
    }

    func setMode(
        _ mode: AutomaticCleanupMode,
        riskAcknowledged: Bool
    ) {
        var next = settings
        next.mode = mode
        if mode != .kill {
            next.riskAcknowledged = false
        } else if riskAcknowledged {
            next.riskAcknowledged = true
        }
        settings = next
    }

    func engageKillSwitch() {
        var next = settings
        next.killSwitchEngaged = true
        settings = next
    }

    func disengageKillSwitch() {
        var next = settings
        next.killSwitchEngaged = false
        settings = next
    }

    func setCaptureEnabled(_ enabled: Bool) {
        var next = settings
        next.captureEnabled = enabled
        settings = next
    }

    func setRetentionDays(_ days: Int) {
        var next = settings
        next.retentionDays = max(1, days)
        settings = next
    }

    func markAutomaticRun(_ report: TmuxCleanupRunReport) {
        lastAutomaticReport = report
        reportPersistenceFailed = !reportStore.save(report)
        var next = settings
        next.lastAutomaticRunAt = report.startedAt
        next.lastAutomaticMode = report.mode
        settings = next
    }

    func setPreviewIdentities(_ identities: Set<TmuxSessionIdentity>) {
        previewIdentities = identities
    }

    func attributes(for identity: TmuxSessionIdentity) -> TmuxSessionAttributes? {
        attributes.first { $0.identity == identity }
    }

    var summaryCounts: TmuxHygieneSummary {
        TmuxHygieneSummary(attributes: attributes)
    }
}

struct TmuxHygieneSummary: Sendable, Equatable {
    var total = 0
    var attached = 0
    var running = 0
    var noCommand = 0
    var unknownProcess = 0
    var shared = 0
    var candidates = 0
    var uncertain = 0

    init(attributes: [TmuxSessionAttributes]) {
        total = attributes.count
        for attribute in attributes {
            if attribute.observation.attachedClients > 0 { attached += 1 }
            switch attribute.observation.process {
            case .running: running += 1
            case .noCommandDetected: noCommand += 1
            case .unknown: unknownProcess += 1
            }
            if attribute.observation.sharedWindows { shared += 1 }
            if attribute.tier != .excluded { candidates += 1 }
            if attribute.uncertain { uncertain += 1 }
        }
    }
}

// MARK: - Automatic cleanup scheduler

/// The only path that dispatches automatic actions. It runs at most once per
/// 24 hours, never on quit, and only after the launch delay.
@MainActor
final class TmuxCleanupScheduler {
    static let launchDelay: TimeInterval = 60
    static let runInterval: TimeInterval = 24 * 60 * 60

    private let hygiene: TmuxHygieneStore
    private let coordinator: TmuxActionCoordinator
    private let launchDate: Date
    private var task: Task<Void, Never>?
    private var isStopped = false

    init(
        hygiene: TmuxHygieneStore,
        coordinator: TmuxActionCoordinator,
        launchDate: Date = Date()
    ) {
        self.hygiene = hygiene
        self.coordinator = coordinator
        self.launchDate = launchDate
    }

    func start() {
        guard task == nil else { return }
        isStopped = false
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                _ = await self?.runIfDue(now: Date())
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func stop() {
        isStopped = true
        task?.cancel()
        task = nil
    }

    func isDue(now: Date) -> Bool {
        let settings = hygiene.settings
        switch settings.mode {
        case .off:
            return false
        case .kill:
            guard settings.riskAcknowledged,
                  !settings.killSwitchEngaged else {
                return false
            }
        case .preview:
            guard !settings.killSwitchEngaged else { return false }
        }
        guard now.timeIntervalSince(launchDate) >= Self.launchDelay else {
            return false
        }
        guard let last = settings.lastAutomaticRunAt else { return true }
        return now.timeIntervalSince(last) >= Self.runInterval
    }

    /// One scheduler tick. Returns true when a run was attempted.
    @discardableResult
    func runIfDue(now: Date) async -> Bool {
        guard !isStopped, !Task.isCancelled, isDue(now: now) else {
            return false
        }
        await hygiene.refresh()
        guard let snapshot = freshSnapshot(now: now) else {
            publish(
                now: now,
                mode: hygiene.settings.mode,
                failure: "A fresh complete scan could not be obtained."
            )
            return true
        }
        let eligible = hygiene.attributes.filter {
            $0.autoEligibility.eligible
        }
        switch hygiene.settings.mode {
        case .preview:
            runPreview(now: now, eligible: eligible)
            return true
        case .kill:
            await runKill(now: now, eligible: eligible, snapshot: snapshot)
            return true
        case .off:
            return false
        }
    }

    private func freshSnapshot(now: Date) -> TmuxSnapshot? {
        guard let snapshot = hygiene.snapshot,
              snapshot.completeness.isComplete,
              snapshot.scannedAt >= now.addingTimeInterval(-1),
              snapshot.scannedAt <= now.addingTimeInterval(1) else {
            return nil
        }
        return snapshot
    }

    private func runPreview(
        now: Date,
        eligible: [TmuxSessionAttributes]
    ) {
        hygiene.setPreviewIdentities(
            Set(eligible.map(\.identity))
        )
        publish(
            now: now,
            mode: .preview,
            previewNames: eligible.map(\.observation.name)
        )
    }

    private func runKill(
        now: Date,
        eligible: [TmuxSessionAttributes],
        snapshot: TmuxSnapshot
    ) async {
        guard !eligible.isEmpty else {
            publish(now: now, mode: .kill)
            return
        }
        let runID = hygiene.budgetStore.beginRun()
        defer { hygiene.budgetStore.endRun() }
        // Respect the caps without refusing a whole backlog: take as many
        // of the longest-idle candidates as both budgets can cover.
        let budget = hygiene.budgetStore.budget
        let rollingRemaining = max(
            0,
            TmuxCleanupBudget.rollingCap
                - budget.rollingCount(now: now)
        )
        let capacity = min(
            TmuxCleanupBudget.perRunCap,
            rollingRemaining
        )
        let chosen = Array(eligible.prefix(capacity))
        let keys = chosen.map { $0.identity.key }
        guard !keys.isEmpty,
              hygiene.budgetStore.reserve(
                  keys: keys,
                  runID: runID,
                  now: now
              ) else {
            publish(
                now: now,
                mode: .kill,
                failure: hygiene.budgetStore.isCorrupt
                    ? "Cleanup accounting is corrupt; automation is blocked."
                    : "The durable cleanup budget is exhausted."
            )
            return
        }

        var rows: [TmuxCleanupRunReport.Row] = []
        var transportFailure: String?
        var stop = false
        for attribute in chosen {
            if stop || isStopped || Task.isCancelled { break }
            guard hygiene.settings.isArmed else { break }
            let outcome = await coordinator.performAutomaticEnd(
                attribute: attribute
            )
            hygiene.budgetStore.settle(
                key: attribute.identity.key,
                runID: runID,
                outcome: outcome.reportLabel,
                now: now
            )
            rows.append(
                TmuxCleanupRunReport.Row(
                    identityKey: attribute.identity.key,
                    name: attribute.observation.name,
                    outcome: outcome.reportLabel,
                    reason: outcome.reason
                )
            )
            switch outcome {
            case .uncertain:
                stop = true
                transportFailure = outcome.reason
            case .skipped, .refused:
                break
            case .ended, .absent:
                hygiene.ledgerStore.discardConversation(
                    for: attribute.identity
                )
            case .notAttempted:
                stop = true
            }
        }
        let settled = Set(rows.map(\.identityKey))
        let undispatched = chosen
            .filter { !settled.contains($0.identity.key) }
        for attribute in undispatched {
            rows.append(
                TmuxCleanupRunReport.Row(
                    identityKey: attribute.identity.key,
                    name: attribute.observation.name,
                    outcome: "notAttempted",
                    reason: "The run stopped before dispatch."
                )
            )
        }
        hygiene.budgetStore.release(
            keys: undispatched.map { $0.identity.key },
            runID: runID
        )
        publish(
            now: now,
            mode: .kill,
            rows: rows,
            failure: transportFailure
        )
        hygiene.registry.merge(snapshot: snapshot)
        await hygiene.refresh()
    }

    private func publish(
        now: Date,
        mode: AutomaticCleanupMode,
        rows: [TmuxCleanupRunReport.Row] = [],
        previewNames: [String] = [],
        failure: String? = nil
    ) {
        var report = TmuxCleanupRunReport()
        report.startedAt = now
        report.mode = mode
        report.rows = rows
        report.previewNames = previewNames
        report.transportFailure = failure
        hygiene.markAutomaticRun(report)
    }
}

extension TmuxActionOutcome {
    var reportLabel: String {
        switch self {
        case .ended: "ended"
        case .absent: "absent"
        case .skipped: "skipped"
        case .refused: "refused"
        case .uncertain: "uncertain"
        case .notAttempted: "notAttempted"
        }
    }

    var reason: String? {
        switch self {
        case .ended, .absent, .notAttempted: nil
        case let .skipped(reason), let .refused(reason),
             let .uncertain(reason):
            reason
        }
    }
}

// MARK: - Folder identity and migration

struct FolderIdentityRecord: Codable, Equatable, Sendable {
    enum Provenance: String, Codable, Sendable {
        case observed
    }

    var volumeUUID: String?
    var fileResourceIdentifier: String?
    var capturedAt: Date
    var provenance: Provenance
}

enum FolderIdentity {
    static func record(for url: URL) -> FolderIdentityRecord? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeUUIDStringKey,
            .fileResourceIdentifierKey
        ]) else {
            return nil
        }
        var resourceIdentifier: String?
        if let data = values.fileResourceIdentifier as? Data {
            resourceIdentifier = data.base64EncodedString()
        } else if let data = values.fileResourceIdentifier as? NSData {
            resourceIdentifier = (data as Data).base64EncodedString()
        }
        let volume = values.volumeUUIDString
        guard volume != nil || resourceIdentifier != nil else {
            return nil
        }
        return FolderIdentityRecord(
            volumeUUID: volume,
            fileResourceIdentifier: resourceIdentifier,
            capturedAt: Date(),
            provenance: .observed
        )
    }

    /// A positive match requires both halves. A missing or partial identity
    /// is not evidence and falls back to manual selection.
    static func matches(
        _ first: FolderIdentityRecord,
        _ second: FolderIdentityRecord
    ) -> Bool {
        guard let firstVolume = first.volumeUUID,
              let secondVolume = second.volumeUUID,
              firstVolume == secondVolume,
              let firstResource = first.fileResourceIdentifier,
              let secondResource = second.fileResourceIdentifier,
              firstResource == secondResource else {
            return false
        }
        return true
    }
}

struct TmuxMigrationCandidate: Identifiable, Sendable, Equatable {
    let identity: TmuxSessionIdentity
    let currentName: String
    let proposedName: String
    let sourcePath: String
    let attachedClients: Int
    let sharedWindows: Bool

    var id: TmuxSessionIdentity { identity }
}

struct TmuxMigrationReport: Codable, Equatable, Sendable {
    struct Row: Codable, Equatable, Sendable {
        let identityKey: String
        let currentName: String
        let proposedName: String
        let outcome: String
        let reason: String?
    }

    var version: Int = 1
    var startedAt: Date = .distantPast
    var sourcePath: String = ""
    var destinationPath: String = ""
    var rows: [Row] = []
}

@MainActor
final class TmuxMigrationReportStore {
    private let storage: HygieneReportStore<TmuxMigrationReport>

    static func defaultURL() -> URL? {
        HygieneFile.supportDirectory()?
            .appendingPathComponent("tmux-migration-report.json")
    }

    init(url: URL? = nil) {
        storage = HygieneReportStore(url: url)
    }

    var report: TmuxMigrationReport? { storage.report }
    var persistenceFailed: Bool { storage.persistenceFailed }

    @discardableResult
    func save(_ report: TmuxMigrationReport) -> Bool {
        storage.save(report)
    }
}

struct AdoptedTabRebind: Sendable, Equatable {
    let oldName: String
    let newName: String
    let destinationPath: String
}

struct TmuxMigrationPreview: Sendable, Equatable {
    let sourcePath: String
    let destinationPath: String
    let destinationPrefix: String
    let candidates: [TmuxMigrationCandidate]
    let excludedNames: [String]
    let crossVolume: Bool
    let identityMatched: Bool
    let reservedNames: [String]
}

enum TmuxMigrationOutcome: Sendable, Equatable {
    case renamed
    case absent
    case nameTaken
    case uncertain(reason: String)
    case failed(reason: String)
    case notAttempted(reason: String)
}

@MainActor
@Observable
final class TmuxMigrationModel {
    private(set) var results: [TmuxSessionIdentity: TmuxMigrationOutcome] = [:]
    private(set) var isRunning = false
    private(set) var lastError: String?
    @ObservationIgnored private let reportStore: TmuxMigrationReportStore

    init(reportStore: TmuxMigrationReportStore = TmuxMigrationReportStore()) {
        self.reportStore = reportStore
    }

    /// Builds a preview. Attached sessions and shared windows are excluded
    /// until resolved; every proposed name and reservation is listed before
    /// confirmation. The folder identity is a hint, never permission.
    func prepare(
        sourcePath: String,
        destinationPath: String,
        destinationPrefix: String,
        snapshot: TmuxSnapshot,
        destinationIdentity: FolderIdentityRecord?,
        sourceIdentity: FolderIdentityRecord?
    ) -> TmuxMigrationPreview {
        let sourceCanonical = TmuxKnownPaths.canonical(sourcePath)
        let relevant = snapshot.sessions.filter {
            guard let path = $0.ownership.verifiedProjectPath else {
                return false
            }
            return TmuxKnownPaths.canonical(path) == sourceCanonical
        }
        var excluded: [String] = []
        var eligible: [TmuxSessionObservation] = []
        for session in relevant {
            if session.attachedClients > 0 || session.sharedWindows {
                excluded.append(session.name)
            } else {
                eligible.append(session)
            }
        }
        var usedNames = Set(snapshot.sessions.map(\.name))
        for session in eligible {
            usedNames.remove(session.name)
        }
        var highest = 0
        for name in usedNames {
            if let index = TmuxNaming.index(
                of: name,
                prefix: destinationPrefix
            ) {
                highest = max(highest, index)
            }
        }
        var candidates: [TmuxMigrationCandidate] = []
        var reservations: [String] = []
        for session in eligible {
            let oldIndex = TmuxNaming.trailingIndex(of: session.name)
            let proposed: String
            if let oldIndex,
               !usedNames.contains(
                   TmuxNaming.sessionName(
                       prefix: destinationPrefix,
                       index: oldIndex
                   )
               ) {
                proposed = TmuxNaming.sessionName(
                    prefix: destinationPrefix,
                    index: oldIndex
                )
            } else {
                var candidate = ""
                repeat {
                    highest += 1
                    candidate = TmuxNaming.sessionName(
                        prefix: destinationPrefix,
                        index: highest
                    )
                } while usedNames.contains(candidate)
                proposed = candidate
            }
            usedNames.insert(proposed)
            reservations.append(proposed)
            candidates.append(
                TmuxMigrationCandidate(
                    identity: session.identity,
                    currentName: session.name,
                    proposedName: proposed,
                    sourcePath: sourceCanonical,
                    attachedClients: session.attachedClients,
                    sharedWindows: session.sharedWindows
                )
            )
        }
        let matched = destinationIdentity != nil
            && sourceIdentity != nil
            && FolderIdentity.matches(
                destinationIdentity!,
                sourceIdentity!
            )
        let crossVolume = destinationIdentity?.volumeUUID != nil
            && sourceIdentity?.volumeUUID != nil
            && destinationIdentity?.volumeUUID != sourceIdentity?.volumeUUID
        return TmuxMigrationPreview(
            sourcePath: sourceCanonical,
            destinationPath: TmuxKnownPaths.canonical(destinationPath),
            destinationPrefix: destinationPrefix,
            candidates: candidates,
            excludedNames: excluded,
            crossVolume: crossVolume,
            identityMatched: matched,
            reservedNames: reservations
        )
    }

    /// Executes a confirmed preview through the coordinator. A definitive
    /// name collision reallocates once; an uncertain rename stops the run
    /// and is never retried.
    func execute(
        preview: TmuxMigrationPreview,
        coordinator: TmuxActionCoordinator,
        snapshot: TmuxSnapshot,
        reserveName: (String) -> Void = { _ in },
        rebindTabs: (AdoptedTabRebind) -> Void
    ) async -> [TmuxSessionIdentity: TmuxMigrationOutcome] {
        guard !isRunning else { return results }
        isRunning = true
        lastError = nil
        defer { isRunning = false }
        var outcomes: [TmuxSessionIdentity: TmuxMigrationOutcome] = [:]
        var report = TmuxMigrationReport(
            startedAt: Date(),
            sourcePath: preview.sourcePath,
            destinationPath: preview.destinationPath
        )
        var usedNames = Set(snapshot.sessions.map(\.name))
        usedNames.formUnion(preview.reservedNames)
        for candidate in preview.candidates {
            guard let observation = snapshot.session(candidate.identity) else {
                outcomes[candidate.identity] = .absent
                report.rows.append(
                    row(
                        candidate,
                        proposed: candidate.proposedName,
                        outcome: .absent
                    )
                )
                continue
            }
            var proposed = candidate.proposedName
            usedNames.remove(proposed)
            var attempt = await coordinator.rename(
                observation: observation,
                newName: proposed,
                newProjectPath: preview.destinationPath
            )
            if case .nameTaken = attempt {
                // A definitive no-effect: allocate once above the highest
                // name now in use and retry exactly once. The taken name is
                // part of "in use", so the retry cannot propose it again.
                usedNames.insert(proposed)
                var highest = 0
                for name in usedNames {
                    if let index = TmuxNaming.index(
                        of: name,
                        prefix: preview.destinationPrefix
                    ) {
                        highest = max(highest, index)
                    }
                }
                highest += 1
                proposed = TmuxNaming.sessionName(
                    prefix: preview.destinationPrefix,
                    index: highest
                )
                usedNames.insert(proposed)
                reserveName(proposed)
                attempt = await coordinator.rename(
                    observation: observation,
                    newName: proposed,
                    newProjectPath: preview.destinationPath
                )
            }
            switch attempt {
            case .renamed:
                usedNames.insert(proposed)
                outcomes[candidate.identity] = .renamed
                rebindTabs(
                    AdoptedTabRebind(
                        oldName: candidate.currentName,
                        newName: proposed,
                        destinationPath: preview.destinationPath
                    )
                )
            case .absent:
                outcomes[candidate.identity] = .absent
            case .nameTaken:
                outcomes[candidate.identity] = .failed(
                    reason: "The destination name was taken twice."
                )
            case let .uncertain(reason):
                outcomes[candidate.identity] = .uncertain(reason: reason)
                report.rows.append(
                    row(candidate, proposed: proposed, outcome: .uncertain(reason: reason))
                )
                for remaining in preview.candidates
                where outcomes[remaining.identity] == nil {
                    let outcome = TmuxMigrationOutcome.notAttempted(
                        reason: "An earlier rename was unresolved."
                    )
                    outcomes[remaining.identity] = outcome
                    report.rows.append(
                        row(
                            remaining,
                            proposed: remaining.proposedName,
                            outcome: outcome
                        )
                    )
                }
                if !reportStore.save(report), lastError == nil {
                    lastError = "The migration report could not be saved."
                }
                isRunning = false
                results = outcomes
                if lastError == nil {
                    lastError = "A rename is unresolved; later sessions were not attempted."
                }
                return outcomes
            case let .skipped(reason), let .refused(reason):
                outcomes[candidate.identity] = .failed(reason: reason)
            }
            if let outcome = outcomes[candidate.identity] {
                report.rows.append(
                    row(candidate, proposed: proposed, outcome: outcome)
                )
                if !reportStore.save(report), lastError == nil {
                    lastError = "The migration report could not be saved."
                }
            }
        }
        if !reportStore.save(report), lastError == nil {
            lastError = "The migration report could not be saved."
        }
        results = outcomes
        return outcomes
    }

    private func row(
        _ candidate: TmuxMigrationCandidate,
        proposed: String,
        outcome: TmuxMigrationOutcome
    ) -> TmuxMigrationReport.Row {
        let label: String
        let reason: String?
        switch outcome {
        case .renamed: label = "renamed"; reason = nil
        case .absent: label = "absent"; reason = nil
        case .nameTaken: label = "nameTaken"; reason = nil
        case let .uncertain(text): label = "uncertain"; reason = text
        case let .failed(text): label = "failed"; reason = text
        case let .notAttempted(text): label = "notAttempted"; reason = text
        }
        return TmuxMigrationReport.Row(
            identityKey: candidate.identity.key,
            currentName: candidate.currentName,
            proposedName: proposed,
            outcome: label,
            reason: reason
        )
    }
}
