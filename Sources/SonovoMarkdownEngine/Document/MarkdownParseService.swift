import Foundation

/// One parse request.
public struct MarkdownParseInput: Sendable, Equatable {
    public let documentID: UUID
    public let revision: UInt64
    public let source: String
    public let enableAutolinks: Bool

    public init(
        documentID: UUID,
        revision: UInt64,
        source: String,
        enableAutolinks: Bool = true
    ) {
        self.documentID = documentID
        self.revision = revision
        self.source = source
        self.enableAutolinks = enableAutolinks
    }
}

/// One parse result, stamped with the revision it describes.
public struct MarkdownParseOutput: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    /// The parser configuration that produced this output. A cache hit must
    /// not cross configurations.
    public let enableAutolinks: Bool
    public let parsed: ParsedMarkdown
    public let ast: SonovoAST
    public let headings: HeadingIndex

    public init(
        documentID: UUID,
        revision: UInt64,
        enableAutolinks: Bool = true,
        parsed: ParsedMarkdown,
        ast: SonovoAST,
        headings: HeadingIndex
    ) {
        self.documentID = documentID
        self.revision = revision
        self.enableAutolinks = enableAutolinks
        self.parsed = parsed
        self.ast = ast
        self.headings = headings
    }
}

/// A serial, coalescing parse service.
///
/// One parse runs at a time. A newer revision for the same document replaces
/// the pending one, so typing cannot queue an unbounded number of parses. The
/// backlog is bounded across documents as well; the oldest pending document is
/// dropped when the bound is exceeded.
public actor MarkdownParseService {
    public typealias Parser = @Sendable (_ source: String, _ enableAutolinks: Bool) -> ParsedMarkdown

    private struct CacheKey: Hashable {
        let documentID: UUID
        let enableAutolinks: Bool
    }

    private struct Waiter {
        let revision: UInt64
        let continuation: CheckedContinuation<MarkdownParseOutput?, Never>
    }

    private let parser: Parser
    private let maxBacklog: Int

    private var pending: [CacheKey: MarkdownParseInput] = [:]
    private var order: [CacheKey] = []
    private var latest: [CacheKey: MarkdownParseOutput] = [:]
    private var waiters: [CacheKey: [Waiter]] = [:]
    private var running = false
    private var inFlight: MarkdownParseInput?
    private var discardedDocuments: Set<UUID> = []

    /// The number of documents currently waiting for a parse.
    public var pendingCount: Int { order.count }

    /// Whether a parse is in flight.
    public var isParsing: Bool { running }

    public init(
        maxBacklog: Int = 1,
        parser: @escaping Parser = { source, enableAutolinks in
            MarkdownParser.parseCanonical(
                source,
                enableAutolinks: enableAutolinks
            )
        }
    ) {
        self.maxBacklog = max(1, maxBacklog)
        self.parser = parser
    }

    /// Requests a parse.
    ///
    /// Returns the newest result available for the document. A caller discards
    /// a result whose revision is older than its current document revision.
    public func parse(_ input: MarkdownParseInput) async -> MarkdownParseOutput? {
        let key = CacheKey(
            documentID: input.documentID,
            enableAutolinks: input.enableAutolinks
        )
        if let cached = latest[key], cached.revision >= input.revision {
            return cached
        }

        // A running parse with the same configuration and an equal or newer
        // revision can satisfy this request. Queuing an older revision would
        // later overwrite the newer cache entry.
        if let inFlight,
           inFlight.documentID == input.documentID,
           inFlight.enableAutolinks == input.enableAutolinks,
           input.revision <= inFlight.revision {
            return await addWaiter(input, key: key)
        }

        // Requests can arrive out of order; coalescing keeps the highest
        // revision for a given document and configuration.
        if let existing = pending[key], existing.revision >= input.revision {
            // Keep the newer pending request.
        } else {
            pending[key] = input
        }
        if !order.contains(key) {
            order.append(key)
        }

        // Bound the cross-document backlog. Dropping the oldest pending
        // request is safe: its caller can retry with the latest revision.
        while order.count > maxBacklog {
            let dropped = order.removeFirst()
            pending.removeValue(forKey: dropped)
            let droppedWaiters = waiters.removeValue(forKey: dropped) ?? []
            for waiter in droppedWaiters {
                waiter.continuation.resume(returning: latest[dropped])
            }
        }

        return await addWaiter(input, key: key)
    }

    /// Drops every cached and pending result for a closed document.
    ///
    /// Without this, `latest` would retain each document's full AST, heading
    /// index, and source for the life of the process.
    public func release(documentID: UUID) {
        let keys = Set(pending.keys)
            .union(waiters.keys)
            .union(latest.keys)
            .filter { $0.documentID == documentID }
        for key in keys {
            pending.removeValue(forKey: key)
            latest.removeValue(forKey: key)
            order.removeAll { $0 == key }
            let entries = waiters.removeValue(forKey: key) ?? []
            for waiter in entries {
                waiter.continuation.resume(returning: nil)
            }
        }
        if inFlight?.documentID == documentID {
            discardedDocuments.insert(documentID)
        }
    }

    private func addWaiter(
        _ input: MarkdownParseInput,
        key: CacheKey
    ) async -> MarkdownParseOutput? {
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(
                Waiter(revision: input.revision, continuation: continuation)
            )
            drain()
        }
    }

    private func drain() {
        guard !running else { return }
        running = true
        Task { await runLoop() }
    }

    /// Runs the parse and augmentation on a thread with a large fixed stack.
    ///
    /// swift-markdown converts the cmark tree recursively before the AST
    /// mapper's own depth limit can run, and the source guards are a
    /// heuristic bound rather than a proof. The cooperative pool's stacks
    /// are small, so one crafted document that slips past a guard would
    /// overflow there; a dedicated stack makes the residual risk much harder
    /// to reach. The sound fix is an iterative converter in the dependency.
    private static func parseOnLargeStack(
        parser: @escaping Parser,
        input: MarkdownParseInput
    ) async -> MarkdownParseOutput {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                let parsed = parser(input.source, input.enableAutolinks)
                let ast = MarkdownSyntaxAugmenter().augment(parsed)
                let headings = HeadingIndex(ast: ast)
                continuation.resume(
                    returning: MarkdownParseOutput(
                        documentID: input.documentID,
                        revision: input.revision,
                        enableAutolinks: input.enableAutolinks,
                        parsed: parsed,
                        ast: ast,
                        headings: headings
                    )
                )
            }
            // Virtual memory, touched only as the recursion uses it.
            thread.stackSize = 64 * 1024 * 1024
            thread.name = "Sonovo.MarkdownParse"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private func runLoop() async {
        while !order.isEmpty {
            let key = order.removeFirst()
            guard let input = pending.removeValue(forKey: key) else {
                continue
            }

            inFlight = input
            let output = await Self.parseOnLargeStack(
                parser: self.parser,
                input: input
            )
            inFlight = nil

            if discardedDocuments.remove(input.documentID) == nil {
                latest[key] = output
            }

            // A newer request may have arrived while this parse ran. It is in
            // `pending` and already queued; waiters receive this result now,
            // and the newer pass follows immediately.
            let pendingWaiters = waiters.removeValue(forKey: key) ?? []
            var remaining: [Waiter] = []
            for waiter in pendingWaiters {
                if waiter.revision <= output.revision {
                    waiter.continuation.resume(returning: output)
                } else {
                    remaining.append(waiter)
                }
            }
            if !remaining.isEmpty {
                waiters[key] = remaining
            }
        }

        running = false

        // There is no suspension between the loop's exit and this point, so
        // `order` cannot have gained work here. Flush any waiter that has no
        // remaining request with the newest cached result; this is the
        // liveness backstop for a request dropped by the backlog bound.
        if !waiters.isEmpty {
            for (key, entries) in waiters {
                let result = latest[key]
                for waiter in entries {
                    waiter.continuation.resume(returning: result)
                }
            }
            waiters.removeAll()
        }
    }
}
