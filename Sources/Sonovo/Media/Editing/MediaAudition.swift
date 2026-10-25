import Foundation

/// Maps a source-timeline selection onto the edited composition for
/// auditioning. The span is the kept material between the selection bounds;
/// a selection entirely inside a removed gap has no audition.
enum MediaAudition {
    static func range(
        for selection: MediaTimeRange,
        in state: MediaEditState
    ) -> ClosedRange<Double>? {
        guard state.editedDuration
            > MediaEditLimits.minimumRangeDuration else {
            return nil
        }
        let lower = state.editedTime(forSourceTime: selection.start)
        let upper = state.editedTime(forSourceTime: selection.end)
        guard upper - lower
            > MediaEditLimits.minimumSelectionDuration else {
            return nil
        }
        return lower ... upper
    }
}
