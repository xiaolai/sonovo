import Foundation
import Testing
import ReferenceAst
@testable import SonovoCore

/// Proves the conformance comparator can fail. A gate that cannot fail is not
/// a gate.
@Suite("Conformance failure injection")
struct FailureInjectionTests {
    private let source = """
    # Heading

    A paragraph with `code`, a [link](https://example.com "title"), and a hard\u{20}\u{20}
    break.

    - [x] done
    - [ ] todo

    3. ordered
    4. next

    | a | b |
    |:--|--:|
    | 1 | 2 |

    ```swift
    let x = 1
    ```
    """

    private func baseline() throws -> [String: Any] {
        let parsed = MarkdownParser.parseCanonical(
            source,
            enableAutolinks: false
        )
        let ours: [String: Any] = [
            "children": [ConformanceProjection.project(parsed)]
        ]
        let oracleData = try ReferenceAst.projection(
            for: source,
            options: ReferenceAstOptions(enableAutolinks: false)
        )
        let oracle = try #require(
            JSONSerialization.jsonObject(with: oracleData) as? [String: Any]
        )

        let normalizedOurs = ConformanceProjection.normalize(ours)
        let normalizedOracle = ConformanceProjection.normalize(oracle)
        let differences = ConformanceProjection.differences(
            normalizedOurs,
            normalizedOracle,
            path: "$"
        )
        #expect(differences.isEmpty, "baseline must match: \(differences.prefix(3))")
        return try #require(normalizedOurs as? [String: Any])
    }

    private func copy(_ value: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func assertDetected(
        _ mutation: (inout [String: Any]) -> Void
    ) throws {
        var candidate = try copy(baseline())
        mutation(&candidate)
        let baseline = try baseline()
        let differences = ConformanceProjection.differences(
            candidate,
            baseline,
            path: "$"
        )
        #expect(!differences.isEmpty, "mutation was not detected")
    }

    @discardableResult
    private func mutateFirst(
        in node: inout [String: Any],
        kind: String,
        _ body: (inout [String: Any]) -> Void
    ) -> Bool {
        if node["kind"] as? String == kind {
            body(&node)
            return true
        }
        guard var children = node["children"] as? [[String: Any]] else {
            return false
        }
        for index in children.indices {
            if mutateFirst(in: &children[index], kind: kind, body) {
                node["children"] = children
                return true
            }
        }
        return false
    }

    @discardableResult
    private func removeFirst(
        in node: inout [String: Any],
        kind: String
    ) -> Bool {
        guard var children = node["children"] as? [[String: Any]] else {
            return false
        }
        if let index = children.firstIndex(where: {
            $0["kind"] as? String == kind
        }) {
            children.remove(at: index)
            node["children"] = children
            return true
        }
        for index in children.indices {
            if removeFirst(in: &children[index], kind: kind) {
                node["children"] = children
                return true
            }
        }
        return false
    }

    @Test("Corrupting a source range fails the gate")
    func corruptRange() throws {
        try assertDetected { root in
            _ = self.mutateFirst(in: &root, kind: "text") { node in
                if let start = node["startUtf16"] as? Int {
                    node["startUtf16"] = start + 1
                }
            }
        }
    }

    @Test("Dropping a hard break fails the gate")
    func dropHardBreak() throws {
        try assertDetected { root in
            let removed = self.removeFirst(in: &root, kind: "linebreak")
            #expect(removed, "no linebreak node found to remove")
        }
    }

    @Test("Changing an ordered-list start fails the gate")
    func changeListStart() throws {
        try assertDetected { root in
            _ = self.mutateFirst(in: &root, kind: "list") { node in
                if let start = node["listStart"] as? Int {
                    node["listStart"] = start + 1
                }
            }
        }
    }

    @Test("Changing a link title fails the gate")
    func changeLinkTitle() throws {
        try assertDetected { root in
            _ = self.mutateFirst(in: &root, kind: "link") { node in
                node["title"] = "changed"
            }
        }
    }

    @Test("Changing a table alignment fails the gate")
    func changeTableAlignment() throws {
        try assertDetected { root in
            _ = self.mutateFirst(in: &root, kind: "table") { node in
                if var alignments = node["tableAlignments"] as? [String],
                   !alignments.isEmpty {
                    alignments[0] = alignments[0] == "left" ? "right" : "left"
                    node["tableAlignments"] = alignments
                }
            }
        }
    }

    @Test("Flipping a task checkbox fails the gate")
    func flipTask() throws {
        try assertDetected { root in
            _ = self.mutateFirst(in: &root, kind: "tasklist") { node in
                node["taskChecked"] = !(node["taskChecked"] as? Bool ?? false)
            }
        }
    }

    @Test("Altering a node outside a selected snapshot fails the gate")
    func alterDistantNode() throws {
        try assertDetected { root in
            _ = self.mutateFirst(in: &root, kind: "code_block") { node in
                node["literal"] = "let x = 2"
            }
        }
    }

    @Test("Changing a headline level fails the gate")
    func changeHeadingLevel() throws {
        try assertDetected { root in
            _ = self.mutateFirst(in: &root, kind: "heading") { node in
                node["headingLevel"] = 3
            }
        }
    }
}
