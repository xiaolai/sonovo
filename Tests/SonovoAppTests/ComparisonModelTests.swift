import AppKit
import XCTest
@testable import Sonovo

@MainActor
final class ComparisonModelTests: XCTestCase {
    func testFitScaleFitsTheLargerImageAtOneSharedScale() {
        let fit = ComparisonModel.fitScale(
            leading: CGSize(width: 800, height: 400),
            trailing: CGSize(width: 400, height: 400),
            in: CGSize(width: 400, height: 300)
        )
        XCTAssertEqual(fit, 0.5, accuracy: 0.0001)
    }

    func testFitScaleUsesOnlyTheAvailableSide() {
        XCTAssertEqual(
            ComparisonModel.fitScale(
                leading: nil,
                trailing: CGSize(width: 400, height: 200),
                in: CGSize(width: 400, height: 300)
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ComparisonModel.fitScale(
                leading: nil,
                trailing: nil,
                in: CGSize(width: 400, height: 300)
            ),
            0
        )
    }

    func testWipeFractionClampsAndClipsTheTrailingSide() {
        let model = makeModel()
        model.setWipe(fraction: -1)
        XCTAssertEqual(
            model.wipeFraction,
            ComparisonModel.minimumWipeFraction
        )
        model.setWipe(fraction: 2)
        XCTAssertEqual(
            model.wipeFraction,
            ComparisonModel.maximumWipeFraction
        )
        model.setWipe(fraction: 0.25)

        XCTAssertEqual(
            ComparisonModel.dividerX(in: 1000, fraction: 0.25),
            250,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ComparisonModel.wipeClipRect(
                in: CGSize(width: 1000, height: 500),
                fraction: 0.25
            ),
            CGRect(x: 250, y: 0, width: 750, height: 500)
        )
    }

    func testActualSizeZoom() {
        XCTAssertEqual(
            ComparisonModel.actualSizeZoom(fit: 0.5, displayScale: 2),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ComparisonModel.actualSizeZoom(fit: 0, displayScale: 2),
            1
        )
        // A tiny image fitted large needs a zoom below the gesture minimum
        // to be genuinely 1:1; actual size must not be clamped.
        XCTAssertEqual(
            ComparisonModel.actualSizeZoom(fit: 20, displayScale: 2),
            0.025,
            accuracy: 0.0001
        )
    }

    func testAlignmentMovesOnlyTheTrailingImage() {
        let model = makeModel()
        model.pan = CGSize(width: 3, height: 4)
        model.alignment = CGSize(width: 10, height: -5)

        XCTAssertEqual(
            model.offset(for: .leading),
            CGSize(width: 3, height: 4)
        )
        XCTAssertEqual(
            model.offset(for: .trailing),
            CGSize(width: 13, height: -1)
        )
    }

    func testActualSizeRequiresBothSidesAtFullResolution() {
        XCTAssertTrue(
            ComparisonModel.canUseActualSize(
                leadingReady: true,
                trailingReady: true,
                leadingDownsampled: false,
                trailingDownsampled: false
            )
        )
        XCTAssertFalse(
            ComparisonModel.canUseActualSize(
                leadingReady: true,
                trailingReady: true,
                leadingDownsampled: false,
                trailingDownsampled: true
            )
        )
        XCTAssertFalse(
            ComparisonModel.canUseActualSize(
                leadingReady: true,
                trailingReady: false,
                leadingDownsampled: false,
                trailingDownsampled: false
            )
        )
    }

    func testMetadataRowsReportDifferences() {
        let leading = ImageDocumentMetadata(
            pixelWidth: 4096,
            pixelHeight: 2160,
            colorModel: "RGB",
            profileName: "sRGB IEC61966-2.1",
            dpiWidth: 72,
            dpiHeight: 72,
            orientation: 1,
            exifSummary: nil,
            fileSize: 1_000
        )
        let trailing = ImageDocumentMetadata(
            pixelWidth: 4096,
            pixelHeight: 2160,
            colorModel: "RGB",
            profileName: "Display P3",
            dpiWidth: 72,
            dpiHeight: 72,
            orientation: 1,
            exifSummary: nil,
            fileSize: 2_000
        )

        let rows = ComparisonModel.metadataRows(
            leading: leading,
            trailing: trailing,
            leadingFallbackSize: 0,
            trailingFallbackSize: 0
        )
        XCTAssertEqual(rows.map(\.label), [
            "Dimensions", "Color profile", "File size"
        ])
        XCTAssertFalse(rows[0].differs)
        XCTAssertTrue(rows[1].differs)
        XCTAssertTrue(rows[2].differs)
        XCTAssertEqual(rows[0].leading, "4096×2160")
        XCTAssertEqual(rows[1].trailing, "Display P3")
    }

    func testMissingSideShowsADashAndDoesNotInventNumbers() {
        let rows = ComparisonModel.metadataRows(
            leading: nil,
            trailing: nil,
            leadingFallbackSize: 0,
            trailingFallbackSize: 0
        )
        XCTAssertEqual(rows.map(\.leading), ["—", "—", "Zero KB"])
        XCTAssertEqual(rows.map(\.trailing), ["—", "—", "Zero KB"])
        XCTAssertFalse(rows.contains { $0.differs })
    }

    func testDisplayDimensionsReportAnOrientationDifference() {
        let metadata = ImageDocumentMetadata(
            pixelWidth: 640,
            pixelHeight: 480,
            colorModel: "RGB",
            profileName: "sRGB",
            dpiWidth: 72,
            dpiHeight: 72,
            orientation: 1,
            exifSummary: nil,
            fileSize: 1_000
        )
        let rotated = ImageDocumentMetadata(
            pixelWidth: 640,
            pixelHeight: 480,
            colorModel: "RGB",
            profileName: "sRGB",
            dpiWidth: 72,
            dpiHeight: 72,
            orientation: 6,
            exifSummary: nil,
            fileSize: 1_000
        )
        let rows = ComparisonModel.metadataRows(
            leading: metadata,
            trailing: rotated,
            leadingFallbackSize: 0,
            trailingFallbackSize: 0
        )
        XCTAssertTrue(rows[0].differs)
        XCTAssertEqual(rows[0].leading, "640×480")
        XCTAssertEqual(rows[0].trailing, "480×640")
    }

    func testFitResetsZoomAndPan() {
        let model = makeModel()
        model.pan = CGSize(width: 40, height: 20)
        model.zoom = 3

        model.fit()
        XCTAssertEqual(model.zoom, 1)
        XCTAssertEqual(model.pan, .zero)
    }

    // MARK: - Helpers

    private func makeModel() -> ComparisonModel {
        ComparisonModel(
            leading: makeAsset(name: "a.png"),
            trailing: makeAsset(name: "b.png")
        )
    }

    private func makeAsset(name: String) -> ProjectAsset {
        ProjectAsset(
            id: name,
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            relativePath: name,
            kind: .image,
            size: 0,
            modified: nil,
            revision: .empty
        )
    }
}
