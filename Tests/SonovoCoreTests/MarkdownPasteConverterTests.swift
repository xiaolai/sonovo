import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown paste converter")
struct MarkdownPasteConverterTests {
    @Test("A URL over a selection becomes a link")
    func urlOverSelection() {
        let input = MarkdownPasteInput(
            flavors: [.url("https://example.com"), .text("https://example.com")],
            selectionText: "docs"
        )
        let plan = MarkdownPasteConverter.plan(
            input: input,
            selection: 0..<4
        )
        guard case let .insert(range, replacement, _) = plan else {
            Issue.record("expected insert, got \(plan)")
            return
        }
        #expect(range == 0..<4)
        #expect(replacement == "[docs](https://example.com)")
    }

    @Test("A URL over an empty selection stays plain")
    func urlWithoutSelection() {
        let input = MarkdownPasteInput(
            flavors: [.url("https://example.com")],
            selectionText: ""
        )
        #expect(
            MarkdownPasteConverter.plan(input: input, selection: 0..<0)
                == .plain
        )
    }

    @Test("Code-shaped text becomes a fenced block with a language")
    func codeDetection() {
        let swift = MarkdownPasteInput(
            flavors: [.text("import Foundation\nfunc f() {\n    let x = 1\n}")],
            selectionText: ""
        )
        guard case let .insert(_, replacement, _) =
            MarkdownPasteConverter.plan(input: swift, selection: 0..<0)
        else {
            Issue.record("swift snippet was not fenced")
            return
        }
        #expect(replacement.hasPrefix("```swift\n"))

        let python = MarkdownPasteInput(
            flavors: [.text("import os\ndef f():\n    pass")],
            selectionText: ""
        )
        guard case let .insert(_, pythonText, _) =
            MarkdownPasteConverter.plan(input: python, selection: 0..<0)
        else {
            Issue.record("python snippet was not fenced")
            return
        }
        #expect(pythonText.hasPrefix("```python\n"))
    }

    @Test("Ordinary prose stays plain")
    func prose() {
        let input = MarkdownPasteInput(
            flavors: [.text("Hello there, this is prose.")],
            selectionText: ""
        )
        #expect(
            MarkdownPasteConverter.plan(input: input, selection: 0..<0)
                == .plain
        )
    }

    @Test("Pasting inside a fence is literal")
    func insideFence() {
        let input = MarkdownPasteInput(
            flavors: [.text("import Foundation\nfunc f() {}")],
            selectionText: "",
            isInsideFence: true
        )
        #expect(
            MarkdownPasteConverter.plan(input: input, selection: 0..<0)
                == .plain
        )
    }

    @Test("A paste over the size cap stays plain")
    func sizeCap() {
        let big = String(
            repeating: "func f() {}\n",
            count: 8_000
        )
        let input = MarkdownPasteInput(
            flavors: [.text(big)],
            selectionText: ""
        )
        #expect(
            MarkdownPasteConverter.plan(input: input, selection: 0..<0)
                == .plain
        )
    }

    @Test("HTML alone converts now that the clipboard corpus passes")
    func htmlConverts() {
        let input = MarkdownPasteInput(
            flavors: [.html("<p>Hello <b>world</b></p>")],
            selectionText: ""
        )
        guard case let .insert(_, replacement, _) =
            MarkdownPasteConverter.plan(input: input, selection: 0..<0)
        else {
            Issue.record("HTML paste did not convert")
            return
        }
        #expect(replacement == "Hello **world**\n")
    }
}
