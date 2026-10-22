import Foundation
import Testing
@testable import SonovoCore

@Suite("Source map")
struct SourceMapTests {
    @Test("Removed line prefixes keep original offsets and columns")
    func removedLinePrefixes() {
        // The original document had "> " before the second line; parsing
        // strips it. Line 2 therefore starts at original offset 15.
        let map = SourceMap(
            source: "ab\ncd",
            baseOffset: 10,
            linePrefixRemovals: [0, 2]
        )
        #expect(map.position(atUTF16Offset: 15)?.line == 2)
        #expect(map.position(atUTF16Offset: 15)?.column == 2)
        #expect(map.position(atUTF16Offset: 17)?.offset == 17)
        let range = SourceRange(
            start: SourcePosition(line: 2, column: 2, offset: 15),
            end: SourcePosition(line: 2, column: 4, offset: 17)
        )
        #expect(map.text(in: range) == "cd")
    }

    @Test("Maps ASCII columns")
    func asciiColumns() {
        let map = SourceMap(source: "abc\ndef\n")
        #expect(map.utf16Offset(line: 1, utf8Column: 1) == 0)
        #expect(map.utf16Offset(line: 1, utf8Column: 4) == 3)
        #expect(map.utf16Offset(line: 2, utf8Column: 1) == 4)
        #expect(map.utf16Offset(line: 2, utf8Column: 4) == 7)
    }

    @Test("Maps CJK and emoji columns")
    func cjkAndEmoji() {
        let map = SourceMap(source: "中文😀x\n")
        // 中 is 3 UTF-8 bytes, 1 UTF-16 unit.
        #expect(map.utf16Offset(line: 1, utf8Column: 4) == 1)
        // 文 ends after 6 bytes -> 2 UTF-16 units.
        #expect(map.utf16Offset(line: 1, utf8Column: 7) == 2)
        // 😀 is 4 UTF-8 bytes and 2 UTF-16 units.
        #expect(map.utf16Offset(line: 1, utf8Column: 11) == 4)
        #expect(map.utf16Offset(line: 1, utf8Column: 12) == 5)
    }

    @Test("Combining marks map by scalar, not grapheme")
    func combiningMarks() {
        // e + combining acute: 1 UTF-16 unit + 1 unit, 3 UTF-8 bytes.
        let map = SourceMap(source: "e\u{0301}z\n")
        #expect(map.utf16Offset(line: 1, utf8Column: 1) == 0)
        #expect(map.utf16Offset(line: 1, utf8Column: 2) == 1)
        // Byte column 3 falls inside the two-byte combining scalar.
        #expect(map.utf16Offset(line: 1, utf8Column: 3) == nil)
        #expect(map.utf16Offset(line: 1, utf8Column: 4) == 2)
        #expect(map.utf16Offset(line: 1, utf8Column: 5) == 3)
    }

    @Test("text(in:) accepts scalar boundaries inside a grapheme")
    func scalarTextRange() throws {
        let source = "e\u{0301}z\n"
        let map = SourceMap(source: source)
        let start = try #require(map.position(atUTF16Offset: 0))
        let end = try #require(map.position(atUTF16Offset: 1))
        #expect(map.position(atUTF16Offset: 1)?.column == 1)
        #expect(map.text(in: SourceRange(start: start, end: end)) == "e")
    }

    @Test("A mid-line fragment reports the original column")
    func fragmentBaseColumn() {
        let map = SourceMap(
            source: "ab",
            baseLine: 3,
            baseOffset: 10,
            baseColumn: 5
        )
        #expect(map.position(atUTF16Offset: 10)?.column == 5)
        #expect(map.position(atUTF16Offset: 11)?.column == 6)
    }

    @Test("An empty range intersects nothing")
    func emptyIntersection() throws {
        let emptyStart = SourcePosition(line: 1, column: 5, offset: 5)
        let empty = SourceRange(start: emptyStart, end: emptyStart)
        let enclosing = SourceRange(
            start: SourcePosition(line: 1, column: 0, offset: 0),
            end: SourcePosition(line: 1, column: 10, offset: 10)
        )
        #expect(!empty.intersects(enclosing))
        #expect(!enclosing.intersects(empty))
    }

    @Test("Rejects out-of-range positions instead of guessing")
    func rejectsInvalidPositions() {
        let map = SourceMap(source: "ab\n")
        #expect(map.utf16Offset(line: 0, utf8Column: 1) == nil)
        #expect(map.utf16Offset(line: 3, utf8Column: 1) == nil)
        #expect(map.utf16Offset(line: 1, utf8Column: 0) == nil)
        #expect(map.utf16Offset(line: 1, utf8Column: 3) == 2)
        #expect(map.utf16Offset(line: 1, utf8Column: 4) == nil)
        // The empty line created by the trailing newline exists.
        #expect(map.utf16Offset(line: 2, utf8Column: 1) == 3)
    }

    @Test("Canonicalizes BOM and line endings")
    func canonicalize() {
        let raw = "\u{FEFF}a\r\nb\rc\n"
        let canonical = SourceMap.canonicalize(raw: raw)
        #expect(canonical.text == "a\nb\nc\n")
        #expect(canonical.hasBOM)
        #expect(canonical.lineEnding == .crlf)
        #expect(canonical.hadMixedLineEndings)
    }

    @Test("Keeps LF files and rejects a UTF-16 report as LF")
    func canonicalizeLF() {
        let canonical = SourceMap.canonicalize(raw: "a\nb\n")
        #expect(canonical.text == "a\nb\n")
        #expect(!canonical.hasBOM)
        #expect(canonical.lineEnding == .lf)
        #expect(!canonical.hadMixedLineEndings)
    }

    @Test("Frontmatter body maps to global positions")
    func frontmatterRebasing() {
        let source = "---\ntitle: x\n---\n\n# Heading\n"
        let parsed = MarkdownParser.parse(source)
        #expect(parsed.ast.frontmatter?.body.contains("title: x") == true)

        guard case let .heading(level, inlines, range) = parsed.ast.blocks.first else {
            Issue.record("expected a heading")
            return
        }
        #expect(level == 1)
        #expect(range?.start.offset == 18)
        #expect(range?.start.line == 5)
        #expect(inlines.count == 1)
    }

    @Test("CRLF plus lone CR counts as mixed")
    func mixedCRStyles() {
        let canonical = SourceMap.canonicalize(raw: "a\r\nb\rc")
        #expect(canonical.hadMixedLineEndings)
    }

    @Test("A range ending at column zero does not include that line")
    func lineSpanEndColumnZero() {
        let range = SourceRange(
            start: SourcePosition(line: 1, column: 0, offset: 0),
            end: SourcePosition(line: 2, column: 0, offset: 2)
        )
        #expect(range.lineSpan == 1...1)
    }

    @Test("Text node ranges cover the raw span for entities and escapes")
    func entityRanges() {
        let parsed = MarkdownParser.parse("&amp; \\* x\n")
        guard case let .paragraph(inlines, _) = parsed.ast.blocks.first,
              case let .text(literal, range) = inlines.first else {
            Issue.record("expected text")
            return
        }
        #expect(literal == "& * x")
        // The upstream range covers the authored bytes, not the decoded text.
        #expect(range?.lowerBound == 0)
        #expect(range?.upperBound == 10)
    }
}
