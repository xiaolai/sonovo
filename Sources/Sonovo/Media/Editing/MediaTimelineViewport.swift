import Foundation

/// The visible source-time window of the audio timeline. This is presentation
/// state, not part of the edit decision: zooming never changes the exported
/// audio and never enters undo.
struct MediaTimelineViewport: Equatable, Sendable {
    private(set) var start: Double
    private(set) var duration: Double

    init(start: Double, duration: Double) {
        self.start = start.isFinite ? start : 0
        self.duration = duration.isFinite && duration > 0 ? duration : 1
    }

    static func full(sourceDuration: Double) -> MediaTimelineViewport {
        guard sourceDuration.isFinite, sourceDuration > 0 else {
            return MediaTimelineViewport(
                start: 0,
                duration: MediaEditLimits.minimumTimelineVisibleDuration
            )
        }
        return MediaTimelineViewport(start: 0, duration: sourceDuration)
    }

    var end: Double { start + duration }

    func clamped(to sourceDuration: Double) -> MediaTimelineViewport {
        guard sourceDuration.isFinite, sourceDuration > 0 else {
            return .full(sourceDuration: 0)
        }
        let minimum = min(
            MediaEditLimits.minimumTimelineVisibleDuration,
            sourceDuration
        )
        let boundedDuration = min(max(duration, minimum), sourceDuration)
        let boundedStart = min(
            max(start, 0),
            max(sourceDuration - boundedDuration, 0)
        )
        return MediaTimelineViewport(
            start: boundedStart,
            duration: boundedDuration
        )
    }

    func time(atFraction fraction: Double) -> Double {
        guard fraction.isFinite else { return start }
        let bounded = min(max(fraction, 0), 1)
        return start + bounded * duration
    }

    func fraction(forTime time: Double) -> Double {
        guard duration > 0, duration.isFinite, time.isFinite else {
            return 0
        }
        return min(max((time - start) / duration, 0), 1)
    }

    /// Zoom while keeping the source time under `anchorFraction` fixed.
    func zoomed(
        by factor: Double,
        anchorFraction: Double,
        sourceDuration: Double
    ) -> MediaTimelineViewport {
        guard factor.isFinite, factor > 0,
              sourceDuration.isFinite, sourceDuration > 0 else {
            return clamped(to: sourceDuration)
        }
        let anchor = min(max(anchorFraction, 0), 1)
        let anchorTime = time(atFraction: anchor)
        let minimum = min(
            MediaEditLimits.minimumTimelineVisibleDuration,
            sourceDuration
        )
        let nextDuration = min(
            max(duration / factor, minimum),
            sourceDuration
        )
        let nextStart = anchorTime - anchor * nextDuration
        return MediaTimelineViewport(
            start: nextStart,
            duration: nextDuration
        ).clamped(to: sourceDuration)
    }

    func scrolled(
        byFraction fraction: Double,
        sourceDuration: Double
    ) -> MediaTimelineViewport {
        guard fraction.isFinite else { return clamped(to: sourceDuration) }
        return MediaTimelineViewport(
            start: start + fraction * duration,
            duration: duration
        ).clamped(to: sourceDuration)
    }

    /// Keep the playhead visible while it is playing. Inside the window this
    /// is a no-op; outside it pages the window so the playhead lands at
    /// `pageFraction` from the leading edge.
    func followed(
        to time: Double,
        sourceDuration: Double,
        pageFraction: Double = 0.8
    ) -> MediaTimelineViewport {
        guard time.isFinite,
              sourceDuration.isFinite,
              sourceDuration > 0 else {
            return clamped(to: sourceDuration)
        }
        guard time < start || time > end else { return self }
        let page = min(max(pageFraction, 0), 1)
        return MediaTimelineViewport(
            start: time - duration * page,
            duration: duration
        ).clamped(to: sourceDuration)
    }
}
