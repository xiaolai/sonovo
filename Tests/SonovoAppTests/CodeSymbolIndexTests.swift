import XCTest
@testable import Sonovo

final class CodeSymbolIndexTests: XCTestCase {
    func testSwiftSymbols() {
        let source = """
        import Foundation

        @MainActor
        final class ViewModel {
            private var count: Int
            static let shared = ViewModel()
            func reload(force: Bool) {}
            init() {}
        }

        struct Row: Identifiable {}

        protocol Loader {}

        extension Row {
            var label: String { "row" }
        }

        func measure() {}
        """
        let symbols = CodeSymbolIndex.symbols(
            in: source,
            language: .swift
        )
        let names = symbols.map(\.name)
        XCTAssertTrue(names.contains("ViewModel"))
        XCTAssertTrue(names.contains("count"))
        XCTAssertTrue(names.contains("shared"))
        XCTAssertTrue(names.contains("reload"))
        XCTAssertTrue(names.contains("init"))
        XCTAssertTrue(names.contains("Row"))
        XCTAssertTrue(names.contains("Loader"))
        XCTAssertTrue(names.contains("label"))
        XCTAssertTrue(names.contains("measure"))
        XCTAssertEqual(
            symbols.first { $0.name == "ViewModel" }?.kind,
            .type
        )
        XCTAssertEqual(
            symbols.first { $0.name == "reload" }?.kind,
            .function
        )
        XCTAssertEqual(
            symbols.first { $0.name == "measure" }?.column,
            6,
            "the column is the name, not the declaration keyword"
        )
        XCTAssertEqual(
            symbols.first { $0.name == "init" }?.column,
            5
        )
    }

    func testParameterizedAttributesAndModifiersAreStripped() {
        let source = """
        @available(iOS 17.0, *)
        func load() {}

        @MainActor
        private(set) var count = 0
        """
        let symbols = CodeSymbolIndex.symbols(
            in: source,
            language: .swift
        )
        XCTAssertEqual(
            symbols.map(\.name),
            ["load", "count"]
        )
        XCTAssertEqual(
            symbols.first { $0.name == "load" }?.column,
            6
        )
    }

    func testJavaScriptInitializerIsRequired() {
        let source = """
        const packed=1
        const spaced = 1
        const typed: number = 1
        let uninitialized: number;
        """
        let symbols = CodeSymbolIndex.symbols(
            in: source,
            language: .typescript
        )
        XCTAssertEqual(
            symbols.map(\.name),
            ["packed", "spaced", "typed"]
        )
    }

    func testAttributeParenthesesAreBalanced() {
        let source = """
        @available(*, deprecated, message: "use load) instead")
        func old() {}

        @available(*, deprecated, message: "use save) instead") func sameLine() {}
        """
        let symbols = CodeSymbolIndex.symbols(
            in: source,
            language: .swift
        )
        XCTAssertEqual(symbols.map(\.name), ["old", "sameLine"])
    }

    func testDeclarationsInsideMultilineConstructsAreSkipped() {
        let swift = """
        /*
        func hidden() {}
        */
        func visible() {}
        """
        let swiftSymbols = CodeSymbolIndex.symbols(
            in: swift,
            language: .swift
        )
        XCTAssertEqual(swiftSymbols.map(\.name), ["visible"])

        let python = """
        text = \"\"\"
        def hidden():
        \"\"\"
        def visible():
        """
        let pythonSymbols = CodeSymbolIndex.symbols(
            in: python,
            language: .python
        )
        XCTAssertEqual(pythonSymbols.map(\.name), ["visible"])
    }

    func testShellFunctionAllowsExtraWhitespace() {
        let symbols = CodeSymbolIndex.symbols(
            in: "build  () {\n}\n",
            language: .shell
        )
        XCTAssertEqual(symbols.map(\.name), ["build"])
    }

    func testJavaScriptAndTypeScriptSymbols() {
        let source = """
        export default class Store {}
        export async function load() {}
        const value = 1
        interface Model {}
        type ID = string
        """
        let symbols = CodeSymbolIndex.symbols(
            in: source,
            language: .typescript
        )
        let names = symbols.map(\.name)
        XCTAssertEqual(names, ["Store", "load", "value", "Model", "ID"])
        XCTAssertEqual(
            symbols.first { $0.name == "Store" }?.kind,
            .type
        )
        XCTAssertEqual(
            symbols.first { $0.name == "load" }?.kind,
            .function
        )
    }

    func testPythonSymbols() {
        let source = """
        class Loader:
            async def run(self):
                pass

        async def main():
            pass

        def helper():
            pass
        """
        let symbols = CodeSymbolIndex.symbols(
            in: source,
            language: .python
        )
        XCTAssertEqual(
            symbols.map(\.name),
            ["Loader", "run", "main", "helper"]
        )
        XCTAssertEqual(symbols[0].kind, .type)
        XCTAssertEqual(symbols[1].kind, .function)
    }

    func testShellSymbols() {
        let source = """
        #!/bin/sh
        function setup() {
            echo hi
        }

        build() {
            make
        }
        """
        let symbols = CodeSymbolIndex.symbols(
            in: source,
            language: .shell
        )
        XCTAssertEqual(symbols.map(\.name), ["setup", "build"])
    }

    func testUnsupportedLanguageHasNoOutline() {
        let symbols = CodeSymbolIndex.symbols(
            in: "fn main() {}",
            language: .rust
        )
        XCTAssertTrue(symbols.isEmpty)
    }

    func testNearestSymbolAtOrAboveLine() {
        let symbols = [
            CodeSymbol(name: "first", kind: .function, line: 2, column: 1),
            CodeSymbol(name: "second", kind: .function, line: 10, column: 1)
        ]
        XCTAssertNil(CodeSymbolIndex.symbol(at: 1, in: symbols))
        XCTAssertEqual(
            CodeSymbolIndex.symbol(at: 2, in: symbols)?.name,
            "first"
        )
        XCTAssertEqual(
            CodeSymbolIndex.symbol(at: 9, in: symbols)?.name,
            "first"
        )
        XCTAssertEqual(
            CodeSymbolIndex.symbol(at: 10, in: symbols)?.name,
            "second"
        )
    }
}
