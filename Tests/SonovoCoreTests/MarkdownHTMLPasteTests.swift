import Darwin
import Foundation
import Network
import Testing
@testable import SonovoCore

@Suite("Markdown HTML paste")
struct MarkdownHTMLPasteTests {
    private struct Case {
        let name: String
        let html: String
        let expected: String?
    }

    private func corpusCases() throws -> [Case] {
        let root = try #require(
            Bundle.module.url(forResource: "Fixtures", withExtension: nil),
            "Fixtures directory missing from the test bundle"
        ).appendingPathComponent("html-paste")
        let names = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".html") }
            .sorted()
        return try names.map { name in
            let base = String(name.dropLast(5))
            let html = try String(
                contentsOf: root.appendingPathComponent(name),
                encoding: .utf8
            )
            let expectedRaw = try String(
                contentsOf: root.appendingPathComponent(base + ".md"),
                encoding: .utf8
            )
            let trimmed = expectedRaw.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return Case(
                name: base,
                html: html,
                expected: trimmed.isEmpty ? nil : expectedRaw
            )
        }
    }

    @Test("The clipboard corpus converts exactly")
    func corpus() throws {
        let cases = try corpusCases()
        #expect(cases.count >= 12, "the corpus shrank")
        for testCase in cases {
            let actual = MarkdownHTMLPaste.convert(testCase.html)
            #expect(
                actual == testCase.expected,
                "corpus case \(testCase.name)"
            )
        }
    }

    @Test("Every converted corpus document parses as Markdown source")
    func corpusIsValidMarkdown() throws {
        for testCase in try corpusCases() {
            guard let source = testCase.expected else { continue }
            let parsed = MarkdownParser.parseCanonical(source)
            #expect(parsed.source == source, "case \(testCase.name)")
        }
    }

    @Test("Input above the size cap is refused")
    func oversized() {
        let html = String(repeating: "<p>word</p>", count: 12_000)
        #expect(html.utf8.count > MarkdownHTMLPaste.maximumBytes)
        #expect(MarkdownHTMLPaste.convert(html) == nil)
    }

    @Test("Malformed markup falls back instead of guessing")
    func malformed() {
        #expect(MarkdownHTMLPaste.convert("<p>a<!-- unterminated") == nil)
        #expect(MarkdownHTMLPaste.convert("<p class=\"x") == nil)
        #expect(MarkdownHTMLPaste.convert("<div><script>") == nil)
    }

    @Test("No visible content produces no conversion")
    func emptyResult() {
        #expect(MarkdownHTMLPaste.convert("<div>   </div>") == nil)
        #expect(MarkdownHTMLPaste.convert("<script>x</script>") == nil)
        #expect(MarkdownHTMLPaste.convert("") == nil)
    }

    @Test("Unsafe schemes never become links or images")
    func unsafeSchemes() {
        let html = """
        <p><a href="javascript:alert(1)">x</a>
        <a href="vbscript:msgbox(1)">y</a>
        <img src="data:image/png;base64,AAAA" alt="z"></p>
        """
        let markdown = MarkdownHTMLPaste.convert(html)
        #expect(markdown == "x y\n")
    }

    @Test("HTML paste uses the conversion chain")
    func pastePlan() {
        let input = MarkdownPasteInput(
            flavors: [.html("<h1>Hi</h1><p>There</p>")],
            selectionText: ""
        )
        guard case let .insert(range, replacement, selection) =
            MarkdownPasteConverter.plan(input: input, selection: 4..<4)
        else {
            Issue.record("HTML paste did not convert")
            return
        }
        #expect(range == 4..<4)
        #expect(replacement == "# Hi\n\nThere\n")
        let caret = 4 + ("# Hi\n\nThere\n" as NSString).length
        #expect(selection == caret..<caret)
    }

    @Test("HTML inside a fence stays literal")
    func pasteInsideFence() {
        let input = MarkdownPasteInput(
            flavors: [.html("<h1>Hi</h1>")],
            selectionText: "",
            isInsideFence: true
        )
        #expect(
            MarkdownPasteConverter.plan(input: input, selection: 0..<0)
                == .plain
        )
    }

    @Test("Malformed or oversized HTML falls back to the text flavor")
    func pasteFallback() {
        let malformed = MarkdownPasteInput(
            flavors: [.text("hello"), .html("<p class=\"x")],
            selectionText: ""
        )
        #expect(
            MarkdownPasteConverter.plan(input: malformed, selection: 0..<0)
                == .plain
        )
        let oversizedHTML = String(
            repeating: "<p>word</p>",
            count: 12_000
        )
        let large = MarkdownPasteInput(
            flavors: [.text("hello"), .html(oversizedHTML)],
            selectionText: ""
        )
        #expect(
            MarkdownPasteConverter.plan(input: large, selection: 0..<0)
                == .plain
        )
    }

    // MARK: - Network isolation

    /// A loopback TCP listener that counts accepted connections. The same
    /// probe records a real connection in the control step, so a zero
    /// afterwards is evidence rather than an untested assumption.
    private final class ConnectionProbe: @unchecked Sendable {
        enum ProbeError: Error {
            case noPort
        }

        private let listener: NWListener
        private let queue = DispatchQueue(
            label: "sonovo.html-paste.probe"
        )
        private let lock = NSLock()
        private var connections = 0

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.loopback),
                port: .any
            )
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                lock.lock()
                connections += 1
                lock.unlock()
                connection.cancel()
            }
        }

        func start() async throws -> UInt16 {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UInt16, Error>) in
                let box = ContinuationBox(continuation)
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        guard let port = self?.listener.port?.rawValue else {
                            box.resume(throwing: ProbeError.noPort)
                            return
                        }
                        box.resume(returning: port)
                    case .failed(let error):
                        box.resume(throwing: error)
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return connections
        }

        func reset() {
            lock.lock()
            connections = 0
            lock.unlock()
        }

        private final class ContinuationBox: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<UInt16, Error>?

            init(_ continuation: CheckedContinuation<UInt16, Error>) {
                self.continuation = continuation
            }

            func resume(returning port: UInt16) {
                finish { $0.resume(returning: port) }
            }

            func resume(throwing error: Error) {
                finish { $0.resume(throwing: error) }
            }

            private func finish(
                _ body: (CheckedContinuation<UInt16, Error>) -> Void
            ) {
                lock.lock()
                let pending = continuation
                continuation = nil
                lock.unlock()
                if let pending { body(pending) }
            }
        }
    }

    @Test("Clipboard conversion never opens a network connection")
    func noNetwork() async throws {
        let probe = try ConnectionProbe()
        let port = try await probe.start()
        defer { probe.stop() }

        // Control: the probe must observe a connection that does happen.
        #expect(Self.connect(port: port) == 0)
        try await Self.waitUntil { probe.count > 0 }
        #expect(
            probe.count > 0,
            "the probe did not observe the control connection"
        )
        probe.reset()

        let url = "http://127.0.0.1:\(port)/tracking.png"
        let markdown = MarkdownHTMLPaste.convert(
            "<p>Docs <img src=\"\(url)\" alt=\"pixel\"></p>"
        )
        #expect(markdown?.contains(url) == true)

        // The conversion is synchronous; anything it started must appear
        // inside this window.
        try await Task.sleep(for: .milliseconds(300))
        #expect(
            probe.count == 0,
            "conversion attempted a network connection"
        )
    }

    @Test("An ordered list keeps its start attribute")
    func orderedListStart() {
        let markdown = MarkdownHTMLPaste.convert(
            "<ol start=\"5\"><li>one</li><li>two</li></ol>"
        )
        #expect(markdown == "5. one\n6. two\n")
    }

    @Test("An extreme ordered start cannot overflow its marker")
    func orderedListExtremeStart() {
        let markdown = MarkdownHTMLPaste.convert(
            "<ol start=\"9223372036854775807\"><li>one</li><li>two</li></ol>"
        )
        // Nine digits is the longest marker Markdown parses, so both the
        // start and the addition are clamped rather than trapping.
        #expect(markdown == "999999999. one\n999999999. two\n")
    }

    @Test("A trailing hard break leaves no dangling backslash")
    func trailingHardBreak() {
        let markdown = MarkdownHTMLPaste.convert("<p>hello<br></p>")
        #expect(markdown == "hello\n")
    }

    @Test("Every trailing hard break is removed, not just the last")
    func repeatedTrailingHardBreaks() {
        let markdown = MarkdownHTMLPaste.convert(
            "<p>hello<br><br><br></p>"
        )
        #expect(markdown == "hello\n")
    }

    @Test("A hard break before text still splits the line")
    func interiorHardBreak() {
        let markdown = MarkdownHTMLPaste.convert(
            "<p>Line one<br>Line two</p>"
        )
        #expect(markdown == "Line one\\\nLine two\n")
    }

    private static func connect(port: UInt16) -> Int32 {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return -1 }
        defer { close(descriptor) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
    }

    private static func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
