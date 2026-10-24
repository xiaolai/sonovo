import XCTest
@testable import Sonovo

@MainActor
final class TmuxActionCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        _ service: FakeHygieneService,
        uncertainURL: URL? = nil
    ) -> TmuxActionCoordinator {
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: uncertainURL)
        )
        // Most tests exercise dispatch without an archive; capture-specific
        // tests opt in explicitly.
        coordinator.captureRequiredProvider = { false }
        return coordinator
    }

    private func selection(
        for observation: TmuxSessionObservation,
        tier: TmuxCandidateTier
    ) -> TmuxBulkSelection {
        TmuxBulkSelection(
            identity: observation.identity,
            name: observation.name,
            authorization: TmuxObservedAuthorization(
                observation: observation,
                tier: tier
            )
        )
    }

    // MARK: Manual End

    func testManualEndBindsToIdentity() async {
        let observation = TmuxTestData.observation()
        let service = FakeHygieneService(sessions: [observation])
        let coordinator = makeCoordinator(service)

        let outcome = await coordinator.endSession(
            named: observation.name
        )
        XCTAssertEqual(outcome, .ended)
        XCTAssertEqual(service.killRequests.count, 1)
        XCTAssertEqual(
            service.killRequests[0].identity,
            observation.identity
        )
        XCTAssertEqual(service.killRequests[0].name, observation.name)
    }

    func testManualEndAbsentAndUnknown() async {
        let complete = FakeHygieneService(sessions: [])
        let absent = await makeCoordinator(complete)
            .endSession(named: "sonovo-demo-ab12cd34-1")
        XCTAssertEqual(absent, .absent)

        let unknownService = FakeHygieneService(
            sessions: [],
            completeness: .unknown
        )
        let unknown = await makeCoordinator(unknownService)
            .endSession(named: "sonovo-demo-ab12cd34-1")
        guard case .uncertain = unknown else {
            return XCTFail("Expected uncertain, got \(unknown)")
        }
    }

    func testManualEndAllowsAnAttachedSessionWithItsExpectedCount() async {
        let observation = TmuxTestData.observation(attached: 1)
        let service = FakeHygieneService(sessions: [observation])
        let coordinator = makeCoordinator(service)
        let outcome = await coordinator.endSession(named: observation.name)
        XCTAssertEqual(outcome, .ended)
        XCTAssertEqual(service.killRequests.count, 1)
        XCTAssertEqual(
            service.killRequests[0].expectedAttachedClients,
            1
        )
    }

    func testManualEndRefusalKeepsTheSession() async {
        let observation = TmuxTestData.observation()
        let service = FakeHygieneService(sessions: [observation])
        service.killOutcome = .refused(reason: "state changed")
        let coordinator = makeCoordinator(service)
        let outcome = await coordinator.endSession(
            named: observation.name
        )
        XCTAssertEqual(outcome, .refused(reason: "state changed"))
        XCTAssertEqual(service.sessions.count, 1)
    }

    // MARK: Bulk transition matrix

    private func currentState(
        _ observation: TmuxSessionObservation
    ) -> FakeHygieneService {
        FakeHygieneService(sessions: [observation])
    }

    func testSelectedIdleCurrentSameEnds() async {
        let observation = TmuxTestData.observation()
        let service = currentState(observation)
        let coordinator = makeCoordinator(service)
        let results = await coordinator.endBulk(
            selections: [selection(for: observation, tier: .idleBulk)],
            cancellation: TmuxBulkCancellation()
        )
        XCTAssertEqual(results[observation.identity], .ended)
    }

    func testSelectedIdleCurrentChangedIsSkipped() async {
        let selected = TmuxTestData.observation()
        let states: [(String, TmuxSessionObservation)] = [
            ("attached", TmuxTestData.observation(attached: 1)),
            ("running", TmuxTestData.observation(process: .running)),
            ("unknown", TmuxTestData.observation(process: .unknown)),
            ("shared", TmuxTestData.observation(shared: true)),
            (
                "ownership",
                TmuxTestData.observation(
                    ownership: .verified(projectPath: "/tmp/moved")
                )
            ),
            (
                "renamed",
                TmuxTestData.observation(
                    name: "sonovo-demo-ab12cd34-9"
                )
            )
        ]
        for (label, current) in states {
            let service = FakeHygieneService(sessions: [current])
            let coordinator = makeCoordinator(service)
            let results = await coordinator.endBulk(
                selections: [
                    selection(for: selected, tier: .idleBulk)
                ],
                cancellation: TmuxBulkCancellation()
            )
            guard case .skipped = results[selected.identity] else {
                XCTFail(
                    "\(label): expected skipped, got "
                        + "\(String(describing: results[selected.identity]))"
                )
                continue
            }
            XCTAssertTrue(
                service.killRequests.isEmpty,
                "\(label): a skipped row must not dispatch"
            )
        }
    }

    func testSelectedRowAbsentYieldsAbsent() async {
        let selected = TmuxTestData.observation()
        let service = FakeHygieneService(sessions: [])
        let coordinator = makeCoordinator(service)
        let results = await coordinator.endBulk(
            selections: [selection(for: selected, tier: .idleBulk)],
            cancellation: TmuxBulkCancellation()
        )
        XCTAssertEqual(results[selected.identity], .absent)
        XCTAssertTrue(service.killRequests.isEmpty)
    }

    func testExplicitTierEndsRunningAndSharedIsSkipped() async {
        let running = TmuxTestData.observation(process: .running)
        let runningService = FakeHygieneService(sessions: [running])
        let runningResults = await makeCoordinator(runningService).endBulk(
            selections: [selection(for: running, tier: .explicitBulk)],
            cancellation: TmuxBulkCancellation()
        )
        XCTAssertEqual(runningResults[running.identity], .ended)

        let shared = TmuxTestData.observation(shared: true)
        let sharedService = FakeHygieneService(sessions: [shared])
        let sharedResults = await makeCoordinator(sharedService).endBulk(
            selections: [selection(for: shared, tier: .explicitBulk)],
            cancellation: TmuxBulkCancellation()
        )
        guard case .skipped = sharedResults[shared.identity] else {
            return XCTFail("Expected shared to be skipped")
        }
        XCTAssertTrue(sharedService.killRequests.isEmpty)
    }

    func testRefusedRowContinuesAndUncertainStops() async {
        let first = TmuxTestData.observation(
            name: "sonovo-demo-ab12cd34-1",
            sessionID: "$1"
        )
        let second = TmuxTestData.observation(
            name: "sonovo-demo-ab12cd34-2",
            sessionID: "$2"
        )
        let third = TmuxTestData.observation(
            name: "sonovo-demo-ab12cd34-3",
            sessionID: "$3"
        )
        let service = FakeHygieneService(
            sessions: [first, second, third]
        )
        let coordinator = makeCoordinator(service)
        var kills = 0
        service.onKill = {
            kills += 1
        }
        let outcomes: [TmuxActionOutcome] = [
            .refused(reason: "definitive"),
            .uncertain(reason: "reply lost")
        ]
        service.killOutcome = .refused(reason: "definitive")
        var results = await coordinator.endBulk(
            selections: [
                selection(for: first, tier: .idleBulk),
                selection(for: second, tier: .idleBulk),
                selection(for: third, tier: .idleBulk)
            ],
            cancellation: TmuxBulkCancellation()
        )
        XCTAssertEqual(results[first.identity], outcomes[0])
        XCTAssertEqual(results[second.identity], outcomes[0])
        XCTAssertEqual(results[third.identity], outcomes[0])
        XCTAssertEqual(kills, 3)

        // Reset and make the second row uncertain: the third is not attempted.
        let service2 = FakeHygieneService(
            sessions: [first, second, third]
        )
        let coordinator2 = makeCoordinator(service2)
        service2.killOutcome = .uncertain(reason: "reply lost")
        results = await coordinator2.endBulk(
            selections: [
                selection(for: first, tier: .idleBulk),
                selection(for: second, tier: .idleBulk),
                selection(for: third, tier: .idleBulk)
            ],
            cancellation: TmuxBulkCancellation()
        )
        XCTAssertEqual(
            results[first.identity],
            .uncertain(reason: "reply lost")
        )
        XCTAssertEqual(
            service2.killRequests.count,
            1,
            "An uncertain row must stop the run"
        )
        guard case .notAttempted = results[third.identity] else {
            return XCTFail("Expected the remaining row to be not attempted")
        }
    }

    func testRowRescanThatIsIncompleteStopsTheRun() async {
        let first = TmuxTestData.observation()
        let service = FakeHygieneService(sessions: [first])
        var calls = 0
        service.snapshotProvider = {
            calls += 1
            if calls == 1 {
                return TmuxTestData.snapshot([first])
            }
            return TmuxTestData.snapshot(
                [first],
                completeness: .incomplete(reason: "pane data")
            )
        }
        let coordinator = makeCoordinator(service)
        let results = await coordinator.endBulk(
            selections: [selection(for: first, tier: .idleBulk)],
            cancellation: TmuxBulkCancellation()
        )
        guard case .notAttempted = results[first.identity] else {
            return XCTFail("Expected the row rescan to stop the run")
        }
        XCTAssertTrue(service.killRequests.isEmpty)
    }

    func testBulkUncertainPersistsAcrossCoordinators() async {
        let directory = TmuxTestFiles.temporaryDirectory()
        let url = directory.appendingPathComponent("uncertain.json")
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
        let coordinator = makeCoordinator(service, uncertainURL: url)
        let results = await coordinator.endBulk(
            selections: [
                selection(for: first, tier: .idleBulk),
                selection(for: second, tier: .idleBulk)
            ],
            cancellation: TmuxBulkCancellation()
        )
        guard case .uncertain = results[first.identity] else {
            return XCTFail("Expected uncertain")
        }
        guard case .notAttempted? = results[second.identity] else {
            return XCTFail("Expected the run to stop")
        }

        let restarted = makeCoordinator(
            FakeHygieneService(sessions: [first]),
            uncertainURL: url
        )
        XCTAssertTrue(restarted.isUncertain(first.identity))
    }

    func testPolicyChangeStopsRemainingRows() async {
        let first = TmuxTestData.observation(
            name: "sonovo-demo-ab12cd34-1",
            sessionID: "$1"
        )
        let second = TmuxTestData.observation(
            name: "sonovo-demo-ab12cd34-2",
            sessionID: "$2"
        )
        let service = FakeHygieneService(sessions: [first, second])
        let coordinator = makeCoordinator(service)
        coordinator.beforeDispatch = {
            coordinator.invalidatePolicy()
        }
        let results = await coordinator.endBulk(
            selections: [
                selection(for: first, tier: .idleBulk),
                selection(for: second, tier: .idleBulk)
            ],
            cancellation: TmuxBulkCancellation()
        )
        XCTAssertEqual(results[first.identity], .ended)
        guard case .skipped = results[second.identity] else {
            return XCTFail("Expected the second row to be skipped")
        }
    }

    func testIncompletePreRunScanAbortsEverything() async {
        let first = TmuxTestData.observation()
        let service = FakeHygieneService(
            sessions: [first],
            completeness: .incomplete(reason: "pane data")
        )
        let coordinator = makeCoordinator(service)
        let results = await coordinator.endBulk(
            selections: [selection(for: first, tier: .idleBulk)],
            cancellation: TmuxBulkCancellation()
        )
        guard case .notAttempted = results[first.identity] else {
            return XCTFail("Expected notAttempted")
        }
        XCTAssertTrue(service.killRequests.isEmpty)
    }

    func testCancellationMarksTheRemainderNotAttempted() async {
        let first = TmuxTestData.observation(
            name: "sonovo-demo-ab12cd34-1",
            sessionID: "$1"
        )
        let second = TmuxTestData.observation(
            name: "sonovo-demo-ab12cd34-2",
            sessionID: "$2"
        )
        let service = FakeHygieneService(sessions: [first, second])
        let coordinator = makeCoordinator(service)
        let cancellation = TmuxBulkCancellation()
        service.onKill = {
            cancellation.cancel()
        }
        let results = await coordinator.endBulk(
            selections: [
                selection(for: first, tier: .idleBulk),
                selection(for: second, tier: .idleBulk)
            ],
            cancellation: cancellation
        )
        XCTAssertEqual(results[first.identity], .ended)
        guard case .notAttempted = results[second.identity] else {
            return XCTFail("Expected the remainder to be not attempted")
        }
        XCTAssertEqual(service.killRequests.count, 1)
    }

    func testGenerationChangeStopsRemainingRows() async {
        let first = TmuxTestData.observation(
            name: "sonovo-demo-ab12cd34-1",
            sessionID: "$1"
        )
        let second = TmuxTestData.observation(
            name: "sonovo-demo-ab12cd34-2",
            sessionID: "$2"
        )
        let service = FakeHygieneService(sessions: [first, second])
        let coordinator = makeCoordinator(service)
        coordinator.beforeDispatch = {
            coordinator.invalidateWorkspace()
        }
        let results = await coordinator.endBulk(
            selections: [
                selection(for: first, tier: .idleBulk),
                selection(for: second, tier: .idleBulk)
            ],
            cancellation: TmuxBulkCancellation()
        )
        XCTAssertEqual(results[first.identity], .ended)
        guard case .skipped = results[second.identity] else {
            return XCTFail("Expected the second row to be skipped")
        }
    }

    // MARK: Uncertainty

    func testUncertainPersistsAcrossCoordinatorsAndBlocksAutomatic() async throws {
        let directory = TmuxTestFiles.temporaryDirectory()
        let url = directory.appendingPathComponent("uncertain.json")
        let observation = TmuxTestData.observation()
        let service = FakeHygieneService(sessions: [observation])
        service.killOutcome = .uncertain(reason: "reply lost")
        let first = makeCoordinator(service, uncertainURL: url)
        let outcome = await first.endSession(named: observation.name)
        guard case .uncertain = outcome else {
            return XCTFail("Expected uncertain")
        }
        XCTAssertTrue(first.isUncertain(observation.identity))
        XCTAssertTrue(first.isUncertain(name: observation.name))

        let secondService = FakeHygieneService(sessions: [observation])
        let second = makeCoordinator(secondService, uncertainURL: url)
        XCTAssertTrue(second.isUncertain(observation.identity))

        let attribute = attributeForAutomatic(observation)
        let automatic = await second.performAutomaticEnd(attribute: attribute)
        guard case .refused = automatic else {
            return XCTFail("Uncertain identity must block automatic End")
        }
        XCTAssertTrue(secondService.killRequests.isEmpty)

        second.reconcile(observation.identity)
        XCTAssertFalse(second.isUncertain(observation.identity))
        let after = await second.performAutomaticEnd(attribute: attribute)
        XCTAssertEqual(after, .ended)
    }

    func testUncertainWriteFailureBlocksInSession() {
        let store = TmuxUncertainStore(
            url: URL(fileURLWithPath: "/dev/null/uncertain.json")
        )
        let identity = TmuxTestData.identity()
        store.record(
            identity,
            name: "sonovo-demo-ab12cd34-1",
            reason: "reply lost",
            now: Date()
        )
        XCTAssertTrue(store.persistenceFailed)
        XCTAssertTrue(store.contains(identity))
        XCTAssertTrue(store.contains(TmuxTestData.identity(sessionID: "$9")))
    }

    func testCorruptUncertaintyFileIsNeverOverwritten() throws {
        let directory = TmuxTestFiles.temporaryDirectory()
        let url = directory.appendingPathComponent("uncertain.json")
        try Data("broken".utf8).write(to: url)
        let store = TmuxUncertainStore(url: url)
        XCTAssertTrue(store.isCorrupt)
        store.record(
            TmuxTestData.identity(),
            name: "sonovo-demo-ab12cd34-1",
            reason: "new uncertainty",
            now: Date()
        )
        let reloaded = TmuxUncertainStore(url: url)
        XCTAssertTrue(
            reloaded.isCorrupt,
            "A corrupt file is the only evidence; it must not be replaced"
        )
    }

    func testCorruptUncertaintyFailsClosed() async throws {
        let directory = TmuxTestFiles.temporaryDirectory()
        let url = directory.appendingPathComponent("uncertain.json")
        try Data("broken".utf8).write(to: url)
        let observation = TmuxTestData.observation()
        let service = FakeHygieneService(sessions: [observation])
        let coordinator = makeCoordinator(service, uncertainURL: url)
        XCTAssertTrue(coordinator.isUncertain(observation.identity))
        let automatic = await coordinator.performAutomaticEnd(attribute: attributeForAutomatic(observation))
        guard case .refused = automatic else {
            return XCTFail("Corrupt uncertainty must block automatic End")
        }
    }

    func testAutomaticEligibilityProviderCanRefuseAStaleAttribute() async {
        let observation = TmuxTestData.observation()
        let service = FakeHygieneService(sessions: [observation])
        let coordinator = makeCoordinator(service)
        coordinator.automaticEligibilityProvider = { _ in false }
        let outcome = await coordinator.performAutomaticEnd(attribute: attributeForAutomatic(observation))
        guard case .refused = outcome else {
            return XCTFail("Expected refused")
        }
        XCTAssertTrue(service.killRequests.isEmpty)
    }

    func testAutomaticDispatchRefusesAnIncompleteRescan() async {
        let observation = TmuxTestData.observation()
        let service = FakeHygieneService(
            sessions: [observation],
            completeness: .incomplete(reason: "pane data")
        )
        let coordinator = makeCoordinator(service)
        let outcome = await coordinator.performAutomaticEnd(attribute: attributeForAutomatic(observation))
        guard case .skipped = outcome else {
            return XCTFail("Expected skipped")
        }
        XCTAssertTrue(service.killRequests.isEmpty)
    }

    func testKillSwitchBlocksAutomaticDispatch() async {
        let observation = TmuxTestData.observation()
        let service = FakeHygieneService(sessions: [observation])
        let coordinator = makeCoordinator(service)
        coordinator.killSwitchProvider = { true }
        let outcome = await coordinator.performAutomaticEnd(attribute: attributeForAutomatic(observation))
        guard case .refused = outcome else {
            return XCTFail("Expected refused")
        }
        XCTAssertTrue(service.killRequests.isEmpty)
    }

    func testAutomaticRechecksCurrentState() async {
        let selected = TmuxTestData.observation()
        let changed = TmuxTestData.observation(process: .running)
        let service = FakeHygieneService(sessions: [changed])
        let coordinator = makeCoordinator(service)
        let outcome = await coordinator.performAutomaticEnd(attribute: attributeForAutomatic(selected))
        guard case .skipped = outcome else {
            return XCTFail("Expected skipped")
        }
        XCTAssertTrue(service.killRequests.isEmpty)
    }

    // MARK: Capture

    func testManualCaptureAndEndNeedsAcknowledgement() async {
        let observation = TmuxTestData.observation()
        let service = FakeHygieneService(sessions: [observation])
        let coordinator = makeCoordinator(service)
        coordinator.captureProvider = { _ in
            TmuxCaptureCommit(
                verdict: .failed,
                committed: false,
                captureID: nil,
                reason: "key unavailable"
            )
        }
        let attribute = automaticAttribute(observation)
        let skipped = await coordinator.captureAndEnd(
            attribute: attribute,
            acknowledgedIncomplete: false
        )
        guard case .skipped = skipped else {
            return XCTFail("Expected skipped")
        }
        XCTAssertTrue(service.killRequests.isEmpty)

        let ended = await coordinator.captureAndEnd(
            attribute: attribute,
            acknowledgedIncomplete: true
        )
        XCTAssertEqual(ended, .ended)
    }

    // MARK: Full transition matrix

    func testTransitionMatrix() async {
        enum Selected: String, CaseIterable {
            case idle, running, unknown, shared
        }
        enum Current: String, CaseIterable {
            case same, attached, running, unknown, shared, absent
        }
        let mutations: [TmuxActionOutcome] = [
            .ended,
            .refused(reason: "definitive"),
            .uncertain(reason: "reply lost"),
            .skipped(reason: "changed"),
            .absent
        ]

        func selectedObservation(_ selected: Selected) -> TmuxSessionObservation {
            switch selected {
            case .idle: TmuxTestData.observation()
            case .running: TmuxTestData.observation(process: .running)
            case .unknown: TmuxTestData.observation(process: .unknown)
            case .shared: TmuxTestData.observation(shared: true)
            }
        }

        func currentObservation(
            _ current: Current,
            selected: TmuxSessionObservation
        ) -> TmuxSessionObservation? {
            switch current {
            case .same: return selected
            case .attached:
                return TmuxTestData.observation(attached: 1)
            case .running:
                return TmuxTestData.observation(process: .running)
            case .unknown:
                return TmuxTestData.observation(process: .unknown)
            case .shared:
                return TmuxTestData.observation(shared: true)
            case .absent:
                return nil
            }
        }

        for selectedState in Selected.allCases {
            let selected = selectedObservation(selectedState)
            let tier: TmuxCandidateTier = selectedState == .idle
                ? .idleBulk
                : .explicitBulk
            for currentState in Current.allCases {
                let current = currentObservation(
                    currentState,
                    selected: selected
                )
                for mutation in mutations {
                    let service = FakeHygieneService(
                        sessions: current.map { [$0] } ?? []
                    )
                    service.killOutcome = mutation
                    let coordinator = makeCoordinator(service)
                    let results = await coordinator.endBulk(
                        selections: [
                            selection(for: selected, tier: tier)
                        ],
                        cancellation: TmuxBulkCancellation()
                    )
                    let expected: TmuxActionOutcome
                    if current == nil {
                        expected = .absent
                    } else if current!.attachedClients > 0 {
                        expected = .skipped(
                            reason: "The session became attached."
                        )
                    } else if current!.sharedWindows {
                        expected = .skipped(
                            reason: "The session gained a shared window."
                        )
                    } else if tier == .idleBulk,
                              current!.process != .noCommandDetected {
                        expected = .skipped(
                            reason: "The session is no longer idle."
                        )
                    } else {
                        expected = mutation
                    }
                    XCTAssertEqual(
                        results[selected.identity],
                        expected,
                        "selected=\(selectedState) current=\(currentState) mutation=\(mutation)"
                    )
                    XCTAssertEqual(results.count, 1)
                }
            }
        }
    }

    // MARK: Selection freezing

    func testBulkSelectionKeepsTheStateObservedAtSelection() async {
        let idle = TmuxTestData.observation()
        let running = TmuxTestData.observation(process: .running)
        let service = FakeHygieneService(sessions: [idle])
        service.completeness = .complete
        let hygiene = TmuxHygieneStore(
            transport: service,
            boot: TmuxTestData.boot,
            ledgerStore: ObservedIdleLedgerStore(url: nil),
            registry: TmuxOwnershipRegistryStore(url: nil),
            settingsStore: TmuxHygieneSettingsStore(
                defaults: UserDefaults(
                    suiteName: "sonovo.tests.\(UUID().uuidString)"
                )!
            ),
            budgetStore: TmuxCleanupBudgetStore(url: nil),
            reportStore: TmuxCleanupReportStore(url: nil)
        )
        hygiene.apply(snapshot: TmuxTestData.snapshot([idle]))
        let coordinator = makeCoordinator(service)
        let model = TmuxSessionsWindowModel(
            hygiene: hygiene,
            coordinator: coordinator,
            archive: nil
        )
        model.toggleBulk(idle.identity)
        XCTAssertEqual(
            model.frozenSelections[idle.identity]?.authorization.tier,
            .idleBulk
        )

        // The session becomes busy after selection. The frozen selection
        // must not be upgraded into an explicit authorization.
        hygiene.apply(snapshot: TmuxTestData.snapshot([running]))
        XCTAssertEqual(
            hygiene.attributes(for: idle.identity)?.tier,
            .explicitBulk
        )
        XCTAssertEqual(
            model.frozenSelections[idle.identity]?.authorization.tier,
            .idleBulk
        )

        service.sessions = [running]
        var confirmed = false
        model.confirm = { _ in
            confirmed = true
            return true
        }
        await model.runBulk()
        XCTAssertTrue(confirmed)
        XCTAssertTrue(service.killRequests.isEmpty)
        guard case .skipped? = model.lastBulkResults[idle.identity] else {
            return XCTFail("Expected the frozen idle row to be skipped")
        }
    }

    // MARK: Policy gating

    func testKillModeRequiresCaptureBeforeEnd() {
        let service = FakeHygieneService(sessions: [])
        let hygiene = TmuxHygieneStore(
            transport: service,
            boot: TmuxTestData.boot,
            ledgerStore: ObservedIdleLedgerStore(url: nil),
            registry: TmuxOwnershipRegistryStore(url: nil),
            settingsStore: TmuxHygieneSettingsStore(
                defaults: UserDefaults(
                    suiteName: "sonovo.tests.\(UUID().uuidString)"
                )!
            ),
            budgetStore: TmuxCleanupBudgetStore(url: nil),
            reportStore: TmuxCleanupReportStore(url: nil)
        )
        let coordinator = makeCoordinator(service)
        let model = TmuxSessionsWindowModel(
            hygiene: hygiene,
            coordinator: coordinator,
            archive: nil
        )
        model.confirm = { _ in true }
        model.setCleanupMode(.kill)
        XCTAssertNotEqual(hygiene.settings.mode, .kill)
        XCTAssertNotNil(model.errorMessage)

        model.setCaptureEnabled(true)
        model.setCleanupMode(.kill)
        XCTAssertEqual(hygiene.settings.mode, .kill)
        XCTAssertTrue(hygiene.settings.isArmed)
    }

    // MARK: Helpers

    private func attributeForAutomatic(
        _ observation: TmuxSessionObservation,
        captureCommitted: Bool = false
    ) -> TmuxSessionAttributes {
        let evaluated = TmuxPermissionEvaluator.evaluate(
            observation: observation,
            association: .other,
            observedIdle: TmuxIdleThreshold.orphan + 1,
            completeness: .complete,
            uncertain: false,
            autoMode: .kill,
            killSwitchEngaged: false
        )
        return TmuxSessionAttributes(
            observation: observation,
            association: .other,
            observedIdle: TmuxIdleThreshold.orphan + 1,
            idleThreshold: TmuxIdleThreshold.orphan,
            thresholdReached: true,
            uncertain: false,
            captureCommitted: captureCommitted,
            permissions: evaluated.permissions,
            autoEligibility: evaluated.auto
        )
    }

    private func automaticAttribute(
        _ observation: TmuxSessionObservation
    ) -> TmuxSessionAttributes {
        attributeForAutomatic(observation)
    }
}
