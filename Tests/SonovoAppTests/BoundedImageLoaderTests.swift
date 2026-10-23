import AppKit
import XCTest
@testable import Sonovo

final class BoundedImageLoaderTests: XCTestCase {
    func testRoundTripsASmallPNG() throws {
        let representation = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2,
                pixelsHigh: 2,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let png = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )
        XCTAssertNotNil(BoundedImageLoader.image(from: png))
        XCTAssertNotNil(BoundedImageLoader.pngData(from: png))
    }

    func testRejectsOversizedData() {
        let oversized = Data(
            repeating: 0,
            count: MediaLimits.maxImageBytes + 1
        )
        XCTAssertNil(BoundedImageLoader.image(from: oversized))
        XCTAssertNil(BoundedImageLoader.pngData(from: oversized))
    }

    func testRejectsOversizedFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SonovoLarge-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(
            atOffset: UInt64(MediaLimits.maxImageBytes + 1)
        )
        try handle.close()

        XCTAssertNil(BoundedImageLoader.image(at: url))
        XCTAssertNil(BoundedImageLoader.pngData(at: url))
    }
}
