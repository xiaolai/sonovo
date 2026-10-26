import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown link editor")
struct MarkdownLinkEditorTests {
    private func target(
        _ source: String,
        at needle: String
    ) -> MarkdownLinkTarget? {
        let parsed = MarkdownParser.parseCanonical(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        let offset = (source as NSString).range(of: needle).location
        return MarkdownLinkEditor.target(
            at: offset,
            in: ast,
            source: source
        )
    }

    @Test("An inline link exposes its text, destination, and title")
    func inlineLink() throws {
        let source = "See [docs](https://example.com \"Title\") now."
        let link = try #require(target(source, at: "docs"))
        #expect(link.kind == .link)
        #expect(link.style == .inline)
        #expect(link.text == "docs")
        #expect(link.destination == "https://example.com")
        #expect(link.title == "Title")
        #expect(link.isEditable)
    }

    @Test("An image exposes its alt and destination")
    func image() throws {
        let source = "![alt text](pic.png)"
        let link = try #require(target(source, at: "alt"))
        #expect(link.kind == .image)
        #expect(link.text == "alt text")
        #expect(link.destination == "pic.png")
    }

    @Test("A wiki link exposes its target and alias")
    func wikiLink() throws {
        let source = "See [[Page|the alias]] now."
        let link = try #require(target(source, at: "the alias"))
        #expect(link.kind == .wikiLink)
        #expect(link.style == .wiki)
        #expect(link.label == "Page")
        #expect(link.alias == "the alias")
        #expect(link.isEditable)
    }

    @Test("A reference link is read-only and resolves its definition")
    func referenceLink() throws {
        let source = "[text][label]\n\n[label]: https://example.com"
        let link = try #require(target(source, at: "text"))
        #expect(link.style == .reference)
        #expect(!link.isEditable)
        #expect(link.destination == "https://example.com")
        #expect(link.definitionRange != nil)
    }

    @Test("Collapsed and shortcut references resolve")
    func collapsedAndShortcut() throws {
        let collapsed = "[text][]\n\n[text]: https://a.example"
        let collapsedLink = try #require(target(collapsed, at: "text"))
        #expect(collapsedLink.style == .collapsed)
        #expect(collapsedLink.destination == "https://a.example")

        let shortcut = "[note]\n\n[note]: https://b.example"
        let shortcutLink = try #require(target(shortcut, at: "note"))
        #expect(shortcutLink.style == .shortcut)
        #expect(shortcutLink.destination == "https://b.example")
    }

    @Test("Committing an inline link rewrites only the construct")
    func commitInline() throws {
        let source = "before [docs](https://old.example) after"
        let link = try #require(target(source, at: "docs"))
        let caret = 3..<3
        let result = try MarkdownLinkEditor.commit(
            MarkdownLinkValues(
                text: "docs",
                destination: "https://new.example",
                title: "T"
            ),
            to: link,
            source: source,
            selection: caret
        )
        #expect(
            result.source
                == "before [docs](https://new.example \"T\") after"
        )
        #expect(result.selection == caret)
    }

    @Test("Committing a wiki alias keeps the target")
    func commitWiki() throws {
        let source = "[[Page]]"
        let link = try #require(target(source, at: "Page"))
        let result = try MarkdownLinkEditor.commit(
            MarkdownLinkValues(target: "Page", alias: "Alias"),
            to: link,
            source: source,
            selection: 2..<2
        )
        #expect(result.source == "[[Page|Alias]]")
    }

    @Test("A reference link refuses a write")
    func referenceRefusesWrite() throws {
        let source = "[text][label]\n\n[label]: https://example.com"
        let link = try #require(target(source, at: "text"))
        #expect(throws: MarkdownLinkError.readOnlyReference) {
            try MarkdownLinkEditor.commit(
                MarkdownLinkValues(text: "text", destination: "x"),
                to: link,
                source: source,
                selection: 1..<1
            )
        }
    }

    @Test("An empty wiki target refuses")
    func emptyWikiTarget() throws {
        let source = "[[Page]]"
        let link = try #require(target(source, at: "Page"))
        #expect(throws: MarkdownLinkError.invalidTarget) {
            try MarkdownLinkEditor.commit(
                MarkdownLinkValues(target: "  ", alias: nil),
                to: link,
                source: source,
                selection: 2..<2
            )
        }
    }

    @Test("An unchanged edit preserves the label's existing escapes")
    func labelRoundTripPreservesEscapes() throws {
        // The label is the raw bracket-inner source, escapes included.
        // Escaping it again doubled every backslash and changed a link the
        // user did not edit.
        let source = #"See [lab \[x\] \\ end](https://example.com) now."#
        let link = try #require(target(source, at: "lab"))
        #expect(link.text == #"lab \[x\] \\ end"#)
        let result = try MarkdownLinkEditor.commit(
            MarkdownLinkValues(
                text: link.text,
                destination: link.destination,
                title: link.title
            ),
            to: link,
            source: source,
            selection: 0..<0
        )
        #expect(result.source == source)
    }

    @Test("A bracket the user typed in the label is escaped")
    func labelBracketIsEscaped() throws {
        let source = "See [docs](https://example.com) now."
        let link = try #require(target(source, at: "docs"))
        let result = try MarkdownLinkEditor.commit(
            MarkdownLinkValues(
                text: "a]b [c]",
                destination: "https://example.com"
            ),
            to: link,
            source: source,
            selection: 0..<0
        )
        // The unmatched `]` must be escaped; the balanced `[c]` pair is
        // literal text either way, and escaping it would add noise.
        #expect(
            result.source
                == #"See [a\]b [c]](https://example.com) now."#
        )
    }

    @Test("A trailing backslash in the label stays a literal")
    func labelTrailingBackslash() throws {
        let source = "See [docs](https://example.com) now."
        let link = try #require(target(source, at: "docs"))
        let result = try MarkdownLinkEditor.commit(
            MarkdownLinkValues(text: #"a\"#, destination: "https://example.com"),
            to: link,
            source: source,
            selection: 0..<0
        )
        #expect(
            result.source == #"See [a\\](https://example.com) now."#
        )
    }

    @Test("Brackets inside a code span in the label stay unescaped")
    func labelCodeSpanRoundTrip() throws {
        // The parser reads `[x]` inside a code span as literal text, not as
        // the label's brackets. Escaping it would put backslashes into the
        // code the reader sees, so the span is copied verbatim.
        let source = #"See [`[x]`](https://example.com) now."#
        let link = try #require(target(source, at: "[x]"))
        #expect(link.text == #"`[x]`"#)
        let result = try MarkdownLinkEditor.commit(
            MarkdownLinkValues(
                text: link.text,
                destination: link.destination,
                title: link.title
            ),
            to: link,
            source: source,
            selection: 0..<0
        )
        #expect(result.source == source)
    }

    @Test("A closing bracket inside a code span does not end the label")
    func labelCodeSpanWithClosingBracket() throws {
        // Reading the label and writing it back must agree that the `]`
        // between backticks is code, not the label's terminator.
        let source = #"See [`]`](https://example.com) now."#
        let link = try #require(target(source, at: "`]`"))
        #expect(link.text == #"`]`"#)
        let result = try MarkdownLinkEditor.commit(
            MarkdownLinkValues(
                text: link.text,
                destination: link.destination,
                title: link.title
            ),
            to: link,
            source: source,
            selection: 0..<0
        )
        #expect(result.source == source)
    }

    @Test("A balanced bracket pair in the label stays raw")
    func labelBalancedBrackets() throws {
        let source = "See [a[bc]d](https://example.com) now."
        let link = try #require(target(source, at: "bc"))
        #expect(link.text == "a[bc]d")
        let result = try MarkdownLinkEditor.commit(
            MarkdownLinkValues(
                text: link.text,
                destination: link.destination,
                title: link.title
            ),
            to: link,
            source: source,
            selection: 0..<0
        )
        #expect(result.source == source)
    }

    @Test("An image inside the label keeps its syntax")
    func labelEmbeddedImage() throws {
        // `![alt](img.png)` is valid link text. Escaping its brackets would
        // turn the image into literal text.
        let source = "See [![alt](img.png)](https://example.com) now."
        let link = try #require(target(source, at: "[!"))
        #expect(link.text == "![alt](img.png)")
        let result = try MarkdownLinkEditor.commit(
            MarkdownLinkValues(
                text: link.text,
                destination: link.destination,
                title: link.title
            ),
            to: link,
            source: source,
            selection: 0..<0
        )
        #expect(result.source == source)
    }
}
