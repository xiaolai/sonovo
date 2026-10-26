import Foundation
import Testing
@testable import SonovoCore

@Suite("Inline HTML")
struct MarkdownInlineHTMLTests {
    @Test("The four allowed tags are recognized in both directions")
    func allowedTags() {
        for tag in MarkdownInlineHTMLTag.allCases {
            let open = MarkdownInlineHTML.match(tag.openTag)
            #expect(open?.tag == tag)
            #expect(open?.isClosing == false)
            let close = MarkdownInlineHTML.match(tag.closeTag)
            #expect(close?.tag == tag)
            #expect(close?.isClosing == true)
        }
    }

    @Test("Tags are case-insensitive and tolerate surrounding whitespace")
    func tolerantSpelling() {
        #expect(
            MarkdownInlineHTML.match(" <MARK> ")?.tag == .mark
        )
        #expect(
            MarkdownInlineHTML.match("</Sup>")?.tag == .superscript
        )
    }

    @Test("Attributes, self-closing forms, and unknown tags are refused")
    func refusedForms() {
        let refused = [
            "<mark class=\"x\">",
            "<mark/>",
            "<mark />",
            "</mark >",
            "<script>",
            "<b>",
            "<u",
            "u",
            ""
        ]
        for raw in refused {
            #expect(MarkdownInlineHTML.match(raw) == nil, "\(raw)")
        }
    }

    @Test("Tag spellings match the HTML the source carries")
    func tagSpellings() {
        #expect(MarkdownInlineHTMLTag.mark.openTag == "<mark>")
        #expect(MarkdownInlineHTMLTag.mark.closeTag == "</mark>")
        #expect(MarkdownInlineHTMLTag.underline.openTag == "<u>")
        #expect(MarkdownInlineHTMLTag.underline.closeTag == "</u>")
        #expect(MarkdownInlineHTMLTag.superscript.openTag == "<sup>")
        #expect(MarkdownInlineHTMLTag.superscript.closeTag == "</sup>")
        #expect(MarkdownInlineHTMLTag.subscriptTag.openTag == "<sub>")
        #expect(MarkdownInlineHTMLTag.subscriptTag.closeTag == "</sub>")
    }

    // MARK: - Commands

    @Test("Each command wraps the selection in its tag pair")
    func wrapSelection() throws {
        let registry = MarkdownCommandRegistry()
        let cases: [(MarkdownCommandKind, String, String)] = [
            (.toggleHighlight, "<mark>", "</mark>"),
            (.toggleUnderline, "<u>", "</u>"),
            (.toggleSuperscript, "<sup>", "</sup>"),
            (.toggleSubscript, "<sub>", "</sub>")
        ]
        for (command, open, close) in cases {
            let result = try registry.apply(
                command,
                to: MarkdownCommandContext(
                    source: "hello",
                    selection: 0..<5
                )
            )
            #expect(result.source == "\(open)hello\(close)", "\(command)")
            let start = (open as NSString).length
            #expect(result.selection == start..<(start + 5))
        }
    }

    @Test("An empty selection inserts an empty pair with the caret inside")
    func emptySelection() throws {
        let registry = MarkdownCommandRegistry()
        let result = try registry.apply(
            .toggleHighlight,
            to: MarkdownCommandContext(source: "ab", selection: 1..<1)
        )
        #expect(result.source == "a<mark></mark>b")
        #expect(result.selection == 7..<7)
    }

    @Test("A wrapped selection unwraps")
    func unwrapOutside() throws {
        let registry = MarkdownCommandRegistry()
        let source = "x <mark>hello</mark> y"
        let start = (source as NSString).range(of: "hello").location
        let result = try registry.apply(
            .toggleHighlight,
            to: MarkdownCommandContext(
                source: source,
                selection: start..<(start + 5)
            )
        )
        #expect(result.source == "x hello y")
        #expect(result.selection == 2..<7)
    }

    @Test("A selection that includes the tags unwraps to its inner text")
    func unwrapSelection() throws {
        let registry = MarkdownCommandRegistry()
        let source = "x <u>hello</u> y"
        let start = (source as NSString).range(of: "<u>").location
        let result = try registry.apply(
            .toggleUnderline,
            to: MarkdownCommandContext(
                source: source,
                selection: start..<(start + 12)
            )
        )
        #expect(result.source == "x hello y")
        #expect(result.selection == 2..<7)
    }

    @Test("Commands are unavailable read-only and appear once in the catalog")
    func availabilityAndCatalog() {
        let registry = MarkdownCommandRegistry()
        let readOnly = MarkdownCommandContext(
            source: "hello",
            selection: 0..<5,
            isReadOnly: true
        )
        for command in [
            MarkdownCommandKind.toggleHighlight,
            .toggleUnderline,
            .toggleSuperscript,
            .toggleSubscript
        ] {
            #expect(!registry.isAvailable(command, in: readOnly))
            let entries = MarkdownCommandCatalog.entries.filter {
                $0.command == command
            }
            #expect(entries.count == 1)
            #expect(entries.first?.category == "Format")
        }
    }
}
