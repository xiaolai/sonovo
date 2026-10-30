import XCTest
@testable import Sonovo

@MainActor
final class TmuxMigrationTests: XCTestCase {
    private let sourcePrefix = "sonovo-old-ab12cd34-"
    private let destinationPrefix = "sonovo-dest-12345678-"

    private func identityRecord(
        volume: String? = "VOLUME-A",
        resource: String? = "RESOURCE-1"
    ) -> FolderIdentityRecord {
        FolderIdentityRecord(
            volumeUUID: volume,
            fileResourceIdentifier: resource,
            capturedAt: Date(),
            provenance: .observed
        )
    }

    private func sourceSession(
        index: Int = 1,
        attached: Int = 0,
        shared: Bool = false,
        path: String = "/tmp/source"
    ) -> TmuxSessionObservation {
        TmuxTestData.observation(
            name: sourcePrefix + "\(index)",
            sessionID: "$\(index)",
            attached: attached,
            shared: shared,
            ownership: .verified(projectPath: path)
        )
    }

    // MARK: Identity

    func testFolderIdentityRequiresBothHalves() {
        XCTAssertTrue(
            FolderIdentity.matches(
                identityRecord(),
                identityRecord()
            )
        )
        XCTAssertFalse(
            FolderIdentity.matches(
                identityRecord(volume: "A"),
                identityRecord(volume: "B")
            )
        )
        XCTAssertFalse(
            FolderIdentity.matches(
                identityRecord(resource: "R1"),
                identityRecord(resource: "R2")
            )
        )
        XCTAssertFalse(
            FolderIdentity.matches(
                identityRecord(resource: nil),
                identityRecord(resource: nil)
            )
        )
        XCTAssertFalse(
            FolderIdentity.matches(
                identityRecord(volume: nil),
                identityRecord(volume: nil)
            )
        )
    }

    // MARK: Preview

    func testPreviewExcludesAttachedAndSharedAndReservesNames() {
        let sessions = [
            sourceSession(index: 1),
            sourceSession(index: 2, attached: 1),
            sourceSession(index: 3, shared: true),
            TmuxTestData.observation(
                name: destinationPrefix + "1",
                sessionID: "$9",
                ownership: .verified(projectPath: "/tmp/destination")
            )
        ]
        let model = TmuxMigrationModel()
        let preview = model.prepare(
            sourcePath: "/tmp/source",
            destinationPath: "/tmp/destination",
            destinationPrefix: destinationPrefix,
            snapshot: TmuxTestData.snapshot(sessions),
            destinationIdentity: identityRecord(),
            sourceIdentity: identityRecord()
        )
        XCTAssertEqual(preview.candidates.count, 1)
        XCTAssertEqual(
            preview.candidates[0].currentName,
            sourcePrefix + "1"
        )
        // Index 1 is taken by the destination, so it moves above the
        // highest destination index.
        XCTAssertEqual(
            preview.candidates[0].proposedName,
            destinationPrefix + "2"
        )
        XCTAssertEqual(
            Set(preview.excludedNames),
            [sourcePrefix + "2", sourcePrefix + "3"]
        )
        XCTAssertEqual(preview.reservedNames, [destinationPrefix + "2"])
        XCTAssertTrue(preview.identityMatched)
    }

    func testPreviewPreservesAFreeOldIndex() {
        let model = TmuxMigrationModel()
        let preview = model.prepare(
            sourcePath: "/tmp/source",
            destinationPath: "/tmp/destination",
            destinationPrefix: destinationPrefix,
            snapshot: TmuxTestData.snapshot([sourceSession(index: 4)]),
            destinationIdentity: identityRecord(),
            sourceIdentity: identityRecord()
        )
        XCTAssertEqual(
            preview.candidates[0].proposedName,
            destinationPrefix + "4"
        )
    }

    func testCrossVolumeAndIdentityMismatchAreReported() {
        let model = TmuxMigrationModel()
        let preview = model.prepare(
            sourcePath: "/tmp/source",
            destinationPath: "/tmp/destination",
            destinationPrefix: destinationPrefix,
            snapshot: TmuxTestData.snapshot([sourceSession()]),
            destinationIdentity: identityRecord(volume: "VOLUME-B"),
            sourceIdentity: identityRecord(volume: "VOLUME-A")
        )
        XCTAssertTrue(preview.crossVolume)
        XCTAssertFalse(preview.identityMatched)

        let missing = model.prepare(
            sourcePath: "/tmp/source",
            destinationPath: "/tmp/destination",
            destinationPrefix: destinationPrefix,
            snapshot: TmuxTestData.snapshot([sourceSession()]),
            destinationIdentity: nil,
            sourceIdentity: identityRecord()
        )
        XCTAssertFalse(missing.identityMatched)
    }

    // MARK: Execution

    func testExecutionRenamesThroughTheCoordinatorAndRebindsTabs() async {
        let session = sourceSession(index: 1)
        let service = FakeHygieneService(sessions: [session])
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: nil)
        )
        let model = TmuxMigrationModel()
        let preview = model.prepare(
            sourcePath: "/tmp/source",
            destinationPath: "/tmp/destination",
            destinationPrefix: destinationPrefix,
            snapshot: TmuxTestData.snapshot([session]),
            destinationIdentity: identityRecord(),
            sourceIdentity: identityRecord()
        )
        var rebinds: [AdoptedTabRebind] = []
        let results = await model.execute(
            preview: preview,
            coordinator: coordinator,
            snapshot: TmuxTestData.snapshot([session]),
            rebindTabs: { rebinds.append($0) }
        )
        XCTAssertEqual(results[session.identity], .renamed)
        XCTAssertEqual(rebinds.count, 1)
        XCTAssertEqual(rebinds[0].oldName, sourceSession(index: 1).name)
        XCTAssertEqual(rebinds[0].newName, destinationPrefix + "1")
        XCTAssertEqual(rebinds[0].destinationPath, "/tmp/destination")
        XCTAssertEqual(service.renameRequests.count, 1)
        XCTAssertEqual(
            service.renameRequests[0].newProjectPath,
            "/tmp/destination"
        )
        XCTAssertTrue(
            service.killRequests.isEmpty,
            "Adoption must never kill a session process"
        )
    }

    func testNameTakenReallocatesOnce() async {
        let session = sourceSession(index: 1)
        let service = FakeHygieneService(sessions: [session])
        service.renameOutcomes = [
            .nameTaken,
            .renamed
        ]
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: nil)
        )
        let model = TmuxMigrationModel()
        let preview = model.prepare(
            sourcePath: "/tmp/source",
            destinationPath: "/tmp/destination",
            destinationPrefix: destinationPrefix,
            snapshot: TmuxTestData.snapshot([session]),
            destinationIdentity: identityRecord(),
            sourceIdentity: identityRecord()
        )
        let results = await model.execute(
            preview: preview,
            coordinator: coordinator,
            snapshot: TmuxTestData.snapshot([session]),
            rebindTabs: { _ in }
        )
        XCTAssertEqual(results[session.identity], .renamed)
        XCTAssertEqual(service.renameRequests.count, 2)
        XCTAssertNotEqual(
            service.renameRequests[0].newName,
            service.renameRequests[1].newName
        )
    }

    func testNameTakenRetryDoesNotStealALaterReservation() async {
        let first = sourceSession(index: 1)
        let second = sourceSession(index: 2)
        let service = FakeHygieneService(sessions: [first, second])
        service.renameOutcomes = [
            .nameTaken,
            .renamed,
            .renamed
        ]
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: nil)
        )
        let model = TmuxMigrationModel()
        let preview = model.prepare(
            sourcePath: "/tmp/source",
            destinationPath: "/tmp/destination",
            destinationPrefix: destinationPrefix,
            snapshot: TmuxTestData.snapshot([first, second]),
            destinationIdentity: identityRecord(),
            sourceIdentity: identityRecord()
        )
        XCTAssertEqual(
            preview.reservedNames,
            [destinationPrefix + "1", destinationPrefix + "2"]
        )
        _ = await model.execute(
            preview: preview,
            coordinator: coordinator,
            snapshot: TmuxTestData.snapshot([first, second]),
            rebindTabs: { _ in }
        )
        XCTAssertEqual(service.renameRequests.count, 3)
        // The retry for the first candidate allocates above both planned
        // names instead of taking the second candidate's reservation.
        XCTAssertEqual(
            service.renameRequests[1].newName,
            destinationPrefix + "3"
        )
        XCTAssertEqual(
            service.renameRequests[2].newName,
            destinationPrefix + "2"
        )
    }

    func testSecondNameTakenIsADefinitiveFailure() async {
        let session = sourceSession(index: 1)
        let service = FakeHygieneService(sessions: [session])
        service.renameOutcomes = [.nameTaken, .nameTaken]
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: nil)
        )
        let model = TmuxMigrationModel()
        let preview = model.prepare(
            sourcePath: "/tmp/source",
            destinationPath: "/tmp/destination",
            destinationPrefix: destinationPrefix,
            snapshot: TmuxTestData.snapshot([session]),
            destinationIdentity: identityRecord(),
            sourceIdentity: identityRecord()
        )
        let results = await model.execute(
            preview: preview,
            coordinator: coordinator,
            snapshot: TmuxTestData.snapshot([session]),
            rebindTabs: { _ in }
        )
        guard case .failed = results[session.identity] else {
            return XCTFail("Expected a definitive failure")
        }
        XCTAssertEqual(service.renameRequests.count, 2)
    }

    func testUncertainRenameStopsAndIsNeverRetried() async {
        let first = sourceSession(index: 1)
        let second = sourceSession(index: 2)
        let service = FakeHygieneService(sessions: [first, second])
        service.renameOutcomes = [.uncertain(reason: "reply lost")]
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: nil)
        )
        let model = TmuxMigrationModel()
        let preview = model.prepare(
            sourcePath: "/tmp/source",
            destinationPath: "/tmp/destination",
            destinationPrefix: destinationPrefix,
            snapshot: TmuxTestData.snapshot([first, second]),
            destinationIdentity: identityRecord(),
            sourceIdentity: identityRecord()
        )
        let results = await model.execute(
            preview: preview,
            coordinator: coordinator,
            snapshot: TmuxTestData.snapshot([first, second]),
            rebindTabs: { _ in }
        )
        guard case .uncertain = results[first.identity] else {
            return XCTFail("Expected uncertain")
        }
        XCTAssertEqual(
            results[second.identity],
            .notAttempted(
                reason: "An earlier rename was unresolved."
            )
        )
        XCTAssertEqual(service.renameRequests.count, 1)
        XCTAssertTrue(coordinator.isUncertain(first.identity))
    }

    func testRenameThatLandedBeforeAReplyLossIsUncertainAndNeverRetried() async {
        let first = sourceSession(index: 1)
        let second = sourceSession(index: 2)
        let service = FakeHygieneService(sessions: [first, second])
        service.renameOutcomes = [.uncertain(reason: "reply lost")]
        service.renameAppliedOnUncertain = true
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: nil)
        )
        let model = TmuxMigrationModel()
        let preview = model.prepare(
            sourcePath: "/tmp/source",
            destinationPath: "/tmp/destination",
            destinationPrefix: destinationPrefix,
            snapshot: TmuxTestData.snapshot([first, second]),
            destinationIdentity: identityRecord(),
            sourceIdentity: identityRecord()
        )
        let results = await model.execute(
            preview: preview,
            coordinator: coordinator,
            snapshot: TmuxTestData.snapshot([first, second]),
            rebindTabs: { _ in }
        )
        guard case .uncertain = results[first.identity] else {
            return XCTFail("Expected uncertain after a reply loss")
        }
        XCTAssertEqual(service.renameRequests.count, 1)
        XCTAssertEqual(
            results[second.identity],
            .notAttempted(
                reason: "An earlier rename was unresolved."
            )
        )
        XCTAssertTrue(coordinator.isUncertain(first.identity))
        XCTAssertEqual(
            service.sessions.first(where: { $0.identity == first.identity })?.name,
            destinationPrefix + "1"
        )
    }

    func testPartialFailureKeepsOtherResults() async {
        let first = sourceSession(index: 1)
        let second = sourceSession(index: 2)
        let service = FakeHygieneService(sessions: [first, second])
        service.renameOutcomes = [
            .refused(reason: "identity changed"),
            .renamed
        ]
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: nil)
        )
        let model = TmuxMigrationModel()
        let preview = model.prepare(
            sourcePath: "/tmp/source",
            destinationPath: "/tmp/destination",
            destinationPrefix: destinationPrefix,
            snapshot: TmuxTestData.snapshot([first, second]),
            destinationIdentity: identityRecord(),
            sourceIdentity: identityRecord()
        )
        let results = await model.execute(
            preview: preview,
            coordinator: coordinator,
            snapshot: TmuxTestData.snapshot([first, second]),
            rebindTabs: { _ in }
        )
        guard case .failed = results[first.identity] else {
            return XCTFail("Expected failed")
        }
        XCTAssertEqual(results[second.identity], .renamed)
    }

    func testMigrationReportIsPersisted() async throws {
        let directory = TmuxTestFiles.temporaryDirectory()
        let url = directory.appendingPathComponent("migration.json")
        let reportStore = TmuxMigrationReportStore(url: url)
        let session = sourceSession(index: 1)
        let service = FakeHygieneService(sessions: [session])
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: nil)
        )
        let model = TmuxMigrationModel(reportStore: reportStore)
        let preview = model.prepare(
            sourcePath: "/tmp/source",
            destinationPath: "/tmp/destination",
            destinationPrefix: destinationPrefix,
            snapshot: TmuxTestData.snapshot([session]),
            destinationIdentity: identityRecord(),
            sourceIdentity: identityRecord()
        )
        _ = await model.execute(
            preview: preview,
            coordinator: coordinator,
            snapshot: TmuxTestData.snapshot([session]),
            rebindTabs: { _ in }
        )
        let report = try XCTUnwrap(reportStore.report)
        XCTAssertEqual(report.rows.count, 1)
        XCTAssertEqual(report.rows[0].outcome, "renamed")
        XCTAssertEqual(
            report.rows[0].currentName,
            sourcePrefix + "1"
        )
        let onDisk = try XCTUnwrap(
            HygieneFile.read(TmuxMigrationReport.self, from: url)
        )
        XCTAssertEqual(onDisk.rows, report.rows)
    }

    // MARK: Ownership and tabs

    func testRenameUpdatesRegistryAndLedger() async throws {
        let directory = TmuxTestFiles.temporaryDirectory()
        let registryURL = directory.appendingPathComponent("registry.json")
        let ledgerURL = directory.appendingPathComponent("ledger.json")
        let registry = TmuxOwnershipRegistryStore(url: registryURL)
        let ledger = ObservedIdleLedgerStore(url: ledgerURL)
        let session = sourceSession(index: 1)
        registry.merge(snapshot: TmuxTestData.snapshot([session]))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.apply(
            snapshot: TmuxTestData.snapshot([session], now: start),
            now: start
        )
        let service = FakeHygieneService(sessions: [session])
        let coordinator = TmuxActionCoordinator(
            transport: service,
            boot: TmuxTestData.boot,
            uncertainStore: TmuxUncertainStore(url: nil),
            registry: registry,
            ledger: ledger
        )
        let outcome = await coordinator.rename(
            observation: session,
            newName: destinationPrefix + "1",
            newProjectPath: "/tmp/destination"
        )
        XCTAssertEqual(outcome, .renamed)
        XCTAssertEqual(
            registry.entries[session.identity],
            TmuxRegistryEntry(
                projectPath: "/tmp/destination",
                createdAt: session.createdAt
            )
        )
        XCTAssertNotNil(ledger.ledger.entries[session.identity])
    }

    func testSourceTabIsDetachedAndDestinationGetsAnAttachOnlyTab() {
        let fake = FakeTmuxForMigration()
        let sourceStore = TerminalSessionsStore(
            workingDirectory: FileManager.default.temporaryDirectory.path,
            projectKey: "/tmp/source",
            projectName: "Source",
            terminalEnvironment: TerminalEnvironment(
                tmux: fake,
                isEnabled: { true }
            )
        )
        let oldName = sourceStore.sessions[0].tmuxSessionName
        XCTAssertNotNil(oldName)
        sourceStore.detachTab(named: oldName!)
        XCTAssertTrue(sourceStore.sessions.isEmpty)

        let destinationStore = TerminalSessionsStore(
            workingDirectory: FileManager.default.temporaryDirectory.path,
            projectKey: "/tmp/destination",
            projectName: "Destination",
            terminalEnvironment: TerminalEnvironment(
                tmux: fake,
                isEnabled: { true }
            )
        )
        let newName = TmuxNaming.sessionName(
            prefix: TmuxNaming.prefix(
                projectKey: "/tmp/destination",
                projectName: "Destination"
            ),
            index: 5
        )
        XCTAssertTrue(
            destinationStore.attachExistingSession(named: newName)
        )
        XCTAssertEqual(
            destinationStore.sessions.last?.tmuxSessionName,
            newName
        )
        XCTAssertEqual(
            destinationStore.sessions.last?.view.initialCommand,
            "/bin/sh -c 'launch:\(newName):~'"
        )
    }

    func testReservedNamesAreSkippedByNewTabs() async {
        let prefix = TmuxNaming.prefix(
            projectKey: "/tmp/project",
            projectName: "Project"
        )
        let fake = FakeTmuxForMigration()
        let store = TerminalSessionsStore(
            workingDirectory: FileManager.default.temporaryDirectory.path,
            projectKey: "/tmp/project",
            projectName: "Project",
            terminalEnvironment: TerminalEnvironment(
                tmux: fake,
                isEnabled: { true }
            )
        )
        store.reserveSessionNames([prefix + "2"])
        store.addSession()
        await store.awaitPendingAllocations()
        XCTAssertEqual(
            store.sessions[1].tmuxSessionName,
            prefix + "3"
        )
        store.releaseSessionNames([prefix + "2"])
    }
}

private final class FakeTmuxForMigration: TmuxControlling, @unchecked Sendable {
    let isAvailable = true
    private let lock = NSLock()
    private var known: Set<String> = []

    func sessionNames(prefix: String) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return known.filter { $0.hasPrefix(prefix) }
    }

    func sessionExists(name: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return known.contains(name)
    }

    func launchInput(name: String, directory: String) -> String {
        lock.lock()
        known.insert(name)
        lock.unlock()
        return "launch:\(name):\(directory)"
    }

    func kill(name: String) -> Bool {
        lock.lock()
        known.remove(name)
        lock.unlock()
        return true
    }

    func runningSessions(
        candidates: Set<String>,
        shellNames: Set<String>
    ) -> Set<String>? {
        []
    }
}
