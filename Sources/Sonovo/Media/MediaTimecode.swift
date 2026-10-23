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
        guard position.isFinite else { return 0 }
        // A frame boundary computed from a nominal rate lands a few ulps
        // below the integer. Without a tiny tolerance, frame 3 reports 2.
        let raw: Double
        if let frameDurationSeconds,
           frameDurationSeconds.isFinite,
           frameDurationSeconds > 0 {
            raw = (position / frameDurationSeconds + 0.000_001)
                .rounded(.down)
        } else {
            guard nominalFrameRate.isFinite, nominalFrameRate > 0 else {
                return 0
            }
            raw = (position * nominalFrameRate + 0.000_001)
                .rounded(.down)
        }
        guard raw.isFinite, raw >= 0 else { return 0 }
        return Int64(exactly: raw) ?? Int64.max
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
        guard rate.isFinite, rate > 0 else { return nil }
        let rawFrames = (elapsed - segment.time) * rate + 0.000_001
        guard rawFrames.isFinite, rawFrames >= 0,
              let elapsedFrames = Int64(exactly: rawFrames.rounded(.down))
        else {
            return nil
        }
        let (frameNumber, overflow) = segment.startFrame
            .addingReportingOverflow(elapsedFrames)
        guard !overflow else { return nil }
        let quanta = segment.frameQuanta.map(Double.init)
        guard MediaTimecodeFormatter.isValidTimecodeInput(
            frameNumber: frameNumber,
            fps: rate,
            frameQuanta: quanta,
            dropFrame: segment.isDropFrame
        ) else {
            return nil
        }
        return MediaTimecodeFormatter.timecode(
            frameNumber: frameNumber,
            fps: rate,
            frameQuanta: quanta,
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
        guard clamped.isFinite else { return "—" }
        let rawMilliseconds = clamped * 1000
        guard rawMilliseconds.isFinite,
              let totalMilliseconds = Int64(
                exactly: rawMilliseconds.rounded()
              ) else {
            return "—"
        }
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

    /// Rejects rates, quanta, and drop-frame metadata that cannot produce a
    /// valid label. The formatter must never divide by a zero divisor or
    /// convert an unrepresentable rate, even when a file supplies one.
    static func isValidTimecodeInput(
        frameNumber: Int64,
        fps: Double,
        frameQuanta: Double?,
        dropFrame: Bool
    ) -> Bool {
        // Real video rates and frame quanta fit far below this; anything
        // larger is malformed metadata, not a labelable timecode track.
        let maximumRate = 240.0
        guard fps.isFinite, fps >= 1, fps <= maximumRate else {
            return false
        }
        let nominalSource = frameQuanta ?? fps
        guard nominalSource.isFinite,
              nominalSource >= 1,
              nominalSource <= maximumRate,
              let nominal = Int64(exactly: nominalSource.rounded()),
              nominal > 0 else {
            return false
        }
        // The quanta is the integer base the labels count in. A base far
        // from the track's own rate (1 on a 29.97 fps track) counts the
        // wrong unit and produces a label that does not describe the frame
        // number, so treat the metadata as unusable rather than label with
        // it. Cross-rate timecode stays valid: 30-label timecode on 24 fps
        // picture is a ratio of 1.25.
        let ratio = Double(nominal) / fps
        guard ratio >= 0.25, ratio <= 4 else { return false }
        // Drop-frame arithmetic mixes the track rate (for the skipped
        // labels) with the quanta (for the modulo). They must describe the
        // same nominal rate or the label runs backwards at minute
        // boundaries; 29.97 fps pairs with 30, not with 15.
        //
        // The skip pattern is defined for 30-based rates. At 23.976 with a
        // base of 24 the ten-minute block and the per-minute block round to
        // values that also walk a label backwards, so those rates cannot be
        // drop-frame at all.
        if dropFrame {
            guard nominal == Int64(fps.rounded()),
                  nominal % 30 == 0 else {
                return false
            }
        }
        guard dropFrame else { return true }
        let drop = (fps * 0.066_666).rounded()
        let perTenMinutes = (fps * 600).rounded()
        let perMinute = Double(nominal) * 60 - drop
        let perDay = (fps * 3600).rounded() * 24
        guard drop.isFinite, perTenMinutes.isFinite,
              perMinute.isFinite, perDay.isFinite,
              drop >= 0,
              let dropFrames = Int64(exactly: drop),
              let framesPer10Minutes = Int64(exactly: perTenMinutes),
              framesPer10Minutes > 0,
              let framesPerMinute = Int64(exactly: perMinute),
              framesPerMinute > 0,
              let framesPer24Hours = Int64(exactly: perDay),
              framesPer24Hours > 0 else {
            return false
        }
        return true
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
        guard isValidTimecodeInput(
            frameNumber: frameNumber,
            fps: fps,
            frameQuanta: frameQuanta,
            dropFrame: dropFrame
        ),
        let nominal = Int64(
            exactly: (frameQuanta ?? fps).rounded()
        ), nominal > 0 else {
            return "00:00:00:00"
        }
        // A negative start timecode is a real pre-roll value; clamping it
        // to zero shows a label the file does not contain.
        let negative = frameNumber < 0
        var frame = frameNumber == Int64.min ? Int64.max : abs(frameNumber)

        if dropFrame {
            let dropFrames = Int64((fps * 0.066_666).rounded())
            let framesPer10Minutes = Int64((fps * 600).rounded())
            let framesPerMinute = Int64(
                exactly: Double(nominal) * 60
                    - Double(dropFrames)
            ) ?? 1
            let (framesPer24Hours, overflowDay) = Int64(
                (fps * 3600).rounded()
            ).multipliedReportingOverflow(by: 24)
            guard !overflowDay, framesPer24Hours > 0 else {
                return "00:00:00:00"
            }
            frame %= framesPer24Hours
            let tenMinuteBlocks = frame / framesPer10Minutes
            let remainder = frame % framesPer10Minutes
            let (nineDrop, overflow1) = dropFrames
                .multipliedReportingOverflow(by: 9)
            let (blockAdjust, overflow2) = nineDrop
                .multipliedReportingOverflow(by: tenMinuteBlocks)
            let minuteAdjust: Int64
            var overflow3 = false
            if remainder > dropFrames {
                let (value, overflow) = dropFrames.multipliedReportingOverflow(
                    by: (remainder - dropFrames) / framesPerMinute
                )
                minuteAdjust = value
                overflow3 = overflow
            } else {
                minuteAdjust = 0
            }
            let (adjust, overflow4) = blockAdjust
                .addingReportingOverflow(minuteAdjust)
            let (adjusted, overflow5) = frame.addingReportingOverflow(adjust)
            guard !overflow1, !overflow2, !overflow3,
                  !overflow4, !overflow5 else {
                return "00:00:00:00"
            }
            frame = adjusted
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
