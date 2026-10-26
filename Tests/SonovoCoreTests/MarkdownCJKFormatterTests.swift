import Foundation
import Testing
@testable import SonovoCore

@Suite("CJK formatter")
struct MarkdownCJKFormatterTests {
    private func format(
        _ source: String,
        selection: Range<Int> = 0..<0
    ) -> MarkdownCJKFormatting {
        MarkdownCJKFormatter.format(source: source, selection: selection)
    }

    // MARK: - Spacing

    @Test("A space is inserted between CJK and Latin or digits")
    func spacingBoundaries() {
        let cases: [(String, String)] = [
            ("中文English", "中文 English"),
            ("English中文", "English 中文"),
            ("中文123", "中文 123"),
            ("123中文", "123 中文"),
            ("日本語ABC", "日本語 ABC"),
            ("ABC日本語", "ABC 日本語"),
            ("ひらがなABC", "ひらがな ABC"),
            ("한글English", "한글 English"),
            ("中文English中文", "中文 English 中文")
        ]
        for (source, expected) in cases {
            let result = format(source)
            #expect(result.source == expected, "\(source)")
            #expect(result.changed)
        }
    }

    @Test("Existing spacing and same-script runs are left alone")
    func spacingExceptions() {
        #expect(format("中文 English").source == "中文 English")
        #expect(format("中文 English").changed == false)
        #expect(format("English words").changed == false)
        #expect(format("中文中文").changed == false)
        #expect(format("123 456").changed == false)
        // A fullwidth comma is punctuation, not a CJK letter; no space is
        // inserted around it.
        #expect(format("中文，English").changed == false)
    }

    // MARK: - Punctuation

    @Test("The punctuation table applies between two CJK characters")
    func punctuationTable() {
        let cases: [(String, String)] = [
            ("中文,中文", "中文，中文"),
            ("中文.中文", "中文。中文"),
            ("中文:中文", "中文：中文"),
            ("中文;中文", "中文；中文"),
            ("中文!中文", "中文！中文"),
            ("中文?中文", "中文？中文")
        ]
        for (source, expected) in cases {
            let result = format(source)
            #expect(result.source == expected, "\(source)")
            #expect(result.normalizedPunctuation == 1)
        }
    }

    @Test("Sentence-final punctuation is normalized after CJK")
    func sentenceFinalPunctuation() {
        #expect(format("中文.").source == "中文。")
        #expect(format("中文!\n").source == "中文！\n")
        #expect(format("中文?").source == "中文？")
        #expect(format("中文. English").source == "中文。 English")
    }

    @Test("Numbers, Latin text, and mixed contexts keep ASCII punctuation")
    func punctuationExceptions() {
        #expect(format("1,000.5").changed == false)
        #expect(format("A,B: C;").changed == false)
        #expect(format("中文, English").changed == false)
        #expect(format("中文1.0").source == "中文 1.0")
        #expect(format("中文1.0").normalizedPunctuation == 0)
        #expect(format("中文...").changed == false)
        #expect(format("中文.English").changed == false)
        #expect(format("English!中文").changed == false)
        #expect(format("注意: 中文").changed == false)
        #expect(format("注意:中文").source == "注意：中文")
    }

    // MARK: - Protected regions

    @Test("Fenced and indented code stay byte-identical")
    func codeBlocksAreProtected() {
        let fenced = "```\n中文English\n```\n"
        #expect(format(fenced).source == fenced)
        let indented = "Paragraph\n\n    中文English\n"
        #expect(format(indented).source == indented)
        let inline = "`中文English`\n"
        #expect(format(inline).source == inline)
        // Text outside the fence still formats.
        let mixed = "中文English\n\n```\n中文English\n```\n"
        #expect(
            format(mixed).source == "中文 English\n\n```\n中文English\n```\n"
        )
    }

    @Test("Frontmatter is protected and the body still formats")
    func frontmatterIsProtected() {
        let source = "---\ntitle: 中文English\n---\n\n中文English\n"
        let result = format(source)
        #expect(
            result.source
                == "---\ntitle: 中文English\n---\n\n中文 English\n"
        )
    }

    @Test("Link text formats while the destination is untouched")
    func linkDestinationsAreProtected() {
        let source = "[中文English](https://example.com/中文English \"标题English\")"
        let result = format(source)
        #expect(
            result.source
                == "[中文 English](https://example.com/中文English \"标题English\")"
        )

        let reference = """
        [中文English][标签中文English]

        [标签中文English]: https://example.com
        """
        #expect(
            format(reference).source == """
            [中文 English][标签中文English]

            [标签中文English]: https://example.com
            """
        )

        // A resolved shortcut reference is identified by its label, so the
        // whole bracket is protected.
        let shortcut = """
        [中文English]

        [中文English]: https://example.com
        """
        #expect(format(shortcut).source == shortcut)
    }

    @Test("Reference definitions, autolinks, and bare URLs are untouched")
    func urlsAreProtected() {
        let definition = "[ref]: https://example.com/中文English\n"
        #expect(format(definition).source == definition)

        let autolink = "<https://example.com/中文English>\n"
        #expect(format(autolink).source == autolink)

        let bare = "看https://example.com/中文English。\n"
        #expect(format(bare).source == bare)
    }

    @Test("Math, wiki links, images, and HTML blocks are untouched")
    func otherProtectedRegions() {
        let math = "公式 $x中文English$ 结束\n"
        #expect(format(math).source == math)

        let wiki = "[[中文English|别名]]\n"
        #expect(format(wiki).source == wiki)

        let image = "![中文English](https://example.com/x.png)\n"
        #expect(format(image).source == image)

        let html = "<div>\n中文English\n</div>\n"
        #expect(format(html).source == html)

        let footnote = "正文[^a]\n\n[^a]: 中文English\n"
        #expect(format(footnote).changed == false)
    }

    @Test("Inline HTML tags are protected but their text formats")
    func inlineHTMLTextFormats() {
        let source = "<span>中文English</span>\n"
        #expect(format(source).source == "<span>中文 English</span>\n")
    }

    @Test("Table cells format like prose")
    func tableCellsFormat() {
        let source = "| 中文English | B |\n| --- | --- |\n| 值123 | x |\n"
        let result = format(source)
        #expect(result.source.contains("| 中文 English | B |"))
        #expect(result.source.contains("| 值 123 | x |"))
    }

    // MARK: - Selection, idempotency, and refusal

    @Test("The selection moves through inserted characters")
    func selectionMapping() {
        let source = "中文English"
        let result = format(source, selection: 2..<2)
        #expect(result.selection == 3..<3)

        let selected = format(source, selection: 2..<3)
        #expect(selected.selection == 3..<4)
    }

    @Test("Formatting is idempotent")
    func idempotency() {
        let source = "中文English,中文.中文123!\n"
        let once = format(source)
        let twice = format(once.source)
        #expect(twice.source == once.source)
        #expect(twice.changed == false)
    }

    @Test("A document with no CJK skips the parse and changes nothing")
    func noCJKFastPath() {
        let source = "English only, with 123 and punctuation."
        let result = format(source)
        #expect(result.source == source)
        #expect(result.changed == false)
    }

    @Test("Counts match the edits that were made")
    func editCounts() {
        let result = format("中文English,中文.中文")
        #expect(result.insertedSpaces == 1)
        #expect(result.normalizedPunctuation == 1)
        // The comma follows `English`, so it is not in a CJK context and
        // stays ASCII; the period sits between two CJK characters.
        #expect(result.source == "中文 English,中文。中文")
    }

    // MARK: - Command path

    @Test("The command registry exposes one CJK formatting command")
    func commandPath() throws {
        let registry = MarkdownCommandRegistry()
        let context = MarkdownCommandContext(
            source: "中文English",
            selection: 0..<0
        )
        let result = try registry.apply(.formatCJK, to: context)
        #expect(result.source == "中文 English")
        #expect(result.actionName == "Format CJK Spacing")
        #expect(registry.title(for: .formatCJK) == "Format CJK Spacing")

        let readOnly = MarkdownCommandContext(
            source: "中文English",
            selection: 0..<0,
            isReadOnly: true
        )
        #expect(!registry.isAvailable(.formatCJK, in: readOnly))
        let composing = MarkdownCommandContext(
            source: "中文English",
            selection: 0..<0,
            hasMarkedText: true
        )
        #expect(!registry.isAvailable(.formatCJK, in: composing))

        let catalog = MarkdownCommandCatalog.entries.filter {
            $0.command == .formatCJK
        }
        #expect(catalog.count == 1)
        #expect(catalog.first?.category == "Text")
    }

    @Test("A no-op command produces an identical result")
    func noOpCommand() throws {
        let registry = MarkdownCommandRegistry()
        let result = try registry.apply(
            .formatCJK,
            to: MarkdownCommandContext(
                source: "中文 English",
                selection: 0..<0
            )
        )
        #expect(result.source == "中文 English")
        #expect(result.changedRange.isEmpty)
    }
}
