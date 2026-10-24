import XCTest
@testable import Sonovo

@MainActor
final class TmuxHygieneTests: XCTestCase {
    func testReportStoreSurfacesWriteFailureAndKeepsLatestReport() throws {
        let directory = TmuxTestFiles.temporaryDirectory()
        let blocked = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let store = TmuxCleanupReportStore(
            url: blocked.appendingPathComponent("report.json")
        )
        var report = TmuxCleanupRunReport()
        report.mode = .preview
        report.startedAt = Date()

        XCTAssertFalse(store.save(report))
        XCTAssertTrue(store.persistenceFailed)
        XCTAssertEqual(store.report?.mode, .preview)
    }

    private func makeHygiene(
        service: FakeHygieneService,
        settings: TmuxHygieneSettings = TmuxHygieneSettings(),
        budgetURL: URL? = nil
    ) -> TmuxHygieneStore {
        let defaults = UserDefaults(
            suiteName: "sonovo.tests.\(UUID().uuidString)"
        )!
        let settingsStore = TmuxHygieneSettingsStore(defaults: defaults)
        settingsStore.settings = settings
        return TmuxHygieneStore(
            transport: service,
            boot: TmuxTestData.boot,
            ledgerStore: ObservedIdleLedgerStore(url: nil),
            registry: TmuxOwnershipRegistryStore(url: nil),
            settingsStore: settingsStore,
            budgetStore: TmuxCleanupBudgetStore(url: budgetURL),
            reportStore: TmuxCleanupReportStore(url: nil)
        )
    }

    private func seedIdle(
        _ ledger: ObservedIdleLedgerStore,
        observation: TmuxSessionObservation,
        start: Date,
        days: Double,
        step: TimeInterval = ObservedIdleLedger.cadence
    ) {
        var time = start
        let end = start.addingTimeInterval(days * 24 * 60 * 60)
        while time <= end {
            ledger.apply(
                snapshot: TmuxTestData.snapshot(
                    [observation],
                    now: time
                ),
                now: time
            )
            time = time.addingTimeInterval(step)
        }
    }

    // MARK: Ledger

    func testIdleCreditRequiresConsecutiveCompleteScans() {
        let observation = TmuxTestData.observation()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = ObservedIdleLedger()
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot([observation], now: start),
            now: start
        )
        XCTAssertEqual(
            ledger.observedIdle(identity: observation.identity, now: start),
            0
        )
        let later = start.addingTimeInterval(600)
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot([observation], now: later),
            now: later
        )
        XCTAssertEqual(
            ledger.observedIdle(identity: observation.identity, now: later),
            600
        )
    }

    func testBusyObservationResetsEvenWhenScanIsIncomplete() {
        let observation = TmuxTestData.observation()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = ObservedIdleLedger()
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot([observation], now: start),
            now: start
        )
        let busy = TmuxTestData.observation(process: .running)
        let later = start.addingTimeInterval(300)
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot(
                [busy],
                completeness: .incomplete(reason: "pane data"),
                now: later
            ),
            now: later
        )
        XCTAssertNil(
            ledger.observedIdle(identity: observation.identity, now: later)
        )
    }

    func testIncompleteScanBreaksContinuity() {
        let observation = TmuxTestData.observation()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = ObservedIdleLedger()
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot([observation], now: start),
            now: start
        )
        let middle = start.addingTimeInterval(300)
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot(
                [observation],
                completeness: .incomplete(reason: "window data"),
                now: middle
            ),
            now: middle
        )
        XCTAssertNil(
            ledger.observedIdle(identity: observation.identity, now: middle)
        )
        let after = start.addingTimeInterval(600)
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot([observation], now: after),
            now: after
        )
        XCTAssertEqual(
            ledger.observedIdle(identity: observation.identity, now: after),
            0
        )
    }

    func testIncompleteScanClearsCreditForSessionsItOmitted() {
        let first = TmuxTestData.observation(
            name: "sonovo-demo-ab12cd34-1",
            sessionID: "$1"
        )
        let second = TmuxTestData.observation(
            name: "sonovo-demo-ab12cd34-2",
            sessionID: "$2"
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = ObservedIdleLedger()
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot(
                [first, second],
                now: start
            ),
            now: start
        )
        XCTAssertNotNil(
            ledger.observedIdle(identity: first.identity, now: start)
        )
        let middle = start.addingTimeInterval(300)
        // The incomplete scan omits the first session entirely.
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot(
                [second],
                completeness: .incomplete(reason: "pane data"),
                now: middle
            ),
            now: middle
        )
        XCTAssertNil(
            ledger.observedIdle(identity: first.identity, now: middle)
        )
        let after = start.addingTimeInterval(600)
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot([first, second], now: after),
            now: after
        )
        XCTAssertEqual(
            ledger.observedIdle(identity: first.identity, now: after),
            0
        )
    }

    func testRefreshAfterASleepGapStartsANewScan() async {
        let observation = TmuxTestData.observation()
        let service = FakeHygieneService(sessions: [observation])
        service.snapshotDelay = 0.3
        let hygiene = makeHygiene(service: service)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        hygiene.nowProvider = { start }
        let first = Task { await hygiene.refresh() }
        try? await Task.sleep(for: .milliseconds(50))
        // A wake from sleep: the in-flight scan is old.
        hygiene.nowProvider = { start.addingTimeInterval(3600) }
        await hygiene.refresh()
        await first.value
        XCTAssertGreaterThanOrEqual(service.snapshotCalls, 2)
        XCTAssertEqual(
            hygiene.snapshot?.scannedAt,
            start.addingTimeInterval(3600)
        )
    }

    func testGapLargerThanCadencePlusGraceStartsANewInterval() {
        let observation = TmuxTestData.observation()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = ObservedIdleLedger()
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot([observation], now: start),
            now: start
        )
        let gap = start.addingTimeInterval(ObservedIdleLedger.maxGap + 1)
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot([observation], now: gap),
            now: gap
        )
        XCTAssertEqual(
            ledger.observedIdle(identity: observation.identity, now: gap),
            0
        )
        XCTAssertNil(
            ledger.observedIdle(
                identity: observation.identity,
                now: gap.addingTimeInterval(ObservedIdleLedger.maxGap + 1)
            )
        )
    }

    func testAttachedSessionLosesCredit() {
        let observation = TmuxTestData.observation()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = ObservedIdleLedger()
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot([observation], now: start),
            now: start
        )
        let attached = TmuxTestData.observation(attached: 1)
        let later = start.addingTimeInterval(300)
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot([attached], now: later),
            now: later
        )
        XCTAssertNil(
            ledger.observedIdle(identity: observation.identity, now: later)
        )
    }

    func testNewServerPIDAndNewBootDiscardEntries() {
        let observation = TmuxTestData.observation(pid: 501)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = ObservedIdleLedger()
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot([observation], now: start),
            now: start
        )
        let newServer = TmuxTestData.observation(pid: 502)
        let later = start.addingTimeInterval(300)
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot([newServer], now: later),
            now: later
        )
        XCTAssertNil(
            ledger.observedIdle(identity: observation.identity, now: later)
        )
        XCTAssertEqual(
            ledger.observedIdle(identity: newServer.identity, now: later),
            0
        )

        let newBoot = BootIdentity(
            launchID: UUID(),
            startedAt: later
        )
        let after = later.addingTimeInterval(300)
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot(
                [newServer],
                now: after,
                boot: newBoot
            ),
            now: after
        )
        XCTAssertEqual(
            ledger.observedIdle(identity: newServer.identity, now: after),
            0
        )
    }

    func testOwnershipChangeResetsInterval() {
        let observation = TmuxTestData.observation()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = ObservedIdleLedger()
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot([observation], now: start),
            now: start
        )
        let changed = TmuxTestData.observation(
            ownership: .verified(projectPath: "/tmp/moved")
        )
        let later = start.addingTimeInterval(300)
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot([changed], now: later),
            now: later
        )
        XCTAssertEqual(
            ledger.observedIdle(identity: observation.identity, now: later),
            0
        )
    }

    func testBackwardClockJumpStartsANewInterval() {
        let observation = TmuxTestData.observation()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = ObservedIdleLedger()
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot([observation], now: start),
            now: start
        )
        let backward = start.addingTimeInterval(-3600)
        ledger = ledger.applying(
            snapshot: TmuxTestData.snapshot(
                [observation],
                now: backward
            ),
            now: backward
        )
        XCTAssertEqual(
            ledger.observedIdle(
                identity: observation.identity,
                now: backward
            ),
            0
        )
    }

    func testCorruptLedgerGrantsNoEligibility() {
        var ledger = ObservedIdleLedger()
        ledger.isCorrupt = true
        let observation = TmuxTestData.observation()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let applied = ledger.applying(
            snapshot: TmuxTestData.snapshot([observation], now: now),
            now: now
        )
        XCTAssertEqual(
            applied.observedIdle(identity: observation.identity, now: now),
            0
        )
    }

    func testCorruptLedgerFileIsDetectedAndGrantsNoCredit() throws {
        let url = TmuxTestFiles.temporaryDirectory()
            .appendingPathComponent("tmux-hygiene.json")
        try Data("not json".utf8).write(to: url)
        let store = ObservedIdleLedgerStore(url: url)
        XCTAssertTrue(store.ledger.isCorrupt)
        XCTAssertNil(
            store.observedIdle(
                identity: TmuxTestData.identity(),
                now: Date()
            )
        )
    }

    // MARK: Permissions

    private func evaluate(
        _ observation: TmuxSessionObservation,
        association: TmuxAssociation = .other,
        idle: TimeInterval? = TmuxIdleThreshold.orphan + 60,
        completeness: Completeness = .complete,
        uncertain: Bool = false,
        mode: AutomaticCleanupMode = .kill,
        killSwitch: Bool = false
    ) -> (TmuxPermissions, TmuxAutoEligibility) {
        TmuxPermissionEvaluator.evaluate(
            observation: observation,
            association: association,
            observedIdle: idle,
            completeness: completeness,
            uncertain: uncertain,
            autoMode: mode,
            killSwitchEngaged: killSwitch
        )
    }

    func testAttachedIsExcludedFromBulkAndAutomatic() {
        let result = evaluate(TmuxTestData.observation(attached: 1))
        XCTAssertFalse(result.0.canBulkDefault)
        XCTAssertFalse(result.0.canBulkExplicit)
        XCTAssertFalse(result.0.canAutoEnd)
        XCTAssertTrue(result.0.canEnd)
    }

    func testSharedWindowIsExplicitOnlyAndNeverAutomatic() {
        let result = evaluate(TmuxTestData.observation(shared: true))
        XCTAssertFalse(result.0.canBulkDefault)
        XCTAssertTrue(result.0.canBulkExplicit)
        XCTAssertFalse(result.0.canAutoEnd)
        XCTAssertFalse(result.1.eligible)
    }

    func testRunningAndUnknownAreExplicitTier() {
        for process in [ProcessObservation.running, .unknown] {
            let result = evaluate(
                TmuxTestData.observation(process: process)
            )
            XCTAssertFalse(result.0.canBulkDefault)
            XCTAssertTrue(result.0.canBulkExplicit)
            XCTAssertFalse(result.0.canAutoEnd)
        }
    }

    func testIdleVerifiedOrphanIsDefaultBulkAndAutomatic() {
        let result = evaluate(TmuxTestData.observation())
        XCTAssertTrue(result.0.canBulkDefault)
        XCTAssertTrue(result.0.canBulkExplicit)
        XCTAssertTrue(result.0.canAutoEnd)
        XCTAssertTrue(result.1.eligible)
    }

    func testUnverifiedOwnershipBlocksDefaultBulkAndAutomatic() {
        for ownership in [Ownership.unmapped, .unrecognized] {
            let result = evaluate(
                TmuxTestData.observation(ownership: ownership)
            )
            XCTAssertFalse(result.0.canBulkDefault)
            XCTAssertTrue(result.0.canBulkExplicit)
            XCTAssertFalse(result.0.canAutoEnd)
        }
    }

    func testIncompleteOrUnknownScanGrantsNoBulkOrAutomatic() {
        for completeness in [
            Completeness.incomplete(reason: "pane data"),
            .unknown
        ] {
            let result = evaluate(
                TmuxTestData.observation(),
                completeness: completeness
            )
            XCTAssertFalse(result.0.canBulkDefault)
            XCTAssertFalse(result.0.canBulkExplicit)
            XCTAssertFalse(result.0.canAutoEnd)
        }
    }

    func testUncertainBlocksAutomaticButNotManualEnd() {
        let result = evaluate(
            TmuxTestData.observation(),
            uncertain: true
        )
        XCTAssertTrue(result.0.canEnd)
        XCTAssertFalse(result.0.canAutoEnd)
        XCTAssertFalse(result.1.eligible)
    }

    func testAutomaticRequiresThresholdAndCaptureAndMode() {
        let below = evaluate(
            TmuxTestData.observation(),
            idle: TmuxIdleThreshold.orphan - 1
        )
        XCTAssertFalse(below.1.eligible)

        // Capture is committed at dispatch time, so it is not an
        // eligibility input; the coordinator enforces it at the gate.
        let capturePending = evaluate(TmuxTestData.observation())
        XCTAssertTrue(capturePending.1.eligible)

        let preview = evaluate(
            TmuxTestData.observation(),
            mode: .preview
        )
        XCTAssertTrue(preview.1.eligible)
        XCTAssertFalse(preview.0.canAutoEnd)

        let killSwitch = evaluate(
            TmuxTestData.observation(),
            killSwitch: true
        )
        XCTAssertTrue(killSwitch.1.eligible)
        XCTAssertFalse(killSwitch.0.canAutoEnd)
    }

    func testOpenProjectAndSampleAreSuggestionsOnly() {
        let open = evaluate(
            TmuxTestData.observation(),
            association: .inWorkspace
        )
        XCTAssertFalse(open.1.eligible)
        let sample = evaluate(
            TmuxTestData.observation(),
            association: .sample
        )
        XCTAssertFalse(sample.1.eligible)
    }

    func testThresholdsByAssociation() {
        XCTAssertEqual(
            TmuxIdleThreshold.threshold(for: .other),
            7 * 24 * 60 * 60
        )
        XCTAssertEqual(
            TmuxIdleThreshold.threshold(for: .recentlyClosed),
            14 * 24 * 60 * 60
        )
        XCTAssertEqual(
            TmuxIdleThreshold.threshold(for: .inWorkspace),
            30 * 24 * 60 * 60
        )
        XCTAssertEqual(
            TmuxIdleThreshold.threshold(for: .sample),
            30 * 24 * 60 * 60
        )
        XCTAssertNil(TmuxIdleThreshold.threshold(for: .unknown))
        XCTAssertTrue(TmuxIdleThreshold.isSuggestionOnly(.inWorkspace))
        XCTAssertFalse(TmuxIdleThreshold.isSuggestionOnly(.other))
    }

    func testSampleNameIsASuggestionEvenWithoutMetadata() {
        var paths = TmuxKnownPaths()
        let sample = TmuxTestData.observation(
            name: "sonovo-sample-1",
            ownership: .unmapped
        )
        XCTAssertEqual(paths.association(for: sample), .sample)
        XCTAssertEqual(
            TmuxIdleThreshold.threshold(for: .sample),
            30 * 24 * 60 * 60
        )
    }

    func testKnownPathAssociation() {
        var paths = TmuxKnownPaths()
        paths.insertOpen("/tmp/project/")
        paths.insertRecentClosed("/tmp/closed")
        XCTAssertEqual(
            paths.association(
                for: .verified(projectPath: "/tmp/project")
            ),
            .inWorkspace
        )
        XCTAssertEqual(
            paths.association(
                for: .verified(projectPath: "/tmp/closed")
            ),
            .recentlyClosed
        )
        XCTAssertEqual(
            paths.association(
                for: .verified(projectPath: "/tmp/elsewhere")
            ),
            .other
        )
        XCTAssertEqual(
            paths.association(for: .unmapped),
            .unknown
        )
        XCTAssertEqual(
            paths.association(for: .verified(projectPath: "sample")),
            .sample
        )
    }

    // MARK: Budget

    func testPerRunCapIsTenAndReservationIsAllOrNothing() {
        var budget = TmuxCleanupBudget()
        let run = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(
            budget.reserve(
                keys: (1...10).map { "k\($0)" },
                runID: run,
                now: now
            )
        )
        XCTAssertFalse(
            budget.reserve(keys: ["k11"], runID: run, now: now)
        )
        XCTAssertEqual(budget.attempts.count, 10)
    }

    func testRollingCapPersistsAcrossStoreRestart() throws {
        let url = TmuxTestFiles.temporaryDirectory()
            .appendingPathComponent("budget.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = TmuxCleanupBudgetStore(url: url)
        let run1 = first.beginRun()
        XCTAssertTrue(
            first.reserve(
                keys: (1...10).map { "a\($0)" },
                runID: run1,
                now: now
            )
        )
        first.endRun()
        let run2 = first.beginRun()
        XCTAssertTrue(
            first.reserve(
                keys: (1...10).map { "b\($0)" },
                runID: run2,
                now: now
            )
        )
        first.endRun()

        let restarted = TmuxCleanupBudgetStore(url: url)
        XCTAssertEqual(restarted.budget.rollingCount(now: now), 20)
        let run3 = restarted.beginRun()
        XCTAssertFalse(
            restarted.reserve(keys: ["c1"], runID: run3, now: now)
        )
    }

    func testRollingWindowExpiresOldAttempts() {
        var budget = TmuxCleanupBudget()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(
            -TmuxCleanupBudget.rollingWindow - 60
        )
        _ = budget.reserve(
            keys: (1...20).map { "old\($0)" },
            runID: UUID(),
            now: old
        )
        XCTAssertEqual(budget.rollingCount(now: now), 0)
        XCTAssertTrue(
            budget.reserve(keys: ["new"], runID: UUID(), now: now)
        )
    }

    func testBudgetReleaseFreesAnUndispatchedReservation() {
        var budget = TmuxCleanupBudget()
        let run = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(
            budget.reserve(keys: ["a", "b"], runID: run, now: now)
        )
        budget.release(key: "b", runID: run)
        XCTAssertEqual(budget.perRunCount(runID: run), 1)
        XCTAssertEqual(budget.rollingCount(now: now), 1)
    }

    func testBudgetWriteFailureBlocksReservation() {
        let store = TmuxCleanupBudgetStore(
            url: URL(fileURLWithPath: "/dev/null/budget.json")
        )
        XCTAssertFalse(
            store.reserve(
                keys: ["a"],
                runID: store.beginRun(),
                now: Date()
            )
        )
        XCTAssertTrue(store.isCorrupt)
    }

    func testCorruptBudgetBlocksReservation() throws {
        let url = TmuxTestFiles.temporaryDirectory()
            .appendingPathComponent("budget.json")
        try Data("broken".utf8).write(to: url)
        let store = TmuxCleanupBudgetStore(url: url)
        XCTAssertTrue(store.isCorrupt)
        XCTAssertFalse(
            store.reserve(
                keys: ["a"],
                runID: store.beginRun(),
                now: Date()
            )
        )
    }

    // MARK: Settings and scheduler

    func testSettingsDefaultOffAndKillRequiresRiskAcknowledgement() {
        let service = FakeHygieneService()
        let hygiene = makeHygiene(service: service)
        XCTAssertEqual(hygiene.settings.mode, .off)
        XCTAssertFalse(hygiene.settings.isArmed)
        hygiene.setMode(.kill, riskAcknowledged: false)
        XCTAssertEqual(hygiene.settings.mode, .kill)
        XCTAssertFalse(hygiene.settings.riskAcknowledged)
        XCTAssertFalse(hygiene.settings.isArmed)
        hygiene.setMode(.kill, riskAcknowledged: true)
        XCTAssertTrue(hygiene.settings.isArmed)
    }

    func testSchedulerDueRules() {
        let service = FakeHygieneService()
        let hygiene = makeHygiene(service: service)
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: nil)
        )
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = TmuxCleanupScheduler(
            hygiene: hygiene,
            coordinator: coordinator,
            launchDate: launch
        )
        XCTAssertFalse(scheduler.isDue(now: launch.addingTimeInterval(59)))
        hygiene.setMode(.preview, riskAcknowledged: false)
        XCTAssertFalse(scheduler.isDue(now: launch.addingTimeInterval(59)))
        XCTAssertTrue(scheduler.isDue(now: launch.addingTimeInterval(60)))

        var settings = hygiene.settings
        settings.lastAutomaticRunAt = launch.addingTimeInterval(100)
        hygiene.settings = settings
        XCTAssertFalse(
            scheduler.isDue(now: launch.addingTimeInterval(100 + 3600))
        )
        XCTAssertTrue(
            scheduler.isDue(
                now: launch.addingTimeInterval(
                    100 + TmuxCleanupScheduler.runInterval
                )
            )
        )

        hygiene.setMode(.kill, riskAcknowledged: true)
        hygiene.engageKillSwitch()
        XCTAssertFalse(
            scheduler.isDue(
                now: launch.addingTimeInterval(
                    100 + TmuxCleanupScheduler.runInterval + 60
                )
            )
        )
    }

    func testPreviewRunMarksEligibleWithoutKilling() async {
        let observation = TmuxTestData.observation()
        let service = FakeHygieneService(sessions: [observation])
        let hygiene = makeHygiene(
            service: service,
            settings: TmuxHygieneSettings(mode: .preview)
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        seedIdle(
            hygiene.ledgerStore,
            observation: observation,
            start: start,
            days: 8
        )
        hygiene.apply(
            snapshot: TmuxTestData.snapshot(
                [observation],
                now: start.addingTimeInterval(8 * 24 * 60 * 60)
            )
        )
        XCTAssertTrue(
            hygiene.attributes[0].autoEligibility.eligible
        )
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: nil)
        )
        let scheduler = TmuxCleanupScheduler(
            hygiene: hygiene,
            coordinator: coordinator,
            launchDate: start.addingTimeInterval(-120)
        )
        hygiene.nowProvider = {
            start.addingTimeInterval(8 * 24 * 60 * 60)
        }
        let ran = await scheduler.runIfDue(
            now: start.addingTimeInterval(8 * 24 * 60 * 60)
        )
        XCTAssertTrue(ran)
        XCTAssertEqual(
            hygiene.previewIdentities,
            [observation.identity]
        )
        XCTAssertTrue(service.killRequests.isEmpty)
        XCTAssertEqual(hygiene.lastAutomaticReport?.mode, .preview)
    }

    func testSchedulerStopPreventsAnyRun() async {
        let service = FakeHygieneService(sessions: [])
        let hygiene = makeHygiene(
            service: service,
            settings: TmuxHygieneSettings(mode: .preview)
        )
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: nil)
        )
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = TmuxCleanupScheduler(
            hygiene: hygiene,
            coordinator: coordinator,
            launchDate: launch.addingTimeInterval(-120)
        )
        XCTAssertTrue(scheduler.isDue(now: launch))
        scheduler.stop()
        let ran = await scheduler.runIfDue(now: launch)
        XCTAssertFalse(ran)
    }

    func testKillRunWithNoCandidatesDoesNotClaimBudgetExhaustion() async {
        let service = FakeHygieneService(sessions: [])
        let hygiene = makeHygiene(
            service: service,
            settings: TmuxHygieneSettings(
                mode: .kill,
                riskAcknowledged: true
            )
        )
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: nil)
        )
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = TmuxCleanupScheduler(
            hygiene: hygiene,
            coordinator: coordinator,
            launchDate: launch.addingTimeInterval(-120)
        )
        hygiene.nowProvider = { launch }
        let ran = await scheduler.runIfDue(now: launch)
        XCTAssertTrue(ran)
        XCTAssertNil(hygiene.lastAutomaticReport?.transportFailure)
        XCTAssertTrue(hygiene.lastAutomaticReport?.rows.isEmpty == true)
    }

    func testUncertainStopReleasesUndispatchedBudget() async {
        let first = TmuxTestData.observation(
            name: "sonovo-demo-ab12cd34-1",
            sessionID: "$1"
        )
        let second = TmuxTestData.observation(
            name: "sonovo-demo-ab12cd34-2",
            sessionID: "$2"
        )
        let service = FakeHygieneService(sessions: [first, second])
        service.killOutcome = .uncertain(reason: "reply lost")
        let budgetURL = TmuxTestFiles.temporaryDirectory()
            .appendingPathComponent("budget.json")
        let hygiene = makeHygiene(
            service: service,
            settings: TmuxHygieneSettings(
                mode: .kill,
                riskAcknowledged: true
            ),
            budgetURL: budgetURL
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var time = start
        let end = start.addingTimeInterval(8 * 24 * 60 * 60)
        while time <= end {
            hygiene.ledgerStore.apply(
                snapshot: TmuxTestData.snapshot(
                    [first, second],
                    now: time
                ),
                now: time
            )
            time = time.addingTimeInterval(ObservedIdleLedger.cadence)
        }
        hygiene.apply(
            snapshot: TmuxTestData.snapshot(
                [first, second],
                now: end
            )
        )
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: nil)
        )
        coordinator.captureRequiredProvider = { false }
        hygiene.uncertainProvider = {
            [weak coordinator] identity in
            coordinator?.isUncertain(identity) ?? true
        }
        let scheduler = TmuxCleanupScheduler(
            hygiene: hygiene,
            coordinator: coordinator,
            launchDate: start.addingTimeInterval(-120)
        )
        hygiene.nowProvider = { end }
        _ = await scheduler.runIfDue(now: end)
        XCTAssertEqual(
            hygiene.lastAutomaticReport?.rows.count,
            2
        )
        XCTAssertEqual(
            hygiene.lastAutomaticReport?.rows.first?.outcome,
            "uncertain"
        )
        XCTAssertEqual(
            hygiene.lastAutomaticReport?.rows.last?.outcome,
            "notAttempted"
        )
        XCTAssertEqual(
            hygiene.budgetStore.budget.rollingCount(now: end),
            1,
            "Only the dispatched row should consume budget"
        )
    }

    func testKillRunDispatchesSequentiallyAndReports() async {
        let observation = TmuxTestData.observation()
        let service = FakeHygieneService(sessions: [observation])
        let budgetURL = TmuxTestFiles.temporaryDirectory()
            .appendingPathComponent("budget.json")
        let hygiene = makeHygiene(
            service: service,
            settings: TmuxHygieneSettings(
                mode: .kill,
                riskAcknowledged: true
            ),
            budgetURL: budgetURL
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        seedIdle(
            hygiene.ledgerStore,
            observation: observation,
            start: start,
            days: 8
        )
        let schedulerTime = start.addingTimeInterval(8 * 24 * 60 * 60)
        service.sessions = [observation]
        hygiene.apply(
            snapshot: TmuxTestData.snapshot(
                [observation],
                now: schedulerTime
            )
        )
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: nil)
        )
        hygiene.uncertainProvider = {
            [weak coordinator] identity in
            coordinator?.isUncertain(identity) ?? true
        }
        coordinator.captureRequiredProvider = { false }
        let scheduler = TmuxCleanupScheduler(
            hygiene: hygiene,
            coordinator: coordinator,
            launchDate: start.addingTimeInterval(-120)
        )
        hygiene.nowProvider = { schedulerTime }
        _ = await scheduler.runIfDue(now: schedulerTime)
        XCTAssertEqual(service.killRequests.count, 1)
        XCTAssertEqual(hygiene.lastAutomaticReport?.rows.count, 1)
        XCTAssertEqual(
            hygiene.lastAutomaticReport?.rows.first?.outcome,
            "ended"
        )
    }
}
