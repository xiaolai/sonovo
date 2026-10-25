import XCTest
@testable import Sonovo

final class ProjectFileTreeTests: XCTestCase {
    func testFoldersComeFirstAndNestedPathsStayDistinct() {
        let nodes = ProjectFileTree.nodes(from: [
            asset("readme", path: "readme.md", kind: .document),
            asset("shot-a", path: "a/shots/one.png", kind: .image),
            asset("shot-b", path: "b/shots/two.png", kind: .image),
            asset("take", path: "audio/vo/take.wav", kind: .audio),
        ])

        XCTAssertEqual(nodes.map(\.name), ["a", "audio", "b", "readme.md"])

        let a = nodes[0]
        let b = nodes[2]
        XCTAssertEqual(a.children?.first?.name, "shots")
        XCTAssertEqual(b.children?.first?.name, "shots")
        XCTAssertNotEqual(
            a.children?.first?.id,
            b.children?.first?.id
        )
    }

    func testFilterKeepsAncestorsAndRevealsTheirFolderTitles() throws {
        let nodes = ProjectFileTree.nodes(from: [
            asset("readme", path: "readme.md", kind: .document),
            asset("take", path: "audio/vo/take.wav", kind: .audio),
        ])

        let filtered = FileNode.filtered(nodes, query: "take")
        let audio = try XCTUnwrap(filtered.first)
        let voice = try XCTUnwrap(audio.children?.first)

        XCTAssertEqual(filtered.map(\.name), ["audio"])
        XCTAssertEqual(audio.children?.map(\.name), ["vo"])
        XCTAssertEqual(voice.children?.map(\.name), ["take.wav"])
        XCTAssertEqual(voice.children?.first?.assetID, "take")
    }

    private func asset(
        _ id: String,
        path: String,
        kind: AssetKind
    ) -> ProjectAsset {
        ProjectAsset(
            id: id,
            url: URL(fileURLWithPath: "/tmp/project/\(path)"),
            name: (path as NSString).lastPathComponent,
            relativePath: path,
            kind: kind,
            size: 0,
            modified: nil,
            revision: .empty
        )
    }
}
