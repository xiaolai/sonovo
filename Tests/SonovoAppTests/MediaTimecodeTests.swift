import CoreMedia
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

    func testInvalidTimecodeInputDoesNotTrap() {
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: 0,
                fps: 0,
                dropFrame: false
            ),
            "00:00:00:00"
        )
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: 0,
                fps: .infinity,
                dropFrame: false
            ),
            "00:00:00:00"
        )
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: 0,
                fps: 29.97,
                frameQuanta: 0,
                dropFrame: true
            ),
            "00:00:00:00"
        )
        // A drop-frame flag with a rate whose ten-minute block rounds to zero
        // must not divide by zero.
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: 0,
                fps: 0.0005,
                frameQuanta: 1,
                dropFrame: true
            ),
            "00:00:00:00"
        )
        XCTAssertEqual(MediaTimecodeFormatter.elapsed(.infinity), "—")
        XCTAssertEqual(MediaTimecodeFormatter.elapsed(1e300), "—")
    }

    func testUnsupportedDropFrameMetadataCannotOverflow() {
        XCTAssertEqual(
            MediaTimecodeFormatter.timecode(
                frameNumber: 540_005_390_999,
                fps: 900_008_985,
                frameQuanta: 1_000_000,
                dropFrame: true
            ),
            "00:00:00:00"
        )
        var timecode = MediaTimecode(
            elapsed: 1,
            nominalFrameRate: 900_008_985,
            sourceSegments: [
                .init(
                    time: 0,
                    startFrame: 540_005_390_999,
                    frameRate: 900_008_985,
                    frameQuanta: 1_000_000,
                    isDropFrame: true,
                    duration: nil
                )
            ],
            isVariableFrameRate: false,
            isTimingVerified: true
        )
        XCTAssertNil(timecode.sourceLabel)
        timecode.elapsed = 1e12
        XCTAssertNil(timecode.sourceLabel)
    }

    func testSourceLabelRejectsFrameOverflow() {
        var timecode = MediaTimecode(
            elapsed: 1,
            nominalFrameRate: 30,
            sourceSegments: [
                .init(
                    time: 0,
                    startFrame: Int64.max,
                    frameRate: 30,
                    frameQuanta: 30,
                    isDropFrame: false,
                    duration: nil
                )
            ],
            isVariableFrameRate: false,
            isTimingVerified: true
        )
        XCTAssertNil(timecode.sourceLabel)
        timecode.elapsed = .greatestFiniteMagnitude
        XCTAssertNil(timecode.sourceLabel)
        XCTAssertFalse(timecode.frameIndex < 0)
    }

    func testContiguityRejectsFrameOverflow() {
        let previous = MediaTimecode.SourceSegment(
            time: 0,
            startFrame: Int64.max,
            frameRate: 30,
            frameQuanta: 30,
            isDropFrame: false,
            duration: nil
        )
        let next = MediaTimecode.SourceSegment(
            time: 1,
            startFrame: 0,
            frameRate: 30,
            frameQuanta: 30,
            isDropFrame: false,
            duration: nil
        )
        XCTAssertFalse(
            MediaPlaybackModel.isContiguous(previous, followedBy: next)
        )
    }

    func testTimecodeFrameNumberCopiesTheSampleBytes() throws {
        var bytes: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 2]
        var block: CMBlockBuffer?
        let status = bytes.withUnsafeMutableBytes { raw in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: raw.baseAddress,
                blockLength: raw.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: raw.count,
                flags: 0,
                blockBufferOut: &block
            )
        }
        XCTAssertEqual(status, kCMBlockBufferNoErr)
        let buffer = try XCTUnwrap(block)
        XCTAssertEqual(
            MediaPlaybackModel.timecodeFrameNumber(in: buffer, width: 8),
            Int64(0x0000_0001_0000_0002)
        )
    }
}
