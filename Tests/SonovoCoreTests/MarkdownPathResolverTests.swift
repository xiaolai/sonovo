import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown path resolver")
struct MarkdownPathResolverTests {
    private struct Tree {
        let base: URL
        let root: URL
        let outside: URL
        let document: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: base)
        }
    }

    private func makeTree() throws -> Tree {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("project", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let rootAssets = root.appendingPathComponent("assets", isDirectory: true)
        let docAssets = docs.appendingPathComponent("assets", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        for directory in [docs, rootAssets, docAssets, outside] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let document = docs.appendingPathComponent("a.md")
        try "doc".write(to: document, atomically: true, encoding: .utf8)
        try "docpic".write(
            to: docAssets.appendingPathComponent("pic.png"),
            atomically: true,
            encoding: .utf8
        )
        try "rootpic".write(
            to: rootAssets.appendingPathComponent("pic.png"),
            atomically: true,
            encoding: .utf8
        )
        try "rootonly".write(
            to: rootAssets.appendingPathComponent("root.png"),
            atomically: true,
            encoding: .utf8
        )
        try "outside".write(
            to: outside.appendingPathComponent("local.txt"),
            atomically: true,
            encoding: .utf8
        )
        return Tree(base: base, root: root, outside: outside, document: document)
    }

    private func resolver(
        _ tree: Tree,
        document: URL? = nil,
        exists: MarkdownPathResolver.Exists? = nil,
        canonical: MarkdownPathResolver.Canonicalize? = nil,
        localMount: MarkdownPathResolver.IsLocalMount? = nil
    ) -> MarkdownPathResolver {
        MarkdownPathResolver(
            documentURL: document ?? tree.document,
            root: tree.root,
            exists: exists ?? MarkdownPathResolver.liveExists,
            canonicalize: canonical ?? MarkdownPathResolver.liveCanonical,
            isLocalMount: localMount ?? MarkdownPathResolver.liveIsLocalMount
        )
    }

    @Test("A document-relative path wins over a root-relative one")
    func documentRelativeWins() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let result = resolver(tree).resolve("assets/pic.png")
        guard case .resolved(let url) = result else {
            Issue.record("expected resolved, got \(result)")
            return
        }
        #expect(url.path.contains("/docs/assets/pic.png"))
    }

    @Test("A root-relative path is the fallback")
    func rootFallback() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let result = resolver(tree).resolve("assets/root.png")
        guard case .resolved(let url) = result else {
            Issue.record("expected resolved, got \(result)")
            return
        }
        #expect(url.path.contains("/project/assets/root.png"))
    }

    @Test("A missing file is named, not refused")
    func missing() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let result = resolver(tree).resolve("assets/missing.png")
        guard case .missing(let url) = result else {
            Issue.record("expected missing, got \(result)")
            return
        }
        #expect(url.path.contains("/docs/assets/missing.png"))
    }

    @Test("Traversal above the effective root refuses")
    func traversal() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        #expect(
            resolver(tree).resolve("../../etc/passwd")
                == .refused(.outsideRoot)
        )
    }

    @Test("Dot-dot inside the root resolves")
    func insideDotDot() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let result = resolver(tree).resolve("../assets/root.png")
        guard case .resolved(let url) = result else {
            Issue.record("expected resolved, got \(result)")
            return
        }
        #expect(url.path.contains("/project/assets/root.png"))
    }

    @Test("An absolute path refuses")
    func absolute() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        #expect(resolver(tree).resolve("/etc/passwd") == .refused(.outsideRoot))
    }

    @Test("Schemes and fragments are not local paths")
    func nonLocal() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let resolver = resolver(tree)
        #expect(
            resolver.resolve("https://example.com/x") == .refused(.notLocal)
        )
        #expect(resolver.resolve("#heading") == .refused(.notLocal))
        #expect(resolver.resolve("//host/x") == .refused(.protocolRelative))
    }

    @Test("Percent escapes and a query are handled")
    func percentAndQuery() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let resolver = resolver(tree)
        let encoded = resolver.resolve("assets/pic%2Epng")
        guard case .resolved = encoded else {
            Issue.record("encoded path failed: \(encoded)")
            return
        }
        let query = resolver.resolve("assets/pic.png?v=1")
        guard case .resolved = query else {
            Issue.record("query path failed: \(query)")
            return
        }
    }

    @Test("An untitled document uses the project root, or refuses")
    func untitled() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let withRoot = resolver(tree, document: nil)
        guard case .resolved = withRoot.resolve("assets/root.png") else {
            Issue.record("untitled with root should resolve")
            return
        }
        let noRoot = MarkdownPathResolver(
            documentURL: nil,
            root: nil,
            exists: MarkdownPathResolver.liveExists,
            canonicalize: MarkdownPathResolver.liveCanonical,
            isLocalMount: MarkdownPathResolver.liveIsLocalMount
        )
        #expect(
            noRoot.resolve("assets/root.png") == .refused(.untitledRelative)
        )
    }

    @Test("A document outside the project uses its own directory")
    func outsideProject() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let document = tree.outside.appendingPathComponent("b.md")
        try "x".write(to: document, atomically: true, encoding: .utf8)
        let resolver = resolver(tree, document: document)
        guard case .resolved = resolver.resolve("local.txt") else {
            Issue.record("outside document should resolve its sibling")
            return
        }
        #expect(
            resolver.resolve("../project/assets/root.png")
                == .refused(.outsideRoot)
        )
    }

    @Test("A non-local mount refuses before the existence probe")
    func nonLocalMountDoesNotProbe() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        final class Counter: @unchecked Sendable {
            var value = 0
        }
        let counter = Counter()
        let resolver = resolver(
            tree,
            exists: { _ in
                counter.value += 1
                return true
            },
            localMount: { _ in false }
        )
        #expect(
            resolver.resolve("assets/pic.png") == .refused(.nonLocalMount)
        )
        #expect(counter.value == 0)
    }

    @Test("A symlink that escapes the root refuses")
    func symlinkEscape() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let link = tree.root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: tree.outside
        )
        let result = resolver(tree).resolve("escape/local.txt")
        #expect(result == .refused(.outsideRoot))
    }

    @Test("Wiki resolution reuses the same root")
    func wiki() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let target = tree.root.appendingPathComponent("page.md")
        try "page".write(to: target, atomically: true, encoding: .utf8)
        let resolver = resolver(tree)
        let result = resolver.resolveWiki(
            WikiLink(target: "page", fragment: nil, alias: nil),
            markdownFiles: [target]
        )
        #expect(result == .resolved(target.standardizedFileURL))
    }
}

@Suite("Markdown path resolver audit regressions")
struct MarkdownPathResolverAuditTests {
    @Test("An encoded hash is a filename, not a fragment")
    func encodedHash() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        let document = base.appendingPathComponent("a.md")
        try "x".write(to: document, atomically: true, encoding: .utf8)
        let target = base.appendingPathComponent("notes#draft.md")
        try "y".write(to: target, atomically: true, encoding: .utf8)

        let resolver = MarkdownPathResolver(
            documentURL: document,
            root: base,
            exists: MarkdownPathResolver.liveExists,
            canonicalize: MarkdownPathResolver.liveCanonical,
            isLocalMount: MarkdownPathResolver.liveIsLocalMount
        )
        let result = resolver.resolve("notes%23draft.md")
        guard case .resolved(let url) = result else {
            Issue.record("expected resolved, got \(result)")
            return
        }
        #expect(url.lastPathComponent == "notes#draft.md")
    }
}
