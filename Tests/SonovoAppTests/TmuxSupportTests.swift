import XCTest
@testable import Sonovo

final class TmuxSupportTests: XCTestCase {
    func testSessionNameShapeAndIndex() {
        let prefix = TmuxNaming.prefix(
            projectKey: "/tmp/My Project",
            projectName: "My Project"
        )
        XCTAssertTrue(prefix.hasPrefix("sonovo-my-project-"))
        let name = TmuxNaming.sessionName(prefix: prefix, index: 3)
        XCTAssertEqual(name, "\(prefix)3")
        XCTAssertEqual(TmuxNaming.index(of: name, prefix: prefix), 3)
        XCTAssertNil(TmuxNaming.index(of: prefix + "x", prefix: prefix))
        XCTAssertNil(
            TmuxNaming.index(
                of: "sonovo-other-abcdef12-1",
                prefix: prefix
            )
        )
    }

    func testHashIsStableAndPathSpecific() {
        XCTAssertEqual(
            TmuxNaming.hash8("/projects/one"),
            TmuxNaming.hash8("/projects/one")
        )
        XCTAssertNotEqual(
            TmuxNaming.hash8("/projects/one"),
            TmuxNaming.hash8("/projects/two")
        )
        XCTAssertEqual(TmuxNaming.hash8("/projects/one").count, 8)
    }

    func testSlugSanitizesNames() {
        XCTAssertEqual(TmuxNaming.slug("My Project!"), "my-project")
        XCTAssertEqual(TmuxNaming.slug("项目"), "项目")
        XCTAssertEqual(TmuxNaming.slug("---"), "project")
    }

    func testAttachShellCommandUsesExactTarget() {
        XCTAssertEqual(
            TmuxCommands.attachShellCommand(
                name: "sonovo-x-ab12cd34-1"
            ),
            "tmux attach -t '=sonovo-x-ab12cd34-1'"
        )
    }

    func testShellQuoteHandlesSpacesAndApostrophes() {
        XCTAssertEqual(TmuxNaming.shellQuote("/tmp/a b"), "'/tmp/a b'")
        XCTAssertEqual(
            TmuxNaming.shellQuote("it's"),
            "'it'\\''s'"
        )
    }

    func testLaunchAndAttachCommands() {
        let command = TmuxCommands.open(
            executable: "/opt/homebrew/bin/tmux",
            name: "sonovo-x-ab12cd34-1",
            directory: "/tmp/a b"
        )
        let tool = "'/opt/homebrew/bin/tmux'"
        let target = "'=sonovo-x-ab12cd34-1'"
        // `set-option` rejects the `=` prefix; it targets the plain name.
        let session = "'sonovo-x-ab12cd34-1'"
        let attach = "exec \(tool) set-option -s exit-unattached off "
            + "\\; set-option -t \(session) destroy-unattached off "
            + "\\; attach -t \(target)"
        let setup = "\(tool) set-option -s exit-unattached off "
            + "\\; new-session -d -s 'sonovo-x-ab12cd34-1' "
            + "-c '/tmp/a b' "
            + "\\; set-option -t \(session) destroy-unattached off"
        let expected = "if \(tool) has-session -t \(target) 2>/dev/null; "
            + "then \(attach); else \(setup) 2>/dev/null; \(attach); fi\n"
        XCTAssertEqual(command, expected)
    }

    func testIndexRejectsAliasesAndOverflow() {
        let prefix = "sonovo-x-ab12cd34-"
        XCTAssertNil(TmuxNaming.index(of: prefix + "0", prefix: prefix))
        XCTAssertNil(TmuxNaming.index(of: prefix + "01", prefix: prefix))
        XCTAssertNil(
            TmuxNaming.index(
                of: prefix + String(Int.max),
                prefix: prefix
            )
        )
    }

    func testShellPaneWithChildIsBusy() {
        let output = "s1\t100\tzsh\ns2\t200\tzsh\n"
        let running = TmuxProbe.runningSessions(
            from: output,
            candidates: ["s1", "s2"],
            shellNames: ["zsh"],
            busyShellPIDs: [100]
        )
        XCTAssertEqual(running, ["s1"])
    }

    func testRunningProbeCountsOnlyNonShellForegrounds() {
        let output = "s1\t100\tzsh\ns1\t101\tclaude\ns2\t200\tnode\n"
            + "s3\t300\tbash\nother\t400\tcodex\n"
        let running = TmuxProbe.runningSessions(
            from: output,
            candidates: ["s1", "s2", "s3"],
            shellNames: ["zsh", "bash", "fish"],
            busyShellPIDs: [100]
        )
        XCTAssertEqual(running, ["s1", "s2"])
    }
}

final class TmuxTypedTransportTests: XCTestCase {
    private let separator = String(TmuxSnapshotParser.fieldSeparator)

    private func sessionLine(
        id: String = "$1",
        name: String = "sonovo-demo-ab12cd34-1",
        pid: Int = 501,
        attached: Int = 0,
        windows: Int = 1,
        created: Int = 1_800_000_000,
        activity: Int = 1_800_000_100,
        projectPath: String = "/tmp/project",
        createdAt: String = "",
        version: String = ""
    ) -> String {
        [
            id, name, String(pid), String(attached),
            String(windows), String(created), String(activity),
            projectPath, createdAt, version
        ].joined(separator: separator)
    }

    private func paneLine(
        session: String = "$1",
        pane: String = "%0",
        pid: Int32 = 42,
        command: String = "zsh",
        path: String = "/tmp/project",
        active: Bool = true,
        dead: Bool = false,
        window: Int = 0
    ) -> String {
        [
            session, pane, String(pid), command, path,
            active ? "1" : "0", dead ? "1" : "0", String(window)
        ].joined(separator: separator)
    }

    private func windowLine(
        session: String = "$1",
        window: String = "@0",
        linked: Bool = false
    ) -> String {
        [
            session, window, linked ? "1" : "0",
            linked ? "sonovo-demo-ab12cd34-1,foreign" : "sonovo-demo-ab12cd34-1"
        ].joined(separator: separator)
    }

    func testCompleteSnapshotParsesOwnershipProcessAndTopology() {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let createdString = ISO8601DateFormatter().string(from: created)
        let snapshot = TmuxSnapshotParser.sessions(
            from: sessionLine(createdAt: createdString, version: "0.5.5"),
            panesText: paneLine(),
            windowsText: windowLine(),
            parentPIDs: [],
            socketPath: TmuxTestData.socket,
            registry: [:],
            boot: TmuxTestData.boot,
            now: TmuxTestData.boot.startedAt
        )
        XCTAssertEqual(snapshot.completeness, .complete)
        XCTAssertEqual(snapshot.sessions.count, 1)
        let session = snapshot.sessions[0]
        XCTAssertEqual(session.name, "sonovo-demo-ab12cd34-1")
        XCTAssertEqual(session.ownership, .verified(projectPath: "/tmp/project"))
        XCTAssertEqual(session.process, .noCommandDetected)
        XCTAssertFalse(session.sharedWindows)
        XCTAssertEqual(session.activePath, "/tmp/project")
        XCTAssertEqual(session.server, TmuxTestData.server())
    }

    func testRunningCommandAndSharedWindow() {
        let snapshot = TmuxSnapshotParser.sessions(
            from: sessionLine(),
            panesText: paneLine(command: "claude"),
            windowsText: windowLine(linked: true),
            parentPIDs: [],
            socketPath: TmuxTestData.socket,
            registry: [:],
            boot: TmuxTestData.boot,
            now: TmuxTestData.boot.startedAt
        )
        XCTAssertEqual(snapshot.sessions[0].process, .running)
        XCTAssertTrue(snapshot.sessions[0].sharedWindows)
    }

    func testShellWithChildIsRunningAndMissingProcessTableIsUnknown() {
        let running = TmuxSnapshotParser.sessions(
            from: sessionLine(),
            panesText: paneLine(pid: 42),
            windowsText: windowLine(),
            parentPIDs: [42],
            socketPath: TmuxTestData.socket,
            registry: [:],
            boot: TmuxTestData.boot,
            now: TmuxTestData.boot.startedAt
        )
        XCTAssertEqual(running.sessions[0].process, .running)

        let unknown = TmuxSnapshotParser.sessions(
            from: sessionLine(),
            panesText: paneLine(),
            windowsText: windowLine(),
            parentPIDs: nil,
            socketPath: TmuxTestData.socket,
            registry: [:],
            boot: TmuxTestData.boot,
            now: TmuxTestData.boot.startedAt
        )
        XCTAssertEqual(unknown.sessions[0].process, .unknown)
    }

    func testRegistryProvesOwnershipWithoutMetadata() {
        let identity = TmuxTestData.identity()
        let registry: [TmuxSessionIdentity: TmuxRegistryEntry] = [
            identity: TmuxRegistryEntry(
                projectPath: "/registry/project",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        ]
        let snapshot = TmuxSnapshotParser.sessions(
            from: sessionLine(projectPath: ""),
            panesText: paneLine(),
            windowsText: windowLine(),
            parentPIDs: [],
            socketPath: TmuxTestData.socket,
            registry: registry,
            boot: TmuxTestData.boot,
            now: TmuxTestData.boot.startedAt
        )
        XCTAssertEqual(
            snapshot.sessions[0].ownership,
            .verified(projectPath: "/registry/project")
        )
    }

    func testMissingRegistryAndUnparseableNameAreNotVerified() {
        let unmapped = TmuxSnapshotParser.sessions(
            from: sessionLine(projectPath: ""),
            panesText: paneLine(),
            windowsText: windowLine(),
            parentPIDs: [],
            socketPath: TmuxTestData.socket,
            registry: [:],
            boot: TmuxTestData.boot,
            now: TmuxTestData.boot.startedAt
        )
        XCTAssertEqual(unmapped.sessions[0].ownership, .unmapped)

        let legacy = TmuxSnapshotParser.sessions(
            from: sessionLine(name: "sonovo-legacy", projectPath: ""),
            panesText: paneLine(),
            windowsText: windowLine(),
            parentPIDs: [],
            socketPath: TmuxTestData.socket,
            registry: [:],
            boot: TmuxTestData.boot,
            now: TmuxTestData.boot.startedAt
        )
        XCTAssertEqual(legacy.sessions[0].ownership, .unrecognized)
    }

    func testMalformedRecordNeverBecomesARow() {
        let snapshot = TmuxSnapshotParser.sessions(
            from: "$1\(separator)too-few-fields",
            panesText: paneLine(),
            windowsText: windowLine(),
            parentPIDs: [],
            socketPath: TmuxTestData.socket,
            registry: [:],
            boot: TmuxTestData.boot,
            now: TmuxTestData.boot.startedAt
        )
        XCTAssertTrue(snapshot.sessions.isEmpty)
        guard case .incomplete = snapshot.completeness else {
            return XCTFail("Expected incomplete, got \(snapshot.completeness)")
        }
    }

    func testOversizedFieldIsIncomplete() {
        let name = "sonovo-" + String(repeating: "a", count: 9000)
        let snapshot = TmuxSnapshotParser.sessions(
            from: sessionLine(name: name),
            panesText: paneLine(),
            windowsText: windowLine(),
            parentPIDs: [],
            socketPath: TmuxTestData.socket,
            registry: [:],
            boot: TmuxTestData.boot,
            now: TmuxTestData.boot.startedAt
        )
        guard case .incomplete = snapshot.completeness else {
            return XCTFail("Expected incomplete")
        }
    }

    func testMissingPaneOrWindowEvidenceIsIncomplete() {
        let noPanes = TmuxSnapshotParser.sessions(
            from: sessionLine(),
            panesText: "",
            windowsText: windowLine(),
            parentPIDs: [],
            socketPath: TmuxTestData.socket,
            registry: [:],
            boot: TmuxTestData.boot,
            now: TmuxTestData.boot.startedAt
        )
        guard case .incomplete = noPanes.completeness else {
            return XCTFail("Expected incomplete without pane evidence")
        }

        let noWindows = TmuxSnapshotParser.sessions(
            from: sessionLine(),
            panesText: paneLine(),
            windowsText: "",
            parentPIDs: [],
            socketPath: TmuxTestData.socket,
            registry: [:],
            boot: TmuxTestData.boot,
            now: TmuxTestData.boot.startedAt
        )
        guard case .incomplete = noWindows.completeness else {
            return XCTFail("Expected incomplete without window evidence")
        }
    }

    func testNilSessionAnswerIsUnknownAndEmptyIsComplete() {
        let unknown = TmuxSnapshotParser.sessions(
            from: nil,
            panesText: nil,
            windowsText: nil,
            parentPIDs: nil,
            socketPath: TmuxTestData.socket,
            registry: [:],
            boot: TmuxTestData.boot,
            now: TmuxTestData.boot.startedAt
        )
        XCTAssertEqual(unknown.completeness, .unknown)

        let empty = TmuxSnapshotParser.sessions(
            from: "",
            panesText: nil,
            windowsText: nil,
            parentPIDs: nil,
            socketPath: TmuxTestData.socket,
            registry: [:],
            boot: TmuxTestData.boot,
            now: TmuxTestData.boot.startedAt
        )
        XCTAssertEqual(empty.completeness, .complete)
        XCTAssertTrue(empty.sessions.isEmpty)
    }

    func testOwnershipCreatedAtFormatParses() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let text = date.formatted(.iso8601)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: text))
    }

    func testLaunchCommandCarriesOwnershipMetadata() {
        let command = TmuxCommands.open(
            executable: "/opt/homebrew/bin/tmux",
            name: "sonovo-demo-ab12cd34-1",
            directory: "/tmp/project",
            ownership: TmuxLaunchOwnership(
                projectPath: "/tmp/project",
                appVersion: "0.5.5"
            )
        )
        XCTAssertTrue(
            command.contains(
                "@sonovo_project_path '/tmp/project'"
            )
        )
        XCTAssertTrue(command.contains("@sonovo_created_at"))
        XCTAssertTrue(command.contains("$(date -u"))
        XCTAssertTrue(command.contains("@sonovo_app_version '0.5.5'"))
    }

    func testParsesOnlyGeneratedNames() {
        XCTAssertTrue(
            TmuxNaming.parsesSessionName("sonovo-demo-ab12cd34-1")
        )
        XCTAssertTrue(TmuxNaming.parsesSessionName("sonovo-sample-1"))
        XCTAssertTrue(
            TmuxNaming.parsesSessionName("sonovo-项目-ab12cd34-2")
        )
        XCTAssertFalse(TmuxNaming.parsesSessionName("sonovo-legacy"))
        XCTAssertFalse(
            TmuxNaming.parsesSessionName("sonovo-demo-ab12cd34-0")
        )
        XCTAssertFalse(
            TmuxNaming.parsesSessionName("sonovo-demo-abcdefgh-1")
        )
        XCTAssertFalse(TmuxNaming.parsesSessionName("foreign-1"))
    }

    func testTrailingIndexIndependentOfPrefix() {
        XCTAssertEqual(
            TmuxNaming.trailingIndex(of: "sonovo-old-ab12cd34-12"),
            12
        )
        XCTAssertNil(TmuxNaming.trailingIndex(of: "sonovo-old-ab12cd34-"))
        XCTAssertNil(TmuxNaming.trailingIndex(of: "sonovo-old-ab12cd34-01"))
    }

    func testCapturePaneBudgetReportsOmissions() {
        let panes = [
            TmuxPaneAddress(paneID: "%1", label: "one"),
            TmuxPaneAddress(paneID: "%2", label: "two"),
            TmuxPaneAddress(paneID: "%3", label: "three")
        ]
        let split = TmuxCapturePanes.split(panes, max: 2)
        XCTAssertEqual(split.kept.map(\.paneID), ["%1", "%2"])
        XCTAssertEqual(split.omitted, 1)
        let none = TmuxCapturePanes.split(panes, max: 0)
        XCTAssertTrue(none.kept.isEmpty)
        XCTAssertEqual(none.omitted, 3)
    }

    func testFinalCaptureClampEnforcesBytesAndLines() {
        let text = "[history+visible]\none\ntwo\n[alternate]\n(none)"
        let clamped = TmuxCaptureClipper.clamp(
            text,
            maxBytes: 12,
            maxLines: 3
        )
        XCTAssertTrue(clamped.truncated)
        XCTAssertLessThanOrEqual(clamped.text.utf8.count, 12)
        XCTAssertLessThanOrEqual(clamped.lines, 3)
    }

    func testCaptureTargetsStablePaneIDsNotIndexes() {
        let pane = TmuxTestData.pane(id: "%42", window: 7)
        XCTAssertEqual(pane.address.paneID, "%42")
        XCTAssertEqual(pane.address.label.contains("%42"), true)
    }

    func testCaptureComposerLabelsHistoryAndAlternateSections() {
        let pane = TmuxPaneAddress(paneID: "%1", label: "window 0")
        let withAlternate = TmuxCaptureComposer.text(
            pane: pane,
            history: "history-line",
            alternate: "alternate-line"
        )
        XCTAssertTrue(withAlternate.contains("%1"))
        XCTAssertTrue(withAlternate.contains("[history+visible]"))
        XCTAssertTrue(withAlternate.contains("history-line"))
        XCTAssertTrue(withAlternate.contains("[alternate]"))
        XCTAssertTrue(withAlternate.contains("alternate-line"))

        let withoutAlternate = TmuxCaptureComposer.text(
            pane: pane,
            history: "history-line",
            alternate: nil
        )
        XCTAssertTrue(
            withoutAlternate.contains("(no alternate screen)")
        )
    }

    func testFramingSeparatorSurvivesEmptyFields() {
        let line = ["$1", "", "", "", "", "", "", "", "", ""]
            .joined(separator: separator)
        let result = TmuxSnapshotParser.records(
            from: line + "\n",
            fieldCount: 10
        )
        guard case let .success(rows) = result else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(rows[0].count, 10)
        XCTAssertEqual(rows[0][1], "")
    }
}

final class TmuxBoundedRunnerTests: XCTestCase {
    func testCancellationStopsTheChild() async {
        let start = Date()
        let output = await Task.detached {
            BoundedProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 5"],
                deadline: Date().addingTimeInterval(5),
                maxBytes: 1024,
                isCancelled: { true }
            )
        }.value
        XCTAssertNotNil(output)
        XCTAssertTrue(output?.cancelled == true)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testTimeoutKeepsPartialOutputAndTerminates() async {
        let start = Date()
        let output = await Task.detached {
            BoundedProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "printf canary; sleep 5"],
                deadline: Date().addingTimeInterval(0.2),
                maxBytes: 1024
            )
        }.value
        XCTAssertNotNil(output)
        XCTAssertTrue(output?.timedOut == true)
        XCTAssertEqual(
            String(decoding: output?.stdout ?? Data(), as: UTF8.self),
            "canary"
        )
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testByteCapTruncatesAndTerminates() async {
        let start = Date()
        let output = await Task.detached {
            BoundedProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "yes"],
                deadline: Date().addingTimeInterval(5),
                maxBytes: 4096
            )
        }.value
        XCTAssertNotNil(output)
        XCTAssertTrue(output?.truncated == true)
        XCTAssertLessThanOrEqual(output?.stdout.count ?? 0, 4096)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testLiveTmuxAvailabilityFollowsTheExecutableProvider() {
        let box = ExecutableBox()
        let tmux = LiveTmux(
            executableProvider: { box.path },
            socketPath: "/tmp/sonovo-test.sock"
        )
        XCTAssertFalse(tmux.isAvailable)
        box.path = "/bin/echo"
        XCTAssertTrue(tmux.isAvailable)
        box.path = nil
        XCTAssertFalse(tmux.isAvailable)
    }
}

private final class ExecutableBox: @unchecked Sendable {
    var path: String?

    init(_ path: String? = nil) {
        self.path = path
    }
}
