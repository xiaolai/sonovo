import Foundation

/// The one-outcome policy for every surface that can meet more than one
/// caret. Each operation maps to exactly one outcome; handlers consult this
/// table instead of deciding for themselves, so the table is the authority.
///
/// The choke point (`shouldChangeTextIn`) still fails closed for an AppKit
/// edit route this table does not name: with more than one caret, an edit
/// that is not the batch is refused rather than applied to the primary.
enum MultiCursorPolicy {
    enum Outcome: Equatable, Sendable {
        /// Run once per caret as one undoable revision.
        case batch
        /// Beep; text and carets unchanged.
        case refuse
        /// Drop to the primary, then run.
        case collapse
        /// Act on the primary only; keep the caret set.
        case primaryOnly
    }

    enum Operation: String, CaseIterable, Sendable {
        case typing
        case backspace
        case delete
        case plainPaste
        case copy
        case cut
        case imagePaste
        case smartPaste
        case blockProjection
        case sourcePeek
        case tableCellTab
        case tableCommand
        case formattingCommand
        case paletteEdit
        case tabIndent
        case listReturn
        case autoPair
        case linkPopover
        case smartSelectAll
        case modeSwitch
        case reload
        case saveAs
        case close
        case splitFocus
        case find
        case focusMode
        case typewriter
        case reviewMarker

        var outcome: Outcome {
            switch self {
            case .typing, .backspace, .delete, .plainPaste, .copy, .cut:
                return .batch
            case .imagePaste, .smartPaste:
                return .refuse
            case .tableCellTab, .tableCommand:
                return .refuse
            case .formattingCommand, .paletteEdit:
                return .refuse
            case .tabIndent, .listReturn, .autoPair:
                return .refuse
            case .blockProjection, .sourcePeek:
                return .collapse
            case .linkPopover, .smartSelectAll:
                return .collapse
            case .modeSwitch, .reload, .saveAs, .close, .splitFocus:
                return .collapse
            case .find, .focusMode, .typewriter, .reviewMarker:
                return .primaryOnly
            }
        }
    }

    /// The table itself, exposed so a test can hold it to the plan.
    static let outcomes: [Operation: Outcome] = Dictionary(
        uniqueKeysWithValues: Operation.allCases.map { ($0, $0.outcome) }
    )
}
