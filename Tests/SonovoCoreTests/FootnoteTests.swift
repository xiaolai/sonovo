import Foundation
import Testing
@testable import SonovoCore

@Suite("Footnotes")
struct FootnoteTests {
    private func augment(_ source: String) -> (
        SonovoAST,
        ParsedMarkdown
    ) {
        let parsed = MarkdownParser.parseCanonical(source)
        return (MarkdownSyntaxAugmenter().augment(parsed), parsed)
    }

    private func references(in ast: SonovoAST) -> [FootnoteReference] {
        var result: [FootnoteReference] = []
        func walk(_ inlines: [Inline]) {
            for inline in inlines {
                switch inline {
                case let .footnoteReference(reference, _):
                    result.append(reference)
                case let .emphasis(children, _),
                     let .strong(children, _),
                     let .strikethrough(children, _):
                    walk(children)
                case let .link(_, _, children, _):
                    walk(children)
                case let .image(_, _, description, _):
                    walk(description)
                default:
                    break
                }
            }
        }
        func walk(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case let .paragraph(inlines, _),
                     let .heading(_, inlines, _):
                    walk(inlines)
                case let .blockQuote(children, _):
                    walk(children)
                case let .list(list, _):
                    for item in list.items { walk(item.blocks) }
                case let .table(table, _):
                    table.header.forEach { walk($0.inlines) }
                    table.rows.forEach { row in
                        row.forEach { walk($0.inlines) }
                    }
                case let .details(details, _):
                    walk(details.summary)
                    walk(details.blocks)
                case let .footnotes(section, _):
                    section.entries.forEach { walk($0.inlines) }
                default:
                    break
                }
            }
        }
        walk(ast.blocks)
        return result
    }

    private func section(in ast: SonovoAST) -> FootnoteSection? {
        for block in ast.blocks {
            if case let .footnotes(section, _) = block { return section }
        }
        return nil
    }

    private func text(in inlines: [Inline]) -> String {
        var result = ""
        for inline in inlines {
            switch inline {
            case let .text(value, _): result += value
            case let .inlineCode(value, _): result += value
            case let .emphasis(children, _),
                 let .strong(children, _),
                 let .strikethrough(children, _):
                result += text(in: children)
            case let .link(_, _, children, _): result += text(in: children)
            case let .image(_, _, description, _):
                result += text(in: description)
            case let .wikiLink(link, _): result += link.display
            case let .footnoteReference(reference, _):
                result += "\(reference.number)"
            case let .math(source, _, _, _):
                result += source
            case .softBreak: result += " "
            case .lineBreak: result += "\n"
            case .inlineHTML: continue
            }
        }
        return result
    }

    // MARK: - Resolution

    @Test("Numbers a reference and appends the section")
    func basic() throws {
        let source = "See[^a] and stop.\n\n[^a]: Note text.\n"
        let (ast, parsed) = augment(source)
        let found = references(in: ast)
        #expect(found == [FootnoteReference(label: "a", number: 1)])
        let section = try #require(section(in: ast))
        #expect(section.entries.count == 1)
        let entry = try #require(section.entries.first)
        #expect(entry.number == 1)
        #expect(entry.label == "a")
        #expect(text(in: entry.inlines) == "Note text.")
        #expect(entry.referenceRanges.count == 1)
        let referenceRange = try #require(entry.referenceRanges.first)
        #expect(
            parsed.source.utf16Range(referenceRange) == "[^a]"
        )
        #expect(
            parsed.source.utf16Range(entry.contentRange) == "Note text."
        )
        #expect(ast.blocks.contains { block in
            if case .footnoteDefinition("a", _) = block { return true }
            return false
        })
    }

    @Test("Numbers by first reference, not by definition order")
    func numberingByFirstReference() throws {
        let source = """
        First[^second], then[^first].

        [^first]: One.
        [^second]: Two.
        """
        let (ast, _) = augment(source)
        #expect(references(in: ast) == [
            FootnoteReference(label: "second", number: 1),
            FootnoteReference(label: "first", number: 2)
        ])
        let section = try #require(section(in: ast))
        #expect(section.entries.map(\.number) == [1, 2])
        #expect(section.entries.map(\.label) == ["second", "first"])
        #expect(section.entries.map { text(in: $0.inlines) } == ["Two.", "One."])
    }

    @Test("Repeated references share a number and each keeps a back-link")
    func repeatedReference() throws {
        let source = "A[^a] B[^a].\n\n[^a]: Note.\n"
        let (ast, _) = augment(source)
        #expect(references(in: ast) == [
            FootnoteReference(label: "a", number: 1),
            FootnoteReference(label: "a", number: 1)
        ])
        let section = try #require(section(in: ast))
        #expect(section.entries.first?.referenceRanges.count == 2)
    }

    // MARK: - Literal fallbacks

    @Test("An undefined reference stays literal")
    func undefinedReference() throws {
        let (ast, _) = augment("See[^missing].\n")
        #expect(references(in: ast).isEmpty)
        #expect(section(in: ast) == nil)
        guard case let .paragraph(inlines, _) = ast.blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(text(in: inlines) == "See[^missing].")
    }

    @Test("A duplicate definition and its references stay literal")
    func duplicateDefinition() throws {
        let source = "See[^a].\n\n[^a]: One.\n\n[^a]: Two.\n"
        let (ast, _) = augment(source)
        #expect(references(in: ast).isEmpty)
        #expect(section(in: ast) == nil)
        #expect(ast.blocks.allSatisfy { block in
            if case .footnoteDefinition = block { return false }
            return true
        })
    }

    @Test("An unreferenced definition stays literal")
    func unreferencedDefinition() throws {
        let source = "Text.\n\n[^a]: Unused.\n"
        let (ast, _) = augment(source)
        #expect(section(in: ast) == nil)
        guard case let .paragraph(inlines, range) = ast.blocks.last else {
            Issue.record("expected a definition paragraph")
            return
        }
        #expect(range != nil)
        #expect(text(in: inlines) == "[^a]: Unused.")
        #expect(ast.blocks.contains { block in
            if case .footnoteDefinition = block { return true }
            return false
        } == false)
    }

    @Test("A duplicate definition's source stays visible")
    func duplicateDefinitionStaysVisible() throws {
        let source = "See[^a].\n\n[^a]: One.\n\n[^a]: Two.\n"
        let (ast, _) = augment(source)
        let visible = ast.blocks.compactMap { block -> String? in
            guard case let .paragraph(inlines, _) = block else { return nil }
            return text(in: inlines)
        }
        #expect(visible.contains("[^a]: One."))
        #expect(visible.contains("[^a]: Two."))
    }

    @Test("Labels are case-folded and whitespace-normalized")
    func labelNormalization() throws {
        let source = "See[^A  B].\n\n[^a b]: Note.\n"
        let (ast, _) = augment(source)
        #expect(references(in: ast) == [
            FootnoteReference(label: "a b", number: 1)
        ])
        #expect(section(in: ast)?.entries.count == 1)
    }

    // MARK: - Exclusions

    @Test("Frontmatter and code block definitions are not footnotes")
    func definitionExclusions() throws {
        let frontmatter = "---\ntitle: x\n[^a]: hidden\n---\n\nSee[^a].\n"
        let (frontmatterAST, _) = augment(frontmatter)
        #expect(references(in: frontmatterAST).isEmpty)
        #expect(section(in: frontmatterAST) == nil)

        let fenced = "```\n[^a]: hidden\n```\n\nSee[^a].\n"
        let (fencedAST, _) = augment(fenced)
        #expect(references(in: fencedAST).isEmpty)
        #expect(section(in: fencedAST) == nil)
    }

    @Test("Code, escapes, and link destinations are not references")
    func exclusions() throws {
        let source = """
        Code `[^a]`, escaped \\[^a], and a [link](https://example.com/[^a]).

        [^a]: Note.
        """
        let (ast, _) = augment(source)
        #expect(references(in: ast).isEmpty)
        #expect(section(in: ast) == nil)
    }

    @Test("References in nested blocks are found in document order")
    func nestedBlocks() throws {
        let source = """
        > Quote[^one]

        - item[^two]

        [^one]: One.
        [^two]: Two.
        """
        let (ast, _) = augment(source)
        #expect(references(in: ast) == [
            FootnoteReference(label: "one", number: 1),
            FootnoteReference(label: "two", number: 2)
        ])
    }

    // MARK: - Content

    @Test("GitHub's documented footnote example renders both notes")
    func gitHubExample() throws {
        let source = """
        Here is a simple footnote[^1].

        A footnote can also have multiple lines[^2].

        [^1]: My reference.
        [^2]: To add line breaks within a footnote, add 2 spaces to the end of a line.  
        This is a second line.
        """
        let (ast, _) = augment(source)
        #expect(references(in: ast) == [
            FootnoteReference(label: "1", number: 1),
            FootnoteReference(label: "2", number: 2)
        ])
        let section = try #require(section(in: ast))
        #expect(section.entries.map { text(in: $0.inlines) } == [
            "My reference.",
            "To add line breaks within a footnote, add 2 spaces to the "
                + "end of a line.\nThis is a second line."
        ])
    }

    @Test("The GFM regression fixture augments as footnotes")
    func gfmRegressionFixture() throws {
        let root = try #require(
            Bundle.module.url(forResource: "Fixtures", withExtension: nil)
        )
        let fixture = try String(
            contentsOf: root.appendingPathComponent(
                "gfmreg/regression.txt"
            ),
            encoding: .utf8
        )
        let lines = fixture.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        let marker = try #require(
            lines.firstIndex { $0.contains("example table footnotes") },
            "the GFM regression fixture lost its footnote example"
        )
        var markdown: [String] = []
        var cursor = marker + 1
        while cursor < lines.count, lines[cursor] != "." {
            markdown.append(lines[cursor])
            cursor += 1
        }
        #expect(cursor < lines.count, "the example has no terminator")
        let source = markdown.joined(separator: "\n") + "\n"
        #expect(source.contains("[^1]: a footnote"))

        let (ast, _) = augment(source)
        #expect(references(in: ast) == [
            FootnoteReference(label: "1", number: 1),
            FootnoteReference(label: "1", number: 1)
        ])
        let section = try #require(section(in: ast))
        #expect(
            section.entries.map { text(in: $0.inlines) } == ["a footnote"]
        )
    }

    @Test("A multi-line definition keeps its line break")
    func multiLineContent() throws {
        let source = "See[^a].\n\n[^a]: First line  \nsecond line\n"
        let (ast, _) = augment(source)
        let section = try #require(section(in: ast))
        let entry = try #require(section.entries.first)
        #expect(text(in: entry.inlines) == "First line\nsecond line")
    }

    @Test("An empty definition renders an empty entry")
    func emptyDefinition() throws {
        let source = "See[^a].\n\n[^a]:\n"
        let (ast, _) = augment(source)
        let section = try #require(section(in: ast))
        let entry = try #require(section.entries.first)
        #expect(entry.inlines.isEmpty)
    }

    // MARK: - Restoring swallowed definitions

    private func detailsParagraphs(
        _ ast: SonovoAST
    ) -> (details: DetailsBlock?, paragraphs: [String]) {
        guard case let .details(details, _) = ast.blocks.first else {
            return (nil, [])
        }
        return (
            details,
            details.blocks.compactMap { block -> String? in
                guard case let .paragraph(inlines, _) = block else {
                    return nil
                }
                return text(in: inlines)
            }
        )
    }

    @Test("A definition the base parser swallowed inside details is restored")
    func swallowedDefinitionInsideDetails() throws {
        // `Note.` is a valid link destination, so the base parser consumes
        // the line as a reference definition and no paragraph survives. The
        // container's own range still covers the line; treating that range as
        // visible made the definition vanish entirely.
        let source = """
        <details>
        <summary>More</summary>

        [^a]: Note.

        </details>
        """
        let (ast, _) = augment(source)
        let (details, paragraphs) = detailsParagraphs(ast)
        #expect(details != nil)
        #expect(paragraphs == ["[^a]: Note."])
        #expect(ast.blocks.count == 1)
    }

    @Test("A visible definition inside details is not duplicated outside")
    func visibleDefinitionInsideDetails() throws {
        // A multiword definition is not a valid link destination, so it
        // survives as a paragraph in the details body. The recursive
        // coverage check must see it and leave the tree alone.
        let source = """
        <details>
        <summary>More</summary>

        [^a]: Note text.

        </details>
        """
        let (ast, _) = augment(source)
        let (details, paragraphs) = detailsParagraphs(ast)
        #expect(details != nil)
        #expect(paragraphs == ["[^a]: Note text."])
        #expect(ast.blocks.count == 1)
    }
}
