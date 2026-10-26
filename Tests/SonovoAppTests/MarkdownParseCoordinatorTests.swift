import XCTest
@testable import Sonovo
import SonovoCore

@MainActor
final class MarkdownParseCoordinatorTests: XCTestCase {
    private nonisolated static func makeOutput(
        _ input: MarkdownParseInput,
        nesting: Bool = false
    ) -> MarkdownParseOutput {
        let parsed = MarkdownParser.parseCanonical(input.source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        let effective = nesting
            ? ParsedMarkdown(
                source: parsed.source,
                ast: parsed.ast,
                bodySourceMap: parsed.bodySourceMap,
                fullSourceMap: parsed.fullSourceMap,
                bodyStartOffset: parsed.bodyStartOffset,
                exceededNestingLimit: true
            )
            : parsed
        return MarkdownParseOutput(
            documentID: input.documentID,
            revision: input.revision,
            parsed: effective,
            ast: ast,
            headings: HeadingIndex(ast: ast)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func makeCoordinator(
        attempts: Int = 2,
        parse: @escaping MarkdownParseCoordinator.ParseOperation
    ) -> MarkdownParseCoordinator {
        MarkdownParseCoordinator(
            maximumAttempts: attempts,
            initialRetryDelay: 0.01,
            maximumRetryDelay: 0.02,
            parse: parse
        )
    }

    func testRequestPublishesReadyAndCountsOneParse() async {
        let documentID = UUID()
        let counter = CallCounter()
        let coordinator = makeCoordinator { input in
            await counter.record()
            return Self.makeOutput(input)
        }
        coordinator.request(
            documentID: documentID,
            identityGeneration: 0,
            revision: 3,
            source: "# Title\n"
        )
        let state = await coordinator.awaitSettled(
            documentID: documentID,
            revision: 3
        )
        guard case .ready(let output)? = state else {
            XCTFail("expected ready, got \(String(describing: state))")
            return
        }
        XCTAssertEqual(output.revision, 3)
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    func testARepeatRequestForTheSameRevisionParsesOnce() async {
        let documentID = UUID()
        let counter = CallCounter()
        let coordinator = makeCoordinator { input in
            await counter.record()
            return Self.makeOutput(input)
        }
        coordinator.request(
            documentID: documentID,
            identityGeneration: 0,
            revision: 1,
            source: "body"
        )
        _ = await coordinator.awaitSettled(
            documentID: documentID,
            revision: 1
        )
        // A mode switch or a second view asks for the same revision.
        coordinator.request(
            documentID: documentID,
            identityGeneration: 0,
            revision: 1,
            source: "body"
        )
        try? await Task.sleep(for: .milliseconds(50))
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    func testADroppedRequestRetriesTheCurrentRevision() async {
        let documentID = UUID()
        let counter = CallCounter()
        let coordinator = makeCoordinator { input in
            let call = await counter.record()
            if call <= 2 { return nil }
            return Self.makeOutput(input)
        }
        coordinator.request(
            documentID: documentID,
            identityGeneration: 0,
            revision: 1,
            source: "body"
        )
        let settled = await waitUntil {
            if case .ready = coordinator.state(for: documentID) {
                return true
            }
            return false
        }
        XCTAssertTrue(settled)
        let calls = await counter.count
        XCTAssertEqual(calls, 3)
    }

    func testARefusalKeepsTheLastSuccessfulOutput() async {
        let documentID = UUID()
        let coordinator = makeCoordinator { input in
            // Revision 1 succeeds; revision 2 trips the nesting guard.
            Self.makeOutput(input, nesting: input.revision == 2)
        }
        coordinator.request(
            documentID: documentID,
            identityGeneration: 0,
            revision: 1,
            source: "ok"
        )
        _ = await coordinator.awaitSettled(
            documentID: documentID,
            revision: 1
        )
        coordinator.request(
            documentID: documentID,
            identityGeneration: 0,
            revision: 2,
            source: "deep"
        )
        let state = await coordinator.awaitSettled(
            documentID: documentID,
            revision: 2
        )
        guard case .refused(let reason, let revision)? = state else {
            XCTFail("expected refused, got \(String(describing: state))")
            return
        }
        XCTAssertEqual(reason, .nestingLimit)
        XCTAssertEqual(revision, 2)
        XCTAssertEqual(
            coordinator.lastSuccessfulOutput(for: documentID)?.revision,
            1
        )
    }

    func testAReleaseDuringParsePublishesNothing() async {
        let documentID = UUID()
        let coordinator = makeCoordinator { input in
            try? await Task.sleep(for: .milliseconds(120))
            return Self.makeOutput(input)
        }
        coordinator.request(
            documentID: documentID,
            identityGeneration: 0,
            revision: 1,
            source: "body"
        )
        coordinator.release(documentID: documentID)
        try? await Task.sleep(for: .milliseconds(200))
        if case .idle = coordinator.state(for: documentID) {
            // Expected: the release removed the state.
        } else {
            XCTFail("a closed document published a parse")
        }
        XCTAssertNil(coordinator.lastSuccessfulOutput(for: documentID))
    }

    func testAnIdentityChangeDropsAStaleCompletion() async {
        let documentID = UUID()
        let coordinator = makeCoordinator { input in
            if input.source == "old" {
                try? await Task.sleep(for: .milliseconds(120))
            }
            return Self.makeOutput(input)
        }
        coordinator.request(
            documentID: documentID,
            identityGeneration: 0,
            revision: 1,
            source: "old"
        )
        // Save As bumps the identity; the new document renders revision 2.
        coordinator.request(
            documentID: documentID,
            identityGeneration: 1,
            revision: 2,
            source: "old"
        )
        let settled = await coordinator.awaitSettled(
            documentID: documentID,
            revision: 2
        )
        guard case .ready(let output)? = settled else {
            XCTFail("expected ready, got \(String(describing: settled))")
            return
        }
        XCTAssertEqual(output.revision, 2)
        try? await Task.sleep(for: .milliseconds(200))
        guard case .ready(let latest) = coordinator
            .state(for: documentID) else {
            XCTFail("the stale completion replaced the state")
            return
        }
        XCTAssertEqual(latest.revision, 2)
    }
}

/// Serializes parse-call counting across the coordinator's worker.
private actor CallCounter {
    private var calls = 0

    @discardableResult
    func record() -> Int {
        calls += 1
        return calls
    }

    var count: Int { calls }
}
