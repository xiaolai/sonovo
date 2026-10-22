import Foundation
import Testing
@testable import SonovoCore

@Suite("DebugToc")
struct DebugTocTests {
    @Test func smoke() throws {
        let source = """
        [TOC]

        # Title

        ## Section
        """
        let parsed = MarkdownParser.parseCanonical(source)
        let ast = MarkdownSyntaxAugmenter().augment(parsed)

        #expect(
            ast.blocks.contains {
                if case .tableOfContents = $0 { return true }
                return false
            }
        )
        let rows = HeadingIndex(ast: ast).rows
        #expect(rows.map(\.text) == ["Title", "Section"])
        #expect(rows.map(\.level) == [1, 2])
    }
}
