import Foundation
import Testing
@testable import SonovoMDXKit

@Suite("MDX toolchain")
struct MDXToolchainTests {
    private static var compilerURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/Sonovo/Resources/mdx-compiler-3.1.1.js"
            )
    }

    private func compile(
        entry: String,
        files: [String: String]
    ) throws -> MDXCompileResponse {
        let toolchain = try MDXToolchain(
            compilerScriptURL: Self.compilerURL
        )
        return try toolchain.compile(
            MDXCompileRequest(entry: entry, files: files)
        )
    }

    @Test("Markdown and expressions compile")
    func markdownAndExpressions() throws {
        let response = try compile(
            entry: "entry.mdx",
            files: [
                "entry.mdx":
                    "# Hello\n\nThe answer is {2 + 2}.\n"
            ]
        )
        #expect(response.ok)
        #expect(response.entry == "entry.mdx")
        let module = try #require(
            response.modules.first { $0.id == "entry.mdx" }
        )
        // The only require is the runtime's jsx entry, supplied by the page;
        // the graph itself has no local dependency.
        #expect(module.imports.isEmpty)
        #expect(module.code.contains("react/jsx-runtime"))
        #expect(module.code.contains("Hello"))
        #expect(module.code.contains("2 + 2"))
    }

    @Test("A JSX component import is compiled as a module")
    func jsxImport() throws {
        let source = """
        import Button from "./Button.jsx"

        <Button label="Save" />
        """
        let response = try compile(
            entry: "entry.mdx",
            files: [
                "entry.mdx": source,
                "Button.jsx": """
                export default function Button(props) {
                  return <button>{props.label}</button>;
                }
                """
            ]
        )
        #expect(response.ok)
        let entryModule = try #require(
            response.modules.first { $0.id == "entry.mdx" }
        )
        #expect(entryModule.imports == ["./Button.jsx"])
        let button = try #require(
            response.modules.first { $0.id == "Button.jsx" }
        )
        #expect(button.imports.isEmpty)
        #expect(button.code.contains("require(\"react\")"))
        #expect(button.code.contains("React.createElement"))
        #expect(button.code.contains("button"))
    }

    @Test("Export-from dependencies are reported")
    func exportFrom() throws {
        let response = try compile(
            entry: "entry.mdx",
            files: [
                "entry.mdx": """
                export { meta } from "./meta.js"

                # Title
                """,
                "meta.js": "export const meta = { title: \"x\" };\n"
            ]
        )
        let module = try #require(
            response.modules.first { $0.id == "entry.mdx" }
        )
        #expect(module.imports.contains("./meta.js"))
    }

    @Test("Imports inside a code fence are not dependencies")
    func codeFenceImportsAreIgnored() throws {
        let response = try compile(
            entry: "entry.mdx",
            files: [
                "entry.mdx": """
                # Imports

                ```js
                import fake from "./fake.js"
                ```
                """
            ]
        )
        let module = try #require(
            response.modules.first { $0.id == "entry.mdx" }
        )
        #expect(!module.imports.contains("./fake.js"))
    }

    @Test("A syntax error carries its source position")
    func syntaxError() throws {
        let response = try compile(
            entry: "entry.mdx",
            files: ["entry.mdx": "# Hi\n\n{unclosed\n"]
        )
        #expect(!response.ok)
        #expect(response.modules.isEmpty)
        let diagnostic = try #require(response.diagnostic)
        #expect(!diagnostic.message.isEmpty)
        #expect(diagnostic.line != nil)
        #expect(diagnostic.column != nil)
        #expect(diagnostic.displayText.contains("Line"))
    }

    @Test("ESM exports reach the compiled module")
    func exportsCompile() throws {
        let response = try compile(
            entry: "entry.mdx",
            files: [
                "entry.mdx": """
                export const meta = { title: "Sonovo" }

                # Title
                """
            ]
        )
        let module = try #require(
            response.modules.first { $0.id == "entry.mdx" }
        )
        #expect(module.code.contains("exports.meta"))
    }

    @Test("The toolchain version is pinned")
    func pinnedVersion() {
        #expect(MDXToolchain.version == "mdx-3.1.1-react-19.3.1-acorn-8.15.0")
    }

    @Test("A missing compiler script is a configuration error")
    func missingScript() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).js")
        #expect(throws: MDXToolchainError.self) {
            _ = try MDXToolchain(compilerScriptURL: missing)
        }
    }

    @Test("A remote import is reported, not fetched")
    func remoteImportIsReported() throws {
        let response = try compile(
            entry: "entry.mdx",
            files: [
                "entry.mdx": """
                import x from "https://example.com/x.js"

                # Title
                """
            ]
        )
        let module = try #require(
            response.modules.first { $0.id == "entry.mdx" }
        )
        #expect(module.imports.contains("https://example.com/x.js"))
    }
}
