import AppKit
import SwiftUI

struct TerminalPane: View {
    @Bindable var state: AppState
    let dock: TerminalDockPosition
    let availableHeight: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var focusToken = 0

    private var store: TerminalSessionsStore {
        state.terminalSessions
    }

    private var isVisible: Bool {
        state.terminalPresentation != .hidden
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            TerminalResizeHandle(
                fraction: $state.terminalFraction,
                totalHeight: availableHeight
            )
            .frame(height: dock == .bottom ? AppTheme.Spacing.s5 : AppTheme.Spacing.zero)
            .clipped()

            header

            if let error = store.lastError {
                Text(error)
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(AppTheme.Palette.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xxs)
                    .background(
                        AppTheme.Palette.warning.opacity(
                            AppTheme.Opacity.ghostSoft
                        )
                    )
                    .onTapGesture {
                        store.dismissError()
                    }
            }

            ZStack {
                TerminalSessionsHost(
                    sessions: store.sessions,
                    selectedID: store.selectedID,
                    isActive: isVisible,
                    focusToken: focusToken
                )

                if store.sessions.isEmpty {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(terminalBackground)
        .onAppear {
            if isVisible {
                focusToken += 1
            }
        }
        .onChange(of: state.terminalPresentation) { _, newValue in
            if newValue != .hidden {
                focusToken += 1
            }
        }
        .onChange(of: store.selectedID) { _, _ in
            if isVisible {
                focusToken += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sonovoRestartTerminal)) { _ in
            if let session = store.selectedSession {
                store.restart(session)
            }
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "terminal")
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)

            TerminalTabBar(store: store)
                .frame(maxWidth: .infinity, alignment: .leading)

            BarIconButton(systemName: "list.bullet.rectangle", help: "Manage Sessions…") {
                openWindow(id: "sessions")
            }
            .focusable(false)

            Menu {
                Picker("Dock", selection: $state.terminalDock) {
                    ForEach(TerminalDock.allCases) { dock in
                        Text(dock.label).tag(dock)
                    }
                }
            } label: {
                Image(systemName: "rectangle.split.2x1")
                    .frame(width: AppTheme.Size.menuIcon, height: AppTheme.Size.menuIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .focusable(false)
            .help("Terminal Dock")
            .accessibilityLabel("Terminal Dock")

            BarIconButton(systemName: "arrow.clockwise", help: "Restart shell") {
                if let session = store.selectedSession {
                    store.restart(session)
                }
            }
            .disabled(store.selectedSession == nil)
            .focusable(false)

            BarIconButton(
                systemName: state.terminalPresentation == .full
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                help: state.terminalPresentation == .full ? "Restore split" : "Fill editor"
            ) {
                state.terminalPresentation = state.terminalPresentation == .full ? .split : .full
            }
            .focusable(false)

            BarIconButton(systemName: "xmark", help: "Hide terminal") {
                state.terminalPresentation = .hidden
            }
            .focusable(false)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(height: AppTheme.Layout.toolbarControlHeight)
        .background(terminalBackground)
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "terminal")
                .font(.system(size: AppTheme.TypeScale.display, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("No Terminal")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
            Button("New Terminal") {
                store.addSession()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalBackground)
    }

    private var terminalBackground: Color {
        colorScheme == .dark ? AppTheme.Palette.terminalDark : AppTheme.Palette.terminalLight
    }
}

private struct TerminalResizeHandle: View {
    @Binding var fraction: CGFloat
    let totalHeight: CGFloat

    @State private var startFraction: CGFloat?

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(AppTheme.Opacity.secondary))
                .frame(width: AppTheme.Size.resizeHandleWidth, height: AppTheme.Size.resizeHandleHeight)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if startFraction == nil {
                        startFraction = fraction
                    }
                    guard let startFraction else { return }
                    let delta = value.translation.height / max(totalHeight, AppTheme.Spacing.hairline)
                    fraction = min(
                        max(startFraction - delta, AppTheme.Layout.terminalMinFraction),
                        AppTheme.Layout.terminalMaxFraction
                    )
                }
                .onEnded { _ in
                    startFraction = nil
                }
        )
        .accessibilityLabel("Resize terminal")
    }
}

extension Notification.Name {
    static let sonovoRestartTerminal = Notification.Name("com.sonovo.restartTerminal")
}

@MainActor
func openSonovoSettings() {
    if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
        return
    }
    if NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) {
        return
    }

    guard let appMenu = NSApp.mainMenu?.items.first(where: { item in
        item.submenu?.items.contains(where: { $0.title.hasPrefix("Settings") }) == true
    }),
    let settingsItem = appMenu.submenu?.items.first(where: { $0.title.hasPrefix("Settings") }),
    let action = settingsItem.action else {
        return
    }
    NSApp.sendAction(action, to: settingsItem.target, from: settingsItem)
}
