import Foundation
import Testing
@testable import SonovoCore

@Suite("Definition lists")
struct DefinitionListTests {
    private func ast(_ source: String) -> SonovoAST {
        let parsed = MarkdownParser.parseCanonical(source)
        return MarkdownSyntaxAugmenter().augment(parsed)
    }

    private func list(_ source: String) throws -> DefinitionList {
        let ast = ast(source)
        guard case let .definitionList(list, _) = ast.blocks.first else {
            Issue.record("expected a definition list, got \(ast.blocks)")
            throw TestFailure()
        }
        return list
    }

    private struct TestFailure: Error {}

    private func text(_ inlines: [Inline]) -> String {
        HeadingIndex.renderedText(inlines, includingMath: false)
    }

    @Test("A term followed by a definition becomes one item")
    func simpleList() throws {
        let source = "Term\n: Definition\n"
        let list = try list(source)
        #expect(list.items.count == 1)
        #expect(list.items[0].terms.count == 1)
        #expect(list.items[0].definitions.count == 1)
        #expect(text(list.items[0].terms[0].inlines) == "Term")
        #expect(text(list.items[0].definitions[0].inlines) == "Definition")
    }

    @Test("Term and definition ranges map to their authored bytes")
    func exactRanges() throws {
        let source = "Term\n: Definition\n"
        let list = try list(source)
        let term = list.items[0].terms[0]
        let definition = list.items[0].definitions[0]
        #expect(
            (source as NSString).substring(
                with: NSRange(
                    location: term.range.lowerBound,
                    length: term.range.length
                )
            ) == "Term"
        )
        #expect(
            (source as NSString).substring(
                with: NSRange(
                    location: definition.range.lowerBound,
                    length: definition.range.length
                )
            ) == "Definition"
        )
        #expect(term.range.upperBound <= definition.range.lowerBound)
    }

    @Test("Multiple definitions and multiple terms group correctly")
    func grouping() throws {
        let source = "Alpha\nBeta\n: One\n: Two\n"
        let list = try list(source)
        #expect(list.items.count == 1)
        #expect(list.items[0].terms.map { text($0.inlines) } == ["Alpha", "Beta"])
        #expect(
            list.items[0].definitions.map { text($0.inlines) }
                == ["One", "Two"]
        )
    }

    @Test("Consecutive items without blank lines stay separate")
    func multipleItems() throws {
        let source = "A\n: a\nB\n: b\n"
        let list = try list(source)
        #expect(list.items.count == 2)
        #expect(text(list.items[0].terms[0].inlines) == "A")
        #expect(text(list.items[1].terms[0].inlines) == "B")
    }

    @Test("Inline Markdown inside a term or definition is parsed")
    func inlineMarkdown() throws {
        let source = "**Bold** and `code`\n: A [link](https://example.com)\n"
        let list = try list(source)
        let term = list.items[0].terms[0].inlines
        #expect(term.contains { if case .strong = $0 { return true }; return false })
        #expect(term.contains { if case .inlineCode = $0 { return true }; return false })
        let definition = list.items[0].definitions[0].inlines
        #expect(definition.contains { if case .link = $0 { return true }; return false })
    }

    @Test("Wiki links and math inside the list still augment")
    func customInlineSyntax() throws {
        let source = "[[Term]] $x^2$\n: See [[Other]] and $y$\n"
        let list = try list(source)
        #expect(
            list.items[0].terms[0].inlines.contains {
                if case .wikiLink = $0 { return true }
                return false
            }
        )
        #expect(
            list.items[0].terms[0].inlines.contains {
                if case .math = $0 { return true }
                return false
            }
        )
        #expect(
            list.items[0].definitions[0].inlines.contains {
                if case .wikiLink = $0 { return true }
                return false
            }
        )
    }

    @Test("Malformed shapes fall back to an ordinary paragraph")
    func literalFallback() {
        let sources = [
            "Term\nnot a definition\n",
            ": orphan definition\n",
            "Term\n:\n",
            "Term\n: one\nTerm\n",
            "Term\n: one\nnot a definition\n"
        ]
        for source in sources {
            let ast = ast(source)
            #expect(
                !ast.blocks.contains {
                    if case .definitionList = $0 { return true }
                    return false
                },
                "\(source.debugDescription)"
            )
        }
    }

    @Test("A single term line is not a definition list")
    func singleLineIsNotAList() {
        let ast = ast("Term\n")
        #expect(ast.blocks.count == 1)
        guard case .paragraph = ast.blocks[0] else {
            Issue.record("expected a paragraph")
            return
        }
    }

    @Test("The source is never rewritten")
    func sourceIsUntouched() throws {
        let source = "Term\n: Definition\n"
        let parsed = MarkdownParser.parseCanonical(source)
        let augmented = MarkdownSyntaxAugmenter().augment(parsed)
        #expect(augmented.blocks.count == 1)
        // The block's bytes are the original paragraph, marker included.
        let range = try #require(augmented.blocks[0].range)
        #expect(
            (source as NSString).substring(
                with: NSRange(location: range.lowerBound, length: range.length)
            ) == source.trimmingCharacters(in: .newlines)
        )
    }

    @Test("A definition list inside a block quote augments in place")
    func nestedInBlockQuote() throws {
        let source = "> Term\n> : Definition\n"
        let ast = ast(source)
        guard case let .blockQuote(children, _) = ast.blocks.first,
              case let .definitionList(list, _) = children.first else {
            Issue.record("expected a nested definition list, got \(ast.blocks)")
            return
        }
        #expect(list.items.count == 1)
        #expect(text(list.items[0].definitions[0].inlines) == "Definition")
    }

    @Test("Rendered search sees term and definition text")
    func renderedSearch() throws {
        let source = "Term\n: Definition\n"
        let blocks = MarkdownRenderedSearch.blocks(ast(source))
        #expect(blocks.count == 1)
        #expect(blocks[0].contains("Term"))
        #expect(blocks[0].contains("Definition"))
    }

    @Test("Reading anchors name the definition list kind")
    func readingKind() throws {
        let ast = ast("Term\n: Definition\n")
        #expect(ReadingBlockKind(ast.blocks[0]) == .definitionList)
    }
}
