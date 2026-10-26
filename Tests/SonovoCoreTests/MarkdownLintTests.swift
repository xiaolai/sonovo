import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown lint")
struct MarkdownLintTests {
    private func lint(_ source: String) -> [MarkdownDiagnostic] {
        let parsed = MarkdownParser.parseCanonical(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        return MarkdownLintEngine.lint(
            source: source,
            ast: ast,
            documentID: UUID(),
            revision: 7
        ).diagnostics
    }

    private func has(_ rule: String, _ source: String) -> Bool {
        lint(source).contains { $0.ruleID == rule }
    }

    @Test("E01 undefined reference")
    func undefinedReference() {
        #expect(has("E01", "[a][missing]\n"))
        #expect(
            !has("E01", "[a][known]\n\n[known]: https://example.com\n")
        )
    }

    @Test("E02 table column mismatch")
    func tableMismatch() {
        #expect(has("E02", "| a | b |\n| --- | --- |\n| 1 |\n"))
        #expect(!has("E02", "| a | b |\n| --- | --- |\n| 1 | 2 |\n"))
    }

    @Test("E03 reversed link")
    func reversedLink() {
        #expect(has("E03", "see (text)[https://x]\n"))
        #expect(!has("E03", "see [text](https://x)\n"))
    }

    @Test("E04 heading without a space")
    func headingWithoutSpace() {
        #expect(has("E04", "#NoSpace\n"))
        #expect(!has("E04", "# Space\n"))
        #expect(has("E04", "> #Nope\n"))
    }

    @Test("E05 spaces inside emphasis")
    func spacedEmphasis() {
        #expect(has("E05", "* spaced *\n"))
        #expect(!has("E05", "*tight*\n"))
        #expect(!has("E05", "3 * 4 * 5\n"))
    }

    @Test("E06 empty link text")
    func emptyLinkText() {
        #expect(has("E06", "[](https://example.com)\n"))
        #expect(!has("E06", "[x](https://example.com)\n"))
        #expect(!has("E06", "[![](pic.png)](https://example.com)\n"))
    }

    @Test("E07 duplicate definitions")
    func duplicateDefinitions() {
        let source = "[a]: https://one\n[a]: https://two\n"
        #expect(has("E07", source))
        #expect(!has("E07", "[a]: https://one\n"))
    }

    @Test("E08 unclosed fence")
    func unclosedFence() {
        #expect(has("E08", "```\ncode\n"))
        #expect(!has("E08", "```\ncode\n```\n"))
    }

    @Test("W01 heading level skip")
    func headingSkip() {
        #expect(has("W01", "# A\n\n### B\n"))
        #expect(!has("W01", "# A\n\n## B\n"))
    }

    @Test("W02 image without alt text")
    func imageAlt() {
        #expect(has("W02", "![](pic.png)\n"))
        #expect(!has("W02", "![alt](pic.png)\n"))
    }

    @Test("W03 unused definition")
    func unusedDefinition() {
        #expect(has("W03", "[unused]: https://x\n"))
        #expect(
            !has("W03", "[a][used]\n\n[used]: https://x\n")
        )
    }

    @Test("W04 fragment matches no heading")
    func fragment() {
        #expect(has("W04", "[x](#nope)\n"))
        #expect(!has("W04", "# Title\n\n[x](#title)\n"))
    }

    @Test("W05 empty destination")
    func emptyDestination() {
        #expect(has("W05", "[x]()\n"))
        #expect(!has("W05", "[x](https://example.com)\n"))
    }

    @Test("A construct inside a fence produces no diagnostics")
    func fencedCodeIsSilent() {
        let source = "```\n#NoSpace\n[a][missing]\n```\n"
        let rules = Set(lint(source).map(\.ruleID))
        #expect(!rules.contains("E01"))
        #expect(!rules.contains("E04"))
    }

    @Test("A construct inside inline code produces no diagnostics")
    func inlineCodeIsSilent() {
        let source = "text `#NoSpace` more\n"
        #expect(!has("E04", source))
    }

    @Test("Diagnostics are stamped with the document and revision")
    func stamped() {
        let parsed = MarkdownParser.parseCanonical("[](x)\n")
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        let id = UUID()
        let result = MarkdownLintEngine.lint(
            source: "[](x)\n",
            ast: ast,
            documentID: id,
            revision: 3
        )
        #expect(result.documentID == id)
        #expect(result.revision == 3)
    }
}

@Suite("Markdown link probe")
struct MarkdownLinkProbeTests {
    private func makeTree() throws -> (root: URL, document: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let document = root.appendingPathComponent("a.md")
        try "x".write(to: document, atomically: true, encoding: .utf8)
        try "y".write(
            to: root.appendingPathComponent("present.png"),
            atomically: true,
            encoding: .utf8
        )
        return (root, document)
    }

    @Test("Local targets are checked and classified")
    func localTargets() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let service = MarkdownLinkProbeService()
        let outcomes = await service.check(
            destinations: ["present.png", "missing.png"],
            documentURL: tree.document,
            root: tree.root
        )
        #expect(outcomes["present.png"] == .exists)
        #expect(outcomes["missing.png"] == .missing)
    }

    @Test("Remote and fragment destinations are not checked")
    func remoteAndFragment() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let service = MarkdownLinkProbeService()
        let outcomes = await service.check(
            destinations: ["https://example.com/x", "#heading"],
            documentURL: tree.document,
            root: tree.root
        )
        #expect(outcomes["https://example.com/x"] == .notChecked)
        #expect(outcomes["#heading"] == .notChecked)
    }

    @Test("Outside-root targets are not checked")
    func outsideRoot() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let service = MarkdownLinkProbeService()
        let outcomes = await service.check(
            destinations: ["../../etc/passwd"],
            documentURL: tree.document,
            root: tree.root
        )
        #expect(outcomes["../../etc/passwd"] == .notChecked)
    }

    @Test("The path budget classifies the overflow as not checked")
    func budget() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let service = MarkdownLinkProbeService(maximumPaths: 1)
        let outcomes = await service.check(
            destinations: ["present.png", "missing.png"],
            documentURL: tree.document,
            root: tree.root
        )
        #expect(outcomes["missing.png"] == .notChecked)
    }

    @Test("A missing local target becomes M001 or M002")
    func probeDiagnostics() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let source = "[a](missing.md) ![b](missing.png)"
        let parsed = MarkdownParser.parseCanonical(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        let targets = MarkdownLintEngine.probeTargets(ast: ast)
        #expect(targets.count == 2)
        let base = MarkdownLintEngine.lint(source: source, ast: ast)
        let service = MarkdownLinkProbeService()
        let outcomes = await service.check(
            destinations: targets.map(\.destination),
            documentURL: tree.document,
            root: tree.root
        )
        let result = MarkdownLintEngine.appendingProbeResults(
            outcomes,
            targets: targets,
            to: base
        )
        #expect(result.diagnostics.contains { $0.ruleID == "M001" })
        #expect(result.diagnostics.contains { $0.ruleID == "M002" })
    }
}
