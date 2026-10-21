import Foundation
import Testing
@testable import SonovoCore

@Suite("Performance and pathological input")
@MainActor
struct PerformanceTests {
    private func largeSource(targetBytes: Int = 220_000) -> String {
        var result = ""
        var index = 0
        while result.utf8.count < targetBytes {
            index += 1
            result += "## Section \(index)\n\n"
            result += "NARRATOR (V.O.)\nThe harbor wakes before the town does. "
            result += "Line \(index) with **emphasis**, `code`, and [a link](https://example.com/\(index)).\n\n"
        }
        return result
    }

    @Test("Parse, augment, and index stay within budget")
    func parseBudget() {
        let source = largeSource()
        #expect(source.utf8.count >= 200_000)

        // Warm up.
        _ = HeadingIndex(
            ast: MarkdownSyntaxAugmenter().augment(
                MarkdownParser.parseCanonical(source)
            )
        )

        func seconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        }

        let clock = ContinuousClock()
        var samples: [Double] = []
        var cpuSamples: [Double] = []
        var parseSamples: [Double] = []
        var augmentSamples: [Double] = []
        var indexSamples: [Double] = []
        for _ in 0..<10 {
            let cpuStart = Self.processCPUSeconds()
            let start = clock.now
            let parsed = MarkdownParser.parseCanonical(source)
            let afterParse = clock.now
            let ast = MarkdownSyntaxAugmenter().augment(parsed)
            let afterAugment = clock.now
            _ = HeadingIndex(ast: ast)
            let afterIndex = clock.now
            samples.append(seconds(afterIndex - start))
            cpuSamples.append(Self.processCPUSeconds() - cpuStart)
            parseSamples.append(seconds(afterParse - start))
            augmentSamples.append(seconds(afterAugment - afterParse))
            indexSamples.append(seconds(afterIndex - afterAugment))
        }
        print("stages: parse median \(parseSamples.sorted()[5])s, augment median \(augmentSamples.sorted()[5])s, index median \(indexSamples.sorted()[5])s")

        let sorted = samples.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let sortedCPU = cpuSamples.sorted()
        let cpuP95 = sortedCPU[Int(Double(sortedCPU.count - 1) * 0.95)]
        print(
            "parse+augment+index on \(source.utf8.count) bytes: "
                + "wall p50 \(sorted[sorted.count / 2])s, p95 \(p95)s; "
                + "cpu p50 \(sortedCPU[sortedCPU.count / 2])s, p95 \(cpuP95)s"
        )

        #if DEBUG
        // Unoptimized builds are not the responsiveness gate; the release run
        // is. Wall-clock during a debug run measures the build machine's load
        // as much as the parser, so the debug guard uses process CPU time:
        // a descheduled process accrues none. It still catches an
        // order-of-magnitude regression.
        #expect(cpuP95 < 1.5, "debug CPU p95 \(cpuP95)s")
        #else
        // Target is 100 ms of parser work; the automated gate allows 150 ms.
        // Gating on CPU time keeps scheduler contention out of the verdict:
        // a release run measured 0.35 s wall and 0.11 s CPU on a machine with
        // a load average above 100. Wall time is printed for the record.
        #expect(cpuP95 < 0.15, "release CPU p95 \(cpuP95)s")
        #endif
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ value: timeval) -> Double {
            Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    @Test("Large files route to read-only")
    func largeFileRouting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-large-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("large.md")
        let data = Data(repeating: 0x61, count: MarkdownLimits.maxEditableDocumentBytes + 16)
        try data.write(to: url)

        let loaded = try MarkdownFileStore().read(url)
        #expect(loaded.isLarge)

        let document = try MarkdownDocument(loading: url)
        #expect(document.isReadOnly)
        #expect(document.isLarge)
    }

    @Test("The heading cap truncates rows, never the index")
    func headingCap() {
        let source = (1...1_100).map { "# H\($0)" }.joined(separator: "\n\n")
        let parsed = MarkdownParser.parseCanonical(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        let index = HeadingIndex(ast: ast)

        #expect(index.headings.count == 1_100)
        #expect(index.totalRowCount == 1_100)
        #expect(index.rows.count == MarkdownLimits.maxTOCEntries)
        #expect(index.heading(forFragment: "h1100")?.text == "H1100")
    }

    @Test("Details nesting stops at the depth limit without losing source")
    func nestedDetailsLimit() {
        var source = ""
        for index in 1...20 {
            source += "<details><summary>S\(index)</summary>\n\n"
        }
        source += "deep body\n"
        for _ in 1...20 {
            source += "</details>\n"
        }

        let parsed = MarkdownParser.parseCanonical(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)

        func depth(_ blocks: [Block]) -> Int {
            var maximum = 0
            for block in blocks {
                if case let .details(details, _) = block {
                    maximum = max(maximum, 1 + depth(details.blocks))
                }
            }
            return maximum
        }

        let measured = depth(ast.blocks)
        #expect(measured <= MarkdownLimits.maxDetailsDepth)
        #expect(parsed.source == source)
    }

    @Test("Pathological wiki-link input is bounded and does not crash")
    func pathologicalWikiInput() {
        let source = String(repeating: "[[Page|", count: 5_000) + "\n"
        let parsed = MarkdownParser.parseCanonical(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        #expect(!ast.blocks.isEmpty)
    }
}
