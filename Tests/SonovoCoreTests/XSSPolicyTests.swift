import Foundation
import Testing
@testable import SonovoCore

/// Runs the vendored markdown-it XSS corpus through the parser and asserts the
/// security policy outcomes. No raw HTML is ever rendered.
@Suite("XSS policy corpus")
struct XSSPolicyTests {
    private func corpus() throws -> String {
        let root = try #require(
            Bundle.module.url(forResource: "Fixtures", withExtension: nil)
        )
        return try String(
            contentsOf: root.appendingPathComponent("xss/xss.txt"),
            encoding: .utf8
        )
    }

    @Test("Every raw HTML node is hidden")
    func rawHTMLIsHidden() throws {
        let parsed = MarkdownParser.parseCanonical(try corpus())
        let ast = MarkdownSyntaxAugmenter().augment(parsed)

        var htmlCount = 0
        func walkInlines(_ inlines: [Inline]) {
            for inline in inlines {
                switch inline {
                case let .inlineHTML(raw, _):
                    htmlCount += 1
                    #expect(MarkdownSecurity.htmlDisposition(for: raw) == .hidden)
                case let .emphasis(children, _),
                     let .strong(children, _),
                     let .strikethrough(children, _):
                    walkInlines(children)
                case let .link(_, _, children, _):
                    walkInlines(children)
                default:
                    continue
                }
            }
        }
        func walk(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case let .htmlBlock(raw, _):
                    htmlCount += 1
                    #expect(MarkdownSecurity.htmlDisposition(for: raw) == .hidden)
                case let .blockQuote(children, _):
                    walk(children)
                case let .list(list, _):
                    for item in list.items { walk(item.blocks) }
                case let .details(details, _):
                    walk(details.blocks)
                    walkInlines(details.summary)
                case let .paragraph(inlines, _):
                    walkInlines(inlines)
                case let .heading(_, inlines, _):
                    walkInlines(inlines)
                case let .table(table, _):
                    for cell in table.header { walkInlines(cell.inlines) }
                    for row in table.rows {
                        for cell in row { walkInlines(cell.inlines) }
                    }
                default:
                    continue
                }
            }
        }
        walk(ast.blocks)
        #expect(htmlCount > 0, "the corpus should contain raw HTML")
    }

    @Test("Dangerous link schemes are always denied")
    func dangerousSchemes() throws {
        let parsed = MarkdownParser.parseCanonical(try corpus())
        let ast = MarkdownSyntaxAugmenter().augment(parsed)

        func check(_ inlines: [Inline]) {
            for inline in inlines {
                switch inline {
                case let .link(destination, _, children, _),
                     let .image(destination, _, children, _):
                    let decision = MarkdownSecurity.linkDecision(for: destination)
                    let lowered = destination.lowercased()
                    for scheme in MarkdownSecurity.deniedSchemes {
                        if lowered.hasPrefix(scheme + ":") {
                            #expect(!decision.isAllowed, "allowed \(destination)")
                        }
                    }
                    check(children)
                case let .emphasis(children, _),
                     let .strong(children, _),
                     let .strikethrough(children, _):
                    check(children)
                default:
                    continue
                }
            }
        }

        func walk(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case let .paragraph(inlines, _), let .heading(_, inlines, _):
                    check(inlines)
                case let .blockQuote(children, _):
                    walk(children)
                case let .list(list, _):
                    for item in list.items { walk(item.blocks) }
                case let .details(details, _):
                    check(details.summary)
                    walk(details.blocks)
                case let .table(table, _):
                    for cell in table.header { check(cell.inlines) }
                    for row in table.rows {
                        for cell in row { check(cell.inlines) }
                    }
                default:
                    continue
                }
            }
        }
        walk(ast.blocks)
    }

    @Test("Representative XSS vectors are denied")
    func vectors() {
        let vectors = [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "file:///etc/passwd",
            "blob:https://example.com/id",
            "vbscript:msgbox(1)"
        ]
        for vector in vectors {
            #expect(!MarkdownSecurity.linkDecision(for: vector).isAllowed)
        }

        for raw in [
            "<img src=x onerror=alert(1)>",
            "<script>alert(1)</script>",
            "<!-- --><svg onload=alert(1)>",
            "<a href=\"javascript:alert(1)\">x</a>"
        ] {
            #expect(MarkdownSecurity.htmlDisposition(for: raw) == .hidden)
        }
    }
}
