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
        let attach = "exec \(tool) set-option -s exit-unattached off "
            + "\\; set-option -t \(target) destroy-unattached off "
            + "\\; attach -t \(target)"
        let setup = "\(tool) set-option -s exit-unattached off "
            + "\\; new-session -d -s 'sonovo-x-ab12cd34-1' "
            + "-c '/tmp/a b' "
            + "\\; set-option -t \(target) destroy-unattached off"
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
