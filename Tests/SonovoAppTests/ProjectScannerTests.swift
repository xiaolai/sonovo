import Foundation
import SonovoCore
import XCTest
@testable import Sonovo

final class ProjectScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoScannerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        super.tearDown()
    }

    func testMapsViewableExtensionsAndGroups() throws {
        try write("script.md", "text")
        try write("brief.pdf", "pdf")
        try write("captions.srt", "srt")
        try write("voice.wav", "wav")
        try write("take.mp4", "mp4")
        try write("still.png", "png")
        try write("model.glb", "glb")
        try write("page.html", "html")
        try write("delivery.zip", "zip")
        try write("notes.bin", "binary")

        let result = ProjectScanner().scan(root: root)
        let byName = Dictionary(
            uniqueKeysWithValues: result.assets.map { ($0.name, $0.kind) }
        )
        XCTAssertEqual(byName["script.md"], .script)
        XCTAssertEqual(byName["brief.pdf"], .document)
        XCTAssertEqual(byName["captions.srt"], .subtitle)
        XCTAssertEqual(byName["voice.wav"], .audio)
        XCTAssertEqual(byName["take.mp4"], .video)
        XCTAssertEqual(byName["still.png"], .image)
        XCTAssertEqual(byName["model.glb"], .model3d)
        XCTAssertEqual(byName["page.html"], .html)
        XCTAssertEqual(byName["delivery.zip"], .archive)
        XCTAssertNil(byName["notes.bin"])
        XCTAssertEqual(
            result.groups.map(\.title),
            ["Documents", "Subtitles", "Audio", "Video", "Images", "3D", "Web", "Archives"]
        )
        XCTAssertFalse(result.truncated)
    }

    func testIgnoresHiddenFilesAndCacheDirectories() throws {
        try write("visible.md", "text")
        try write(".hidden.md", "hidden")
        try write("node_modules/package.md", "cache")
        try write("DerivedData/cache.png", "cache")
        try write(".git/config.md", "git")
        try write(".build/object.md", "build")

        let names = Set(
            ProjectScanner().scan(root: root).assets.map(\.name)
        )
        XCTAssertEqual(names, ["visible.md"])
    }

    func testDirectorySymlinksAreNotFollowedAndFileSymlinksStayContained() throws {
        let outer = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoScannerOutside-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: outer,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outer) }

        try write("real/inside.md", "inside")
        try write("notes.md", "notes")
        try write("outside.md", "outside", in: outer)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.md"),
            withDestinationURL: root.appendingPathComponent("real/inside.md")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.md"),
            withDestinationURL: outer.appendingPathComponent("outside.md")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape-folder"),
            withDestinationURL: outer
        )

        let result = ProjectScanner().scan(root: root)
        let ids = result.assets.map(\.id)
        XCTAssertEqual(
            Set(ids).count,
            ids.count,
            "A file reachable by two paths must be indexed once"
        )
        XCTAssertEqual(
            result.assets.filter { $0.id.hasSuffix("/real/inside.md") }.count,
            1
        )
        XCTAssertTrue(result.assets.contains { $0.name == "notes.md" })
        XCTAssertFalse(
            result.assets.contains {
                ["escape.md", "escape-folder", "outside.md"].contains($0.name)
            }
        )
    }

    func testCapsStopTraversalAndReportTruncation() throws {
        for index in 0..<20 {
            try write("file-\(index).md", "text")
        }
        var scanner = ProjectScanner()
        scanner.limits = .init(
            maximumDepth: 12,
            maximumAssets: 3,
            maximumVisitedEntries: 200_000
        )
        let result = scanner.scan(root: root)
        XCTAssertEqual(result.assets.count, 3)
        XCTAssertTrue(result.truncated)
    }

    func testVisitedCapBoundsAnUnsupportedTree() throws {
        for index in 0..<200 {
            try write("junk-\(index).bin", "binary")
        }
        var scanner = ProjectScanner()
        scanner.limits = .init(
            maximumDepth: 12,
            maximumAssets: 20_000,
            maximumVisitedEntries: 50
        )
        let result = scanner.scan(root: root)
        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.visitedEntries, 51)
    }

    func testUnreadableDirectoryMarksTheScanPartial() throws {
        try write("readable.md", "text")
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: locked,
            withIntermediateDirectories: true
        )
        try write("locked/inside.md", "text")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: locked.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: locked.path
            )
        }

        let result = ProjectScanner().scan(root: root)
        XCTAssertTrue(
            result.isPartial,
            "A directory that could not be read must be reported"
        )
        XCTAssertTrue(
            result.assets.contains { $0.name == "readable.md" },
            "Readable entries still appear in a partial scan"
        )
    }

    func testRevisionChangesWhenContentChanges() throws {
        let file = try write("script.md", "one")
        let first = ProjectScanner().scan(root: root).assets
        try Data("a much longer body".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: file.path
        )

        let second = ProjectScanner().scan(root: root).assets
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(first[0].revision, second[0].revision)
        XCTAssertEqual(first[0].id, second[0].id)
    }

    func testRootItselfIsCanonicalized() throws {
        let canonical = MarkdownSecurity.canonical(root)
        let result = ProjectScanner().scan(root: root)
        XCTAssertEqual(result.root, canonical)
        XCTAssertEqual(
            ProjectScanner.kind(forExtension: "GLB"),
            .model3d
        )
        XCTAssertEqual(
            ProjectScanner.kind(forExtension: "PDF"),
            .document
        )
    }

    // MARK: - Helpers

    @discardableResult
    private func write(
        _ relativePath: String,
        _ contents: String,
        in directory: URL? = nil
    ) throws -> URL {
        let base = directory ?? root!
        let url = base.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }
}
