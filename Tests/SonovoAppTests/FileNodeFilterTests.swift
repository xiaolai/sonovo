import XCTest
@testable import Sonovo

final class FileNodeFilterTests: XCTestCase {
    private let tree = [
        FileNode(
            id: "scripts",
            name: "Scripts",
            icon: "folder",
            assetID: nil,
            children: [
                FileNode(
                    id: "alpha",
                    name: "alpha.md",
                    icon: "doc",
                    assetID: "alpha",
                    children: nil
                ),
                FileNode(
                    id: "beta",
                    name: "beta.md",
                    icon: "doc",
                    assetID: "beta",
                    children: nil
                ),
            ]
        ),
        FileNode(
            id: "stills",
            name: "Stills",
            icon: "folder",
            assetID: nil,
            children: [
                FileNode(
                    id: "harbor",
                    name: "harbor.png",
                    icon: "photo",
                    assetID: "harbor",
                    children: nil
                )
            ]
        ),
    ]

    func testEmptyQueryReturnsTheWholeTree() {
        XCTAssertEqual(
            FileNode.filtered(tree, query: "").map(\.id),
            ["scripts", "stills"]
        )
    }

    func testFileMatchKeepsItsAncestors() throws {
        let result = FileNode.filtered(tree, query: "alpha")
        let scripts = try XCTUnwrap(result.first)
        XCTAssertEqual(result.map(\.id), ["scripts"])
        XCTAssertEqual(scripts.children?.map(\.id), ["alpha"])
    }

    func testFolderMatchKeepsItsSubtree() throws {
        let result = FileNode.filtered(tree, query: "stills")
        let stills = try XCTUnwrap(result.first)
        XCTAssertEqual(result.map(\.id), ["stills"])
        XCTAssertEqual(stills.children?.map(\.id), ["harbor"])
    }

    func testQueryTrimsWhitespaceAndNoMatchIsEmpty() {
        XCTAssertEqual(
            FileNode.filtered(tree, query: "  alpha  ").map(\.id),
            ["scripts"]
        )
        XCTAssertTrue(FileNode.filtered(tree, query: "missing").isEmpty)
    }
}
