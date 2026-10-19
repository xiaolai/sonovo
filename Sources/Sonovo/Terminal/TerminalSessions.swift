import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    var title: String
    var workingDirectory: String = "~"
    let view: GhosttyTerminalView

    init(title: String) {
        self.title = title
        self.view = GhosttyTerminalView(frame: .zero)

        view.onWorkingDirectoryChanged = { [weak self] path in
            self?.workingDirectory = path
        }
    }
}

@MainActor
@Observable
final class TerminalSessionsStore {
    private(set) var sessions: [TerminalSession] = []
    var selectedID: UUID?
    private var nextNumber = 1

    init() {
        addSession()
    }

    var selectedSession: TerminalSession? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    func addSession() {
        let session = TerminalSession(title: "Terminal \(nextNumber)")
        nextNumber += 1

        let id = session.id
        session.view.onCloseRequested = { [weak self] in
            self?.closeSession(id)
        }
        session.view.onNewTabRequested = { [weak self] in
            self?.addSession()
        }

        sessions.append(session)
        selectedID = session.id
    }

    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func closeSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        session.view.shutdown()

        if selectedID == id {
            selectedID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
        }
    }
}

@MainActor
struct TerminalSessionsHost: NSViewRepresentable {
    let sessions: [TerminalSession]
    let selectedID: UUID?
    let isActive: Bool
    let focusToken: Int

    func makeNSView(context: Context) -> TerminalHostView {
        let view = TerminalHostView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: TerminalHostView, context: Context) {
        view.update(
            sessions: sessions,
            selectedID: selectedID,
            isActive: isActive,
            focusToken: focusToken
        )
    }
}

@MainActor
final class TerminalHostView: NSView {
    private var hosted: [UUID: GhosttyTerminalView] = [:]
    private var lastFocusToken = 0

    override func layout() {
        super.layout()
        for view in hosted.values {
            view.frame = bounds
        }
    }

    func update(
        sessions: [TerminalSession],
        selectedID: UUID?,
        isActive: Bool,
        focusToken: Int
    ) {
        let currentIDs = Set(sessions.map(\.id))

        for (id, view) in hosted where !currentIDs.contains(id) {
            view.removeFromSuperview()
            hosted[id] = nil
        }

        for session in sessions {
            let view: GhosttyTerminalView
            if let existing = hosted[session.id] {
                view = existing
            } else {
                view = session.view
                addSubview(view)
                hosted[session.id] = view
            }

            view.frame = bounds
            view.isHidden = session.id != selectedID
        }

        guard let selectedID, let selected = hosted[selectedID] else { return }

        if isActive {
            selected.initializeIfNeeded()
        }

        if focusToken != lastFocusToken {
            lastFocusToken = focusToken
            DispatchQueue.main.async { [weak selected] in
                selected?.focus()
            }
        }
    }
}

struct TerminalTabBar: View {
    let store: TerminalSessionsStore

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    ForEach(store.sessions) { session in
                        TerminalTabButton(store: store, session: session)
                    }
                }
            }

            Button {
                store.addSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: AppTheme.TypeScale.xs, weight: .medium))
                    .frame(width: AppTheme.Size.addIcon, height: AppTheme.Size.addIcon)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel("New Terminal Tab")
            .help("New Terminal Tab")
        }
    }
}

private struct TerminalTabButton: View {
    let store: TerminalSessionsStore
    let session: TerminalSession

    @State private var isHovering = false

    private var isSelected: Bool {
        store.selectedID == session.id
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                store.select(session.id)
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "terminal")
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                    Text(session.title)
                        .font(.system(size: AppTheme.TypeScale.xs, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: AppTheme.Size.terminalTabMaxWidth, alignment: .leading)
                }
                .padding(.leading, AppTheme.Spacing.s7)
                .padding(
                    .trailing,
                    (isHovering || isSelected) ? AppTheme.ControlSize.small : AppTheme.Spacing.s7
                )
                .frame(height: AppTheme.ControlSize.regular)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.micro, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(AppTheme.Opacity.soft) : Color.clear)
                )
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.micro, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(AppTheme.Opacity.borderStrong), lineWidth: AppTheme.BorderWidth.hairline)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(session.workingDirectory)

            if isHovering || isSelected {
                Button {
                    store.closeSession(session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: AppTheme.TypeScale.tiny, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: AppTheme.Size.terminalTabClose, height: AppTheme.Size.terminalTabClose)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, AppTheme.Spacing.s3)
                .accessibilityLabel("Close \(session.title)")
                .help("Close Terminal Tab")
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
