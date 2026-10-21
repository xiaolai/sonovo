import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    var title: String
    var workingDirectory: String
    let view: GhosttyTerminalView

    init(title: String, workingDirectory: String = "~") {
        self.title = title
        self.workingDirectory = workingDirectory
        self.view = GhosttyTerminalView(frame: .zero)
        self.view.initialWorkingDirectory = workingDirectory

        view.onWorkingDirectoryChanged = { [weak self] path in
            self?.workingDirectory = path
        }
        view.onTitleChanged = { [weak self] title in
            // Ghostty can report an empty title while a program starts.
            guard let self, !title.isEmpty else { return }
            self.title = title
        }
    }
}

@MainActor
@Observable
final class TerminalSessionsStore {
    private(set) var sessions: [TerminalSession] = []
    var selectedID: UUID?
    let workingDirectory: String
    private var nextNumber = 1
    /// A foreground process is running in at least one session. The Ghostty
    /// surface is the source of truth, but it is not observable; the chip
    /// rail polls this through `refreshProcessStates()`.
    private(set) var runningProcessCount = 0
    @ObservationIgnored
    var processProbe: (TerminalSession) -> Bool = { $0.view.processAlive }

    init(workingDirectory: String = "~") {
        self.workingDirectory = workingDirectory
        addSession()
    }

    var selectedSession: TerminalSession? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    func addSession() {
        let session = TerminalSession(
            title: "Terminal \(nextNumber)",
            workingDirectory: workingDirectory
        )
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
        refreshProcessStates()
    }

    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func closeSession(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else {
            return
        }
        if session.view.processAlive, !confirmClose(session) {
            return
        }
        // The modal confirmation runs the main loop; a process-exit callback
        // can remove this session or change its position. Resolve it again
        // instead of removing whatever now sits at the captured index.
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            return
        }
        let closing = sessions[index]
        sessions.remove(at: index)
        closing.view.shutdown()

        if selectedID == id {
            selectedID = sessions.isEmpty
                ? nil
                : sessions[min(index, sessions.count - 1)].id
        }
        refreshProcessStates()
    }

    /// One termination path for project close, window close, and quit. The
    /// interactive path confirms a live process; quitting does not block on a
    /// dialog the user cannot see.
    func shutdownAll(force: Bool = false) {
        let snapshot = sessions
        sessions.removeAll()
        selectedID = nil
        for session in snapshot {
            if !force, session.view.processAlive, !confirmClose(session) {
                sessions.append(session)
                if selectedID == nil { selectedID = session.id }
                continue
            }
            session.view.shutdown()
        }
        refreshProcessStates()
    }

    /// Recomputes the badge count. Mutating only on change keeps @Observable
    /// from invalidating every chip on each poll.
    func refreshProcessStates() {
        let count = sessions.filter(processProbe).count
        if count != runningProcessCount {
            runningProcessCount = count
        }
    }

    private func confirmClose(_ session: TerminalSession) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close \(session.title)?"
        alert.informativeText = "A process is still running in this terminal."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
    /// Latest values from the representable. The deferred focus check reads
    /// these rather than the values captured when the token was issued.
    private var selectedID: UUID?
    private var isActive = false

    override func layout() {
        super.layout()
        for view in hosted.values {
            view.frame = bounds
        }
    }

    /// A hidden terminal must not keep the window's keyboard focus.
    private func resignFocus(in view: NSView) {
        guard let window = view.window,
              let responder = window.firstResponder as? NSView,
              responder === view || responder.isDescendant(of: view)
        else {
            return
        }
        _ = window.makeFirstResponder(nil)
    }

    func update(
        sessions: [TerminalSession],
        selectedID: UUID?,
        isActive: Bool,
        focusToken: Int
    ) {
        self.selectedID = selectedID
        self.isActive = isActive
        let currentIDs = Set(sessions.map(\.id))

        for (id, view) in hosted where !currentIDs.contains(id) {
            resignFocus(in: view)
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
            let visible = isActive && session.id == selectedID
            view.isHidden = !visible
            if !visible {
                resignFocus(in: view)
            }
        }

        guard let selectedID, let selected = hosted[selectedID] else { return }

        if isActive {
            selected.initializeIfNeeded()
        }

        if focusToken != lastFocusToken {
            lastFocusToken = focusToken
            let token = focusToken
            let desiredID = selectedID
            DispatchQueue.main.async { [weak self, weak selected] in
                // The deferred focus must not land after another tab was
                // selected or the pane was hidden.
                guard let self,
                      let selected,
                      self.selectedID == desiredID,
                      self.isActive,
                      self.lastFocusToken == token,
                      !selected.isHidden else {
                    return
                }
                selected.focus()
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
