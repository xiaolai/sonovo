import XCTest
@testable import Sonovo

final class TerminalShellTests: XCTestCase {
    func testUsableRequiresAnExecutableRegularFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SonovoShell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(TerminalShell.isUsable("/bin/zsh"))
        XCTAssertFalse(TerminalShell.isUsable(directory.path))
        XCTAssertFalse(TerminalShell.isUsable("/definitely/missing/zsh"))
        XCTAssertFalse(TerminalShell.isUsable("bin/zsh"))

        let script = directory.appendingPathComponent("plain.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        XCTAssertFalse(TerminalShell.isUsable(script.path))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        XCTAssertTrue(TerminalShell.isUsable(script.path))
    }

    func testResolveFallsBackToTheAccountShell() {
        XCTAssertEqual(TerminalShell.resolve("/bin/zsh"), "/bin/zsh")
        XCTAssertEqual(
            TerminalShell.resolve("not a path"),
            TerminalShell.accountShell
        )
        XCTAssertEqual(
            TerminalShell.resolve(""),
            TerminalShell.accountShell
        )
        XCTAssertEqual(
            TerminalShell.resolve("/definitely/missing/zsh"),
            TerminalShell.accountShell
        )
    }

    func testMissingOnlyForNonEmptyUnusablePaths() {
        XCTAssertFalse(TerminalShell.isMissing(""))
        XCTAssertFalse(TerminalShell.isMissing("/bin/zsh"))
        XCTAssertTrue(TerminalShell.isMissing("/definitely/missing/zsh"))
    }

    func testAvailableOptionsAreExecutable() {
        for option in TerminalShell.available() {
            XCTAssertTrue(
                TerminalShell.isUsable(option.path),
                "offered a shell that cannot run: \(option.path)"
            )
        }
    }
}
