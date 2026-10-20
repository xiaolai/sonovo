import Foundation
import Testing
@testable import SonovoCore

@Suite("DebugToc")
struct DebugTocTests {
    @Test func smoke() throws {
        let source = try String(contentsOfFile: "/tmp/sonovo-smoke.md", encoding: .utf8)
        let parsed = MarkdownParser.parseCanonical(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)
        for block in ast.blocks {
            switch block {
            case .tableOfContents(let range):
                print("TOC", String(describing: range))
            case let .paragraph(_, range):
                print("P", String(describing: range))
            case let .heading(level, inlines, range):
                print("H\(level)", HeadingIndex.renderedText(inlines), String(describing: range))
            default:
                print("OTHER", block)
            }
        }
        print("ROWS", HeadingIndex(ast: ast).rows.map(\.text))
    }
}
