import Foundation
import Testing
@testable import SonovoCore

@Suite("Math")
struct MathTests {
    private func augment(_ source: String) -> SonovoAST {
        MarkdownSyntaxAugmenter().augment(MarkdownParser.parseCanonical(source))
    }

    private func inlines(of ast: SonovoAST) throws -> [Inline] {
        guard case let .paragraph(inlines, _) = ast.blocks.prefix(1).first else {
            Issue.record("expected a paragraph, got \(ast.blocks)")
            return []
        }
        return inlines
    }

    private func math(_ inline: Inline) -> (String, String, Bool)? {
        if case let .math(source, raw, display, _) = inline {
            return (source, raw, display)
        }
        return nil
    }

    private func paragraphMath(_ source: String) throws -> (String, String, Bool) {
        let ast = augment(source)
        let inlines = try inlines(of: ast)
        guard inlines.count == 1, let match = math(inlines[0]) else {
            Issue.record("expected one math inline, got \(inlines)")
            return ("", "", false)
        }
        return match
    }

    // MARK: - Inline

    @Test("Inline math becomes one node with the TeX source and its raw slice")
    func inlineMath() throws {
        let match = try paragraphMath("$E = mc^2$\n")
        #expect(match.0 == "E = mc^2")
        #expect(match.1 == "$E = mc^2$")
        #expect(match.2 == false)
    }

    @Test("Text around inline math is preserved")
    func inlineMathSplitsText() throws {
        let ast = augment("before $x$ after\n")
        let inlines = try inlines(of: ast)
        #expect(inlines.count == 3)
        guard case let .text(before, _) = inlines[0],
              case let .text(after, _) = inlines[2] else {
            Issue.record("expected text around the formula, got \(inlines)")
            return
        }
        #expect(before == "before ")
        #expect(after == " after")
        #expect(math(inlines[1])?.0 == "x")
    }

    @Test("Several inline formulas in one paragraph")
    func multipleInlineFormulas() throws {
        let ast = augment("$a$ and $b$\n")
        let inlines = try inlines(of: ast)
        let formulas = inlines.compactMap { math($0)?.0 }
        #expect(formulas == ["a", "b"])
    }

    @Test("Escaped dollars stay literal")
    func escapedDollars() throws {
        let ast = augment("Price \\$5 and \\$10\n")
        let inlines = try inlines(of: ast)
        #expect(inlines.allSatisfy { math($0) == nil })
        #expect(inlines.contains { inline in
            if case let .text(value, _) = inline { return value.contains("$5") }
            return false
        })
    }

    @Test("An escaped closer does not end math")
    func escapedCloser() throws {
        let match = try paragraphMath("$a \\$ b$\n")
        #expect(match.0 == "a \\$ b")
    }

    @Test("Currency and a digit after the closer are not math")
    func currencyHeuristics() throws {
        for source in ["$5 and $10\n", "$x$2\n", "US$5\n"] {
            let ast = augment(source)
            let inlines = try inlines(of: ast)
            #expect(
                inlines.allSatisfy { math($0) == nil },
                "unexpected math in \(source)"
            )
        }
    }

    @Test("Whitespace just inside the delimiters is not math")
    func whitespaceEdges() throws {
        for source in ["$ x$\n", "$x $\n", "$ $", "$$\n"] {
            let ast = augment(source)
            let inlines = try inlines(of: ast)
            #expect(
                inlines.allSatisfy { math($0) == nil },
                "unexpected math in \(source)"
            )
        }
    }

    @Test("Unclosed math stays literal")
    func unclosed() throws {
        let ast = augment("$x and more\n")
        let inlines = try inlines(of: ast)
        #expect(inlines.allSatisfy { math($0) == nil })
    }

    @Test("A formula may contain braces and a command")
    func bracesAndCommands() throws {
        let match = try paragraphMath("$\\frac{a}{b}$\n")
        #expect(match.0 == "\\frac{a}{b}")
        #expect(match.2 == false)
    }

    // MARK: - Display

    @Test("A paragraph that is only a display formula becomes display math")
    func displaySoleParagraph() throws {
        let ast = augment("$$\n\\frac{a}{b}\n$$\n")
        let inlines = try inlines(of: ast)
        guard let match = MarkdownInlineMath.soleDisplay(in: inlines) else {
            Issue.record("expected display math, got \(inlines)")
            return
        }
        #expect(match.source.trimmingCharacters(in: .whitespacesAndNewlines) == "\\frac{a}{b}")
        #expect(match.raw.hasPrefix("$$"))
    }

    @Test("Display math accepts surrounding whitespace")
    func displayTrailingWhitespace() throws {
        let ast = augment("$$x$$\n\n")
        let inlines = try inlines(of: ast)
        guard let match = MarkdownInlineMath.soleDisplay(in: inlines) else {
            Issue.record("expected display math, got \(inlines)")
            return
        }
        #expect(match.source == "x")
    }

    @Test("Display delimiters in the middle of a paragraph stay literal")
    func displayMidParagraph() throws {
        let ast = augment("before $$x$$ after\n")
        let inlines = try inlines(of: ast)
        #expect(inlines.allSatisfy { math($0) == nil })
        let text = inlines.compactMap { inline -> String? in
            if case let .text(value, _) = inline { return value }
            return nil
        }.joined()
        #expect(text.contains("$$x$$"))
    }

    @Test("Two display formulas in one paragraph stay literal")
    func twoDisplayFormulas() throws {
        let ast = augment("$$a$$\n\n$$b$$\n")
        // Two paragraphs, each sole content: both are display math.
        #expect(ast.blocks.count == 2)
        for block in ast.blocks {
            guard case let .paragraph(inlines, _) = block else {
                Issue.record("expected paragraphs")
                return
            }
            #expect(MarkdownInlineMath.soleDisplay(in: inlines) != nil)
        }
    }

    @Test("An unmatched display opener stays literal")
    func unmatchedDisplay() throws {
        let ast = augment("$$x\n")
        let inlines = try inlines(of: ast)
        #expect(inlines.allSatisfy { math($0) == nil })
    }

    // MARK: - Context rules

    @Test("Inline code and fenced code are not scanned")
    func codeExcluded() throws {
        let ast = augment("`$x$`\n\n```\n$y$\n```\n")
        guard case let .paragraph(inlines, _) = ast.blocks[0] else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(inlines.allSatisfy { math($0) == nil })
        guard case let .codeBlock(code, _) = ast.blocks[1] else {
            Issue.record("expected a code block")
            return
        }
        #expect(code.code.contains("$y$"))
    }

    @Test("Link labels are excluded from math")
    func linkExcluded() throws {
        let ast = augment("[$x$](https://example.com)\n")
        let inlines = try inlines(of: ast)
        #expect(inlines.count == 1)
        guard case let .link(_, _, children, _) = inlines[0] else {
            Issue.record("expected a link, got \(inlines)")
            return
        }
        #expect(children.allSatisfy { math($0) == nil })
    }

    @Test("Math inside emphasis keeps the authored style")
    func emphasisPreserved() throws {
        let ast = augment("**$x$**\n")
        let inlines = try inlines(of: ast)
        guard case let .strong(children, _) = inlines.first else {
            Issue.record("expected strong, got \(inlines)")
            return
        }
        #expect(children.contains { math($0)?.0 == "x" })
    }

    @Test("Math in headings, tables, and details is recognized")
    func blockContainers() throws {
        let heading = augment("# Speed $v$\n")
        guard case let .heading(_, headingInlines, _) = heading.blocks.first else {
            Issue.record("expected a heading")
            return
        }
        #expect(headingInlines.contains { math($0)?.0 == "v" })

        let table = augment("| $a$ |\n| --- |\n| $b$ |\n")
        guard case let .table(block, _) = table.blocks.first else {
            Issue.record("expected a table")
            return
        }
        #expect(block.header[0].inlines.contains { math($0)?.0 == "a" })
        #expect(block.rows[0][0].inlines.contains { math($0)?.0 == "b" })

        let details = augment("<details><summary>See $s$</summary>\n\nBody $t$\n\n</details>\n")
        guard case let .details(detailsBlock, _) = details.blocks.first else {
            Issue.record("expected details")
            return
        }
        #expect(detailsBlock.summary.contains { math($0)?.0 == "s" })
        let body = detailsBlock.blocks.compactMap { block -> [Inline]? in
            if case let .paragraph(inlines, _) = block { return inlines }
            return nil
        }.flatMap { $0 }
        #expect(body.contains { math($0)?.0 == "t" })
    }

    @Test("Math in blockquotes and list items is recognized")
    func quoteAndListContainers() throws {
        let quote = augment("> Inline $q$ here\n")
        guard case let .blockQuote(quoteBlocks, _) = quote.blocks.first,
              case let .paragraph(quoteInlines, _) = quoteBlocks.first else {
            Issue.record("expected a blockquote paragraph")
            return
        }
        #expect(quoteInlines.contains { math($0)?.0 == "q" })

        let list = augment("- Inline $l$ here\n")
        guard case let .list(listBlock, _) = list.blocks.first,
              let item = listBlock.items.first,
              case let .paragraph(listInlines, _) = item.blocks.first else {
            Issue.record("expected a list paragraph")
            return
        }
        #expect(listInlines.contains { math($0)?.0 == "l" })
    }

    @Test("Display math in a quote or list item stays a block formula")
    func displayInContainers() {
        let quote = augment("> $$q$$\n")
        guard case let .blockQuote(quoteBlocks, _) = quote.blocks.first,
              case let .paragraph(quoteInlines, _) = quoteBlocks.first else {
            Issue.record("expected a blockquote paragraph")
            return
        }
        #expect(MarkdownInlineMath.soleDisplay(in: quoteInlines)?.source == "q")

        let list = augment("- $$l$$\n")
        guard case let .list(listBlock, _) = list.blocks.first,
              let item = listBlock.items.first,
              case let .paragraph(listInlines, _) = item.blocks.first else {
            Issue.record("expected a list paragraph")
            return
        }
        #expect(MarkdownInlineMath.soleDisplay(in: listInlines)?.source == "l")
    }

    @Test("Math in footnote content is recognized")
    func footnoteMath() throws {
        let ast = augment("Text[^a]\n\n[^a]: Note $x$\n")
        guard case let .footnotes(section, _) = ast.blocks.last else {
            Issue.record("expected footnotes, got \(ast.blocks)")
            return
        }
        #expect(section.entries.count == 1)
        #expect(section.entries[0].inlines.contains { math($0)?.0 == "x" })
    }

    @Test("Frontmatter is not scanned for math")
    func frontmatterIgnored() throws {
        let source = """
        ---
        title: $x$
        ---

        Body $y$
        """
        let ast = augment(source)
        #expect(ast.frontmatter?.body.contains("$x$") == true)
        guard case let .paragraph(inlines, _) = ast.blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(inlines.contains { math($0)?.0 == "y" })
        #expect(!inlines.contains { math($0)?.0 == "x" })
    }

    // MARK: - Security and limits

    @Test("Commands that could reach outside math are rejected")
    func deniedCommands() {
        for command in [
            "\\href{https://example.com}{x}",
            "\\url{https://example.com}",
            "\\includegraphics{/etc/passwd}",
            "\\input{/etc/passwd}",
            "\\include{secret}",
            "\\htmlClass{x}{y}",
            "\\def\\x{y}",
            "\\newcommand{\\x}{y}",
            "\\require{file}",
            "\\write18{echo hi}"
        ] {
            #expect(
                !MarkdownMathPolicy.accepts(command),
                "policy accepted \(command)"
            )
        }
    }

    @Test("A denied command keeps the paragraph literal")
    func deniedCommandStaysLiteral() throws {
        let ast = augment("$\\href{https://example.com}{x}$\n")
        let inlines = try inlines(of: ast)
        #expect(inlines.allSatisfy { math($0) == nil })
    }

    @Test("An over-long formula stays literal")
    func lengthCap() throws {
        let huge = String(
            repeating: "x",
            count: MarkdownLimits.maxMathSourceCharacters + 1
        )
        let ast = augment("$\(huge)$\n")
        let inlines = try inlines(of: ast)
        #expect(inlines.allSatisfy { math($0) == nil })
        #expect(!MarkdownMathPolicy.accepts(huge))
    }

    @Test("An over-nested formula stays literal")
    func depthCap() {
        let depth = MarkdownLimits.maxMathBraceDepth + 1
        let nested = String(repeating: "{", count: depth)
            + "x"
            + String(repeating: "}", count: depth)
        #expect(!MarkdownMathPolicy.accepts(nested))
        #expect(MarkdownMathPolicy.accepts(String(repeating: "{", count: 8) + "x" + String(repeating: "}", count: 8)))
    }

    @Test("The scanner stays linear on a long paragraph")
    func scannerPerformance() {
        let source = String(repeating: "$x$ ", count: 2_000) + "\n"
        let clock = ContinuousClock()
        let ast = clock.measure {
            _ = MarkdownSyntaxAugmenter().augment(MarkdownParser.parseCanonical(source))
        }
        #expect(ast < .seconds(5), "scanning took \(ast)")
    }
}
