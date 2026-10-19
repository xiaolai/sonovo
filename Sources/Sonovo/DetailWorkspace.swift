import SwiftUI

struct DetailWorkspace: View {
    @Bindable var state: AppState

    var body: some View {
        GeometryReader { geometry in
            let layout = WorkspaceLayout(state: state, size: geometry.size)

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    if state.showTabBar {
                        EditorTabBar(state: state)
                    }
                    if state.showBreadcrumbs {
                        EditorBreadcrumb(state: state)
                    }
                    EditorContentView(state: state)
                }
                .frame(
                    width: layout.editorFrame.width,
                    height: layout.editorFrame.height,
                    alignment: .topLeading
                )
                .clipped()

                TerminalPane(
                    state: state,
                    dock: layout.terminalDock,
                    availableHeight: layout.availableHeight
                )
                .frame(width: layout.terminalFrame.width, height: layout.terminalFrame.height)
                .clipped()
                .offset(x: layout.terminalFrame.minX, y: layout.terminalFrame.minY)
                .zIndex(2)

                InspectorView(state: state, placement: layout.inspectorPlacement)
                    .frame(width: layout.inspectorFrame.width, height: layout.inspectorFrame.height)
                    .clipped()
                    .offset(x: layout.inspectorFrame.minX, y: layout.inspectorFrame.minY)
                    .zIndex(1)

                if layout.showVerticalDivider {
                    Rectangle()
                        .fill(Color.appSeparator)
                        .frame(width: AppTheme.BorderWidth.hairline, height: layout.availableHeight)
                        .offset(x: layout.editorFrame.maxX, y: 0)
                }

                if layout.showHorizontalDivider {
                    Rectangle()
                        .fill(Color.appSeparator)
                        .frame(width: layout.editorFrame.width, height: AppTheme.BorderWidth.hairline)
                        .offset(x: 0, y: layout.editorFrame.maxY)
                }

                TransportBar(state: state)
                    .frame(width: geometry.size.width, height: AppTheme.transportHeight)
                    .offset(y: geometry.size.height - AppTheme.transportHeight)
                    .zIndex(3)
            }
            .background(Color.appContent)
        }
    }
}

@MainActor
struct WorkspaceLayout {
    let size: CGSize
    let availableHeight: CGFloat
    let editorFrame: CGRect
    let terminalFrame: CGRect
    let inspectorFrame: CGRect
    let terminalDock: TerminalDockPosition
    let inspectorPlacement: InspectorPlacement
    let showVerticalDivider: Bool
    let showHorizontalDivider: Bool

    private static let inspectorRightWidth: CGFloat = 304
    private static let terminalMinWidth: CGFloat = 340
    private static let terminalMaxWidth: CGFloat = 520
    private static let bottomInspectorHeight: CGFloat = 240

    init(state: AppState, size: CGSize) {
        self.size = size

        let availableHeight = max(size.height - AppTheme.transportHeight, 0)
        self.availableHeight = availableHeight

        if state.terminalPresentation == .full {
            editorFrame = .zero
            terminalFrame = CGRect(x: 0, y: 0, width: size.width, height: availableHeight)
            inspectorFrame = .zero
            terminalDock = .full
            inspectorPlacement = .hidden
            showVerticalDivider = false
            showHorizontalDivider = false
            return
        }

        let terminalSplit = state.terminalPresentation == .split
        let inspectorVisible = state.inspectorVisible
        let effectiveDock: TerminalDockPosition
        if terminalSplit {
            switch state.terminalDock {
            case .automatic:
                effectiveDock = size.width >= 1000 ? .right : .bottom
            case .right:
                effectiveDock = .right
            case .bottom:
                effectiveDock = .bottom
            }
        } else {
            effectiveDock = .right
        }

        let terminalAtRight = terminalSplit && effectiveDock == .right
        let terminalAtBottom = terminalSplit && effectiveDock == .bottom

        let terminalRightWidth = min(max(size.width * 0.32, Self.terminalMinWidth), Self.terminalMaxWidth)
        let rightWidth: CGFloat
        if terminalAtRight {
            rightWidth = terminalRightWidth
        } else if inspectorVisible {
            rightWidth = Self.inspectorRightWidth
        } else {
            rightWidth = 0
        }

        let terminalBottomHeight = min(
            max(availableHeight * state.terminalFraction, 180),
            max(0, availableHeight - 160)
        )
        let bottomInspectorHeight = min(
            Self.bottomInspectorHeight,
            max(160, availableHeight * 0.30)
        )

        let bottomHeight: CGFloat
        if terminalAtBottom {
            bottomHeight = terminalBottomHeight
        } else if terminalAtRight && inspectorVisible {
            bottomHeight = bottomInspectorHeight
        } else {
            bottomHeight = 0
        }

        let editorWidth = max(size.width - rightWidth, 0)
        let editorHeight = max(availableHeight - bottomHeight, 0)
        editorFrame = CGRect(x: 0, y: 0, width: editorWidth, height: editorHeight)

        if terminalAtRight {
            terminalFrame = CGRect(x: editorWidth, y: 0, width: rightWidth, height: availableHeight)
        } else if terminalAtBottom {
            terminalFrame = CGRect(
                x: 0,
                y: availableHeight - bottomHeight,
                width: editorWidth,
                height: bottomHeight
            )
        } else {
            terminalFrame = .zero
        }

        if inspectorVisible {
            if terminalAtRight {
                inspectorFrame = CGRect(
                    x: 0,
                    y: availableHeight - bottomHeight,
                    width: editorWidth,
                    height: bottomHeight
                )
                inspectorPlacement = .bottom
            } else {
                inspectorFrame = CGRect(
                    x: editorWidth,
                    y: 0,
                    width: rightWidth,
                    height: availableHeight
                )
                inspectorPlacement = .right
            }
        } else {
            inspectorFrame = .zero
            inspectorPlacement = .hidden
        }

        terminalDock = terminalAtRight ? .right : .bottom

        showVerticalDivider = rightWidth > 0
        showHorizontalDivider = bottomHeight > 0 && editorWidth > 0
    }
}
