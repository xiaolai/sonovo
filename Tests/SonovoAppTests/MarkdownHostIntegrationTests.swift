import Foundation
import XCTest
import SonovoWorkspaceHost
import SonovoMarkdownFeature
@testable import Sonovo

@MainActor final class MarkdownHostIntegrationTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testProjectHostedViewSuppressesTheNestedFileBrowser() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(
            MarkdownFeature.projectView(workspace: MarkdownWorkspace(), project: Project(folderURL: root))
                .showsFileBrowser,
            "a project-hosted markdown view must not duplicate the navigator"
        )
        XCTAssertTrue(
            MarkdownWorkspaceView(workspace: MarkdownWorkspace())
                .showsFileBrowser,
            "the standalone workspace still needs its file list"
        )
    }
}
