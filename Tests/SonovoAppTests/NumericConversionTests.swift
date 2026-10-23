import SonovoCore
import XCTest
@testable import Sonovo

final class NumericConversionTests: XCTestCase {
    func testIntRejectsNonFiniteAndOutOfRange() {
        XCTAssertNil(NumericConversion.int(Double.infinity))
        XCTAssertNil(NumericConversion.int(Double.nan))
        XCTAssertNil(NumericConversion.int(1e300))
        XCTAssertEqual(NumericConversion.int(2.4), 2)
        XCTAssertEqual(NumericConversion.int(2.6), 3)
    }

    func testFloorAndCeilRejectNonFinite() {
        XCTAssertNil(NumericConversion.floor(.nan))
        XCTAssertNil(NumericConversion.floor(.infinity))
        XCTAssertNil(NumericConversion.ceil(.infinity))
        XCTAssertEqual(NumericConversion.floor(2.9), 2)
        XCTAssertEqual(NumericConversion.ceil(2.1), 3)
    }

    func testClampedSaturatesAndNeverTraps() {
        // `Double(Int.max)` is 2^63, which `Int(_:)` cannot represent; the
        // clamp must return the bound, not trap.
        XCTAssertEqual(
            NumericConversion.clamped(.infinity, to: 0...100),
            100
        )
        XCTAssertEqual(
            NumericConversion.clamped(Double(Int.max), to: 0...Int.max),
            Int.max
        )
        XCTAssertEqual(NumericConversion.clamped(.nan, to: 0...100), 0)
        XCTAssertEqual(
            NumericConversion.clamped(-.infinity, to: 0...100),
            0
        )
        XCTAssertEqual(NumericConversion.clamped(50.4, to: 0...100), 50)
    }

    func testMillisecondsSaturates() {
        XCTAssertEqual(NumericConversion.milliseconds(.infinity), 0)
        XCTAssertEqual(NumericConversion.milliseconds(-1), 0)
        XCTAssertEqual(NumericConversion.milliseconds(1.5), 1500)
        XCTAssertEqual(NumericConversion.milliseconds(1e300), Int.max)
    }

    func testCodeEditorSettingsClampTabWidthOnEveryPath() {
        let range = AppTheme.Code.tabWidthRange
        XCTAssertEqual(
            CodeEditorSettings(tabWidth: 0).tabWidth,
            range.lowerBound
        )
        XCTAssertEqual(
            CodeEditorSettings(tabWidth: 1_000).tabWidth,
            range.upperBound
        )
        var settings = CodeEditorSettings()
        settings.tabWidth = -5
        XCTAssertEqual(settings.tabWidth, range.lowerBound)
    }

    func testTabWidthIsClamped() {
        XCTAssertEqual(
            AppTheme.Code.clampedTabWidth(Int.max),
            AppTheme.Code.tabWidthRange.upperBound
        )
        XCTAssertEqual(
            AppTheme.Code.clampedTabWidth(Int.min),
            AppTheme.Code.tabWidthRange.lowerBound
        )
        XCTAssertEqual(
            AppTheme.Code.clampedTabWidth(AppTheme.Code.tabWidthDefault),
            AppTheme.Code.tabWidthDefault
        )
    }

    func testEditorFontSizeIsClamped() {
        let range = AppTheme.Preferences.editorFontSizeRange
        XCTAssertEqual(
            Preferences.clampedEditorFontSize(1e300),
            CGFloat(range.upperBound)
        )
        XCTAssertEqual(
            Preferences.clampedEditorFontSize(.infinity),
            AppTheme.Reading.sourceSize
        )
        XCTAssertEqual(
            Preferences.clampedEditorFontSize(-1),
            AppTheme.Reading.sourceSize
        )
        XCTAssertEqual(
            Preferences.clampedEditorFontSize(1),
            CGFloat(range.lowerBound)
        )
    }
}
