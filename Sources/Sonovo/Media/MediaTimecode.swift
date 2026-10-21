import Foundation

/// Source timecode, elapsed time, and frame index are distinct values. A
/// nominal rate cannot reconstruct source timecode on its own; when the file
/// has no usable `tmcd` sample the source label is simply absent.
struct MediaTimecode: Equatable, Sendable {
    /// One `tmcd` sample: the frame number that applies from `time` on the
    /// asset timeline. Timecode tracks can start after zero or jump, so the
    /// label is derived from the applicable segment, not from asset time
    /// zero.
    struct SourceSegment: Equatable, Sendable {
        let time: Double
        let startFrame: Int64
        /// The timecode track's own rate, which can differ from the video.
        let frameRate: Double?
        /// Frames per second for labeling (the track's frame quanta). It is
        /// the integer base the labels count in, even for a fractional rate.
        let frameQuanta: Int?
        let isDropFrame: Bool
        /// How long this sample remains valid. A gap in the timecode track
        /// has no label; without this, the previous label would be
        /// extrapolated across it.
        let duration: Double?
    }

    var elapsed: Double = 0
    var nominalFrameRate: Double = 0
    /// Exact frame duration when the video track declares one. A nominal
    /// Float rate such as 29.97 accumulates error at frame boundaries.
    var frameDurationSeconds: Double?
    var sourceSegments: [SourceSegment] = []
    var isVariableFrameRate = false
    /// False until the whole video track's timing was measured. Elapsed
    /// time may still be shown, but source timecode derived from it would
    /// be fabricated on an unverified timeline.
    var isTimingVerified = false

    var frameIndex: Int64 {
        let position = max(elapsed, 0)
        // A frame boundary computed from a nominal rate lands a few ulps
        // below the integer. Without a tiny tolerance, frame 3 reports 2.
        if let frameDurationSeconds, frameDurationSeconds > 0 {
            return Int64(
                (position / frameDurationSeconds + 0.000_001).rounded(.down)
            )
        }
        guard nominalFrameRate > 0 else { return 0 }
        return Int64(
            (position * nominalFrameRate + 0.000_001).rounded(.down)
        )
    }

    var sourceLabel: String? {
        guard !isVariableFrameRate,
              isTimingVerified,
              let segment = sourceSegment(at: elapsed) else {
            return nil
        }
        // The timecode track can run at a different rate than the picture
        // (for example 30 fps timecode on 24 fps film). Use its own rate.
        let rate = segment.frameRate ?? nominalFrameRate
        guard rate > 0 else { return nil }
        let elapsedFrames = Int64(
            ((elapsed - segment.time) * rate + 0.000_001).rounded(.down)
        )
        return MediaTimecodeFormatter.timecode(
            frameNumber: segment.startFrame + elapsedFrames,
            fps: rate,
            frameQuanta: segment.frameQuanta.map(Double.init),
            dropFrame: segment.isDropFrame
        )
    }

    /// The sample covering `time`, or nil before the first sample and
    /// across a gap. Never extrapolate a label the track does not contain.
    private func sourceSegment(at time: Double) -> SourceSegment? {
        guard let index = sourceSegments.lastIndex(where: {
            $0.time <= time
        }) else {
            return nil
        }
        let segment = sourceSegments[index]
        if let duration = segment.duration, duration > 0 {
            // Half-open: the sample covers its start but not its end. An
            // inclusive end would label the first frame of a following gap
            // with the segment that just ended.
            return time < segment.time + duration ? segment : nil
        }
        if index + 1 < sourceSegments.count {
            return time < sourceSegments[index + 1].time ? segment : nil
        }
        return segment
    }

    var frameLabel: String? {
        guard nominalFrameRate > 0 else { return nil }
        return "Frame \(frameIndex)"
    }
}

enum MediaTimecodeFormatter {
    static func elapsed(_ seconds: Double) -> String {
        let clamped = max(seconds, 0)
        let totalMilliseconds = Int64((clamped * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let secondsPart = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        return String(
            format: "%02d:%02d:%02d.%03d",
            Int(hours),
            Int(minutes),
            Int(secondsPart),
            Int(milliseconds)
        )
    }

    /// `dropFrame` is only meaningful for 29.97/59.94-style rates. The
    /// algorithm adjusts the frame number so minute boundaries skip the two
    /// (or four) labels that do not exist.
    static func timecode(
        frameNumber: Int64,
        fps: Double,
        frameQuanta: Double? = nil,
        dropFrame: Bool
    ) -> String {
        let nominal = Int64((frameQuanta ?? fps).rounded())
        guard nominal > 0 else { return "00:00:00:00" }
        // A negative start timecode is a real pre-roll value; clamping it
        // to zero shows a label the file does not contain.
        let negative = frameNumber < 0
        var frame = frameNumber == Int64.min ? Int64.max : abs(frameNumber)

        if dropFrame {
            let dropFrames = Int64((fps * 0.066_666).rounded())
            let framesPer10Minutes = Int64((fps * 600).rounded())
            let framesPerMinute = nominal * 60 - dropFrames
            let framesPer24Hours = Int64((fps * 3600).rounded()) * 24
            frame %= framesPer24Hours
            let tenMinuteBlocks = frame / framesPer10Minutes
            let remainder = frame % framesPer10Minutes
            if remainder > dropFrames {
                frame += dropFrames * 9 * tenMinuteBlocks
                    + dropFrames * ((remainder - dropFrames) / framesPerMinute)
            } else {
                frame += dropFrames * 9 * tenMinuteBlocks
            }
        }

        let frames = Int(frame % nominal)
        let totalSeconds = Int(frame / nominal)
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = (totalSeconds / 3600) % 24
        let separator = dropFrame ? ";" : ":"
        let sign = negative ? "-" : ""
        return sign + String(
            format: "%02d:%02d:%02d%@%02d",
            hours,
            minutes,
            seconds,
            separator,
            frames
        )
    }
}
