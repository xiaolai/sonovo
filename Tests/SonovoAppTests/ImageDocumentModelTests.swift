import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Sonovo

@MainActor
final class ImageDocumentModelTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        files = []
        super.tearDown()
    }

    func testLoadsPNGAndReportsMetadata() async throws {
        let url = try makeImage(
            width: 640,
            height: 480,
            type: .png,
            extension: "png"
        )
        let model = ImageDocumentModel(url: url)
        await model.load()

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.metadata?.pixelWidth, 640)
        XCTAssertEqual(model.metadata?.pixelHeight, 480)
        XCTAssertFalse(model.isDownsampled)
        XCTAssertNotNil(model.image)
    }

    func testReloadPicksUpReplacedPixels() async throws {
        let url = try makeImage(
            width: 100,
            height: 50,
            type: .png,
            extension: "png"
        )
        let replacement = try makeImage(
            width: 300,
            height: 200,
            type: .png,
            extension: "png"
        )
        let model = ImageDocumentModel(url: url)
        await model.load()
        XCTAssertEqual(model.metadata?.pixelWidth, 100)

        try Data(contentsOf: replacement).write(to: url)
        await model.reload()

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.metadata?.pixelWidth, 300)
        XCTAssertEqual(model.metadata?.pixelHeight, 200)
    }

    func testLoadsTIFF() async throws {
        let url = try makeImage(
            width: 320,
            height: 200,
            type: .tiff,
            extension: "tiff"
        )
        let model = ImageDocumentModel(url: url)
        await model.load()
        XCTAssertEqual(model.state, .ready)
        XCTAssertNotNil(model.image)
    }

    func testLoadsHEIC() async throws {
        let url = try makeImage(
            width: 320,
            height: 200,
            type: .heic,
            extension: "heic"
        )
        let model = ImageDocumentModel(url: url)
        await model.load()
        XCTAssertEqual(model.state, .ready)
        XCTAssertNotNil(model.image)
    }

    func testLoadsWebP() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoImage-\(UUID().uuidString).webp"
            )
        files.append(url)
        try Data(base64Encoded: webpFixture)!.write(to: url)

        let model = ImageDocumentModel(url: url)
        await model.load()
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.metadata?.pixelWidth, 640)
        XCTAssertEqual(model.metadata?.pixelHeight, 480)
    }

    func testReadsEXIFSummary() async throws {
        let url = try makeEXIFJPEG()
        let model = ImageDocumentModel(url: url)
        await model.load()

        XCTAssertEqual(
            model.metadata?.exifSummary,
            "Sonovo Test Camera · 1/250s · f/2.8 · ISO 100 · 50 mm"
        )
    }

    func testAppliesEXIFOrientationToTheDisplayedImage() async throws {
        let url = try makeOrientedJPEG(
            width: 640,
            height: 480,
            orientation: 6
        )
        let model = ImageDocumentModel(url: url)
        await model.load()

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.metadata?.orientation, 6)
        // Stored dimensions stay raw; the decoded image is rotated.
        XCTAssertEqual(model.metadata?.pixelWidth, 640)
        XCTAssertEqual(model.metadata?.pixelHeight, 480)
        XCTAssertEqual(model.image?.size, NSSize(width: 480, height: 640))
    }

    func testDownsamplePolicyForLargeImages() {
        let large = ImageDocumentModel.displayPolicy(
            width: 10_000,
            height: 10_000
        )
        XCTAssertTrue(large.downsampled)
        XCTAssertEqual(
            large.maxPixel,
            ImageDocumentModel.previewDimension
        )

        let normal = ImageDocumentModel.displayPolicy(
            width: 640,
            height: 480
        )
        XCTAssertFalse(normal.downsampled)
        XCTAssertEqual(normal.maxPixel, 640)
    }

    func testUnsupportedImageFailsWithANamedState() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SonovoBad-\(UUID().uuidString).avif")
        files.append(url)
        try Data("not an image".utf8).write(to: url)

        let model = ImageDocumentModel(url: url)
        await model.load()
        guard case .failed(let message) = model.state else {
            return XCTFail("Expected a failure, got \(model.state)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - Helpers

    private func makeImage(
        width: Int,
        height: Int,
        type: UTType,
        extension fileExtension: String
    ) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageTestError.context
        }
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw ImageTestError.image
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoImage-\(UUID().uuidString).\(fileExtension)"
            )
        files.append(url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageTestError.destination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageTestError.finalize
        }
        return url
    }

    private func makeOrientedJPEG(
        width: Int,
        height: Int,
        orientation: Int
    ) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageTestError.context
        }
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw ImageTestError.image
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoImage-\(UUID().uuidString).jpg"
            )
        files.append(url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageTestError.destination
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ImageTestError.finalize
        }
        return url
    }

    private func makeEXIFJPEG() throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 64,
            height: 48,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageTestError.context
        }
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        guard let image = context.makeImage() else {
            throw ImageTestError.image
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SonovoImage-\(UUID().uuidString).jpg"
            )
        files.append(url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageTestError.destination
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Sonovo",
                kCGImagePropertyTIFFModel: "Test Camera"
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [100],
                kCGImagePropertyExifFocalLength: 50.0
            ]
        ]
        CGImageDestinationAddImage(
            destination,
            image,
            properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ImageTestError.finalize
        }
        return url
    }

    /// A 640×480 solid WebP. ImageIO decodes WebP on macOS 27 but has no
    /// public encoder, so the fixture is embedded rather than generated.
    private let webpFixture =
        "UklGRqgCAABXRUJQVlA4IJwCAACQRACdASqAAuABPpFIoU0lpCMiIAgAsBIJaW7hd2Ee3AAAE94J"
        + "yHvtk5D32ych77ZOQ99snIe+2TkPfbJyHvtk5D32ych77ZOQ99snIe+2TkPfbJyHvtlAy8XJyHvt"
        + "k5D32ych77ZOQ+A/S7Xi5OQ99snIe+2TkPfbJziIuTkPfbJyHvtk5D32ych78AQD32ych77ZOQ99"
        + "snIe+2Tkf88nIe+2TkPfbJyHvtk5D325l+ntk5D32ych77ZOQ99snIiB5OQ99snIe+2TkPfbJyHv"
        + "tmMtPbJyHvtk5D32ych77ZOQ+hfS7Xi5OQ99snIe+2TkPfbKBl4uTkPfbJyHvtk5D32ych8B+l2v"
        + "Fych77ZOQ99snIe+2TnERcnIe+2TkPfbJyHvtk5D34AgHvtk5D32ych77ZOQ99snI/55OQ99snIe"
        + "+2TkPfbJyHvtzL9PbJyHvtk5D32ych77ZOREDych77ZOQ99snIe+2TkPfbMZae2TkPfbJyHvtk5D"
        + "32ych9C+l2vFych77ZOQ99snIe+2UDLxcnIe+2TkPfbJyHvtk5D4D9LteLk5D32ych77ZOQ99snO"
        + "Ii5OQ99snIe+2TkPfbJyHvwBAPfbJyHvtk5D32ych77ZOR/zych77ZOQ99snIe+2TkPfbmX6e2Tk"
        + "PfbJyHvtk5D32yciIHk5D32ych77ZOQ99snIe+2Yy09snIe+2TkPfbJyHvtk5D6F9LteLk5D32yc"
        + "h77ZOQ99YAD+/6/rn//sWctgXj///ucD/ucD/ucD+NuKxkpxgXR7U4SBEggEaSASVQCSqASVQCSq"
        + "ASVQCSqASVQCSqASVQCSqASVQCSqASVQCSqASVQCSqASVQCSqASVQCSqASVQCSqASVQCSqASVQCS"
        + "qAQAAA=="
}

private enum ImageTestError: Error {
    case context
    case image
    case destination
    case finalize
}
