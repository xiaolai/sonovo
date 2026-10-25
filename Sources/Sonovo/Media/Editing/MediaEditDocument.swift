import Foundation
import Observation
import SonovoCore

/// A replace-original request is addressed to one project document. Retained
/// editors for other projects must not consume it through a shared boolean.
struct MediaReplaceRequest: Equatable, Sendable {
    let projectID: String
    let documentID: String
}

/// One non-destructive edit session for one source path. It owns the edit
/// decision and its undo history, not the file and not the player: switching
/// tabs may release the decoder, but the kept ranges and selection survive
/// until the tab or project closes.
@MainActor
@Observable
final class MediaEditDocument: Identifiable {
    let id: String
    private(set) var asset: ProjectAsset
    private(set) var editState: MediaEditState?
    private(set) var isStale = false
    private(set) var staleMessage: String?
    /// Structural edits and selection changes are frozen while this document
    /// owns an export. The workspace sets this; the document enforces it at
    /// every mutation boundary, not only in the view.
    private(set) var isExporting = false
    /// Non-undoable timeline presentation state. `nil` means fit the source.
    var timelineViewport: MediaTimelineViewport?

    private var undoStack: [MediaEditState.Snapshot] = []
    private var redoStack: [MediaEditState.Snapshot] = []

    init(asset: ProjectAsset) {
        self.asset = asset
        id = MarkdownSecurity.canonical(asset.url).path
    }

    var sourceDuration: Double { editState?.sourceDuration ?? 0 }
    var editedDuration: Double { editState?.editedDuration ?? 0 }
    var hasPendingEdits: Bool { editState?.hasEdits == true }

    var canUndo: Bool {
        !isStale && !isExporting && !undoStack.isEmpty
    }

    var canRedo: Bool {
        !isStale && !isExporting && !redoStack.isEmpty
    }

    var canTrimToSelection: Bool {
        !isStale && editState?.canTrimToSelection == true
    }

    var canDeleteSelection: Bool {
        !isStale && editState?.canDeleteSelection == true
    }

    var canReset: Bool {
        !isStale && editState?.hasEdits == true
    }

    var canExport: Bool {
        !isStale && (editState?.editedDuration ?? 0)
            > MediaEditLimits.minimumRangeDuration
    }

    var canReplaceOriginal: Bool {
        canExport && MediaExportService.canReplace(source: asset)
    }

    var selection: MediaTimeRange? { editState?.selection }

    /// The first successful metadata load sets the full source range. A
    /// negative or non-finite duration never becomes an editable state.
    func prepare(sourceDuration: Double) {
        guard editState == nil,
              !isExporting,
              sourceDuration.isFinite,
              sourceDuration > 0 else {
            return
        }
        editState = MediaEditState(sourceDuration: sourceDuration)
        timelineViewport = nil
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Called by the project when the scan or sample registry reports a new
    /// revision for this path. An open edit session cannot silently continue
    /// against different bytes.
    func observe(asset newAsset: ProjectAsset) {
        guard newAsset.revision != asset.revision else {
            asset = newAsset
            return
        }
        if !isStale {
            staleMessage = "This file changed on disk while it was open."
        }
        asset = newAsset
        isStale = true
    }

    /// Accept the revision currently on disk and start a fresh edit. The
    /// caller supplies the newly loaded source duration.
    func reload(sourceDuration: Double) {
        guard !isExporting,
              sourceDuration.isFinite,
              sourceDuration > 0 else {
            return
        }
        editState = MediaEditState(sourceDuration: sourceDuration)
        timelineViewport = nil
        undoStack.removeAll()
        redoStack.removeAll()
        isStale = false
        staleMessage = nil
    }

    @discardableResult
    func setSelection(start: Double, end: Double) -> Bool {
        guard !isStale, !isExporting, var state = editState else {
            return false
        }
        let changed = state.setSelection(start: start, end: end)
        editState = state
        return changed
    }

    @discardableResult
    func setSelectionStart(atSourceTime time: Double) -> Bool {
        guard let state = editState else { return false }
        let end = state.selection?.end ?? state.sourceDuration
        let minimum = MediaEditLimits.minimumSelectionDuration
        let proposed = min(max(time, 0), state.sourceDuration)
        guard proposed <= end - minimum + 1e-9 else {
            return false
        }
        let start = min(proposed, max(end - minimum, 0))
        return setSelection(start: start, end: end)
    }

    @discardableResult
    func setSelectionEnd(atSourceTime time: Double) -> Bool {
        guard let state = editState else { return false }
        let start = state.selection?.start ?? 0
        let minimum = MediaEditLimits.minimumSelectionDuration
        let proposed = min(max(time, 0), state.sourceDuration)
        guard proposed >= start + minimum - 1e-9 else {
            return false
        }
        let end = max(proposed, start + minimum)
        return setSelection(start: start, end: end)
    }

    @discardableResult
    func clearSelection() -> Bool {
        guard !isStale, !isExporting, var state = editState else {
            return false
        }
        guard state.clearSelection() else { return false }
        editState = state
        return true
    }

    /// Remove a batch of source ranges as one user action. Used by pause
    /// removal; returns `.tooShort` without mutating if the result would leave
    /// less than the minimum retained material.
    @discardableResult
    func removeRanges(_ ranges: [MediaTimeRange]) -> MediaEditRemovalResult {
        guard !isStale, !isExporting,
              var next = editState,
              let current = editState else {
            return .unchanged
        }
        let result = next.removeRanges(ranges)
        guard result == .changed else { return result }
        undoStack.append(current.snapshot)
        trimHistory(&undoStack)
        redoStack.removeAll()
        editState = next
        return .changed
    }

    /// Selection-only nudge; intentionally does not enter undo.
    @discardableResult
    func nudgeSelectionStart(bySourceDelta delta: Double) -> Bool {
        guard !isStale, !isExporting, var state = editState else {
            return false
        }
        guard state.nudgeSelectionStart(by: delta) else { return false }
        editState = state
        return true
    }

    @discardableResult
    func nudgeSelectionEnd(bySourceDelta delta: Double) -> Bool {
        guard !isStale, !isExporting, var state = editState else {
            return false
        }
        guard state.nudgeSelectionEnd(by: delta) else { return false }
        editState = state
        return true
    }

    func beginExportLock() {
        isExporting = true
    }

    func endExportLock() {
        isExporting = false
    }

    @discardableResult
    func trimToSelection() -> Bool {
        perform { $0.trimToSelection() }
    }

    @discardableResult
    func deleteSelection() -> Bool {
        perform { $0.deleteSelection() }
    }

    @discardableResult
    func reset() -> Bool {
        perform { $0.reset() }
    }

    @discardableResult
    func undo() -> Bool {
        guard !isStale,
              !isExporting,
              let state = editState,
              let previous = undoStack.popLast() else {
            return false
        }
        redoStack.append(state.snapshot)
        trimHistory(&redoStack)
        editState = MediaEditState(
            sourceDuration: state.sourceDuration,
            snapshot: previous
        )
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard !isStale,
              !isExporting,
              let state = editState,
              let next = redoStack.popLast() else {
            return false
        }
        undoStack.append(state.snapshot)
        trimHistory(&undoStack)
        editState = MediaEditState(
            sourceDuration: state.sourceDuration,
            snapshot: next
        )
        return true
    }

    private func perform(
        _ change: (inout MediaEditState) -> Bool
    ) -> Bool {
        guard !isStale, !isExporting,
              var next = editState,
              let current = editState else {
            return false
        }
        guard change(&next) else { return false }
        undoStack.append(current.snapshot)
        trimHistory(&undoStack)
        redoStack.removeAll()
        editState = next
        return true
    }

    private func trimHistory(
        _ history: inout [MediaEditState.Snapshot]
    ) {
        let limit = DocumentHistoryLimits.undoLevels
        if history.count > limit {
            history.removeFirst(history.count - limit)
        }
    }
}
