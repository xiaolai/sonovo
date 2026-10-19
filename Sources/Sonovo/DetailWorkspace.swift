import SwiftUI

struct DetailWorkspace: View {
    @Bindable var state: AppState
    @AppStorage("sonovo.canvasInset") private var canvasInset = AppTheme.Canvas.comfortableInset
    @AppStorage("sonovo.canvasRadius") private var canvasRadius = AppTheme.Canvas.roundedRadius

    var body: some View {
        GeometryReader { geometry in
            let layout = WorkspaceLayout(state: state, size: geometry.size)

            ZStack(alignment: .topLeading) {
                VStack(spacing: AppTheme.Spacing.zero) {
                    if state.showTabBar {
                        EditorTabBar(state: state)
                    }
                    if state.showBreadcrumbs {
                        EditorBreadcrumb(state: state)
                    }
                    EditorContentView(state: state)
                        .appCanvasStyle(
                            inset: CGFloat(canvasInset),
                            radius: CGFloat(canvasRadius)
                        )
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
                    availableHeight: layout.terminalResizeHeight
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

                TransportBar(state: state)
                    .frame(width: layout.transportFrame.width, height: layout.transportFrame.height)
                    .offset(x: layout.transportFrame.minX, y: layout.transportFrame.minY)
                    .zIndex(3)
            }
            .background(Color.appText)
        }
    }
}

@MainActor
struct WorkspaceLayout {
    let size: CGSize
    let availableHeight: CGFloat
    let terminalResizeHeight: CGFloat
    let editorFrame: CGRect
    let terminalFrame: CGRect
    let inspectorFrame: CGRect
    let transportFrame: CGRect
    let terminalDock: TerminalDockPosition
    let inspectorPlacement: InspectorPlacement

    init(state: AppState, size: CGSize) {
        self.size = size

        let contentHeight = size.height
        self.availableHeight = contentHeight

        let transportHeight = AppTheme.Layout.transportHeight
        let contentAboveTransport = max(contentHeight - transportHeight, 0)
        self.terminalResizeHeight = contentAboveTransport

        if state.terminalPresentation == .full {
            editorFrame = .zero
            terminalFrame = CGRect(
                x: 0,
                y: 0,
                width: size.width,
                height: contentAboveTransport
            )
            inspectorFrame = .zero
            transportFrame = CGRect(
                x: 0,
                y: contentAboveTransport,
                width: size.width,
                height: transportHeight
            )
            terminalDock = .full
            inspectorPlacement = .hidden
            return
        }

        let terminalSplit = state.terminalPresentation == .split
        let inspectorVisible = state.inspectorVisible
        let effectiveDock: TerminalDockPosition
        if terminalSplit {
            switch state.terminalDock {
            case .automatic:
                effectiveDock = size.width >= AppTheme.Layout.autoDockThreshold ? .right : .bottom
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

        let rightWidth: CGFloat
        if terminalAtRight {
            rightWidth = min(
                max(size.width * AppTheme.Layout.terminalRightFraction, AppTheme.Layout.terminalMinWidth),
                AppTheme.Layout.terminalMaxWidth
            )
        } else if inspectorVisible {
            rightWidth = AppTheme.Layout.inspectorWidth
        } else {
            rightWidth = 0
        }

        let mainWidth = max(size.width - rightWidth, 0)
        let bottomHeight: CGFloat
        if terminalAtBottom {
            bottomHeight = min(
                max(contentAboveTransport * state.terminalFraction, AppTheme.Layout.terminalMinHeight),
                max(0, contentAboveTransport - AppTheme.Layout.terminalMinEditorHeight)
            )
        } else if terminalAtRight && inspectorVisible {
            bottomHeight = min(
                AppTheme.Layout.bottomInspectorHeight,
                max(
                    AppTheme.Layout.bottomInspectorMinHeight,
                    contentAboveTransport * AppTheme.Layout.bottomInspectorFraction
                )
            )
        } else {
            bottomHeight = 0
        }

        let editorHeight = max(contentAboveTransport - bottomHeight, 0)
        editorFrame = CGRect(x: 0, y: 0, width: mainWidth, height: editorHeight)

        if terminalAtRight {
            terminalFrame = CGRect(x: mainWidth, y: 0, width: rightWidth, height: contentHeight)
        } else if terminalAtBottom {
            terminalFrame = CGRect(x: 0, y: editorHeight, width: mainWidth, height: bottomHeight)
        } else {
            terminalFrame = .zero
        }

        if inspectorVisible {
            if terminalAtRight {
                inspectorFrame = CGRect(
                    x: 0,
                    y: contentHeight - bottomHeight,
                    width: mainWidth,
                    height: bottomHeight
                )
                inspectorPlacement = .bottom
            } else {
                inspectorFrame = CGRect(
                    x: mainWidth,
                    y: 0,
                    width: rightWidth,
                    height: contentHeight
                )
                inspectorPlacement = .right
            }
        } else {
            inspectorFrame = .zero
            inspectorPlacement = .hidden
        }

        let transportY: CGFloat
        if inspectorPlacement == .bottom {
            transportY = max(contentHeight - bottomHeight - transportHeight, 0)
        } else {
            transportY = contentAboveTransport
        }
        transportFrame = CGRect(
            x: 0,
            y: transportY,
            width: mainWidth,
            height: transportHeight
        )

        terminalDock = terminalAtRight ? .right : .bottom
    }
}
