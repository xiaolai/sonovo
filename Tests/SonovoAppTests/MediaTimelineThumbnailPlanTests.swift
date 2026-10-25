import XCTest
@testable import Sonovo

final class MediaTimelineThumbnailPlanTests: XCTestCase {
    func testFullViewportCapsTheTileCountAndKeepsTimesInside() {
        let plan = MediaTimelineThumbnailPlan.make(
            viewport: MediaTimelineViewport(start: 0, duration: 10),
            sourceDuration: 10,
            width: 1_000
        )
        XCTAssertEqual(plan.count, MediaEditLimits.thumbnailMaximumTiles)
        XCTAssertEqual(plan.times.count, plan.count)
        XCTAssertEqual(plan.times, plan.times.sorted())
        for time in plan.times {
            XCTAssertGreaterThanOrEqual(time, 0)
            XCTAssertLessThanOrEqual(time, 10)
        }
    }

    func testNarrowStripUsesOneCenteredTile() {
        let plan = MediaTimelineThumbnailPlan.make(
            viewport: MediaTimelineViewport(start: 0, duration: 10),
            sourceDuration: 10,
            width: 40
        )
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.times.first ?? -1, 5, accuracy: 0.0001)
    }

    func testZoomedViewportOnlySamplesVisibleTime() {
        let plan = MediaTimelineThumbnailPlan.make(
            viewport: MediaTimelineViewport(start: 2, duration: 2),
            sourceDuration: 10,
            width: 500
        )
        XCTAssertGreaterThan(plan.count, 1)
        for time in plan.times {
            XCTAssertGreaterThanOrEqual(time, 2)
            XCTAssertLessThanOrEqual(time, 4)
        }
    }

    func testToleranceShrinksWithDeepZoom() {
        let full = MediaTimelineThumbnailPlan.tolerance(
            viewport: MediaTimelineViewport(start: 0, duration: 10),
            count: 12
        )
        let deep = MediaTimelineThumbnailPlan.tolerance(
            viewport: MediaTimelineViewport(start: 0, duration: 0.1),
            count: 12
        )
        XCTAssertEqual(full, 0.1, accuracy: 0.0001)
        XCTAssertGreaterThan(deep, 0)
        XCTAssertLessThan(deep, 0.01)
    }

    func testInvalidSourceDurationStillProducesAFinitePlan() {
        let plan = MediaTimelineThumbnailPlan.make(
            viewport: MediaTimelineViewport(start: 0, duration: 1),
            sourceDuration: .nan,
            width: 300
        )
        XCTAssertGreaterThanOrEqual(plan.count, 1)
        XCTAssertTrue(plan.times.allSatisfy { $0.isFinite })
        XCTAssertTrue(plan.times.allSatisfy { $0 == 0 })
    }
}
