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
}
