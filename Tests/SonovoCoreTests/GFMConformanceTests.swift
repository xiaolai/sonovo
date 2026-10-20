import Foundation
import Testing
import ReferenceAst
@testable import SonovoCore

/// Compares the GFM extension corpus with the pinned cmark-gfm oracle.
@Suite("GFM conformance")
struct GFMConformanceTests {
    struct Example {
        let index: Int
        let markdown: String
    }

    static func examples() throws -> [Example] {
        let root = try #require(
            Bundle.module.url(forResource: "Fixtures", withExtension: nil)
        )
        let url = root.appendingPathComponent("gfmext/extensions.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        var examples: [Example] = []
        var index = 0
        var cursor = 0
        let fencePrefix = String(repeating: "`", count: 32)

        while cursor < lines.count {
            let line = String(lines[cursor])
            if line.hasPrefix(fencePrefix), line.contains("example") {
                index += 1
                cursor += 1
                var markdown: [String] = []
                while cursor < lines.count, String(lines[cursor]) != "." {
                    markdown.append(String(lines[cursor]))
                    cursor += 1
                }
                // Skip the dot line and the expected HTML until the fence.
                cursor += 1
                while cursor < lines.count,
                      !String(lines[cursor]).hasPrefix(fencePrefix) {
                    cursor += 1
                }
                examples.append(
                    Example(index: index, markdown: markdown.joined(separator: "\n") + "\n")
                )
            }
            cursor += 1
        }
        return examples
    }

    /// Accepted divergences from the GFM extension corpus.
    struct Divergence {
        let reason: String
        let paths: [String]
        let ignoresPositions: Bool
    }

    /// Accepted divergences from the GFM extension corpus.
    static let acceptedDivergences: [Int: Divergence] = [
        9: Divergence(
            reason: "cmark computes a code-span end from decoded content length; Sonovo reports the authored span, which is what highlighting needs.",
            paths: [
                "$.children[0].children[0].children[2].children[0].children[1].endUtf16",
                "$.children[0].children[0].children[3].children[0].children[0].children[0].children[0].endUtf16"
            ],
            ignoresPositions: false
        ),
        11: Divergence(
            reason: "cmark's code-span end excludes escaped backslashes; Sonovo reports the authored span.",
            paths: ["$.children[0].children[0].children[4].children[1].children[0].endUtf16"],
            ignoresPositions: false
        ),
        16: Divergence(
            reason: "cmark's table source position is null or unstable when a table follows a paragraph without a blank line; Sonovo reports the authored table span.",
            paths: [
                "$.children[0].children[1].children[0].",
                "$.children[0].children[1].children[1]."
            ],
            ignoresPositions: false
        ),
        18: Divergence(
            reason: "cmark reports a bogus end position for text following a strikethrough; Sonovo reports the authored span.",
            paths: ["$.children[0].children[4].children[3].endUtf16"],
            ignoresPositions: false
        ),
        19: Divergence(
            reason: "cmark's autolink source positions include the preceding character and overlap neighbouring text nodes. The gate still compares structure, literals, and destinations exactly.",
            paths: [],
            ignoresPositions: true
        ),
        26: Divergence(
            reason: "cmark's autolink source positions include the preceding character inside strikethrough. Structure, literals, and destinations are still compared.",
            paths: [],
            ignoresPositions: true
        ),
        27: Divergence(
            reason: "cmark's autolink positions inside table cells are null or include the preceding character. Structure, literals, and destinations are still compared.",
            paths: [],
            ignoresPositions: true
        )
    ]

    @Test("GFM extension corpus conformance")
    func gfmExtensions() throws {
        let examples = try Self.examples()
        #expect(examples.count == 30)

        var failures: [String] = []
        var seen: Set<Int> = []

        for example in examples {
            let parsed = MarkdownParser.parseCanonical(
                example.markdown,
                enableAutolinks: true
            )
            let ours: [String: Any] = [
                "children": [ConformanceProjection.project(parsed)]
            ]
            let oracleData = try ReferenceAst.projection(
                for: example.markdown,
                options: ReferenceAstOptions(enableAutolinks: true)
            )
            let oracle = try #require(
                JSONSerialization.jsonObject(with: oracleData) as? [String: Any]
            )

            let differences = ConformanceProjection.differences(
                ConformanceProjection.normalize(ours),
                ConformanceProjection.normalize(oracle),
                path: "$"
            )
            if let accepted = Self.acceptedDivergences[example.index],
               !differences.isEmpty {
                seen.insert(example.index)
                let positionKeys = [
                    "startLine", "startUtf16", "endLine", "endUtf16"
                ]
                let unexpected = differences.filter { difference in
                    let path = String(difference.split(separator: ":", maxSplits: 1)[0])
                    if accepted.paths.contains(where: { path.hasPrefix($0) }) {
                        return false
                    }
                    if accepted.ignoresPositions,
                       positionKeys.contains(where: { path.hasSuffix($0) }) {
                        return false
                    }
                    return true
                }
                if !unexpected.isEmpty {
                    failures.append(
                        "example \(example.index): signature changed\n"
                            + unexpected.prefix(3).joined(separator: "\n")
                    )
                }
                continue
            }

            if !differences.isEmpty {
                failures.append(
                    "example \(example.index): \(example.markdown.debugDescription)\n"
                        + differences.prefix(3).joined(separator: "\n")
                )
            }
        }

        let stale = Set(Self.acceptedDivergences.keys).subtracting(seen)
        if !stale.isEmpty {
            failures.append("Stale divergence declarations: \(stale.sorted())")
        }

        if !failures.isEmpty {
            print("GFM failures: \(failures.count) of \(examples.count)")
            for failure in failures.prefix(8) {
                print(failure)
                print("---")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) GFM conformance failures")
    }
}
