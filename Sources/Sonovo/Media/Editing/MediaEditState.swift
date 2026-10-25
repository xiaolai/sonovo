import Foundation

/// A source-timeline range. Editing works in source time; the composition
/// concatenates the kept ranges onto the edited timeline.
struct MediaTimeRange: Hashable, Sendable {
    let start: Double
    let duration: Double

    init(start: Double, duration: Double) {
        self.start = start
        self.duration = duration
    }

    init(start: Double, end: Double) {
        self.init(start: start, duration: max(0, end - start))
    }

    var end: Double { start + duration }

    var isValid: Bool {
        start.isFinite
            && duration.isFinite
            && start >= 0
            && duration > 0
    }

    func clamped(to upperBound: Double) -> MediaTimeRange? {
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

    func intersection(with other: MediaTimeRange) -> MediaTimeRange? {
        let lower = max(start, other.start)
        let upper = min(end, other.end)
        guard upper - lower > MediaEditLimits.minimumRangeDuration else {
            return nil
        }
        return MediaTimeRange(start: lower, duration: upper - lower)
    }

    /// The part of this range not covered by `cut`.
    func subtracting(_ cut: MediaTimeRange) -> [MediaTimeRange] {
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

enum MediaEditLimits {
    /// A click is not a trim. Selections shorter than this are discarded
    /// rather than producing an inaudible or single-frame take.
    // token-exempt: edit threshold, not a visual value
    static let minimumSelectionDuration: Double = 0.02
    // token-exempt: edit threshold, not a visual value
    static let minimumRangeDuration: Double = 0.001
    static let timescale: Int32 = 600_000
}

/// The complete non-destructive edit decision: which source ranges survive,
/// and the current source-timeline selection. The source file is never
/// modified by this value.
struct MediaEditState: Equatable, Sendable {
    struct Snapshot: Equatable, Sendable {
        let keepRanges: [MediaTimeRange]
        let selection: MediaTimeRange?
    }

    let sourceDuration: Double
    private(set) var keepRanges: [MediaTimeRange]
    var selection: MediaTimeRange?

    init(
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

    var snapshot: Snapshot {
        Snapshot(keepRanges: keepRanges, selection: selection)
    }

    init(sourceDuration: Double, snapshot: Snapshot) {
        self.init(
            sourceDuration: sourceDuration,
            keepRanges: snapshot.keepRanges,
            selection: snapshot.selection
        )
    }

    var editedDuration: Double {
        keepRanges.reduce(0) { $0 + $1.duration }
    }

    var hasEdits: Bool {
        guard !keepRanges.isEmpty else { return true }
        guard keepRanges.count == 1, let only = keepRanges.first else {
            return true
        }
        return abs(only.start) > MediaEditLimits.minimumRangeDuration
            || abs(only.end - sourceDuration)
                > MediaEditLimits.minimumRangeDuration
    }

    var canTrimToSelection: Bool {
        guard let selection else { return false }
        return keepRanges.contains {
            $0.intersection(with: selection) != nil
        }
    }

    var canDeleteSelection: Bool {
        guard let selection else { return false }
        return keepRanges.contains {
            $0.intersection(with: selection) != nil
        }
    }

    /// The source ranges removed by the current edit, including the head and
    /// tail. The waveform shades these while the player previews the edited
    /// timeline.
    var removedRanges: [MediaTimeRange] {
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
    func sourceTime(forEditedTime time: Double) -> Double {
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
    func editedTime(forSourceTime time: Double) -> Double {
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

    mutating func setSelection(start: Double, end: Double) -> Bool {
        let lower = min(max(min(start, end), 0), sourceDuration)
        let upper = min(max(max(start, end), 0), sourceDuration)
        guard upper - lower > MediaEditLimits.minimumSelectionDuration else {
            let changed = selection != nil
            selection = nil
            return changed
        }
        let next = MediaTimeRange(start: lower, duration: upper - lower)
        guard selection != next else { return false }
        selection = next
        return true
    }

    mutating func clearSelection() -> Bool {
        guard selection != nil else { return false }
        selection = nil
        return true
    }

    /// Keep only the parts of the current edit inside the selection. The
    /// selection is deliberately cleared: after the cut, it no longer names
    /// a range in the edited composition.
    mutating func trimToSelection() -> Bool {
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
    mutating func deleteSelection() -> Bool {
        guard let selection else { return false }
        let next = keepRanges.flatMap { $0.subtracting(selection) }
        guard next != keepRanges else { return false }
        keepRanges = next
        self.selection = nil
        return true
    }

    mutating func reset() -> Bool {
        let full = MediaTimeRange(start: 0, duration: sourceDuration)
        guard keepRanges != [full] || selection != nil else { return false }
        keepRanges = sourceDuration > 0 ? [full] : []
        selection = nil
        return true
    }

    private mutating func coalesceRanges() {
        guard !keepRanges.isEmpty else { return }
        var merged: [MediaTimeRange] = []
        for range in keepRanges {
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
        keepRanges = merged
    }
}
