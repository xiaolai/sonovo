import AppKit
import XCTest
@testable import Sonovo

@MainActor
final class CodeSyntaxHighlighterTests: XCTestCase {
    func testSwiftTokensAndKeywords() {
        let snapshot = CodeSyntaxHighlighter.lex(
            text: "let value = 42 // note\n",
            language: .swift,
            revision: 1
        )
        XCTAssertEqual(snapshot.revision, 1)
        let tokens = snapshot.tokens(
            intersecting: NSRange(
                location: 0,
                length: ("let value = 42 // note\n" as NSString).length
            )
        )
        XCTAssertTrue(
            tokens.contains {
                $0.kind == .keyword
                    && ($0.range.location == 0)
            },
            "let must be a keyword at the start of the line"
        )
        XCTAssertTrue(tokens.contains { $0.kind == .number })
        XCTAssertTrue(tokens.contains { $0.kind == .comment })
    }

    func testBlockCommentStateCrossesLines() {
        let text = "/*\n x\n*/\nlet a = 1\n"
        let snapshot = CodeSyntaxHighlighter.lex(
            text: text,
            language: .swift,
            revision: 1
        )
        XCTAssertEqual(snapshot.lines.count, 5)
        XCTAssertEqual(
            snapshot.lines[0].endState,
            .blockComment(depth: 1, close: "*/", nested: true)
        )
        XCTAssertEqual(
            snapshot.lines[1].stateAtStart,
            .blockComment(depth: 1, close: "*/", nested: true)
        )
        XCTAssertEqual(snapshot.lines[2].endState, .normal)
        XCTAssertEqual(snapshot.lines[3].stateAtStart, .normal)
    }

    func testPythonTripleStringAndShellHeredocCarryState() {
        let python = CodeSyntaxHighlighter.lex(
            text: "s = \"\"\"\ninside\n\"\"\"\n",
            language: .python,
            revision: 1
        )
        XCTAssertEqual(
            python.lines[0].endState,
            .multilineString(delimiter: "\"\"\"")
        )
        XCTAssertEqual(
            python.lines[1].stateAtStart,
            .multilineString(delimiter: "\"\"\"")
        )
        XCTAssertEqual(python.lines[2].endState, .normal)

        let shell = CodeSyntaxHighlighter.lex(
            text: "cat <<EOF\nbody\nEOF\necho done\n",
            language: .shell,
            revision: 1
        )
        XCTAssertEqual(
            shell.lines[0].endState,
            .heredoc(delimiter: "EOF", indentation: .exact)
        )
        XCTAssertEqual(
            shell.lines[1].stateAtStart,
            .heredoc(delimiter: "EOF", indentation: .exact)
        )
        XCTAssertEqual(shell.lines[2].endState, .normal)
    }

    func testEditingAMultilineOpenerAboveTheViewportPropagates() {
        var lines = ["/*"]
        for index in 1..<999 {
            lines.append("let value\(index) = \(index)")
        }
        lines.append("*/")
        let text = lines.joined(separator: "\n") + "\n"
        let first = CodeSyntaxHighlighter.lex(
            text: text,
            language: .swift,
            revision: 1
        )
        XCTAssertEqual(
            first.lines[998].endState,
            .blockComment(depth: 1, close: "*/", nested: true)
        )

        var edited = lines
        edited[0] = "//"
        let relexed = CodeSyntaxHighlighter.relex(
            previous: first,
            text: edited.joined(separator: "\n") + "\n",
            language: .swift,
            revision: 2,
            editedLine: 0
        )
        XCTAssertEqual(relexed.revision, 2)
        XCTAssertEqual(relexed.lines[998].endState, .normal)
        XCTAssertEqual(
            relexed.lines[998].stateAtStart,
            .normal,
            "downstream state must update when the opener is removed"
        )
        XCTAssertGreaterThan(
            relexed.reprocessedLineCount,
            900,
            "a changed multiline opener must propagate to its closer"
        )
        XCTAssertTrue(
            relexed.tokens(
                intersecting: relexed.range(ofLine: 501)!
            ).contains { $0.kind == .keyword }
        )
    }

    func testLocalEditReusesDownstreamCheckpoints() {
        var lines = (0..<1000).map { "let value\($0) = \($0)" }
        let first = CodeSyntaxHighlighter.lex(
            text: lines.joined(separator: "\n") + "\n",
            language: .swift,
            revision: 1
        )
        lines[500] = "let value500 = 999"
        let relexed = CodeSyntaxHighlighter.relex(
            previous: first,
            text: lines.joined(separator: "\n") + "\n",
            language: .swift,
            revision: 2,
            editedLine: 500
        )
        XCTAssertEqual(
            relexed.reprocessedLineCount,
            1,
            "a state-neutral edit must stop at the next matching line"
        )
        XCTAssertEqual(relexed.lines.count, first.lines.count)
        XCTAssertEqual(
            relexed.lines[501].tokens,
            first.lines[501].tokens
        )
    }

    func testEditThatChangesLineCountRealignsDownstream() {
        var lines = (0..<100).map { "let value\($0) = \($0)" }
        let first = CodeSyntaxHighlighter.lex(
            text: lines.joined(separator: "\n") + "\n",
            language: .swift,
            revision: 1
        )
        lines.insert("// inserted", at: 50)
        let relexed = CodeSyntaxHighlighter.relex(
            previous: first,
            text: lines.joined(separator: "\n") + "\n",
            language: .swift,
            revision: 2,
            editedLine: 50
        )
        XCTAssertEqual(relexed.lines.count, first.lines.count + 1)
        XCTAssertEqual(
            relexed.lines[51].stateAtStart,
            .normal
        )
        XCTAssertEqual(
            relexed.lines[52].tokens,
            first.lines[51].tokens,
            "the shifted downstream line keeps its tokens"
        )
    }

    func testLongLineIsPlainAndNamed() {
        let long = String(repeating: "a", count: 20_001)
        let snapshot = CodeSyntaxHighlighter.lex(
            text: "\(long)\nlet a = 1\n",
            language: .swift,
            revision: 1
        )
        XCTAssertTrue(snapshot.lines[0].isPlain)
        XCTAssertEqual(snapshot.lines[0].tokens.count, 0)
        XCTAssertEqual(snapshot.longLineCount, 1)
        XCTAssertFalse(snapshot.lines[1].isPlain)
    }

    func testRelexAfterASkippedRevisionFallsBackToFullLex() {
        let lines = (0..<50).map { "let value\($0) = \($0)" }
        let text = lines.joined(separator: "\n") + "\n"
        let first = CodeSyntaxHighlighter.lex(
            text: text,
            language: .swift,
            revision: 1
        )
        var edited = lines
        edited[10] = "let value10 = 99"
        let snapshot = CodeSyntaxHighlighter.relex(
            previous: first,
            text: edited.joined(separator: "\n") + "\n",
            language: .swift,
            revision: 3,
            editedLine: 10
        )
        XCTAssertEqual(
            snapshot.reprocessedLineCount,
            snapshot.lines.count,
            "a skipped revision must not reuse a stale prefix"
        )
    }

    func testContinuationLinesEmitTokens() {
        let comment = CodeSyntaxHighlighter.lex(
            text: "/*\n x\n*/\n",
            language: .swift,
            revision: 1
        )
        XCTAssertTrue(
            comment.tokens(
                intersecting: comment.range(ofLine: 2)!
            ).contains { $0.kind == .comment }
        )
        let python = CodeSyntaxHighlighter.lex(
            text: "s = \"\"\"\ninside\n\"\"\"\n",
            language: .python,
            revision: 1
        )
        XCTAssertTrue(
            python.tokens(
                intersecting: python.range(ofLine: 2)!
            ).contains { $0.kind == .string }
        )
    }

    func testBacktickStringResumesOnTheNextLine() {
        let snapshot = CodeSyntaxHighlighter.lex(
            text: "const s = `line one\nline two`\n",
            language: .javascript,
            revision: 1
        )
        XCTAssertEqual(
            snapshot.lines[0].endState,
            .multilineString(delimiter: "`")
        )
        XCTAssertEqual(
            snapshot.lines[1].stateAtStart,
            .multilineString(delimiter: "`")
        )
        XCTAssertEqual(snapshot.lines[1].endState, .normal)
        XCTAssertTrue(
            snapshot.tokens(
                intersecting: snapshot.range(ofLine: 2)!
            ).contains { $0.kind == .string }
        )
    }

    func testRustRawStringsAreRecognized() {
        let snapshot = CodeSyntaxHighlighter.lex(
            text: "let s = r#\"raw \"quoted\" text\"#;\n",
            language: .rust,
            revision: 1
        )
        let strings = snapshot.tokens(
            intersecting: snapshot.range(ofLine: 1)!
        ).filter { $0.kind == .string }
        XCTAssertFalse(strings.isEmpty)
        XCTAssertEqual(snapshot.lines[0].endState, .normal)

        let plain = CodeSyntaxHighlighter.lex(
            text: "let s = r\"raw\";\n",
            language: .rust,
            revision: 1
        )
        XCTAssertTrue(
            plain.tokens(
                intersecting: plain.range(ofLine: 1)!
            ).contains { $0.kind == .string }
        )
    }

    func testCaseInsensitiveKeywordsMatch() {
        let sql = CodeSyntaxHighlighter.lex(
            text: "SELECT * FROM table_name;\n",
            language: .sql,
            revision: 1
        )
        let keywords = sql.tokens(
            intersecting: sql.range(ofLine: 1)!
        ).filter { $0.kind == .keyword }
        XCTAssertEqual(keywords.count, 2)

        let docker = CodeSyntaxHighlighter.lex(
            text: "FROM alpine:3.20\n",
            language: .dockerfile,
            revision: 1
        )
        XCTAssertTrue(
            docker.tokens(
                intersecting: docker.range(ofLine: 1)!
            ).contains { $0.kind == .keyword }
        )
    }

    func testLuaBlockCommentWinsOverItsLineCommentPrefix() {
        let snapshot = CodeSyntaxHighlighter.lex(
            text: "--[[\nbody\n]]\nlet x = 1\n",
            language: .lua,
            revision: 1
        )
        XCTAssertEqual(
            snapshot.lines[0].endState,
            .blockComment(depth: 1, close: "]]", nested: false)
        )
        XCTAssertEqual(snapshot.lines[2].endState, .normal)
        XCTAssertTrue(
            snapshot.tokens(
                intersecting: snapshot.range(ofLine: 2)!
            ).contains { $0.kind == .comment }
        )
    }

    func testLongLineStillAdvancesTheStateMachine() {
        let long = String(repeating: "a", count: 20_001)
        let text = "/* \(long) */ let x = 1\nlet y = 2\n"
        let snapshot = CodeSyntaxHighlighter.lex(
            text: text,
            language: .swift,
            revision: 1
        )
        XCTAssertTrue(snapshot.lines[0].isPlain)
        XCTAssertEqual(snapshot.lines[0].endState, .normal)
        XCTAssertTrue(
            snapshot.tokens(
                intersecting: snapshot.range(ofLine: 2)!
            ).contains { $0.kind == .keyword },
            "the line after a long closing delimiter must be highlighted"
        )
    }

    func testEmojiCountsAsOneFourByteScalar() {
        let under = String(repeating: "😀", count: 4_999)
        let over = String(repeating: "😀", count: 5_001)
        XCTAssertEqual(under.utf8.count, 19_996)
        XCTAssertEqual(over.utf8.count, 20_004)
        XCTAssertFalse(
            CodeSyntaxHighlighter.lex(
                text: under + "\n",
                language: .plainText,
                revision: 1
            ).lines[0].isPlain
        )
        XCTAssertTrue(
            CodeSyntaxHighlighter.lex(
                text: over + "\n",
                language: .plainText,
                revision: 1
            ).lines[0].isPlain
        )
    }

    func testNumberScannerStopsAtAnOperator() {
        let text = "let x = 1+2\n"
        let snapshot = CodeSyntaxHighlighter.lex(
            text: text,
            language: .swift,
            revision: 1
        )
        let ns = text as NSString
        let numbers = snapshot.tokens(
            intersecting: snapshot.range(ofLine: 1)!
        ).filter { $0.kind == .number }.map {
            ns.substring(with: $0.range)
        }
        XCTAssertEqual(numbers, ["1", "2"])
    }

    func testPythonHashCommentNeedsNoBoundary() {
        let text = "x=1#note\n"
        let snapshot = CodeSyntaxHighlighter.lex(
            text: text,
            language: .python,
            revision: 1
        )
        let ns = text as NSString
        let comments = snapshot.tokens(
            intersecting: snapshot.range(ofLine: 1)!
        ).filter { $0.kind == .comment }.map {
            ns.substring(with: $0.range)
        }
        XCTAssertEqual(comments, ["#note"])
    }

    func testShellCommentStillNeedsABoundary() {
        let text = "echo foo#bar\n"
        let snapshot = CodeSyntaxHighlighter.lex(
            text: text,
            language: .shell,
            revision: 1
        )
        XCTAssertFalse(
            snapshot.tokens(
                intersecting: snapshot.range(ofLine: 1)!
            ).contains { $0.kind == .comment }
        )
    }

    func testShellSingleQuotesAreLiteral() {
        let text = "echo 'C:\\' # note\n"
        let snapshot = CodeSyntaxHighlighter.lex(
            text: text,
            language: .shell,
            revision: 1
        )
        let ns = text as NSString
        let strings = snapshot.tokens(
            intersecting: snapshot.range(ofLine: 1)!
        ).filter { $0.kind == .string }.map {
            ns.substring(with: $0.range)
        }
        XCTAssertEqual(strings, ["'C:\\'"])
        XCTAssertTrue(
            snapshot.tokens(
                intersecting: snapshot.range(ofLine: 1)!
            ).contains { $0.kind == .comment }
        )
    }

    func testHereStringIsNotAHeredoc() {
        let snapshot = CodeSyntaxHighlighter.lex(
            text: "cat <<<EOF\nstill normal\n",
            language: .shell,
            revision: 1
        )
        XCTAssertEqual(snapshot.lines[0].endState, .normal)
        XCTAssertEqual(snapshot.lines[1].stateAtStart, .normal)
    }

    func testMarkupQuoteCarriesAcrossLines() {
        let snapshot = CodeSyntaxHighlighter.lex(
            text: "<a href=\"x\n>y\">\n",
            language: .xml,
            revision: 1
        )
        XCTAssertEqual(
            snapshot.lines[0].endState,
            .markupTag(quote: 0x22)
        )
        XCTAssertEqual(
            snapshot.lines[1].stateAtStart,
            .markupTag(quote: 0x22)
        )
        XCTAssertEqual(snapshot.lines[1].endState, .normal)
    }

    func testEscapedBacktickDoesNotCloseATemplateString() {
        let text = "const s = `a\\`b`;\n"
        let snapshot = CodeSyntaxHighlighter.lex(
            text: text,
            language: .javascript,
            revision: 1
        )
        XCTAssertEqual(snapshot.lines[0].endState, .normal)
        let strings = snapshot.tokens(
            intersecting: snapshot.range(ofLine: 1)!
        ).filter { $0.kind == .string }
        XCTAssertEqual(strings.count, 1)
    }

    func testJSONCCommentsAreHighlighted() {
        let snapshot = CodeSyntaxHighlighter.lex(
            text: "// note\nlet x = 1 /* trailing */\n",
            language: .jsonc,
            revision: 1
        )
        let comments = snapshot.tokens(
            intersecting: NSRange(
                location: 0,
                length: ("// note\nlet x = 1 /* trailing */\n" as NSString).length
            )
        ).filter { $0.kind == .comment }
        XCTAssertEqual(comments.count, 2)
    }

    func testTOMLTripleSingleQuotedStringIsLiteral() {
        let snapshot = CodeSyntaxHighlighter.lex(
            text: "s = '''\n# not a comment \\\n'''\n",
            language: .toml,
            revision: 1
        )
        XCTAssertEqual(
            snapshot.lines[1].stateAtStart,
            .multilineString(delimiter: "'''")
        )
        XCTAssertFalse(
            snapshot.tokens(
                intersecting: snapshot.range(ofLine: 2)!
            ).contains { $0.kind == .comment }
        )
        XCTAssertTrue(
            snapshot.tokens(
                intersecting: snapshot.range(ofLine: 2)!
            ).contains { $0.kind == .string }
        )
    }

    func testRustLifetimesAreNotStrings() {
        let lifetimes = CodeSyntaxHighlighter.lex(
            text: "fn f<'a>(x: &'a str) {}\n",
            language: .rust,
            revision: 1
        )
        XCTAssertFalse(
            lifetimes.tokens(
                intersecting: lifetimes.range(ofLine: 1)!
            ).contains { $0.kind == .string },
            "lifetimes must not open a character string"
        )

        let char = CodeSyntaxHighlighter.lex(
            text: "let c = 'x';\n",
            language: .rust,
            revision: 1
        )
        XCTAssertTrue(
            char.tokens(
                intersecting: char.range(ofLine: 1)!
            ).contains { $0.kind == .string }
        )
    }

    func testRubyHeredocNeedsAnAdjacentDelimiter() {
        let shift = CodeSyntaxHighlighter.lex(
            text: "items << value\nnext line\n",
            language: .ruby,
            revision: 1
        )
        XCTAssertEqual(shift.lines[0].endState, .normal)
        XCTAssertEqual(shift.lines[1].stateAtStart, .normal)

        let heredoc = CodeSyntaxHighlighter.lex(
            text: "sql = <<~SQL\nselect 1\nSQL\n",
            language: .ruby,
            revision: 1
        )
        XCTAssertEqual(
            heredoc.lines[0].endState,
            .heredoc(delimiter: "SQL", indentation: .whitespace)
        )
        XCTAssertEqual(heredoc.lines[2].endState, .normal)
    }

    func testRubyIndentedHeredocTerminatorsClose() {
        for marker in ["<<~SQL", "<<-SQL"] {
            let snapshot = CodeSyntaxHighlighter.lex(
                text: "sql = \(marker)\n  select 1\n  SQL\nlet x = 1\n",
                language: .ruby,
                revision: 1
            )
            XCTAssertEqual(
                snapshot.lines[2].endState,
                .normal,
                "an indented terminator closes \(marker)"
            )
            XCTAssertEqual(
                snapshot.lines[3].stateAtStart,
                .normal,
                "the line after \(marker) is code again"
            )
        }

        // A plain `<<SQL` keeps the shell rule: the terminator is the whole
        // line, so an indented one is still body text.
        let plain = CodeSyntaxHighlighter.lex(
            text: "sql = <<SQL\n  select 1\n  SQL\nlet x = 1\n",
            language: .ruby,
            revision: 1
        )
        XCTAssertEqual(
            plain.lines[2].endState,
            .heredoc(delimiter: "SQL", indentation: .exact)
        )
        XCTAssertEqual(
            plain.lines[3].stateAtStart,
            .heredoc(delimiter: "SQL", indentation: .exact)
        )
    }

    func testShellHeredocDashAcceptsTabsButNotSpaces() {
        let tabs = CodeSyntaxHighlighter.lex(
            text: "cat <<-EOF\n\tbody\n\tEOF\necho done\n",
            language: .shell,
            revision: 1
        )
        XCTAssertEqual(tabs.lines[2].endState, .normal)
        XCTAssertEqual(tabs.lines[3].stateAtStart, .normal)

        let spaces = CodeSyntaxHighlighter.lex(
            text: "cat <<-EOF\n  body\n  EOF\necho done\n",
            language: .shell,
            revision: 1
        )
        XCTAssertEqual(
            spaces.lines[2].endState,
            .heredoc(delimiter: "EOF", indentation: .tabs),
            "shell only strips tabs, so a space-indented EOF is body text"
        )
        XCTAssertEqual(
            spaces.lines[3].stateAtStart,
            .heredoc(delimiter: "EOF", indentation: .tabs)
        )
    }

    func testMultipleHeredocsOnOneLineCarryTheirBodiesInOrder() {
        let snapshot = CodeSyntaxHighlighter.lex(
            text: "cat <<FIRST <<SECOND\n"
                + "first body\nFIRST\nsecond body\nSECOND\necho done\n",
            language: .shell,
            revision: 1
        )
        XCTAssertEqual(
            snapshot.lines[0].endState,
            .heredoc(
                pending: [
                    CodeHeredocTerminator(
                        delimiter: "FIRST",
                        indentation: .exact
                    ),
                    CodeHeredocTerminator(
                        delimiter: "SECOND",
                        indentation: .exact
                    )
                ]
            )
        )
        XCTAssertEqual(
            snapshot.lines[2].endState,
            .heredoc(delimiter: "SECOND", indentation: .exact),
            "closing the first body activates the second"
        )
        XCTAssertEqual(
            snapshot.lines[3].stateAtStart,
            .heredoc(delimiter: "SECOND", indentation: .exact)
        )
        XCTAssertEqual(snapshot.lines[4].endState, .normal)
        XCTAssertEqual(snapshot.lines[5].stateAtStart, .normal)
    }

    func testHeredocProbeIgnoresQuotedAndEmbeddedMarkers() {
        let escaped = CodeSyntaxHighlighter.lex(
            text: "cat <<FIRST \"a\\\" <<FAKE\" <<SECOND\n"
                + "one\nFIRST\ntwo\nSECOND\ndone\n",
            language: .shell,
            revision: 1
        )
        XCTAssertEqual(
            escaped.lines[0].endState,
            .heredoc(
                pending: [
                    CodeHeredocTerminator(
                        delimiter: "FIRST",
                        indentation: .exact
                    ),
                    CodeHeredocTerminator(
                        delimiter: "SECOND",
                        indentation: .exact
                    )
                ]
            ),
            "an escaped quote keeps the quoted marker out of the queue"
        )
        XCTAssertEqual(escaped.lines[4].endState, .normal)
        XCTAssertEqual(escaped.lines[5].stateAtStart, .normal)

        let embedded = CodeSyntaxHighlighter.lex(
            text: "cat <<FIRST foo#bar <<SECOND\n"
                + "one\nFIRST\ntwo\nSECOND\ndone\n",
            language: .shell,
            revision: 1
        )
        XCTAssertEqual(
            embedded.lines[0].endState,
            .heredoc(
                pending: [
                    CodeHeredocTerminator(
                        delimiter: "FIRST",
                        indentation: .exact
                    ),
                    CodeHeredocTerminator(
                        delimiter: "SECOND",
                        indentation: .exact
                    )
                ]
            ),
            "a # inside a word does not start a comment"
        )
        XCTAssertEqual(embedded.lines[4].endState, .normal)
    }

    func testHeredocProbeUsesTheLanguageCommentRule() {
        let shell = CodeSyntaxHighlighter.lex(
            text: "cat <<FIRST;# ignored <<FAKE\none\nFIRST\ndone\n",
            language: .shell,
            revision: 1
        )
        XCTAssertEqual(
            shell.lines[0].endState,
            .heredoc(delimiter: "FIRST", indentation: .exact),
            "a # after a shell separator starts a comment"
        )

        let ruby = CodeSyntaxHighlighter.lex(
            text: "puts <<FIRST, foo# ignored <<FAKE\none\nFIRST\ndone\n",
            language: .ruby,
            revision: 1
        )
        XCTAssertEqual(
            ruby.lines[0].endState,
            .heredoc(delimiter: "FIRST", indentation: .exact),
            "Ruby starts a comment at any unquoted #"
        )
    }

    func testHeredocCloserMustBeTheWholeTrimmedLine() {
        let prefixed = CodeSyntaxHighlighter.lex(
            text: "sql = <<SQL\nbody\nSQLX\nSQL\n",
            language: .ruby,
            revision: 1
        )
        XCTAssertEqual(
            prefixed.lines[2].endState,
            .heredoc(delimiter: "SQL", indentation: .exact),
            "a delimiter prefix does not close the heredoc"
        )
        XCTAssertEqual(prefixed.lines[3].endState, .normal)

        let trailing = CodeSyntaxHighlighter.lex(
            text: "sql = <<~SQL\nbody\n  SQL extra\n  SQL\n",
            language: .ruby,
            revision: 1
        )
        XCTAssertEqual(
            trailing.lines[2].endState,
            .heredoc(delimiter: "SQL", indentation: .whitespace),
            "trailing content after the delimiter does not close it"
        )
        XCTAssertEqual(trailing.lines[3].endState, .normal)
    }

    func testIncrementalRelexCarriesAChangedHeredocPolicy() {
        let before = CodeSyntaxHighlighter.lex(
            text: "sql = <<SQL\nbody\n  SQL\nlet x = 1\n",
            language: .ruby,
            revision: 1
        )
        XCTAssertEqual(
            before.lines[3].stateAtStart,
            .heredoc(delimiter: "SQL", indentation: .exact),
            "the exact policy keeps an indented line open"
        )

        // Only the opener's policy changes. The relex must re-evaluate the
        // closer against the new policy, not reuse the old line states.
        let after = CodeSyntaxHighlighter.relex(
            previous: before,
            text: "sql = <<~SQL\nbody\n  SQL\nlet x = 1\n",
            language: .ruby,
            revision: 2,
            editedLine: 0
        )
        XCTAssertEqual(
            after.lines[2].endState,
            .normal,
            "the squiggly policy closes on the indented delimiter"
        )
        XCTAssertEqual(after.lines[3].stateAtStart, .normal)
    }

    func testKotlinRawTripleStringsDoNotProcessEscapes() {
        let snapshot = CodeSyntaxHighlighter.lex(
            text: "val s = \"\"\"C:\\path\\\"\"\"\nval x = 1\n",
            language: .kotlin,
            revision: 1
        )
        XCTAssertEqual(snapshot.lines[0].endState, .normal)
        XCTAssertTrue(
            snapshot.tokens(
                intersecting: snapshot.range(ofLine: 2)!
            ).contains { $0.kind == .keyword }
        )
    }

    func testRustHexCharacterLiteralsAreStrings() {
        let snapshot = CodeSyntaxHighlighter.lex(
            text: "let c = '\\x41';\n",
            language: .rust,
            revision: 1
        )
        XCTAssertTrue(
            snapshot.tokens(
                intersecting: snapshot.range(ofLine: 1)!
            ).contains { $0.kind == .string },
            "a hexadecimal character literal must be a string"
        )
    }

    func testStaleRevisionIsNeverApplied() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoStale-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file.swift")
        try Data("let value = 1\n".utf8).write(to: url)

        let document = CodeDocument(url: url)
        await document.load()
        let controller = CodeEditorController(
            document: document,
            settings: CodeEditorSettings()
        )
        let live = CodeSyntaxHighlighter.lex(
            text: document.source,
            language: document.language,
            revision: document.revision
        )
        controller.applyHighlight(live)
        guard let storage = controller.textView.textStorage else {
            return XCTFail("no text storage")
        }
        let keywordRange = NSRange(location: 0, length: 3)
        let applied = storage.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertNotNil(applied)

        let stale = CodeSyntaxHighlighter.lex(
            text: document.source,
            language: document.language,
            revision: document.revision + 10
        )
        controller.applyHighlight(stale)
        let after = storage.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(applied, after)
        _ = keywordRange
    }
}
