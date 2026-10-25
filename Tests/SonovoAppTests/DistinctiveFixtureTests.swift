import AppKit
import AVFoundation
import CoreMedia
import XCTest
@testable import Sonovo

final class DistinctiveFixtureTests: XCTestCase {
    func testAdjacentFilmstripTimesProduceDifferentPictures() async throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "distinctive",
                withExtension: "mov",
                subdirectory: "Fixtures"
            )
        )
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let early = try await generator.image(
            at: CMTime(seconds: 0.2, preferredTimescale: 600_000)
        ).image
        let late = try await generator.image(
            at: CMTime(seconds: 2.6, preferredTimescale: 600_000)
        ).image
        let earlyData = try pngData(early)
        let lateData = try pngData(late)
        XCTAssertNotEqual(
            earlyData,
            lateData,
            "the fixture must make adjacent filmstrip frames visually distinct"
        )
    }

    private func pngData(_ image: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        return try XCTUnwrap(
            rep.representation(using: .png, properties: [:])
        )
    }
}
