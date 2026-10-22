import Foundation
import XCTest
@testable import Sonovo

/// M1 — model-level measurements for the viewer budgets. First paint and
/// keystroke rendering need the running app, which this repository does not
/// launch on the user's workstation; these measure the work behind them
/// (bounded read/decode, full lex, incremental lex, literal find) and record
/// the numbers in the plan.
@MainActor
final class CodePerformanceTests: XCTestCase {
    private func fixture(
        text: String,
        name: String
    ) throws -> (URL, CodeTestSupport) {
        let support = CodeTestSupport()
        let root = try support.makeRoot(files: [name: Data(text.utf8)])
        return (root.appendingPathComponent(name), support)
    }

    func testTwoMegabyteColdReadAndLex() async throws {
        let line = "let value = 1234567890\n"
        let count = max(1, CodeLimits.editableBytes / line.utf8.count)
        let text = String(repeating: line, count: count)
        let (url, support) = try fixture(text: text, name: "large.swift")
        defer { support.tearDown() }

        let clock = ContinuousClock()
        // Best of three: the numbers are a liveness check on an unoptimized
        // build, and a single run on a loaded machine can be several times
        // the true cost. A real regression shows up in every run.
        var readDuration = Duration.seconds(3_600)
        var outcome: CodeFileReadOutcome?
        for _ in 0..<3 {
            let start = clock.now
            outcome = try CodeFileReader().read(url: url)
            readDuration = min(readDuration, clock.now - start)
        }
        guard case .loaded(let read) = outcome else {
            return XCTFail("the 2 MB fixture must load")
        }

        var lexDuration = Duration.seconds(3_600)
        var snapshot: CodeLexSnapshot?
        for _ in 0..<3 {
            let start = clock.now
            snapshot = CodeSyntaxHighlighter.lex(
                text: read.contents.canonicalText,
                language: .swift,
                revision: 1
            )
            lexDuration = min(lexDuration, clock.now - start)
        }
        guard let snapshot else {
            return XCTFail("the 2 MB fixture must lex")
        }
        print(
            "M1 2MB: read=\(readDuration) lex=\(lexDuration) "
                + "lines=\(snapshot.lines.count)"
        )
        XCTAssertLessThan(readDuration, .seconds(1))
        #if DEBUG
        // Unoptimized builds measure the algorithm, not the shipping
        // configuration. The recorded M1 numbers come from `-c release`.
        // This ceiling is a liveness check on a shared machine: concurrent
        // builds and test runs can make the best of three several times the
        // idle cost (observed 5.6 s under load, 1.3–2.1 s idle), while a
        // real algorithmic regression would be tens of seconds.
        XCTAssertLessThan(lexDuration, .seconds(12))
        #else
        XCTAssertLessThan(lexDuration, .milliseconds(400))
        #endif
    }

    func testTwentyThousandLineKeystrokeRelexAndFind() async throws {
        var lines = (0..<20_000).map { "let value\($0) = \($0)" }
        let text = lines.joined(separator: "\n") + "\n"
        let (url, support) = try fixture(text: text, name: "lines.swift")
        defer { support.tearDown() }

        let first = CodeSyntaxHighlighter.lex(
            text: text,
            language: .swift,
            revision: 1
        )
        lines[10_000] = "let value10000 = 99999"
        let edited = lines.joined(separator: "\n") + "\n"

        let clock = ContinuousClock()
        var start = clock.now
        let relexed = CodeSyntaxHighlighter.relex(
            previous: first,
            text: edited,
            language: .swift,
            revision: 2,
            editedLine: 10_000
        )
        let relexDuration = clock.now - start
        print(
            "M1 20k keystroke: relex=\(relexDuration) "
                + "reprocessed=\(relexed.reprocessedLineCount)"
        )
        #if DEBUG
        // See the release note above; the Debug ceiling is a liveness check
        // and the suite may run other classes in parallel.
        XCTAssertLessThan(relexDuration, .milliseconds(500))
        #else
        XCTAssertLessThan(relexDuration, .milliseconds(16))
        #endif

        let document = CodeDocument(url: url)
        await document.load()
        let controller = CodeEditorController(
            document: document,
            settings: CodeEditorSettings()
        )
        let findStart = clock.now
        let matches = controller.find("value10000")
        let findDuration = clock.now - findStart
        print(
            "M1 20k find: \(findDuration) matches=\(matches.count)"
        )
        XCTAssertLessThan(findDuration, .milliseconds(200))
    }
}
