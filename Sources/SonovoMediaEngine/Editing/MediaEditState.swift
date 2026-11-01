import SonovoDocumentSupport
import SonovoFileIO
import SonovoDomainTypes
import Foundation

/// A source-timeline range. Editing works in source time; the composition
/// concatenates the kept ranges onto the edited timeline.
package struct MediaTimeRange: Hashable, Sendable {
    package let start: Double
    package let duration: Double

    package init(start: Double, duration: Double) {
        self.start = start
        self.duration = duration
    }

    package init(start: Double, end: Double) {
        self.init(start: start, duration: max(0, end - start))
    }

    package var end: Double { start + duration }

    package var isValid: Bool {
        start.isFinite
            && duration.isFinite
            && start >= 0
            && duration > 0
    }

    package func clamped(to upperBound: Double) -> MediaTimeRange? {
        guard start.isFinite, duration.isFinite, upperBound.isFinite,
              upperBound > 0 else {
            return nil
        }
        let lower = min(max(start, 0), upperBound)
        let upper = min(max(end, 0), upperBound)
        guard upper - lower > MediaEditLimits.minimumRangeDuration else {
            return nil
        }
        return MediaTimeRange(start: lower, duration: upper - lower)
    }

    package func intersection(with other: MediaTimeRange) -> MediaTimeRange? {
        let lower = max(start, other.start)
        let upper = min(end, other.end)
        guard upper - lower > MediaEditLimits.minimumRangeDuration else {
            return nil
        }
        return MediaTimeRange(start: lower, duration: upper - lower)
    }

    /// The part of this range not covered by `cut`.
    package func subtracting(_ cut: MediaTimeRange) -> [MediaTimeRange] {
        guard let overlap = intersection(with: cut) else { return [self] }
        var result: [MediaTimeRange] = []
        if overlap.start - start > MediaEditLimits.minimumRangeDuration {
            result.append(
                MediaTimeRange(start: start, duration: overlap.start - start)
            )
        }
        if end - overlap.end > MediaEditLimits.minimumRangeDuration {
            result.append(
                MediaTimeRange(start: overlap.end, duration: end - overlap.end)
            )
        }
        return result
    }
}

package enum MediaEditLimits {
    /// A click is not a trim. Selections shorter than this are discarded
    /// rather than producing an inaudible or single-frame take.
    // token-exempt: edit threshold, not a visual value
    package static let minimumSelectionDuration: Double = 0.02
    // token-exempt: edit threshold, not a visual value
    package static let minimumRangeDuration: Double = 0.001
    /// The smallest source window the audio timeline can zoom into. This is
    /// an interaction bound, not a drawing value.
    // token-exempt: timeline interaction bound, not a visual value
    package static let minimumTimelineVisibleDuration: Double = 0.1
    /// Fine and coarse keyboard nudges for a selection edge.
    // token-exempt: edit step, not a visual value
    package static let selectionNudgeStep: Double = 0.010
    // token-exempt: edit step, not a visual value
    package static let selectionNudgeCoarseStep: Double = 0.100
    /// A silence batch that leaves less than this much material is refused
    /// rather than producing a near-empty take.
    // token-exempt: edit threshold, not a visual value
    package static let minimumRetainedDuration: Double = 0.5
    /// Default pause detector settings. RMS is measured on the analysis
    /// waveform; these are audio thresholds, not visual tokens.
    // token-exempt: audio detector setting, not a visual value
    package static let silenceThresholdDBFS: Double = -35
    // token-exempt: audio detector setting, not a visual value
    package static let silenceMinimumPause: Double = 0.30
    // token-exempt: audio detector setting, not a visual value
    package static let silenceGuardPadding: Double = 0.05
    // token-exempt: audio detector setting, not a visual value
    package static let silenceHysteresisDB: Double = 6
    // token-exempt: audio detector setting, not a visual value
    package static let silenceThresholdRange: ClosedRange<Double> = -60 ... -20
    // token-exempt: audio detector setting, not a visual value
    package static let silenceMinimumPauseRange: ClosedRange<Double> = 0.15 ... 1.0
    /// The click-guard fade at each cut. The platform smooths volume ramps,
    /// so this is deliberately longer than the few-millisecond fade that looks
    /// sufficient on paper.
    // token-exempt: audio fade duration, not a visual value
    package static let cutFadeDuration: Double = 0.030
    /// Padding around a transcript word cut, clamped to the neighbouring
    /// word boundary. This protects the onset and tail of the removed word.
    // token-exempt: audio cut guard, not a visual value
    package static let transcriptGuardPadding: Double = 0.030
    // token-exempt: thumbnail request tolerance, not a visual value
    package static let thumbnailTimeTolerance: Double = 0.1
    // token-exempt: thumbnail cache bound, not a visual value
    package static let thumbnailMaximumTiles: Int = 12
    // token-exempt: thumbnail sampling position, not a visual value
    package static let thumbnailTileCenterFraction: Double = 0.5
    package static let timescale: Int32 = 600_000
}

/// Result of a batched structural edit such as removing detected pauses.
package enum MediaEditRemovalResult: Equatable, Sendable {
    case changed
    case unchanged
    case tooShort
}

/// The complete non-destructive edit decision: which source ranges survive,
/// and the current source-timeline selection. The source file is never
/// modified by this value.
package struct MediaEditState: Equatable, Sendable {
    package struct Snapshot: Equatable, Sendable {
        package let keepRanges: [MediaTimeRange]
        package let selection: MediaTimeRange?
    }

    package let sourceDuration: Double
    package private(set) var keepRanges: [MediaTimeRange]
    package var selection: MediaTimeRange?

    package init(
        sourceDuration: Double,
        keepRanges: [MediaTimeRange]? = nil,
        selection: MediaTimeRange? = nil
    ) {
        let duration = sourceDuration.isFinite ? max(sourceDuration, 0) : 0
        self.sourceDuration = duration
        let supplied = keepRanges ?? [
            MediaTimeRange(start: 0, duration: duration)
        ]
        self.keepRanges = supplied
            .compactMap { $0.clamped(to: duration) }
            .sorted { $0.start < $1.start }
        self.selection = selection?.clamped(to: duration)
        coalesceRanges()
    }

    package var snapshot: Snapshot {
        Snapshot(keepRanges: keepRanges, selection: selection)
    }

    package init(sourceDuration: Double, snapshot: Snapshot) {
        self.init(
            sourceDuration: sourceDuration,
            keepRanges: snapshot.keepRanges,
            selection: snapshot.selection
        )
    }

    package var editedDuration: Double {
        keepRanges.reduce(0) { $0 + $1.duration }
    }

    package var hasEdits: Bool {
        guard !keepRanges.isEmpty else { return true }
        guard keepRanges.count == 1, let only = keepRanges.first else {
            return true
        }
        return abs(only.start) > MediaEditLimits.minimumRangeDuration
            || abs(only.end - sourceDuration)
                > MediaEditLimits.minimumRangeDuration
    }

    package var canTrimToSelection: Bool {
        guard let selection else { return false }
        return keepRanges.contains {
            $0.intersection(with: selection) != nil
        }
    }

    package var canDeleteSelection: Bool {
        guard let selection else { return false }
        return keepRanges.contains {
            $0.intersection(with: selection) != nil
        }
    }

    /// The source ranges removed by the current edit, including the head and
    /// tail. The waveform shades these while the player previews the edited
    /// timeline.
    package var removedRanges: [MediaTimeRange] {
        var result: [MediaTimeRange] = []
        var cursor = 0.0
        for range in keepRanges {
            if range.start - cursor > MediaEditLimits.minimumRangeDuration {
                result.append(
                    MediaTimeRange(
                        start: cursor,
                        duration: range.start - cursor
                    )
                )
            }
            cursor = max(cursor, range.end)
        }
        if sourceDuration - cursor > MediaEditLimits.minimumRangeDuration {
            result.append(
                MediaTimeRange(
                    start: cursor,
                    duration: sourceDuration - cursor
                )
            )
        }
        return result
    }

    /// Maps a position on the edited composition back to the source. A
    /// position past the end lands on the final kept source frame.
    package func sourceTime(forEditedTime time: Double) -> Double {
        guard !keepRanges.isEmpty else { return 0 }
        let target = time.isFinite ? max(time, 0) : 0
        var cursor = 0.0
        for range in keepRanges {
            if target < cursor + range.duration {
                return min(
                    range.start + (target - cursor),
                    range.end
                )
            }
            cursor += range.duration
        }
        return keepRanges[keepRanges.count - 1].end
    }

    /// Maps a source position onto the edited composition. A position inside
    /// a removed range collapses to the end of the preceding kept range, so
    /// seeking from the source waveform always lands on playable material.
    package func editedTime(forSourceTime time: Double) -> Double {
        guard !keepRanges.isEmpty else { return 0 }
        let target = time.isFinite ? max(time, 0) : 0
        var cursor = 0.0
        for range in keepRanges {
            if target < range.start {
                return cursor
            }
            if target <= range.end {
                return cursor + (target - range.start)
            }
            cursor += range.duration
        }
        return editedDuration
    }

    package mutating func setSelection(start: Double, end: Double) -> Bool {
        let lower = min(max(min(start, end), 0), sourceDuration)
        let upper = min(max(max(start, end), 0), sourceDuration)
        let rawDuration = upper - lower
        guard rawDuration + 1e-9 >= MediaEditLimits.minimumSelectionDuration
        else {
            let changed = selection != nil
            selection = nil
            return changed
        }
        let duration = min(
            max(rawDuration, MediaEditLimits.minimumSelectionDuration),
            sourceDuration - lower
        )
        let next = MediaTimeRange(start: lower, duration: duration)
        guard selection != next else { return false }
        selection = next
        return true
    }

    package mutating func clearSelection() -> Bool {
        guard selection != nil else { return false }
        selection = nil
        return true
    }

    /// Keep only the parts of the current edit inside the selection. The
    /// selection is deliberately cleared: after the cut, it no longer names
    /// a range in the edited composition.
    package mutating func trimToSelection() -> Bool {
        guard let selection else { return false }
        let next = keepRanges.compactMap {
            $0.intersection(with: selection)
        }
        guard next != keepRanges else { return false }
        keepRanges = next
        self.selection = nil
        return true
    }

    /// Remove the selection and close the gap in the preview.
    package mutating func deleteSelection() -> Bool {
        guard let selection else { return false }
        let next = keepRanges.flatMap { $0.subtracting(selection) }
        guard next != keepRanges else { return false }
        keepRanges = next
        self.selection = nil
        return true
    }

    /// Remove every supplied source range in one structural mutation. Used
    /// by pause removal, where one user action must produce one undo entry
    /// rather than one entry per detected pause.
    package mutating func removeRanges(_ ranges: [MediaTimeRange]) -> MediaEditRemovalResult {
        let next = rangesAfterRemoving(ranges)
        guard next != keepRanges else { return .unchanged }
        let retained = next.reduce(0) { $0 + $1.duration }
        guard retained >= MediaEditLimits.minimumRetainedDuration else {
            return .tooShort
        }
        keepRanges = next
        selection = nil
        return .changed
    }

    /// The material that would remain if `ranges` were removed. This lets the
    /// confirmation UI refuse an outcome that leaves almost nothing before
    /// committing the edit.
    package func retainedDuration(afterRemoving ranges: [MediaTimeRange]) -> Double {
        rangesAfterRemoving(ranges).reduce(0) { $0 + $1.duration }
    }

    /// Move the start edge without swapping edges or clearing a selection
    /// that reaches the minimum width. Selection changes are deliberately not
    /// undoable, matching drag-selection.
    package mutating func nudgeSelectionStart(by delta: Double) -> Bool {
        guard let selection, delta.isFinite else { return false }
        let upper = max(
            selection.end - MediaEditLimits.minimumSelectionDuration,
            0
        )
        let nextStart = min(max(selection.start + delta, 0), upper)
        guard nextStart != selection.start else { return false }
        self.selection = MediaTimeRange(
            start: nextStart,
            duration: selection.end - nextStart
        )
        return true
    }

    package mutating func nudgeSelectionEnd(by delta: Double) -> Bool {
        guard let selection, delta.isFinite else { return false }
        let lower = min(
            selection.start + MediaEditLimits.minimumSelectionDuration,
            sourceDuration
        )
        let nextEnd = min(max(selection.end + delta, lower), sourceDuration)
        guard nextEnd != selection.end else { return false }
        self.selection = MediaTimeRange(
            start: selection.start,
            duration: nextEnd - selection.start
        )
        return true
    }

    private func rangesAfterRemoving(
        _ ranges: [MediaTimeRange]
    ) -> [MediaTimeRange] {
        let cuts = ranges
            .compactMap { $0.clamped(to: sourceDuration) }
            .sorted { $0.start < $1.start }
        guard !cuts.isEmpty else { return keepRanges }
        var next = keepRanges
        for cut in cuts {
            next = next.flatMap { $0.subtracting(cut) }
        }
        return Self.coalesced(next)
    }

    package mutating func reset() -> Bool {
        let full = MediaTimeRange(start: 0, duration: sourceDuration)
        guard keepRanges != [full] || selection != nil else { return false }
        keepRanges = sourceDuration > 0 ? [full] : []
        selection = nil
        return true
    }

    private mutating func coalesceRanges() {
        keepRanges = Self.coalesced(keepRanges)
    }

    private static func coalesced(
        _ ranges: [MediaTimeRange]
    ) -> [MediaTimeRange] {
        guard !ranges.isEmpty else { return [] }
        var merged: [MediaTimeRange] = []
        for range in ranges {
            if let last = merged.last,
               range.start - last.end <= MediaEditLimits.minimumRangeDuration {
                merged[merged.count - 1] = MediaTimeRange(
                    start: last.start,
                    duration: max(last.end, range.end) - last.start
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
