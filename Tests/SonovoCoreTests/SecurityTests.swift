import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown security")
struct SecurityTests {
    @Test("Link schemes are allowed or denied exactly")
    func linkSchemes() {
        #expect(MarkdownSecurity.linkDecision(for: "https://example.com") == .allowed(.external))
        #expect(MarkdownSecurity.linkDecision(for: "HTTP://example.com") == .allowed(.external))
        #expect(MarkdownSecurity.linkDecision(for: "mailto:a@example.com") == .allowed(.mailto))
        #expect(MarkdownSecurity.linkDecision(for: "#heading") == .allowed(.fragment))
        #expect(MarkdownSecurity.linkDecision(for: "assets/picture.png") == .allowed(.local))

        for denied in [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "data:text/html,<script>",
            "file:///etc/passwd",
            "blob:https://example.com/id",
            "vbscript:msgbox",
            "//example.com/path",
            "sonovo://take/1",
            ""
        ] {
            #expect(!MarkdownSecurity.linkDecision(for: denied).isAllowed, "should deny \(denied)")
        }
    }

    @Test("Local paths reject traversal and schemes")
    func localPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let document = root.appendingPathComponent("docs/script.md")
        try FileManager.default.createDirectory(
            at: document.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: document.path, contents: Data())

        #expect(
            MarkdownSecurity.resolveLocalPath(
                "assets/a.png",
                relativeTo: document,
                root: root
            )?.path == root.appendingPathComponent("docs/assets/a.png").path
        )
        #expect(
            MarkdownSecurity.resolveLocalPath(
                "../outside.png",
                relativeTo: document,
                root: root
            ) == nil
        )
        #expect(
            MarkdownSecurity.resolveLocalPath(
                "/etc/passwd",
                relativeTo: document,
                root: root
            ) == nil
        )
        #expect(
            MarkdownSecurity.resolveLocalPath(
                "~/secret",
                relativeTo: document,
                root: root
            ) == nil
        )
    }

    @Test("Symlink escapes are rejected")
    func symlinkEscape() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-symlink-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let document = root.appendingPathComponent("script.md")
        FileManager.default.createFile(atPath: document.path, contents: Data())

        #expect(
            MarkdownSecurity.resolveLocalPath(
                "escape/secret.txt",
                relativeTo: document,
                root: root
            ) == nil
        )
    }

    @Test("Wiki target validation rejects absolute, traversal, and schemes")
    func wikiTargets() {
        #expect(MarkdownSecurity.isValidWikiTarget("Act One"))
        #expect(MarkdownSecurity.isValidWikiTarget("scenes/act-one"))
        #expect(!MarkdownSecurity.isValidWikiTarget("/etc/passwd"))
        #expect(!MarkdownSecurity.isValidWikiTarget("../secret"))
        #expect(!MarkdownSecurity.isValidWikiTarget("https://example.com"))
        #expect(!MarkdownSecurity.isValidWikiTarget("~/secret"))
        #expect(!MarkdownSecurity.isValidWikiTarget(""))
    }

    @Test("A fragment-only wiki link resolves to the current document")
    func fragmentOnlyWikiResolution() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-fragment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let current = root.appendingPathComponent("current.md")
        FileManager.default.createFile(atPath: current.path, contents: Data())

        let resolver = WikiLinkResolver(
            workspaceRoot: root,
            documentURL: current,
            markdownFiles: [current]
        )
        #expect(
            resolver.resolve(
                WikiLink(target: "", fragment: "Heading", alias: nil)
            ) == .resolved(current.standardizedFileURL)
        )
    }

    @Test("Basename candidates outside the workspace are rejected")
    func basenameContainment() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-basename-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let current = root.appendingPathComponent("current.md")
        let outside = base.appendingPathComponent("Outside.md")
        FileManager.default.createFile(atPath: current.path, contents: Data())
        FileManager.default.createFile(atPath: outside.path, contents: Data())

        let resolver = WikiLinkResolver(
            workspaceRoot: root,
            documentURL: current,
            markdownFiles: [current, outside]
        )
        #expect(
            resolver.resolve(
                WikiLink(target: "Outside", fragment: nil, alias: nil)
            ) == .missing
        )
    }

    @Test("Ambiguous basename results are bounded")
    func basenameCandidateLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let current = root.appendingPathComponent("current.md")
        FileManager.default.createFile(atPath: current.path, contents: Data())

        var files: [URL] = [current]
        for index in 0...(MarkdownLimits.maxWikiLinkCandidates + 1) {
            let directory = root.appendingPathComponent("d\(index)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let file = directory.appendingPathComponent("Same.md")
            FileManager.default.createFile(atPath: file.path, contents: Data())
            files.append(file)
        }

        let resolver = WikiLinkResolver(
            workspaceRoot: root,
            documentURL: current,
            markdownFiles: files
        )
        let result = resolver.resolve(
            WikiLink(target: "Same", fragment: nil, alias: nil)
        )
        guard case let .ambiguous(urls) = result else {
            Issue.record("expected an ambiguous resolution, got \(result)")
            return
        }
        #expect(urls.count == MarkdownLimits.maxWikiLinkCandidates)
    }

    @Test("Wiki resolver prefers document, then root, then a unique basename")
    func wikiResolution() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-wiki-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let current = docs.appendingPathComponent("current.md")
        let sibling = docs.appendingPathComponent("Sibling.md")
        let rootDoc = root.appendingPathComponent("RootDoc.md")
        let duplicateA = docs.appendingPathComponent("a/Duplicate.md")
        let duplicateB = docs.appendingPathComponent("b/Duplicate.md")

        for file in [current, sibling, rootDoc, duplicateA, duplicateB] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }

        let resolver = WikiLinkResolver(
            workspaceRoot: root,
            documentURL: current,
            markdownFiles: [current, sibling, rootDoc, duplicateA, duplicateB]
        )

        #expect(
            resolver.resolve(WikiLink(target: "Sibling", fragment: nil, alias: nil))
                == .resolved(sibling)
        )
        #expect(
            resolver.resolve(WikiLink(target: "RootDoc", fragment: nil, alias: nil))
                == .resolved(rootDoc)
        )
        #expect(
            resolver.resolve(WikiLink(target: "../RootDoc", fragment: nil, alias: nil))
                == .missing
        )

        let ambiguous = resolver.resolve(
            WikiLink(target: "Duplicate", fragment: nil, alias: nil)
        )
        if case let .ambiguous(urls) = ambiguous {
            #expect(urls.count == 2)
        } else {
            Issue.record("expected an ambiguous resolution, got \(ambiguous)")
        }
    }
}
