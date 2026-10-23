import XCTest
@testable import Sonovo

final class NumericConversionTests: XCTestCase {
    func testIntRejectsNonFiniteAndOutOfRange() {
        XCTAssertNil(NumericConversion.int(.infinity))
        XCTAssertNil(NumericConversion.int(.nan))
        XCTAssertNil(NumericConversion.int(1e300))
        XCTAssertEqual(NumericConversion.int(2.4), 2)
        XCTAssertEqual(NumericConversion.int(2.6), 3)
    }

    func testMillisecondsSaturates() {
        XCTAssertEqual(NumericConversion.milliseconds(.infinity), 0)
        XCTAssertEqual(NumericConversion.milliseconds(-1), 0)
        XCTAssertEqual(NumericConversion.milliseconds(1.5), 1500)
        XCTAssertEqual(NumericConversion.milliseconds(1e300), Int.max)
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
