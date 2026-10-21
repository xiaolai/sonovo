import Foundation
import XCTest
@testable import Sonovo

@MainActor
final class QuickLookSupportTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        files = []
        super.tearDown()
    }

    func testSystemPreviewIsDetectedAndIconsAreRejected() async throws {
        let text = try makeFile(name: "sample.txt", contents: "Hello")
        let unknown = try makeFile(
            name: "sample.xyz",
            contents: "unknown provider"
        )

        let textPreview = await QuickLookSupport.canPreview(text)
        let unknownPreview = await QuickLookSupport.canPreview(unknown)
        XCTAssertTrue(textPreview, "macOS has a text previewer")
        XCTAssertFalse(
            unknownPreview,
            "An icon representation is not a preview"
        )
    }

    func testThumbnailProviderSkipsIcons() async throws {
        let text = try makeFile(name: "thumb.txt", contents: "Hello")
        let unknown = try makeFile(
            name: "thumb.xyz",
            contents: "unknown provider"
        )

        let textThumbnail = await ThumbnailProvider.shared.thumbnail(
            for: text,
            size: CGSize(width: 32, height: 32)
        )
        let unknownThumbnail = await ThumbnailProvider.shared.thumbnail(
            for: unknown,
            size: CGSize(width: 32, height: 32)
        )
        XCTAssertNotNil(textThumbnail)
        XCTAssertNil(unknownThumbnail)
    }

    private func makeFile(name: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoQuickLook-\(UUID().uuidString)-\(name)"
            )
        try Data(contents.utf8).write(to: url)
        files.append(url)
        return url
    }
}
