import SwiftUI

struct DetailWorkspace: View {
    @Bindable var state: AppState

    var body: some View {
        GeometryReader { geometry in
            let layout = WorkspaceLayout(state: state, size: geometry.size)

            ZStack(alignment: .topLeading) {
                ProjectEditorHostsView(
                    state: state,
                    projects: state.workspace.allProjects,
                    active: state.liveProject
                )
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
                // The terminal sessions are per project. Rebuild the pane on a
                // project switch so the host and tab bar cannot keep showing
                // the previous project's sessions while the menu acts on the
                // new project's store.
                .id(state.liveProject.id)
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
            // The inspector is a custom pane, not a NavigationSplitView
            // column. Animate its slide and the editor reflow with the same
            // timing used by the system sidebar.
            .animation(AppTheme.Motion.panel, value: state.inspectorVisible)
        }
    }
}

@MainActor
struct WorkspaceLayout {
    let terminalResizeHeight: CGFloat
    let editorFrame: CGRect
    let terminalFrame: CGRect
    let inspectorFrame: CGRect
    let transportFrame: CGRect
    let terminalDock: TerminalDockPosition
    let inspectorPlacement: InspectorPlacement

    init(state: AppState, size: CGSize) {
        let contentHeight = size.height

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
        let bottomInspectorHeight: CGFloat
        if terminalAtRight {
            bottomInspectorHeight = min(
                AppTheme.Layout.bottomInspectorHeight,
                max(
                    AppTheme.Layout.bottomInspectorMinHeight,
                    contentAboveTransport * AppTheme.Layout.bottomInspectorFraction
                )
            )
        } else {
            bottomInspectorHeight = 0
        }

        let bottomHeight: CGFloat
        if terminalAtBottom {
            bottomHeight = min(
                max(contentAboveTransport * state.terminalFraction, AppTheme.Layout.terminalMinHeight),
                max(0, contentAboveTransport - AppTheme.Layout.terminalMinEditorHeight)
            )
        } else if terminalAtRight && inspectorVisible {
            bottomHeight = bottomInspectorHeight
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
        } else if terminalAtRight {
            // Park the hidden pane just below the window so showing it
            // slides up from the bottom edge instead of growing from zero.
            inspectorFrame = CGRect(
                x: 0,
                y: contentHeight,
                width: mainWidth,
                height: bottomInspectorHeight
            )
            inspectorPlacement = .bottom
        } else {
            // Park it just beyond the trailing edge for the same reason.
            inspectorFrame = CGRect(
                x: size.width,
                y: 0,
                width: AppTheme.Layout.inspectorWidth,
                height: contentHeight
            )
            inspectorPlacement = .right
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
