import Foundation
import Testing
import ReferenceAst
@testable import SonovoCore

@Suite("Reference AST oracle")
struct ReferenceAstTests {
    @Test("Emits a sorted semantic projection for a heading and paragraph")
    func headingAndParagraph() throws {
        let data = try ReferenceAst.projection(for: "# Title\n\nHello\n")
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let children = try #require(json["children"] as? [[String: Any]])
        #expect(children.count == 1)

        let document = children[0]
        #expect(document["kind"] as? String == "document")

        let blocks = try #require(document["children"] as? [[String: Any]])
        #expect(blocks.map { $0["kind"] as? String } == ["heading", "paragraph"])
        #expect(blocks[0]["headingLevel"] as? Int == 1)
        #expect(blocks[0]["startUtf16"] as? Int == 0)
        #expect(blocks[0]["endUtf16"] as? Int == 7)
        #expect(blocks[1]["startUtf16"] as? Int == 9)
    }

    @Test("Maps multibyte columns to UTF-16 offsets")
    func multibyteColumns() throws {
        let source = "é😀 [link](https://example.com)\n"
        let data = try ReferenceAst.projection(for: source)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let document = (json["children"] as! [[String: Any]])[0]
        let paragraph = (document["children"] as! [[String: Any]])[0]
        let link = (paragraph["children"] as! [[String: Any]])
            .first { $0["kind"] as? String == "link" }
        let resolved = try #require(link)
        #expect(resolved["destination"] as? String == "https://example.com")

        // "é" is 2 UTF-8 bytes / 1 UTF-16 unit; "😀" is 4 bytes / 2 units.
        // The link starts after "é😀 " = 4 UTF-16 units.
        #expect(resolved["startUtf16"] as? Int == 4)
    }

    @Test("Attaches GFM table, task list, strikethrough, and autolink")
    func gfmExtensions() throws {
        let source = """
        | a | b |
        |:--|--:|
        | 1 | 2 |

        - [x] done

        ~~gone~~ and www.example.com
        """
        let data = try ReferenceAst.projection(for: source)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"table\""))
        #expect(text.contains("\"tasklist\""))
        #expect(text.contains("\"taskChecked\" : true"))
        #expect(text.contains("\"strikethrough\""))
        #expect(text.contains("\"destination\" : \"http://www.example.com\""))
    }
}
