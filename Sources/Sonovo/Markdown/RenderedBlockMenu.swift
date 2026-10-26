import SonovoCore

/// One action the rendered block context menu offers.
enum RenderedBlockAction: Equatable {
    case editInSource
    /// Opens the block's source in place, without leaving Rendered.
    case editBlock
    /// Opens a transient source panel anchored to the block.
    case sourcePeek
    /// Sets the authored `open` attribute to the payload value.
    case setDetailsOpen(Bool)

    var title: String {
        switch self {
        case .editInSource:
            "Edit in Source"
        case .editBlock:
            "Edit Block"
        case .sourcePeek:
            "Source Peek"
        case .setDetailsOpen(true):
            "Open by Default"
        case .setDetailsOpen(false):
            "Closed by Default"
        }
    }
}

/// Builds the rendered block context menu. Pure so availability and routing
/// can be tested without mounting a view.
enum RenderedBlockMenu {
    static func actions(
        for block: Block,
        canEditInSource: Bool,
        canSetDetailsOpen: Bool,
        canEditBlock: Bool = false
    ) -> [RenderedBlockAction] {
        var actions: [RenderedBlockAction] = []
        if canEditInSource {
            actions.append(.editInSource)
        }
        if canEditBlock, block.range != nil {
            actions.append(.editBlock)
            actions.append(.sourcePeek)
        }
        if case let .details(details, _) = block, canSetDetailsOpen {
            // Offer the opposite of the authored default: the action always
            // changes the source.
            actions.append(.setDetailsOpen(!details.isOpen))
        }
        return actions
    }

    /// The action a double-click performs. Only blocks with a source range
    /// and an edit route qualify; everything else keeps native double-click
    /// text selection.
    static func doubleClickAction(
        for block: Block,
        canEditInSource: Bool
    ) -> RenderedBlockAction? {
        guard canEditInSource, block.range != nil else { return nil }
        return .editInSource
    }

    static func perform(
        _ action: RenderedBlockAction,
        range: SourceRange,
        editInSource: ((SourceRange) -> Void)?,
        setDetailsOpen: ((SourceRange, Bool) -> Void)?,
        editBlock: ((SourceRange) -> Void)? = nil,
        sourcePeek: ((SourceRange) -> Void)? = nil
    ) {
        switch action {
        case .editInSource:
            editInSource?(range)
        case .editBlock:
            editBlock?(range)
        case .sourcePeek:
            sourcePeek?(range)
        case .setDetailsOpen(let open):
            setDetailsOpen?(range, open)
        }
    }
}
