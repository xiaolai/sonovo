import XCTest
@testable import Sonovo

@MainActor
final class TerminalSessionsTests: XCTestCase {
    private var fixture: ProjectUXTestSupport!

    override func setUp() {
        super.setUp()
        fixture = ProjectUXTestSupport()
    }

    override func tearDown() {
        fixture.tearDown()
        fixture = nil
        super.tearDown()
    }

    func testProcessProbeDrivesTheCount() {
        let store = TerminalSessionsStore()
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.runningProcessCount, 0)

        store.processProbe = { _ in true }
        store.refreshProcessStates()
        XCTAssertEqual(store.runningProcessCount, 1)

        // A repeated poll with the same answer must not invalidate chips.
        store.refreshProcessStates()
        XCTAssertEqual(store.runningProcessCount, 1)

        store.processProbe = { _ in false }
        store.refreshProcessStates()
        XCTAssertEqual(store.runningProcessCount, 0)
    }

    func testAddAndShutdownRefreshImmediately() {
        let store = TerminalSessionsStore()
        store.processProbe = { _ in true }
        store.refreshProcessStates()
        XCTAssertEqual(store.runningProcessCount, 1)

        store.addSession()
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.runningProcessCount, 2)

        store.shutdownAll(force: true)
        XCTAssertEqual(store.sessions.count, 0)
        XCTAssertEqual(store.runningProcessCount, 0)
    }

    func testWorkspaceRefreshesEveryProject() throws {
        let workspace = fixture.makeWorkspace()
        let project = try XCTUnwrap(
            workspace.openProject(
                at: try fixture.makeRoot(name: "one")
            )
        )
        workspace.demoProject.terminalSessions.processProbe = { _ in true }
        project.terminalSessions.processProbe = { _ in true }

        workspace.refreshTerminalProcessStates()

        XCTAssertEqual(
            workspace.demoProject.terminalSessions.runningProcessCount,
            1
        )
        XCTAssertEqual(
            project.terminalSessions.runningProcessCount,
            1
        )
    }

    func testTmuxTabsUseTheProjectPrefix() async {
        let prefix = TmuxNaming.prefix(
            projectKey: "/tmp/project",
            projectName: "Project"
        )
        let fake = FakeTmux()
        let store = makeTmuxStore(fake: fake, path: "/tmp/project")

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(
            store.sessions[0].tmuxSessionName,
            prefix + "1"
        )
        XCTAssertEqual(store.sessions[0].view.initialCommand, "/bin/sh")
        XCTAssertEqual(
            store.sessions[0].view.initialInput,
            "launch:\(prefix)1:"
                + FileManager.default.temporaryDirectory.path
        )

        store.addSession()
        await store.awaitPendingAllocations()
        XCTAssertEqual(
            store.sessions[1].tmuxSessionName,
            prefix + "2"
        )
    }

    func testRestoreAppendsOnlyMissingIndexes() async {
        let prefix = TmuxNaming.prefix(
            projectKey: "/tmp/project",
            projectName: "Project"
        )
        let fake = FakeTmux(names: [prefix + "3", prefix + "1"])
        let store = makeTmuxStore(fake: fake, path: "/tmp/project")

        let deadline = Date().addingTimeInterval(2)
        while store.sessions.count < 2, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(
            store.sessions[0].tmuxSessionName,
            prefix + "1"
        )
        XCTAssertEqual(
            store.sessions[1].tmuxSessionName,
            prefix + "3"
        )
        XCTAssertEqual(
            store.sessions[1].view.initialInput,
            "launch:\(prefix)3:"
                + FileManager.default.temporaryDirectory.path
        )

        store.addSession()
        await store.awaitPendingAllocations()
        XCTAssertEqual(
            store.sessions.last?.tmuxSessionName,
            prefix + "4"
        )
    }

    func testClosingTmuxTabDetachesAndEndingKills() async throws {
        let prefix = TmuxNaming.prefix(
            projectKey: "/tmp/project",
            projectName: "Project"
        )
        let fake = FakeTmux()
        let store = makeTmuxStore(fake: fake, path: "/tmp/project")
        let first = store.sessions[0]

        store.closeSession(first.id)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(fake.killedNames.isEmpty)

        let ending = makeTmuxStore(fake: fake, path: "/tmp/project")
        let name = try XCTUnwrap(ending.sessions[0].tmuxSessionName)
        ending.endConfirmation = { _ in true }
        fake.markRunning([name])
        await ending.endSession(ending.sessions[0].id)
        XCTAssertEqual(fake.killedNames, [name])
        XCTAssertEqual(name, prefix + "1")
        XCTAssertTrue(ending.sessions.isEmpty)
    }

    func testEndFailureKeepsTheTabVisible() async {
        let fake = FakeTmux()
        let store = makeTmuxStore(fake: fake, path: "/tmp/project")
        let name = store.sessions[0].tmuxSessionName
        if let name {
            fake.markRunning([name])
        }
        fake.killSucceeds = false
        store.endConfirmation = { _ in true }

        await store.endSession(store.sessions[0].id)

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertNotNil(store.lastError)
        store.dismissError()
        XCTAssertNil(store.lastError)
    }

    func testNewTabAfterClosingAllStillQueriesServer() async {
        let prefix = TmuxNaming.prefix(
            projectKey: "/tmp/project",
            projectName: "Project"
        )
        let fake = FakeTmux(names: [prefix + "1"])
        let store = makeTmuxStore(fake: fake, path: "/tmp/project")
        store.closeSession(store.sessions[0].id)
        // A server-only session the local counters do not know about. Only a
        // real query can push the next allocation past it.
        fake.markKnown(prefix + "5")

        store.addSession()
        await store.awaitPendingAllocations()

        XCTAssertEqual(
            store.sessions[0].tmuxSessionName,
            prefix + "6"
        )
    }

    func testFailedDiscoveryRefusesNewTab() async {
        let fake = FakeTmux()
        let store = makeTmuxStore(fake: fake, path: "/tmp/project")
        fake.failDiscovery()

        store.addSession()
        await store.awaitPendingAllocations()

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertNotNil(store.lastError)
    }

    func testTmuxProbeUpdatesCountAsynchronously() async {
        let fake = FakeTmux()
        let store = makeTmuxStore(fake: fake, path: "/tmp/project")
        let name = store.sessions[0].tmuxSessionName
        if let name {
            fake.markRunning([name])
        }

        store.refreshProcessStates()

        let deadline = Date().addingTimeInterval(2)
        while store.runningProcessCount != 1, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.runningProcessCount, 1)
    }

    func testShutdownNeverKillsTmuxAndIgnoresItsProcesses() {
        let fake = FakeTmux()
        let store = makeTmuxStore(fake: fake, path: "/tmp/project")
        store.processProbe = { _ in true }

        XCTAssertFalse(store.hasLiveDirectProcess)
        store.shutdownAll(force: false)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(fake.killedNames.isEmpty)

        let direct = TerminalSessionsStore()
        direct.processProbe = { _ in true }
        XCTAssertTrue(direct.hasLiveDirectProcess)
    }

    private func makeTmuxStore(
        fake: FakeTmux,
        path: String
    ) -> TerminalSessionsStore {
        TerminalSessionsStore(
            workingDirectory: FileManager.default.temporaryDirectory.path,
            projectKey: path,
            projectName: URL(fileURLWithPath: path).lastPathComponent,
            terminalEnvironment: TerminalEnvironment(
                tmux: fake,
                isEnabled: { true }
            )
        )
    }
}

private final class FakeTmux: TmuxControlling, @unchecked Sendable {
    let isAvailable = true
    private let lock = NSLock()
    private var known: Set<String>
    private var killed: [String] = []
    private var running: Set<String> = []
    var killSucceeds = true
    private var namesUnavailable = false

    init(names: [String] = []) {
        self.known = Set(names)
    }

    func failDiscovery() {
        lock.lock()
        defer { lock.unlock() }
        namesUnavailable = true
    }

    var killedNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return killed
    }

    func sessionNames(prefix: String) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        guard !namesUnavailable else { return nil }
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
        defer { lock.unlock() }
        guard killSucceeds else { return false }
        killed.append(name)
        known.remove(name)
        return true
    }

    func markRunning(_ names: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        running = names
    }

    func markKnown(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        known.insert(name)
    }

    func runningSessions(
        candidates: Set<String>,
        shellNames: Set<String>
    ) -> Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        return running.intersection(candidates)
    }
}
