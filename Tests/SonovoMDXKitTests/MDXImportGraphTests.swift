import Foundation
import Testing
@testable import SonovoMDXKit

@Suite("MDX import graph")
struct MDXImportGraphTests {
    private static var compilerURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/Sonovo/Resources/mdx-compiler-3.1.1.js"
            )
    }

    private func makeProject(
        _ files: [String: String]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-mdx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        for (path, source) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try source.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func resolve(
        entry: String,
        in root: URL,
        limits: MDXImportLimits = .standard
    ) async throws -> MDXResolvedGraph {
        let toolchain = try MDXToolchain(
            compilerScriptURL: Self.compilerURL
        )
        return try await MDXImportGraphResolver.resolve(
            entry: root.appendingPathComponent(entry),
            projectRoot: root,
            limits: limits,
            compile: { try toolchain.compile($0) }
        )
    }

    private func expectError(
        _ expected: MDXImportGraphError,
        _ body: () async throws -> MDXResolvedGraph
    ) async {
        do {
            _ = try await body()
            Issue.record("expected \(expected)")
        } catch let error as MDXImportGraphError {
            #expect(error == expected)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("A local import chain resolves into one graph")
    func chain() async throws {
        let root = try makeProject([
            "entry.mdx": """
            import Button from "./components/Button.jsx"

            # Title

            <Button />
            """,
            "components/Button.jsx": """
            import { color } from "../theme.js"

            export default function Button() {
              return <button style={{ color }}>Go</button>;
            }
            """,
            "theme.js": "export const color = \"black\";\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let graph = try await resolve(entry: "entry.mdx", in: root).graph

        #expect(graph.entryID == "entry.mdx")
        #expect(
            Set(graph.files.keys) == [
                "entry.mdx", "components/Button.jsx", "theme.js"
            ]
        )
        #expect(graph.files["theme.js"] == "export const color = \"black\";\n")
    }

    @Test("Extensionless and directory imports resolve like a bundler")
    func extensionlessAndIndex() async throws {
        let root = try makeProject([
            "entry.mdx": """
            import Button from "./components/Button"
            import Widget from "./widgets"

            # Title
            """,
            "components/Button.jsx": "export default function Button() { return <b>B</b>; }\n",
            "widgets/index.mdx": "# Widget\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let graph = try await resolve(entry: "entry.mdx", in: root).graph
        #expect(
            Set(graph.files.keys) == [
                "entry.mdx", "components/Button.jsx", "widgets/index.mdx"
            ]
        )
    }

    @Test(".mdx wins over .jsx for an extensionless import")
    func extensionPrecedence() async throws {
        let root = try makeProject([
            "entry.mdx": """
            import A from "./A"

            # Title
            """,
            "A.mdx": "# MDX\n",
            "A.jsx": "export default function A() { return <b>JSX</b>; }\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let graph = try await resolve(entry: "entry.mdx", in: root).graph
        #expect(graph.files["A.mdx"] != nil)
        #expect(graph.files["A.jsx"] == nil)

        // The cache re-validation uses the same order.
        let resolved = try MDXImportGraphResolver.resolveImport(
            specifier: "./A",
            from: "entry.mdx",
            projectRoot: root
        )
        #expect(resolved?.id == "A.mdx")
    }

    @Test("A remote import is refused")
    func remoteRefused() async throws {
        let root = try makeProject([
            "entry.mdx": """
            import x from "https://example.com/x.js"

            # Title
            """
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        await expectError(
            .remoteImport(
                module: "entry.mdx",
                specifier: "https://example.com/x.js"
            )
        ) {
            try await resolve(entry: "entry.mdx", in: root)
        }
    }

    @Test("A bare package import is refused")
    func bareRefused() async throws {
        let root = try makeProject([
            "entry.mdx": """
            import _ from "lodash"

            # Title
            """
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        await expectError(.bareImport(module: "entry.mdx", specifier: "lodash")) {
            try await resolve(entry: "entry.mdx", in: root)
        }
    }

    @Test("An import that climbs above the root is refused")
    func dotDotRefused() async throws {
        let root = try makeProject([
            "entry.mdx": """
            import x from "./sub/a.mdx"

            # Title
            """,
            "sub/a.mdx": """
            import outside from "../../outside.js"

            # A
            """
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        await expectError(
            .escapingImport(module: "sub/a.mdx", specifier: "../../outside.js")
        ) {
            try await resolve(entry: "entry.mdx", in: root)
        }
    }

    @Test("A symbolic link that leaves the project is refused")
    func symlinkRefused() async throws {
        let root = try makeProject([
            "entry.mdx": """
            import x from "./sub/link.js"

            # Title
            """,
            "sub/placeholder.txt": ""
        ])
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-mdx-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let secret = outside.appendingPathComponent("secret.js")
        try "export const secret = 1;\n".write(
            to: secret,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("sub/link.js"),
            withDestinationURL: secret
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        await expectError(
            .escapingImport(module: "entry.mdx", specifier: "./sub/link.js")
        ) {
            try await resolve(entry: "entry.mdx", in: root)
        }
    }

    @Test("A missing import is reported with its module")
    func missingRefused() async throws {
        let root = try makeProject([
            "entry.mdx": """
            import x from "./nope.js"

            # Title
            """
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        await expectError(.missingImport(module: "entry.mdx", specifier: "./nope.js")) {
            try await resolve(entry: "entry.mdx", in: root)
        }
    }

    @Test("An unsupported import extension is reported")
    func unsupportedExtension() async throws {
        let root = try makeProject([
            "entry.mdx": """
            import data from "./data.json"

            # Title
            """,
            "data.json": "{}"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        await expectError(
            .unsupportedImport(module: "entry.mdx", specifier: "./data.json")
        ) {
            try await resolve(entry: "entry.mdx", in: root)
        }
    }

    @Test("An entry outside the project is refused")
    func entryOutside() async throws {
        let root = try makeProject(["inside.mdx": "# In\n"])
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-mdx-entry-\(UUID().uuidString).mdx")
        try "# Out\n".write(to: outside, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let toolchain = try MDXToolchain(
            compilerScriptURL: Self.compilerURL
        )
        await expectError(.entryNotInProject(outside.resolvingSymlinksInPath().path)) {
            try await MDXImportGraphResolver.resolve(
                entry: outside,
                projectRoot: root,
                compile: { try toolchain.compile($0) }
            )
        }
    }

    @Test("Only .mdx and .jsx entries open")
    func entryExtension() async throws {
        let root = try makeProject(["notes.md": "# Notes\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        await expectError(.unsupportedEntryExtension("notes.md")) {
            try await resolve(entry: "notes.md", in: root)
        }
    }

    @Test("The file cap is enforced")
    func fileCap() async throws {
        let root = try makeProject([
            "entry.mdx": """
            import a from "./a.mdx"
            import b from "./b.mdx"

            # Title
            """,
            "a.mdx": "# A\n",
            "b.mdx": "# B\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        await expectError(.tooManyFiles(limit: 2)) {
            try await resolve(
                entry: "entry.mdx",
                in: root,
                limits: MDXImportLimits(maxFiles: 2)
            )
        }
    }

    @Test("The per-file byte cap is enforced")
    func fileCapBytes() async throws {
        let root = try makeProject(["entry.mdx": "# Title\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        await expectError(
            .fileTooLarge(
                module: "entry.mdx",
                bytes: 8,
                limit: 4
            )
        ) {
            try await resolve(
                entry: "entry.mdx",
                in: root,
                limits: MDXImportLimits(maxFileBytes: 4)
            )
        }
    }

    @Test("A compile error stops the graph with its diagnostic")
    func compileError() async throws {
        let root = try makeProject(["entry.mdx": "# Hi\n\n{unclosed\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await resolve(entry: "entry.mdx", in: root)
            Issue.record("expected a compile failure")
        } catch let error as MDXImportGraphError {
            guard case .compileFailed(let diagnostic) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(diagnostic.line != nil)
        }
    }

    @Test("The round cap stops an over-deep chain")
    func roundCap() async throws {
        let root = try makeProject([
            "entry.mdx": "import a from \"./a.mdx\"\n\n# E\n",
            "a.mdx": "import b from \"./b.mdx\"\n\n# A\n",
            "b.mdx": "import c from \"./c.mdx\"\n\n# B\n",
            "c.mdx": "# C\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        await expectError(.roundLimit(2)) {
            try await resolve(
                entry: "entry.mdx",
                in: root,
                limits: MDXImportLimits(maxRounds: 2)
            )
        }
    }

    @Test("The graph key follows dependency content")
    func cacheKeyInvalidation() async throws {
        let root = try makeProject([
            "entry.mdx": "import a from \"./a.mdx\"\n\n# E\n",
            "a.mdx": "# A\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try await resolve(entry: "entry.mdx", in: root).graph
        let firstKey = MDXCompileCacheKey.graphKey(first)
        try "# A changed\n".write(
            to: root.appendingPathComponent("a.mdx"),
            atomically: true,
            encoding: .utf8
        )
        let second = try await resolve(entry: "entry.mdx", in: root).graph
        #expect(firstKey != MDXCompileCacheKey.graphKey(second))
    }

    @Test("Resolving never rewrites a source file")
    func sourcePreserved() async throws {
        let root = try makeProject([
            "entry.mdx": "import a from \"./a.mdx\"\n\n# E\n",
            "a.mdx": "# A\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let before = try Data(
            contentsOf: root.appendingPathComponent("a.mdx")
        )
        _ = try await resolve(entry: "entry.mdx", in: root)
        let after = try Data(
            contentsOf: root.appendingPathComponent("a.mdx")
        )
        #expect(before == after)
    }
}
