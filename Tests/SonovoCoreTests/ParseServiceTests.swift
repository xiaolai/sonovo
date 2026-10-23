import Foundation
import Testing
@testable import SonovoCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var inFlight = 0
    private var maxInFlight = 0
    private var mainThreadCalls = 0

    func begin(_ onMainThread: Bool) {
        lock.lock()
        starts += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        if onMainThread { mainThreadCalls += 1 }
        lock.unlock()
    }

    func end() {
        lock.lock()
        inFlight -= 1
        lock.unlock()
    }

    var snapshot: (starts: Int, maxInFlight: Int, mainThreadCalls: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (starts, maxInFlight, mainThreadCalls)
    }
}

@Suite("Parse service")
struct ParseServiceTests {
    private func slowParser(_ counter: Counter) -> MarkdownParseService.Parser {
        { source, enableAutolinks in
            counter.begin(Thread.isMainThread)
            Thread.sleep(forTimeInterval: 0.05)
            counter.end()
            return MarkdownParser.parseCanonical(
                source,
                enableAutolinks: enableAutolinks
            )
        }
    }

    @Test("Coalesces typing into at most one in-flight parse plus the latest pending")
    func coalescing() async {
        let counter = Counter()
        let service = MarkdownParseService(parser: slowParser(counter))
        let documentID = UUID()

        let results = await withTaskGroup(
            of: MarkdownParseOutput?.self
        ) { group in
            for revision in 1...10 {
                group.addTask {
                    await service.parse(
                        MarkdownParseInput(
                            documentID: documentID,
                            revision: UInt64(revision),
                            source: "# Revision \(revision)\n"
                        )
                    )
                }
            }
            var collected: [MarkdownParseOutput?] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        let stats = counter.snapshot
        #expect(stats.maxInFlight == 1)
        #expect(stats.starts <= 2)
        #expect(stats.mainThreadCalls == 0)
        let revisions = results.compactMap { $0 }.map(\.revision)
        #expect(
            revisions.contains(10),
            "revisions \(revisions), starts \(stats.starts)"
        )
        #expect(await service.pendingCount == 0)
        let stillParsing = await service.isParsing
        #expect(!stillParsing)
    }

    @Test("Returns the latest cached result for a stale revision")
    func cachedLatest() async throws {
        let counter = Counter()
        let service = MarkdownParseService(parser: slowParser(counter))
        let documentID = UUID()

        let first = await service.parse(
            MarkdownParseInput(
                documentID: documentID,
                revision: 5,
                source: "# Old\n"
            )
        )
        #expect(first?.revision == 5)

        let second = await service.parse(
            MarkdownParseInput(
                documentID: documentID,
                revision: 3,
                source: "# Older\n"
            )
        )
        #expect(second?.revision == 5)
        #expect(counter.snapshot.starts == 1)
    }

    @Test("An older request during a newer parse does not regress the cache")
    func olderDuringNewer() async {
        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var entered = false
            private var released = false

            func markEntered() {
                lock.lock(); entered = true; lock.unlock()
            }

            var hasEntered: Bool {
                lock.lock(); defer { lock.unlock() }
                return entered
            }

            func wait() {
                while true {
                    lock.lock()
                    let finished = released
                    lock.unlock()
                    if finished { return }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }

            func release() {
                lock.lock(); released = true; lock.unlock()
            }
        }

        let gate = Gate()
        let counter = Counter()
        let service = MarkdownParseService(parser: { source, enableAutolinks in
            counter.begin(Thread.isMainThread)
            defer { counter.end() }
            if source.contains("newer") {
                gate.markEntered()
                gate.wait()
            }
            return MarkdownParser.parseCanonical(
                source,
                enableAutolinks: enableAutolinks
            )
        })
        let documentID = UUID()

        let newer = Task {
            await service.parse(
                MarkdownParseInput(
                    documentID: documentID,
                    revision: 10,
                    source: "# newer\n"
                )
            )
        }
        for _ in 0..<500 where !gate.hasEntered {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.hasEntered)

        let older = Task {
            await service.parse(
                MarkdownParseInput(
                    documentID: documentID,
                    revision: 9,
                    source: "# older\n"
                )
            )
        }
        // Let the older request attach to the in-flight parse.
        try? await Task.sleep(for: .milliseconds(50))
        gate.release()

        #expect(await newer.value?.revision == 10)
        #expect(await older.value?.revision == 10)

        let cached = await service.parse(
            MarkdownParseInput(
                documentID: documentID,
                revision: 1,
                source: "ignored\n"
            )
        )
        #expect(cached?.revision == 10)
        #expect(counter.snapshot.starts == 1)
    }

    @Test("The cache does not cross autolink configurations")
    func configurationCache() async {
        let service = MarkdownParseService()
        let documentID = UUID()

        let withLinks = await service.parse(
            MarkdownParseInput(
                documentID: documentID,
                revision: 1,
                source: "www.example.com\n",
                enableAutolinks: true
            )
        )
        let withoutLinks = await service.parse(
            MarkdownParseInput(
                documentID: documentID,
                revision: 1,
                source: "www.example.com\n",
                enableAutolinks: false
            )
        )

        #expect(withLinks?.enableAutolinks == true)
        #expect(withoutLinks?.enableAutolinks == false)
    }

    @Test("Releasing a document evicts its cached result")
    func releaseDocument() async {
        let counter = Counter()
        let service = MarkdownParseService(parser: { source, enableAutolinks in
            counter.begin(Thread.isMainThread)
            defer { counter.end() }
            return MarkdownParser.parseCanonical(
                source,
                enableAutolinks: enableAutolinks
            )
        })
        let documentID = UUID()
        let input = MarkdownParseInput(
            documentID: documentID,
            revision: 1,
            source: "# A\n"
        )

        _ = await service.parse(input)
        _ = await service.parse(input)
        #expect(counter.snapshot.starts == 1)

        await service.release(documentID: documentID)
        _ = await service.parse(input)
        #expect(counter.snapshot.starts == 2)
    }

    @Test("Bounds the cross-document backlog")
    func boundedBacklog() async {
        let counter = Counter()
        let service = MarkdownParseService(maxBacklog: 1, parser: slowParser(counter))

        let firstID = UUID()
        let secondID = UUID()
        let first = Task {
            await service.parse(
                MarkdownParseInput(
                    documentID: firstID,
                    revision: 1,
                    source: "# A\n"
                )
            )
        }
        let second = Task {
            await service.parse(
                MarkdownParseInput(
                    documentID: secondID,
                    revision: 1,
                    source: "# B\n"
                )
            )
        }

        let firstResult = await first.value
        let secondResult = await second.value
        #expect(firstResult != nil || secondResult != nil)
        #expect(await service.pendingCount <= 1)
        #expect(counter.snapshot.starts <= 2)
    }

    @Test("Parses a near-miss nested document without overflowing a pool stack")
    func parsesResidualNesting() async throws {
        // This shape passes the source guards but still makes the reference
        // parser build a few hundred nested nodes, because a code span
        // hides one of the closers from the scanner. The parse service runs
        // the converter on a dedicated large stack, so the residual case
        // parses instead of depending on the cooperative pool's stack.
        let source = String(repeating: "*a `b*\n `\n", count: 300) + "x"
            + String(repeating: "\na*", count: 300)
        let service = MarkdownParseService()
        let output = try #require(
            await service.parse(
                MarkdownParseInput(
                    documentID: UUID(),
                    revision: 1,
                    source: source
                )
            )
        )
        #expect(output.parsed.source == source)
    }

    @Test("Produces an augmented AST and heading index")
    func augmentsResult() async throws {
        let service = MarkdownParseService()
        let output = try #require(
            await service.parse(
                MarkdownParseInput(
                    documentID: UUID(),
                    revision: 1,
                    source: "# Title\n\nSee [[Page]].\n"
                )
            )
        )
        #expect(output.ast.blocks.count == 2)
        #expect(output.headings.headings.first?.slug == "title")
        guard case let .paragraph(inlines, _) = output.ast.blocks[1] else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(inlines.contains { inline in
            if case .wikiLink = inline { return true }
            return false
        })
    }
}
