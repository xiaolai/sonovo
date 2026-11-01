import SonovoDocumentSupport
import SonovoFileIO
import SonovoDomainTypes
import CoreMedia
import Foundation

/// One inserted audio span on the edited composition. Times are composition
/// time, not source time.
package struct MediaAudioInsertion: Sendable {
    package let trackID: CMPersistentTrackID
    package let sourceRange: MediaTimeRange
    package let insertedStart: Double
    package let insertedDuration: Double
    package let isFirstInTrack: Bool
    package let isLastInTrack: Bool
}

/// A fade-in and/or fade-out for one inserted audio span. `MediaTimeRange` is
/// used here as a composition-time window.
package struct MediaAudioFadeSpan: Equatable, Sendable {
    package let trackID: CMPersistentTrackID
    package let fadeIn: MediaTimeRange?
    package let fadeOut: MediaTimeRange?
}

package struct MediaAudioFadePlan: Equatable, Sendable {
    package let spans: [MediaAudioFadeSpan]

    package var hasFades: Bool {
        spans.contains { $0.fadeIn != nil || $0.fadeOut != nil }
    }
}

/// Derives the click-guard fades from the actual inserted spans. A fade is
/// applied at a cut or trimmed boundary, not at an untouched file head/tail.
package enum MediaAudioFadePlanner {
    package static func plan(
        insertions: [MediaAudioInsertion],
        sourceDuration: Double
    ) -> MediaAudioFadePlan {
        guard sourceDuration.isFinite, sourceDuration > 0 else {
            return MediaAudioFadePlan(spans: [])
        }
        let sorted = insertions.sorted {
            if $0.trackID != $1.trackID {
                return $0.trackID < $1.trackID
            }
            return $0.insertedStart < $1.insertedStart
        }
        var spans: [MediaAudioFadeSpan] = []
        for insertion in sorted {
            guard insertion.insertedDuration
                > MediaEditLimits.minimumRangeDuration else {
                continue
            }
            let half = insertion.insertedDuration / 2
            let fade = min(MediaEditLimits.cutFadeDuration, half)
            guard fade > MediaEditLimits.minimumRangeDuration else {
                continue
            }
            let needsFadeIn = !insertion.isFirstInTrack
                || insertion.sourceRange.start
                    > MediaEditLimits.minimumRangeDuration
                || insertion.insertedStart
                    > MediaEditLimits.minimumRangeDuration
            let needsFadeOut = !insertion.isLastInTrack
                || insertion.sourceRange.end
                    < sourceDuration - MediaEditLimits.minimumRangeDuration
            let fadeIn = needsFadeIn
                ? MediaTimeRange(
                    start: insertion.insertedStart,
                    duration: fade
                )
                : nil
            let fadeOut = needsFadeOut
                ? MediaTimeRange(
                    start: insertion.insertedStart
                        + insertion.insertedDuration - fade,
                    duration: fade
                )
                : nil
            guard fadeIn != nil || fadeOut != nil else { continue }
            spans.append(
                MediaAudioFadeSpan(
                    trackID: insertion.trackID,
                    fadeIn: fadeIn,
                    fadeOut: fadeOut
                )
            )
        }
        return MediaAudioFadePlan(spans: spans)
    }
}
