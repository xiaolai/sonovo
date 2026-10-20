import Foundation
import Testing
@testable import SonovoCore

@Suite("Syntax augmenter")
struct AugmenterTests {
    private func augment(_ source: String) -> SonovoAST {
        MarkdownSyntaxAugmenter().augment(MarkdownParser.parseCanonical(source))
    }

    private func inlines(of ast: SonovoAST) throws -> [Inline] {
        guard case let .paragraph(inlines, _) = ast.blocks.first else {
            Issue.record("expected a paragraph, got \(ast.blocks)")
            return []
        }
        return inlines
    }

    private func wikiLinks(in inlines: [Inline]) -> [WikiLink] {
        inlines.compactMap { inline in
            if case let .wikiLink(link, _) = inline { return link }
            return nil
        }
    }

    // MARK: - Wiki links

    @Test("Parses plain and aliased wiki links")
    func wikiLinksBasic() throws {
        let ast = augment("See [[Page]] and [[Other|Alias]].\n")
        let links = wikiLinks(in: try inlines(of: ast))
        #expect(links == [
            WikiLink(target: "Page", fragment: nil, alias: nil),
            WikiLink(target: "Other", fragment: nil, alias: "Alias")
        ])
    }

    @Test("Claims a cross-node alias as one wiki link")
    func wikiLinkCrossNodeAlias() throws {
        let ast = augment("See [[Page|*alias*]].\n")
        let inlines = try inlines(of: ast)
        let links = wikiLinks(in: inlines)
        #expect(links.count == 1)
        #expect(links[0].target == "Page")
        #expect(links[0].alias == "*alias*")
        #expect(links[0].display == "*alias*")
        // The emphasis inside the alias must not survive.
        #expect(!inlines.contains { inline in
            if case .emphasis = inline { return true }
            return false
        })
    }

    @Test("Preserves text around a wiki link")
    func wikiLinkSplitsText() throws {
        let ast = augment("pre [[Page]] post\n")
        let inlines = try inlines(of: ast)
        #expect(inlines.count == 3)
        guard case let .text(before, _) = inlines[0],
              case let .text(after, _) = inlines[2] else {
            Issue.record("expected text around the link")
            return
        }
        #expect(before == "pre ")
        #expect(after == " post")
    }

    @Test("Preserves an unrelated style node's authored range")
    func styleRangePreserved() throws {
        let ast = augment("**bold** [[Page]]\n")
        guard case let .paragraph(inlines, _) = ast.blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        guard case let .strong(_, range) = inlines.first else {
            Issue.record("expected the strong node first, got \(inlines)")
            return
        }
        #expect(range?.lowerBound == 0)
        #expect(range?.upperBound == 8)
    }

    @Test("Adjacent style nodes keep separate identities and ranges")
    func adjacentStylesStaySeparate() throws {
        let ast = augment("**one**__two__ [[Page]]\n")
        guard case let .paragraph(inlines, _) = ast.blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        let ranges = inlines.compactMap { inline -> SourceRange? in
            if case let .strong(_, range) = inline { return range }
            return nil
        }
        #expect(ranges.count == 2)
        #expect(ranges[0] != ranges[1])
    }

    @Test("An inline fragment at the document origin keeps its offset")
    func fragmentOrigin() throws {
        let inlines = InlineFragmentParser.parse(
            "- item",
            baseLine: 1,
            baseOffset: 0
        )
        let first = try #require(inlines.first)
        #expect(first.range?.lowerBound == 0)
        #expect(first.range?.upperBound == 6)
    }

    @Test("Keeps the enclosing style around a wiki link")
    func wikiLinkKeepsEnclosingStrong() throws {
        let ast = augment("**[[Page]]**\n")
        let inlines = try inlines(of: ast)
        #expect(inlines.count == 1)
        guard case let .strong(children, _) = inlines[0] else {
            Issue.record("expected the wiki link to stay bold, got \(inlines)")
            return
        }
        #expect(children.contains { inline in
            if case .wikiLink = inline { return true }
            return false
        })
    }

    @Test("Keeps boundary whitespace when an entity forces a reparse")
    func wikiLinkEntityWhitespace() throws {
        let ast = augment("&amp; [[Page]]\n")
        let inlines = try inlines(of: ast)
        var before = ""
        for inline in inlines {
            if case let .text(value, _) = inline {
                before += value
            } else {
                break
            }
        }
        #expect(before == "& ")
    }

    @Test("Keeps a list-looking slice literal after a wiki link")
    func wikiLinkSuffixListMarker() throws {
        let ast = augment("[[Page]] - &amp;\n")
        let inlines = try inlines(of: ast)
        var after = ""
        var sawLink = false
        for inline in inlines {
            if case .wikiLink = inline {
                sawLink = true
            } else if sawLink, case let .text(value, _) = inline {
                after += value
            }
        }
        #expect(after == " - &")
    }

    @Test("Rejects escaped, embedded, empty, and entity openers")
    func wikiLinksRejected() throws {
        for source in [
            "\\[[Page]]\n",
            "![[image.png]]\n",
            "[[|alias]]\n",
            "&#91;&#91;Page]]\n",
            "`[[code]]`\n",
            "[link [[Page]]](https://example.com)\n",
            "[[Page\n+ #Heading]]\n"
        ] {
            let ast = augment(source)
            let count = wikiLinks(in: try inlines(of: ast)).count
            #expect(count == 0, "unexpected wiki link in \(source.debugDescription)")
        }
    }

    @Test("Treats an empty alias as no alias")
    func wikiLinkEmptyAlias() throws {
        let ast = augment("[[Page|]]\n")
        let links = wikiLinks(in: try inlines(of: ast))
        #expect(links.count == 1)
        #expect(links[0].alias == nil)
        #expect(links[0].display == "Page")
    }

    @Test("Parses fragments and their display")
    func wikiLinkFragment() throws {
        let ast = augment("[[Page#Heading]]\n")
        let links = wikiLinks(in: try inlines(of: ast))
        #expect(links.count == 1)
        #expect(links[0].target == "Page")
        #expect(links[0].fragment == "Heading")
        #expect(links[0].display == "Page#Heading")
    }

    @Test("Wiki link ranges cover the whole authored span")
    func wikiLinkRange() throws {
        let source = "pre [[Page|Alias]] post\n"
        let ast = augment(source)
        guard case let .wikiLink(_, range) = try inlines(of: ast)[1] else {
            Issue.record("expected a wiki link")
            return
        }
        #expect(source.utf16Range(try #require(range)) == "[[Page|Alias]]")
    }

    @Test("Every backslash parity is handled")
    func wikiLinkBackslashes() throws {
        let even = augment("\\\\[[Page]]\n")
        #expect(wikiLinks(in: try inlines(of: even)).count == 1)

        let odd = augment("\\\\\\[[Page]]\n")
        #expect(wikiLinks(in: try inlines(of: odd)).count == 0)
    }

    // MARK: - TOC

    @Test("Recognizes a standalone TOC marker")
    func tocMarker() throws {
        let ast = augment("# Top\n\n[TOC]\n\n## First\n")
        #expect(ast.blocks.contains { block in
            if case .tableOfContents = block { return true }
            return false
        })
    }

    @Test("Does not recognize escaped, linked, or contained markers")
    func tocRejections() throws {
        for source in [
            "\\[TOC]\n",
            "[TOC](https://example.com)\n",
            "> [TOC]\n",
            "- [TOC]\n",
            "`[TOC]`\n",
            "&#91;TOC]\n"
        ] {
            let ast = augment(source)
            #expect(!ast.blocks.contains { block in
                if case .tableOfContents = block { return true }
                return false
            }, "unexpected TOC in \(source.debugDescription)")
        }
    }

    @Test("Accepts case and surrounding whitespace")
    func tocCaseAndWhitespace() throws {
        for source in ["[toc]\n", "  [TOC]  \n", "[ToC]\n"] {
            let ast = augment(source)
            #expect(ast.blocks.contains { block in
                if case .tableOfContents = block { return true }
                return false
            }, "missing TOC in \(source.debugDescription)")
        }
    }

    @Test("Allows multiple TOC markers")
    func tocMultiple() throws {
        let ast = augment("[TOC]\n\n# A\n\n[TOC]\n")
        let count = ast.blocks.filter { block in
            if case .tableOfContents = block { return true }
            return false
        }.count
        #expect(count == 2)
    }

    // MARK: - Details

    private func details(of ast: SonovoAST) -> [DetailsBlock] {
        ast.blocks.compactMap { block in
            if case let .details(details, _) = block { return details }
            return nil
        }
    }

    @Test("Parses a compact details block")
    func compactDetails() throws {
        let source = "<details><summary>Summary</summary>Body *here*</details>\n"
        let ast = augment(source)
        let blocks = details(of: ast)
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(block.isOpen == false)
        #expect(block.summary.count == 1)
        #expect(block.blocks.count == 1)
        guard case let .paragraph(inlines, _) = block.blocks.first else {
            Issue.record("expected a body paragraph")
            return
        }
        #expect(inlines.contains { inline in
            if case .emphasis = inline { return true }
            return false
        })
    }

    @Test("Parses a multi-block details block and keeps the body blocks")
    func multiBlockDetails() throws {
        let source = """
        <details open>
        <summary>Summary with *inline*</summary>

        Body paragraph.

        - list item
        </details>
        """
        let ast = augment(source)
        let blocks = details(of: ast)
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(block.isOpen)
        #expect(block.blocks.count == 2)
        #expect(block.summary.contains { inline in
            if case .emphasis = inline { return true }
            return false
        })
    }

    @Test("Reads only a real open attribute")
    func detailsOpenAttribute() throws {
        let cases: [(String, Bool)] = [
            ("<details open><summary>S</summary>x</details>\n", true),
            ("<details open=\"open\"><summary>S</summary>x</details>\n", true),
            ("<details data-open=\"true\"><summary>S</summary>x</details>\n", false),
            ("<details data-state=\"open\"><summary>S</summary>x</details>\n", false)
        ]
        for (source, expected) in cases {
            let block = try #require(details(of: augment(source)).first)
            #expect(block.isOpen == expected, "wrong open state for \(source)")
        }
    }

    @Test("Nests details recursively")
    func nestedDetails() throws {
        let source = """
        <details>
        <summary>Outer</summary>

        <details>
        <summary>Inner</summary>

        Inner body.
        </details>
        </details>
        """
        let ast = augment(source)
        let outer = try #require(details(of: ast).first)
        #expect(outer.blocks.count == 1)
        guard case let .details(inner, _) = outer.blocks.first else {
            Issue.record("expected nested details, got \(outer.blocks)")
            return
        }
        #expect(inner.blocks.count == 1)
    }

    @Test("Leaves unclosed and stray tags raw")
    func malformedDetails() {
        for source in [
            "<details><summary>S</summary>\n\nBody with no close.\n",
            "</details>\n",
            "<details><summary>S</summary>no close\n"
        ] {
            let ast = augment(source)
            #expect(details(of: ast).isEmpty, "unexpected details for \(source)")
        }
    }

    @Test("Malformed attributes cannot stall details parsing")
    func detailsMalformedAttribute() {
        // Before the cursor-progress guard this input looped forever.
        let ast = augment("<details @><summary>S</summary>x</details>\n")
        #expect(details(of: ast).isEmpty)
    }

    @Test("Keeps body content that shares the opening details block")
    func detailsOpeningBlockBody() throws {
        let source = "<details><summary>S</summary>lost\n\nbody\n\n</details>\n"
        let block = try #require(details(of: augment(source)).first)
        let paragraphs = block.blocks.compactMap { block -> String? in
            guard case let .paragraph(inlines, _) = block else { return nil }
            return HeadingIndex.renderedText(inlines)
        }
        #expect(paragraphs.contains("lost"))
        #expect(paragraphs.contains("body"))
    }

    @Test("Ignores summary text inside another tag's attribute")
    func summaryInsideAttribute() throws {
        let source = "<details><div title=\"<summary>Fake</summary>\">"
            + "<summary>Real</summary>body</details>\n"
        let block = try #require(details(of: augment(source)).first)
        #expect(HeadingIndex.renderedText(block.summary) == "Real")
    }

    @Test("Ignores summary tags inside a comment before the real summary")
    func summaryInsideComment() throws {
        let source = "<details><!-- <summary>Fake</summary> -->"
            + "<summary>Real</summary>body</details>\n"
        let block = try #require(details(of: augment(source)).first)
        #expect(HeadingIndex.renderedText(block.summary) == "Real")
    }

    @Test("Ignores summary tags inside a fence before the real summary")
    func summaryInsideFence() throws {
        let source = """
        <details>
        ```
        <summary>Fake</summary>
        ```
        <summary>Real</summary>body</details>
        """
        let block = try #require(details(of: augment(source)).first)
        #expect(HeadingIndex.renderedText(block.summary) == "Real")
    }

    @Test("Does not treat tags in comments, code, or quotes as structural")
    func detailsLexicalSafety() throws {
        let source = """
        <details><summary>S</summary>
        <!-- </details> -->
        `</details>`
        </details>
        """
        let ast = augment(source)
        #expect(details(of: ast).count == 1)
    }

    @Test("Resolves document reference definitions inside a details body")
    func detailsReferenceDefinitions() throws {
        let source = """
        [ref]: /url "title"

        <details><summary>S</summary>[foo][ref]</details>
        """
        let ast = augment(source)
        let block = try #require(details(of: ast).first)
        guard case let .paragraph(inlines, _) = block.blocks.first,
              case let .link(destination, title, _, _) = inlines.first else {
            Issue.record("expected a resolved link, got \(block.blocks)")
            return
        }
        #expect(destination == "/url")
        #expect(title == "title")
    }

    @Test("Details inside a blockquote are paired")
    func detailsInBlockQuote() throws {
        let source = "> <details><summary>S</summary>x</details>\n"
        let ast = augment(source)
        guard case let .blockQuote(blocks, _) = ast.blocks.first else {
            Issue.record("expected a blockquote")
            return
        }
        #expect(blocks.contains { block in
            if case .details = block { return true }
            return false
        })
    }

    @Test("Product fixtures exercise all three syntaxes")
    func productFixtures() throws {
        let root = try #require(
            Bundle.module.url(forResource: "Fixtures", withExtension: nil)
        )

        let wiki = try String(
            contentsOf: root.appendingPathComponent("sonovo/wiki-links.md"),
            encoding: .utf8
        )
        let wikiAst = augment(wiki)
        let wikiCount = wikiAst.blocks.reduce(0) { total, block in
            guard case let .paragraph(inlines, _) = block else { return total }
            return total + wikiLinks(in: inlines).count
        }
        #expect(wikiCount == 3)

        let toc = try String(
            contentsOf: root.appendingPathComponent("sonovo/toc.md"),
            encoding: .utf8
        )
        let tocAst = augment(toc)
        #expect(tocAst.blocks.filter { block in
            if case .tableOfContents = block { return true }
            return false
        }.count == 1)

        let detailsSource = try String(
            contentsOf: root.appendingPathComponent("sonovo/details.md"),
            encoding: .utf8
        )
        let detailsAst = augment(detailsSource)
        let topLevel = details(of: detailsAst)
        #expect(topLevel.count == 2)
        let nested = topLevel[1].blocks.contains { block in
            if case .details = block { return true }
            return false
        }
        #expect(nested)
    }
}
