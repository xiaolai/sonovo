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
    /// The tmux session this tab is a client of, when tmux is active. The
    /// client can detach without ending the session or its processes.
    let tmuxSessionName: String?

    init(
        title: String,
        workingDirectory: String = "~",
        tmuxSessionName: String? = nil
    ) {
        self.title = title
        self.workingDirectory = workingDirectory
        self.tmuxSessionName = tmuxSessionName
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
    private let terminalEnvironment: TerminalEnvironment
    private let tmuxPrefix: String?
    private var nextNumber = 1
    private var highestTmuxIndex = 0
    /// Only the first tab created in `init` may skip the server lookup; a
    /// tab created after every tab was closed must still see the server.
    private var isInitialAllocation = true
    private var probeGeneration: UInt64 = 0
    private var probeInFlight = false
    private var probeNames: Set<String> = []
    private var tmuxRunningNames: Set<String> = []
    private var tmuxRunningCount = 0
    /// A foreground process is running in at least one session. The Ghostty
    /// surface is the source of truth for a direct shell; a tmux tab asks the
    /// server instead, because its client is always a live process.
    private(set) var runningProcessCount = 0
    /// The last session action that failed in a way the user must see.
    private(set) var lastError: String?
    @ObservationIgnored
    var processProbe: (TerminalSession) -> Bool = { $0.view.processAlive }
    /// Test seam for the busy-session confirmation. nil shows the alert.
    @ObservationIgnored
    var endConfirmation: ((String) -> Bool)?
    /// Test seam for restarting a busy direct shell. nil shows the alert.
    @ObservationIgnored
    var restartConfirmation: ((String) -> Bool)?
    private var discoveryGeneration: UInt64 = 0
    /// Tab allocations waiting on the tmux server. They run one at a time so
    /// two quick New Tab presses cannot both read the same name list.
    private var allocationPending = 0
    private var allocationRunning = false
    /// Invalidates queued allocations when every session is shut down, so a
    /// pending New Tab cannot repopulate a closed project.
    private var allocationGeneration: UInt64 = 0

    init(
        workingDirectory: String = "~",
        projectKey: String? = nil,
        projectName: String = "",
        terminalEnvironment: TerminalEnvironment = .disabled
    ) {
        self.workingDirectory = workingDirectory
        self.terminalEnvironment = terminalEnvironment
        self.tmuxPrefix = projectKey.map {
            TmuxNaming.prefix(projectKey: $0, projectName: projectName)
        }
        addSession()
        restoreTmuxSessions()
    }

    var selectedSession: TerminalSession? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    private var usesTmux: Bool {
        guard let tmux = terminalEnvironment.tmux,
              tmuxPrefix != nil,
              terminalEnvironment.isEnabled() else {
            return false
        }
        // tmux cannot start in a directory that is currently unavailable.
        // Checking here lets an offline project come back without a rebuild
        // of its terminal environment.
        var isDirectory: ObjCBool = false
        let path = (workingDirectory as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(
            atPath: path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return false
        }
        return tmux.isAvailable
    }

    func addSession() {
        let initial = isInitialAllocation
        isInitialAllocation = false
        if initial {
            // Project creation must stay free of a tmux process, and the
            // first tab has no server names to avoid.
            switch nextTmuxName() {
            case let .allocate(name):
                allocateSession(name: name)
            case .refuse:
                lastError =
                    "Could not reach the tmux server. No tab was opened."
            }
            return
        }
        allocationPending += 1
        startAllocationIfNeeded()
    }

    /// Runs the next queued allocation. The server query happens off the
    /// main actor; the allocation itself resumes on it.
    private func startAllocationIfNeeded() {
        guard !allocationRunning, allocationPending > 0 else { return }
        allocationRunning = true
        allocationPending -= 1
        let generation = allocationGeneration
        guard usesTmux,
              let prefix = tmuxPrefix,
              let tmux = terminalEnvironment.tmux else {
            finishAllocation(tmuxName: nextTmuxName())
            return
        }
        Task { @MainActor [weak self] in
            let names = await Task.detached(priority: .userInitiated) {
                tmux.sessionNames(prefix: prefix)
            }.value
            guard let self, generation == self.allocationGeneration else {
                return
            }
            guard let names else {
                // Allocating blind could attach an unrelated conversation.
                self.lastError =
                    "Could not reach the tmux server. No tab was opened."
                self.finishAllocation(tmuxName: .refuse)
                return
            }
            for name in names {
                if let index = TmuxNaming.index(of: name, prefix: prefix) {
                    self.highestTmuxIndex = max(self.highestTmuxIndex, index)
                }
            }
            self.finishAllocation(tmuxName: self.nextTmuxName())
        }
    }

    private func finishAllocation(tmuxName: TmuxAllocation) {
        switch tmuxName {
        case let .allocate(name):
            allocateSession(name: name)
        case .refuse:
            lastError = "Could not reach the tmux server. No tab was opened."
        }
        allocationRunning = false
        startAllocationIfNeeded()
    }

    /// Test seam: waits until every queued tab allocation has run.
    func awaitPendingAllocations() async {
        while allocationRunning || allocationPending > 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func allocateSession(name: String?) {
        let session = TerminalSession(
            title: "Terminal \(nextNumber)",
            workingDirectory: workingDirectory,
            tmuxSessionName: name
        )
        nextNumber += 1
        if let name {
            session.view.initialCommand = "/bin/sh"
            session.view.initialInput = terminalEnvironment.tmux?
                .launchInput(name: name, directory: workingDirectory)
            highestTmuxIndex = max(
                highestTmuxIndex,
                indexFromName(name) ?? 0
            )
        }
        wire(session)
        sessions.append(session)
        selectedID = session.id
        refreshProcessStates()
    }

    /// Finds tmux sessions left by an earlier run and appends a tab for each
    /// one that is not already shown. Tab 1 keeps its slot and name; a
    /// discovered session for it simply means the existing tab will attach
    /// when its surface starts.
    func restoreTmuxSessions() {
        guard usesTmux,
              let prefix = tmuxPrefix,
              let tmux = terminalEnvironment.tmux else {
            return
        }
        discoveryGeneration &+= 1
        let generation = discoveryGeneration
        Task { @MainActor [weak self] in
            let names = await Task.detached(priority: .utility) {
                tmux.sessionNames(prefix: prefix)
            }.value
            guard let self,
                  generation == self.discoveryGeneration,
                  let names else {
                return
            }
            self.applyRestored(names: names, prefix: prefix)
        }
    }

    private func applyRestored(names: [String], prefix: String) {
        let parsed = names.compactMap { name -> (Int, String)? in
            guard let index = TmuxNaming.index(
                of: name,
                prefix: prefix
            ) else {
                return nil
            }
            return (index, name)
        }.sorted { $0.0 < $1.0 }
        guard !parsed.isEmpty else { return }

        for (index, name) in parsed {
            highestTmuxIndex = max(highestTmuxIndex, index)
            if sessions.contains(where: { $0.tmuxSessionName == name }) {
                continue
            }
            let session = TerminalSession(
                title: "Terminal \(index)",
                workingDirectory: workingDirectory,
                tmuxSessionName: name
            )
            session.view.initialCommand = "/bin/sh"
            session.view.initialInput = terminalEnvironment.tmux?
                .launchInput(name: name, directory: workingDirectory)
            wire(session)
            sessions.append(session)
        }
        nextNumber = max(nextNumber, highestTmuxIndex + 1)
        refreshProcessStates()
    }

    private enum TmuxAllocation {
        /// A tmux name, or nil when tmux is disabled for this project.
        case allocate(String?)
        /// tmux is enabled but cannot report its sessions, so any name this
        /// tab picked could attach an unrelated conversation.
        case refuse
    }

    private func nextTmuxName() -> TmuxAllocation {
        guard usesTmux, let prefix = tmuxPrefix else { return .allocate(nil) }
        let index = max(nextNumber, highestTmuxIndex + 1)
        // The parser accepts indexes up to this ceiling; allocating beyond
        // it would create a name that never restores.
        guard index <= 999_999 else { return .refuse }
        return .allocate(TmuxNaming.sessionName(prefix: prefix, index: index))
    }

    private func indexFromName(_ name: String) -> Int? {
        guard let prefix = tmuxPrefix else { return nil }
        return TmuxNaming.index(of: name, prefix: prefix)
    }

    private func wire(_ session: TerminalSession) {
        let id = session.id
        session.view.onCloseRequested = { [weak self] in
            self?.closeSession(id)
        }
        session.view.onNewTabRequested = { [weak self] in
            self?.addSession()
        }
    }

    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Closes the tab. A tmux session is only detached; its agent keeps
    /// running. Use `endSession` to stop it.
    func closeSession(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else {
            return
        }
        if session.tmuxSessionName == nil,
           session.view.processAlive,
           !confirmClose(session) {
            return
        }
        // A discovery result that arrives after this close must not bring
        // the tab back by itself.
        discoveryGeneration &+= 1
        removeSession(session)
    }

    /// Ends a tmux session and closes its tab. This is the only path that
    /// stops an agent in a tmux-backed tab.
    func endSession(_ id: UUID) async {
        guard let session = sessions.first(where: { $0.id == id }) else {
            return
        }
        guard let name = session.tmuxSessionName else {
            if session.view.processAlive, !confirmClose(session) {
                return
            }
            removeSession(session)
            return
        }
        guard let tmux = terminalEnvironment.tmux else {
            lastError = "Could not reach tmux to end \(name)."
            return
        }
        discoveryGeneration &+= 1
        lastError = nil

        // Both tmux queries run off the main actor: a stalled server must
        // not freeze the window. The tab is revalidated after each await.
        let exists = await Task.detached(priority: .userInitiated) {
            tmux.sessionExists(name: name)
        }.value
        guard sessions.contains(where: { $0.id == id }) else { return }
        guard let exists else {
            lastError = "Could not reach tmux to end \(name)."
            return
        }
        if exists {
            // Confirmation is about a live foreground process; an idle
            // session is still ended, because End Session is explicit.
            // An unknown probe result is treated as busy, so a failed
            // probe never kills without confirmation.
            let running = await Task.detached(priority: .userInitiated) {
                tmux.runningSessions(
                    candidates: [name],
                    shellNames: Self.shellNames
                )?.contains(name)
            }.value
            guard sessions.contains(where: { $0.id == id }) else { return }
            if running != false {
                let confirmed = endConfirmation?(name) ?? confirmEnd(name)
                guard confirmed else { return }
            }
            let killed = await Task.detached(priority: .userInitiated) {
                tmux.kill(name: name)
            }.value
            guard killed else {
                // Keep the tab: the agent may still be running, and the
                // UI must not claim it ended.
                lastError = "Could not end \(name). "
                    + "The session may still be running."
                return
            }
        }
        guard let current = sessions.first(where: { $0.id == id }) else {
            return
        }
        removeSession(current)
    }

    /// Restarts one tab. A tmux tab's client can be replaced without killing
    /// the session; a direct shell with a live foreground process needs an
    /// explicit confirmation, because restarting freezes that process.
    func restart(_ session: TerminalSession) {
        if session.tmuxSessionName == nil, processProbe(session) {
            let confirmed = restartConfirmation?(session.title)
                ?? confirmRestart(session)
            guard confirmed else { return }
        }
        session.view.restart()
    }

    func dismissError() {
        lastError = nil
    }

    /// A live process in a tab that is not protected by tmux. Project close
    /// and quit only need to warn about these.
    var hasLiveDirectProcess: Bool {
        sessions.contains {
            $0.tmuxSessionName == nil && processProbe($0)
        }
    }

    private func removeSession(_ session: TerminalSession) {
        // The modal confirmation runs the main loop; a process-exit callback
        // can remove this session or change its position. Resolve it again
        // instead of removing whatever now sits at the captured index.
        guard let index = sessions.firstIndex(where: {
            $0.id == session.id
        }) else {
            return
        }
        sessions.remove(at: index)
        session.view.shutdown()

        if selectedID == session.id {
            selectedID = sessions.isEmpty
                ? nil
                : sessions[min(index, sessions.count - 1)].id
        }
        refreshProcessStates()
    }

    /// One termination path for project close, window close, and quit. The
    /// interactive path confirms a live direct-shell process; quitting does
    /// not block on a dialog the user cannot see. tmux sessions are never
    /// killed here: detaching is the contract.
    func shutdownAll(force: Bool = false) {
        discoveryGeneration &+= 1
        allocationGeneration &+= 1
        allocationPending = 0
        allocationRunning = false
        let snapshot = sessions
        sessions.removeAll()
        selectedID = nil
        for session in snapshot {
            if !force,
               session.tmuxSessionName == nil,
               session.view.processAlive,
               !confirmClose(session) {
                sessions.append(session)
                if selectedID == nil { selectedID = session.id }
                continue
            }
            session.view.shutdown()
        }
        refreshProcessStates()
    }

    /// Recomputes the badge count. Direct-shell probes stay synchronous; the
    /// tmux probe runs off the main actor and applies only its newest result,
    /// so a stalled tmux server cannot freeze the UI on every poll.
    func refreshProcessStates() {
        let directCount = currentDirectCount()
        let tmuxNames = Set(sessions.compactMap(\.tmuxSessionName))
        guard !tmuxNames.isEmpty,
              let tmux = terminalEnvironment.tmux,
              tmux.isAvailable else {
            // No tmux work: invalidate any probe and drop its last value.
            probeGeneration &+= 1
            probeInFlight = false
            probeNames = []
            tmuxRunningNames = []
            tmuxRunningCount = 0
            setRunningCount(directCount)
            return
        }
        // Intersect the last probe with the tabs that still exist. A closed
        // tab must not keep inflating the badge while the next probe waits.
        tmuxRunningCount = tmuxRunningNames
            .intersection(tmuxNames)
            .count
        setRunningCount(directCount + tmuxRunningCount)
        // A slow probe must be allowed to finish. Restarting it on every
        // two-second poll would discard every result forever.
        if probeInFlight, probeNames == tmuxNames {
            return
        }
        probeGeneration &+= 1
        let generation = probeGeneration
        probeInFlight = true
        probeNames = tmuxNames
        Task { @MainActor [weak self] in
            let running = await Task.detached(priority: .utility) {
                tmux.runningSessions(
                    candidates: tmuxNames,
                    shellNames: Self.shellNames
                )
            }.value
            guard let self else { return }
            // A stale completion must not clear the newer probe's flag or
            // publish its count.
            guard generation == self.probeGeneration else { return }
            self.probeInFlight = false
            // nil is unknown: keep the previous badge rather than claim idle.
            if let running {
                self.tmuxRunningNames = running
                self.tmuxRunningCount = running
                    .intersection(tmuxNames)
                    .count
            }
            // A direct process may have started while the probe ran; use the
            // current count, not the snapshot captured at launch.
            self.setRunningCount(
                self.currentDirectCount() + self.tmuxRunningCount
            )
        }
    }

    private func currentDirectCount() -> Int {
        sessions.filter {
            $0.tmuxSessionName == nil && processProbe($0)
        }.count
    }

    private func setRunningCount(_ count: Int) {
        if count != runningProcessCount {
            runningProcessCount = count
        }
    }

    nonisolated private static let shellNames: Set<String> = [
        "zsh", "bash", "fish", "sh", "login", "tmux"
    ]

    private func confirmClose(_ session: TerminalSession) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close \(session.title)?"
        alert.informativeText = "A process is still running in this terminal."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmEnd(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "End \(name)?"
        alert.informativeText =
            "The agent and every process in this tmux session will stop."
        alert.addButton(withTitle: "End Session")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmRestart(_ session: TerminalSession) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Restart \(session.title)?"
        alert.informativeText =
            "A process is still running in this terminal. Restarting ends it."
        alert.addButton(withTitle: "Restart")
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
        .contextMenu {
            if let name = session.tmuxSessionName {
                Button("Copy tmux Attach Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        TmuxCommands.attachShellCommand(name: name),
                        forType: .string
                    )
                }
                Button("Reattach Sessions") {
                    store.restoreTmuxSessions()
                }
                Divider()
                Button("End Session") {
                    Task { await store.endSession(session.id) }
                }
            } else {
                Button("Reattach Sessions") {
                    store.restoreTmuxSessions()
                }
            }
        }
    }
}
