import XCTest
@testable import Sonovo

final class MediaAuditionTests: XCTestCase {
    func testFullSourceSelectionMapsDirectly() {
        let state = MediaEditState(sourceDuration: 10)
        let range = MediaAudition.range(
            for: MediaTimeRange(start: 1, duration: 1),
            in: state
        )
        XCTAssertEqual(range?.lowerBound ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(range?.upperBound ?? -1, 2, accuracy: 0.0001)
    }

    func testSelectionAcrossACutMapsToTheKeptEditedSpan() {
        let state = MediaEditState(
            sourceDuration: 10,
            keepRanges: [
                MediaTimeRange(start: 0, duration: 2),
                MediaTimeRange(start: 4, duration: 2)
            ]
        )
        let range = MediaAudition.range(
            for: MediaTimeRange(start: 1, duration: 4),
            in: state
        )
        XCTAssertEqual(range?.lowerBound ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(range?.upperBound ?? -1, 3, accuracy: 0.0001)
    }

    func testSelectionInsideARemovedGapCannotAudition() {
        let state = MediaEditState(
            sourceDuration: 10,
            keepRanges: [
                MediaTimeRange(start: 0, duration: 2),
                MediaTimeRange(start: 4, duration: 2)
            ]
        )
        XCTAssertNil(
            MediaAudition.range(
                for: MediaTimeRange(start: 2.5, duration: 1),
                in: state
            )
        )
    }

    func testSelectionEndingInsideARemovedGapClampsToTheCut() {
        let state = MediaEditState(
            sourceDuration: 10,
            keepRanges: [
                MediaTimeRange(start: 0, duration: 2),
                MediaTimeRange(start: 4, duration: 2)
            ]
        )
        let range = MediaAudition.range(
            for: MediaTimeRange(start: 1, duration: 2),
            in: state
        )
        XCTAssertEqual(range?.lowerBound ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(range?.upperBound ?? -1, 2, accuracy: 0.0001)
    }

    func testEmptyEditCannotAudition() {
        let state = MediaEditState(
            sourceDuration: 10,
            keepRanges: []
        )
        XCTAssertNil(
            MediaAudition.range(
                for: MediaTimeRange(start: 1, duration: 1),
                in: state
            )
        )
    }
}
