import XCTest
@testable import Sonovo

final class MediaTimecodeTests: XCTestCase {
    func testElapsedFormatting() {
        XCTAssertEqual(
            MediaTimecodeFormatter.elapsed(0),
            "00:00:00.000"
        )
        XCTAssertEqual(
            MediaTimecodeFormatter.elapsed(3661.234),
            "01:01:01.234"
        )
        XCTAssertEqual(
            MediaTimecodeFormatter.elapsed(59.9996),
            "00:01:00.000"
        )
        XCTAssertEqual(
            MediaTimecodeFormatter.elapsed(-4),
            "00:00:00.000"
        )
    }

    func testNonDropFrameTimecode() {
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: 0,
                fps: 30,
                dropFrame: false
            ),
            "00:00:00:00"
        )
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: 29,
                fps: 30,
                dropFrame: false
            ),
            "00:00:00:29"
        )
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: 30,
                fps: 30,
                dropFrame: false
            ),
            "00:00:01:00"
        )
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: 24,
                fps: 24,
                dropFrame: false
            ),
            "00:00:01:00"
        )
    }

    func testDropFrameBoundaries() {
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: 1798,
                fps: 29.97,
                dropFrame: true
            ),
            "00:00:59;28"
        )
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: 1799,
                fps: 29.97,
                dropFrame: true
            ),
            "00:00:59;29"
        )
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: 1800,
                fps: 29.97,
                dropFrame: true
            ),
            "00:01:00;02"
        )
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: 17_982,
                fps: 29.97,
                dropFrame: true
            ),
            "00:10:00;00"
        )
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: 107_892,
                fps: 29.97,
                dropFrame: true
            ),
            "01:00:00;00"
        )
    }

    func testSourceSegmentEndIsExclusive() {
        var timecode = MediaTimecode(
            elapsed: 1,
            nominalFrameRate: 30,
            sourceSegments: [
                .init(
                    time: 0,
                    startFrame: 900,
                    frameRate: 30,
                    frameQuanta: 30,
                    isDropFrame: false,
                    duration: 1
                )
            ],
            isVariableFrameRate: false,
            isTimingVerified: true
        )
        // The first frame after the sample is not covered by it.
        XCTAssertNil(timecode.sourceLabel)

        timecode.elapsed = 0.999
        XCTAssertEqual(timecode.sourceLabel, "00:00:30:29")
    }

    func testSourceTimecodeRequiresAStartFrameAndIsAbsentForVFR() {
        var timecode = MediaTimecode(
            elapsed: 1,
            nominalFrameRate: 30,
            sourceSegments: [
                .init(
                    time: 0,
                    startFrame: 900,
                    frameRate: 30,
                    frameQuanta: 30,
                    isDropFrame: false,
                    duration: nil
                )
            ],
            isVariableFrameRate: false,
            isTimingVerified: true
        )
        XCTAssertEqual(timecode.frameIndex, 30)
        XCTAssertEqual(timecode.sourceLabel, "00:00:31:00")

        timecode.isVariableFrameRate = true
        XCTAssertNil(timecode.sourceLabel)
        XCTAssertEqual(timecode.frameLabel, "Frame 30")

        timecode.isVariableFrameRate = false
        timecode.isTimingVerified = false
        XCTAssertNil(timecode.sourceLabel)
    }

    func testSourceTimecodeFollowsSegmentsAndTheirStartTimes() {
        var timecode = MediaTimecode(
            elapsed: 0,
            nominalFrameRate: 30,
            sourceSegments: [
                .init(
                    time: 0,
                    startFrame: 900,
                    frameRate: 30,
                    frameQuanta: 30,
                    isDropFrame: false,
                    duration: nil
                ),
                .init(
                    time: 2,
                    startFrame: 3000,
                    frameRate: 30,
                    frameQuanta: 30,
                    isDropFrame: false,
                    duration: nil
                )
            ],
            isVariableFrameRate: false,
            isTimingVerified: true
        )
        timecode.elapsed = 1
        XCTAssertEqual(timecode.sourceLabel, "00:00:31:00")
        // A jump is honored: the second sample restarts the label at 3000.
        timecode.elapsed = 2.5
        XCTAssertEqual(timecode.sourceLabel, "00:01:40:15")
    }

    func testNegativeTimecodeKeepsItsSign() {
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: -30,
                fps: 30,
                dropFrame: false
            ),
            "-00:00:01:00"
        )
    }

    func testFrameQuantaDrivesTheLabelBase() {
        // 23.976 fps counts in 24-frame seconds; the real rate still drives
        // the drop-frame arithmetic.
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: 48,
                fps: 23.976,
                frameQuanta: 24,
                dropFrame: false
            ),
            "00:00:02:00"
        )
    }
}
