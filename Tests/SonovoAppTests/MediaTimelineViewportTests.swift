import XCTest
@testable import Sonovo

@MainActor
final class MediaTimelineViewportTests: XCTestCase {
    func testFullViewportCoversTheSourceAndClampsToItsDuration() {
        let full = MediaTimelineViewport.full(sourceDuration: 10)
        XCTAssertEqual(full.start, 0, accuracy: 0.0001)
        XCTAssertEqual(full.duration, 10, accuracy: 0.0001)
        XCTAssertEqual(full.end, 10, accuracy: 0.0001)

        let shifted = MediaTimelineViewport(start: 9, duration: 4)
            .clamped(to: 10)
        XCTAssertEqual(shifted.start, 6, accuracy: 0.0001)
        XCTAssertEqual(shifted.duration, 4, accuracy: 0.0001)
    }

    func testZoomKeepsTheAnchorTimeFixed() {
        let viewport = MediaTimelineViewport(start: 2, duration: 4)
        let anchorFraction = 0.25
        let anchorBefore = viewport.time(atFraction: anchorFraction)
        let zoomed = viewport.zoomed(
            by: 2,
            anchorFraction: anchorFraction,
            sourceDuration: 20
        )
        XCTAssertEqual(
            zoomed.time(atFraction: anchorFraction),
            anchorBefore,
            accuracy: 0.0001
        )
        XCTAssertEqual(zoomed.duration, 2, accuracy: 0.0001)
    }

    func testZoomClampsToTheMinimumAndTheSource() {
        let viewport = MediaTimelineViewport(start: 0, duration: 10)
        let maximum = viewport.zoomed(
            by: 10_000,
            anchorFraction: 0.5,
            sourceDuration: 10
        )
        XCTAssertEqual(
            maximum.duration,
            MediaEditLimits.minimumTimelineVisibleDuration,
            accuracy: 0.0001
        )
        let minimum = viewport.zoomed(
            by: 0.01,
            anchorFraction: 0.5,
            sourceDuration: 10
        )
        XCTAssertEqual(minimum.duration, 10, accuracy: 0.0001)
    }

    func testScrollAndFractionRoundTrip() {
        let viewport = MediaTimelineViewport(start: 0, duration: 4)
        let scrolled = viewport.scrolled(byFraction: 0.5, sourceDuration: 10)
        XCTAssertEqual(scrolled.start, 2, accuracy: 0.0001)
        for time in [2.0, 3.7, 5.999] {
            let fraction = scrolled.fraction(forTime: time)
            XCTAssertEqual(
                scrolled.time(atFraction: fraction),
                time,
                accuracy: 0.0001
            )
        }
        XCTAssertEqual(scrolled.fraction(forTime: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(scrolled.fraction(forTime: 10), 1, accuracy: 0.0001)
    }

    func testInvalidInputsStayFiniteAndBounded() {
        let invalid = MediaTimelineViewport(
            start: .nan,
            duration: .infinity
        )
        XCTAssertTrue(invalid.start.isFinite)
        XCTAssertTrue(invalid.duration.isFinite)
        XCTAssertGreaterThan(invalid.duration, 0)

        let clamped = MediaTimelineViewport(start: -10, duration: -1)
            .clamped(to: 0)
        XCTAssertTrue(clamped.start.isFinite)
        XCTAssertTrue(clamped.duration.isFinite)
        XCTAssertGreaterThan(clamped.duration, 0)
        XCTAssertEqual(clamped.fraction(forTime: .nan), 0, accuracy: 0.0001)
        XCTAssertEqual(
            clamped.time(atFraction: .nan),
            clamped.start,
            accuracy: 0.0001
        )
    }

    func testFollowPagesOnlyWhenThePlayheadLeavesTheWindow() {
        let viewport = MediaTimelineViewport(start: 2, duration: 4)
        XCTAssertEqual(
            viewport.followed(to: 3, sourceDuration: 20),
            viewport
        )
        let paged = viewport.followed(to: 10, sourceDuration: 20)
        XCTAssertEqual(paged.duration, 4, accuracy: 0.0001)
        XCTAssertTrue(paged.start <= 10 && paged.end >= 10)
    }

    func testViewportIsNotPartOfUndo() {
        let document = MediaEditDocument(asset: makeAsset())
        document.prepare(sourceDuration: 10)
        document.timelineViewport = MediaTimelineViewport(
            start: 2,
            duration: 4
        )
        document.setSelection(start: 1, end: 2)
        _ = document.trimToSelection()
        _ = document.undo()
        XCTAssertEqual(
            document.timelineViewport,
            MediaTimelineViewport(start: 2, duration: 4)
        )
        document.reload(sourceDuration: 12)
        XCTAssertNil(document.timelineViewport)
    }

    private func makeAsset() -> ProjectAsset {
        ProjectAsset(
            id: "timeline-test",
            url: URL(fileURLWithPath: "/tmp/timeline-test.wav"),
            name: "timeline-test.wav",
            relativePath: "timeline-test.wav",
            kind: .audio,
            size: 0,
            modified: nil,
            revision: .empty
        )
    }
}
