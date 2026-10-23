import Foundation
import Testing
@testable import SonovoCore

@Suite("Base parser")
struct ParserTests {
    @Test("Parses an empty document")
    func emptyDocument() {
        let parsed = MarkdownParser.parse("")
        #expect(parsed.ast.blocks.isEmpty)
        #expect(parsed.ast.frontmatter == nil)
        #expect(parsed.source.isEmpty)
    }

    @Test("Parses GFM tables, task lists, and strikethrough")
    func gfmExtensions() throws {
        let source = """
        | a | b |
        |:--|--:|
        | 1 | 2 |

        - [x] done
        - [ ] todo

        ~~gone~~
        """
        let parsed = MarkdownParser.parseCanonical(source)
        #expect(parsed.ast.blocks.count == 3)

        guard case let .table(table, _) = parsed.ast.blocks[0] else {
            Issue.record("expected a table")
            return
        }
        #expect(table.alignments == [.left, .right])
        #expect(table.header.count == 2)
        #expect(table.rows.count == 1)
        #expect(table.header[0].inlines.count == 1)

        guard case let .list(list, _) = parsed.ast.blocks[1] else {
            Issue.record("expected a list")
            return
        }
        #expect(list.items.count == 2)
        #expect(list.items[0].checked == true)
        #expect(list.items[1].checked == false)
        #expect(list.tight == true)

        guard case let .paragraph(inlines, _) = parsed.ast.blocks[2] else {
            Issue.record("expected a paragraph")
            return
        }
        guard case .strikethrough = inlines.first else {
            Issue.record("expected strikethrough, got \(inlines)")
            return
        }
    }

    @Test("Recovers reference definitions inside containers")
    func referenceDefinitionsInContainers() {
        for source in [
            "> [ref]: /target\n\n> [foo][ref]\n",
            "- [ref]: /target\n\n[foo][ref]\n",
            "  [ref]: /target\n\n[foo][ref]\n",
            "- > [ref]: /target\n\n[foo][ref]\n",
            "> [ref]:\n> /target\n\n[foo][ref]\n"
        ] {
            let parsed = MarkdownParser.parseCanonical(source)
            #expect(
                parsed.ast.referenceDefinitions.count == 1,
                "no definition recovered from \(source.debugDescription)"
            )
            #expect(parsed.ast.referenceDefinitions.first?.label == "ref")
            #expect(parsed.ast.referenceDefinitions.first?.destination == "/target")
        }
    }

    @Test("Normalizes a multiline container label")
    func multilineReferenceLabel() {
        let source = "> [multi\n> line]: /target\n\n[foo][multi line]\n"
        let parsed = MarkdownParser.parseCanonical(source)
        #expect(parsed.ast.referenceDefinitions.first?.label == "multi line")
        #expect(parsed.ast.referenceDefinitions.first?.destination == "/target")
    }

    @Test("Parses GFM extended autolinks")
    func extendedAutolinks() throws {
        let source = "See www.example.com, https://example.com/a?b=c. and foo@bar.example.com\n"
        let parsed = MarkdownParser.parseCanonical(source)
        guard case let .paragraph(inlines, _) = parsed.ast.blocks.first else {
            Issue.record("expected a paragraph")
            return
        }

        let links = inlines.compactMap { inline -> (String, [Inline])? in
            if case let .link(destination, _, children, _) = inline {
                return (destination, children)
            }
            return nil
        }
        #expect(links.map(\.0) == [
            "http://www.example.com",
            "https://example.com/a?b=c",
            "mailto:foo@bar.example.com"
        ])

        let displays = links.compactMap { link -> String? in
            guard case let .text(text, _) = link.1.first else { return nil }
            return text
        }
        #expect(displays == [
            "www.example.com",
            "https://example.com/a?b=c",
            "foo@bar.example.com"
        ])
    }

    @Test("Email autolinks reject invalid endings")
    func emailEndings() {
        let parsed = MarkdownParser.parseCanonical("a@b.c- a@b.c_\n")
        guard case let .paragraph(inlines, _) = parsed.ast.blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        let links = inlines.compactMap { inline -> String? in
            if case let .link(destination, _, _, _) = inline {
                return destination
            }
            return nil
        }
        #expect(links.isEmpty)
    }

    @Test("An entity-like suffix is excluded from a URL")
    func autolinkEntitySuffix() {
        let parsed = MarkdownParser.parseCanonical(
            "www.example.com/search?q=x&hl;\n"
        )
        guard case let .paragraph(inlines, _) = parsed.ast.blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        let links = inlines.compactMap { inline -> String? in
            if case let .link(destination, _, _, _) = inline {
                return destination
            }
            return nil
        }
        #expect(links == ["http://www.example.com/search?q=x"])
    }

    @Test("A leading underscore does not hide a www autolink")
    func underscoreBeforeWWW() {
        let parsed = MarkdownParser.parseCanonical("_www.a.co\n")
        guard case let .paragraph(inlines, _) = parsed.ast.blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        let links = inlines.compactMap { inline -> String? in
            if case let .link(destination, _, _, _) = inline {
                return destination
            }
            return nil
        }
        #expect(links == ["http://www.a.co"])
    }

    @Test("Punctuation after an entity suffix is still trimmed")
    func entitySuffixWithPunctuation() {
        let parsed = MarkdownParser.parseCanonical(
            "www.a.co/?x&hl;!\n"
        )
        guard case let .paragraph(inlines, _) = parsed.ast.blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        let links = inlines.compactMap { inline -> String? in
            if case let .link(destination, _, _, _) = inline {
                return destination
            }
            return nil
        }
        #expect(links == ["http://www.a.co/?x"])
    }

    @Test("A definition-shaped line inside a paragraph is not recovered")
    func paragraphReferenceNotRecovered() {
        let parsed = MarkdownParser.parseCanonical(
            "text\n[ref]: /target\n"
        )
        #expect(parsed.ast.referenceDefinitions.isEmpty)
    }

    @Test("A top-level label may contain a continuation >")
    func labelWithGreaterThan() {
        let parsed = MarkdownParser.parseCanonical(
            "[multi\n    >name]: /target\n"
        )
        #expect(
            parsed.ast.referenceDefinitions.first?.label == "multi >name"
        )
    }

    @Test("Does not nest an autolink inside an existing link")
    func noNestedAutolinks() throws {
        let source = "[www.example.com](https://example.com)\n"
        let parsed = MarkdownParser.parseCanonical(source)
        guard case let .paragraph(inlines, _) = parsed.ast.blocks.first,
              case let .link(destination, _, children, _) = inlines.first else {
            Issue.record("expected one link")
            return
        }
        #expect(destination == "https://example.com")
        #expect(children.count == 1)
        if case .text = children[0] {
        } else {
            Issue.record("expected plain text inside the link")
        }
    }

    @Test("Preserves YAML frontmatter verbatim and rebases body ranges")
    func frontmatter() throws {
        let source = "---\ntitle: Episode One\nunknown-key: kept\n---\n\n# Heading\n\nBody.\n"
        let parsed = MarkdownParser.parse(source)

        let frontmatter = try #require(parsed.ast.frontmatter)
        #expect(frontmatter.raw == "---\ntitle: Episode One\nunknown-key: kept\n---")
        #expect(frontmatter.body.contains("unknown-key: kept"))
        #expect(frontmatter.range.lowerBound == 0)

        guard case let .heading(level, _, range) = parsed.ast.blocks.first else {
            Issue.record("expected a heading")
            return
        }
        #expect(level == 1)
        #expect(range?.start.line == 6)
        #expect(parsed.bodyStartOffset == frontmatter.range.upperBound + 1)
    }

    @Test("Leaves an unclosed frontmatter fence as ordinary Markdown")
    func unclosedFrontmatter() {
        let source = "---\ntitle: x\n\n# Heading\n"
        let parsed = MarkdownParser.parseCanonical(source)
        #expect(parsed.ast.frontmatter == nil)
        #expect(parsed.ast.blocks.count >= 2)
    }

    @Test("Custom syntax stays literal without the augmenter")
    func customSyntaxStaysLiteral() throws {
        let source = """
        # T

        [TOC]

        See [[Page|alias]].

        <details><summary>S</summary>

        Body.
        </details>
        """
        let parsed = MarkdownParser.parseCanonical(source)
        #expect(!parsed.ast.blocks.isEmpty)
        #expect(parsed.ast.blocks.contains { block in
            if case .tableOfContents = block { return true }
            return false
        } == false)
    }

    @Test("CJK and emoji ranges stay in UTF-16 units")
    func cjkRanges() throws {
        let source = "# 标题 🎬\n\n中文 **粗体** 结束\n"
        let parsed = MarkdownParser.parseCanonical(source)
        guard case let .heading(_, inlines, headingRange) = parsed.ast.blocks.first else {
            Issue.record("expected a heading")
            return
        }
        #expect(headingRange?.lowerBound == 0)
        #expect(headingRange?.upperBound == 7)

        guard case let .text(text, textRange) = inlines.first else {
            Issue.record("expected text")
            return
        }
        #expect(text == "标题 🎬")
        #expect(textRange?.lowerBound == 2)
        #expect(textRange?.upperBound == 7)
    }

    @Test("Parses a pathological nesting depth without crashing")
    func pathologicalNesting() {
        let source = String(repeating: "> ", count: 2_000) + "deep\n"
        let parsed = MarkdownParser.parseCanonical(source)
        #expect(!parsed.ast.blocks.isEmpty)
    }

    @Test("Mixed container nesting reaches the guard")
    func mixedContainerNesting() {
        let sources = [
            String(repeating: ">  ", count: 200) + "deep\n",
            String(repeating: "> - ", count: 200) + "deep\n",
            String(repeating: "1. ", count: 200) + "deep\n"
        ]
        for source in sources {
            let parsed = MarkdownParser.parseCanonical(source)
            #expect(
                parsed.exceededNestingLimit,
                "guard missed \(source.prefix(24))"
            )
            #expect(!parsed.ast.blocks.isEmpty)
        }
    }

    @Test("Nesting guard ignores literal fenced and HTML content")
    func nestingGuardLiterals() {
        let quotedFence = "> ```\n"
            + String(repeating: "> ", count: 130)
            + "\n> ```\n"
        #expect(!NestingGuard.exceedsLimit(quotedFence, limit: 100))

        let htmlBlock = "<pre>\n"
            + String(repeating: "> ", count: 130)
            + "\n</pre>\n"
        #expect(!NestingGuard.exceedsLimit(htmlBlock, limit: 100))

        let declaration = "<!DOCTYPE\n"
            + String(repeating: "> ", count: 130)
            + ">\n"
        #expect(!NestingGuard.exceedsLimit(declaration, limit: 100))

        let quotedHTML = "> <pre>\n"
            + String(repeating: "> ", count: 130)
            + "\n> </pre>\n"
        #expect(!NestingGuard.exceedsLimit(quotedHTML, limit: 100))

        let attack = String(repeating: "> ", count: 130) + "x"
        #expect(NestingGuard.exceedsLimit(attack, limit: 100))
    }

    @Test("A whitespace-only line ends a reference label")
    func referenceLabelWhitespaceLine() {
        let source = "[unclosed\n   \n[ref]: /target\n\n[ref]\n"
        let parsed = MarkdownParser.parseCanonical(source)
        #expect(parsed.ast.referenceDefinitions.contains {
            $0.label == "ref" && $0.destination == "/target"
        })
    }

    @Test("Scheme autolinks require a non-empty authority")
    func autolinkAuthority() {
        let parsed = MarkdownParser.parseCanonical(
            "https://?a and https://example.com\n",
            enableAutolinks: true
        )
        guard case let .paragraph(inlines, _) = parsed.ast.blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        let links = inlines.compactMap { inline -> String? in
            if case let .link(destination, _, _, _) = inline {
                return destination
            }
            return nil
        }
        #expect(links == ["https://example.com"])
    }

    @Test("HTML suppression requires a tag boundary and case-insensitive close")
    func nestingGuardHTMLBoundary() {
        let deep = String(repeating: "> ", count: 130) + "deep\n"
        // `<scripture>` is not `<script>`; as a standalone tag it is a type-7
        // HTML block only until the blank line.
        #expect(NestingGuard.exceedsLimit("<scripture>\n\n" + deep, limit: 100))
        // A raw script block ends at `</SCRIPT>`.
        #expect(
            !NestingGuard.exceedsLimit(
                "<script>\n" + deep + "</SCRIPT>\n",
                limit: 100
            )
        )
    }

    @Test("A container-scoped fence ends with its container")
    func nestingGuardFenceScope() {
        let source = "> ```\n> code\n\n"
            + String(repeating: "> ", count: 130) + "deep\n"
        #expect(NestingGuard.exceedsLimit(source, limit: 100))

        // A top-level fence absorbs an indented unquoted line.
        let topLevel = "  ```\n"
            + String(repeating: "> ", count: 130) + "\n  ```\n"
        #expect(!NestingGuard.exceedsLimit(topLevel, limit: 100))
    }

    @Test("Single-label and port authorities follow the GFM rules")
    func autolinkAuthorityEdges() {
        let parsed = MarkdownParser.parseCanonical(
            "http://a www.example.com:8080/x http://foo_bar"
        )
        var destinations: [String] = []
        func collect(_ inlines: [Inline]) {
            for inline in inlines {
                switch inline {
                case let .link(destination, _, children, _):
                    destinations.append(destination)
                    collect(children)
                case let .emphasis(children, _), let .strong(children, _),
                     let .strikethrough(children, _):
                    collect(children)
                default:
                    break
                }
            }
        }
        for block in parsed.ast.blocks {
            if case let .paragraph(inlines, _) = block {
                collect(inlines)
            }
        }
        #expect(destinations.contains("http://a"))
        #expect(destinations.contains("http://www.example.com:8080/x"))
        #expect(!destinations.contains("http://foo_bar"))
    }

    @Test("Parses the large product fixture")
    func largeFixture() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "large-script",
                withExtension: "md",
                subdirectory: "Fixtures/sonovo"
            )
        )
        let source = try String(contentsOf: url, encoding: .utf8)
        let parsed = MarkdownParser.parseCanonical(source)
        #expect(parsed.ast.blocks.count == 1_001)
        #expect(parsed.ast.blocks.first?.range != nil)
    }

    @Test("A source over the line budget is kept as one raw block")
    func sourceLineBudget() {
        let source = String(
            repeating: "a\n",
            count: MarkdownLimits.maxSourceLines + 1
        )
        let parsed = MarkdownParser.parseCanonical(source)
        #expect(parsed.exceededNestingLimit)
        #expect(parsed.ast.blocks.count == 1)
        // The line table is the allocation the budget exists to avoid; an
        // over-budget source must not build one.
        #expect(!parsed.fullSourceMap.isIndexed)
        #expect(parsed.fullSourceMap.position(atUTF16Offset: 0) == nil)
    }

    @Test("Deep inline nesting is kept as one raw block")
    func inlineDepthBudget() {
        let source = String(
            repeating: "[",
            count: MarkdownLimits.maxParseDepth + 1
        ) + "x" + String(
            repeating: "]",
            count: MarkdownLimits.maxParseDepth + 1
        )
        let parsed = MarkdownParser.parseCanonical(source)
        #expect(parsed.exceededNestingLimit)
        #expect(parsed.ast.blocks.count == 1)
    }

    @Test("Fenced code does not count as inline nesting")
    func fencedCodeDoesNotTripTheInlineGuard() {
        let source = "# Title\n\n```\n"
            + String(repeating: "*", count: MarkdownLimits.maxParseDepth + 1)
            + "\n```\n"
        let parsed = MarkdownParser.parseCanonical(source)
        #expect(!parsed.exceededNestingLimit)
        #expect(parsed.ast.blocks.count == 2)
    }

    @Test("Short delimiter runs cannot nest past the guard")
    func shortDelimiterNestingBudget() {
        let source = String(repeating: "*a _a ", count: 200)
            + "x"
            + String(repeating: " a_ a*", count: 200)
        let parsed = MarkdownParser.parseCanonical(source)
        #expect(parsed.exceededNestingLimit)
    }

    @Test("A document with too many inline delimiters is kept raw")
    func inlineDelimiterBudget() {
        let source = String(
            repeating: "*a*",
            count: (MarkdownLimits.maxInlineDelimiters / 2) + 1
        )
        let parsed = MarkdownParser.parseCanonical(source)
        #expect(parsed.exceededNestingLimit)
    }

    @Test("A very long emphasis delimiter run is kept as one raw block")
    func emphasisRunBudget() {
        let source = String(
            repeating: "*",
            count: MarkdownLimits.maxParseDepth + 1
        ) + "x" + String(
            repeating: "*",
            count: MarkdownLimits.maxParseDepth + 1
        )
        let parsed = MarkdownParser.parseCanonical(source)
        #expect(parsed.exceededNestingLimit)
    }
}
