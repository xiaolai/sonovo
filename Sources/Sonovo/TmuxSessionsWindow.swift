import AppKit
import Observation
import SwiftUI

// MARK: - Model

struct BulkResultRow: Identifiable, Equatable {
    let id: TmuxSessionIdentity
    let name: String
    let outcome: TmuxActionOutcome
}

struct SessionsProjectChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let prefix: String
    let identity: FolderIdentityRecord?
}

struct SessionsFilters: Equatable {
    var showAttached = true
    var showRunning = true
    var showIdle = true
    var showUnknown = true
    var showShared = true
    var candidatesOnly = false
}

enum SessionsConfirmation {
    case endOne(String)
    case endBulk(
        names: [String],
        explicitStates: [String]
    )
    case captureIncomplete(String)
    case enableKill
    case adopt(names: [String], crossVolume: Bool)
    case exportPlaintext
}

@MainActor
@Observable
final class TmuxSessionsWindowModel {
    let hygiene: TmuxHygieneStore
    let coordinator: TmuxActionCoordinator?
    let archive: TmuxArchiveStore?
    let migration: TmuxMigrationModel

    @ObservationIgnored var knownPathsProvider: () -> TmuxKnownPaths = {
        TmuxKnownPaths()
    }
    @ObservationIgnored var openSession:
        (TmuxSessionObservation) -> Bool = { _ in false }
    @ObservationIgnored var projectChoices: () -> [SessionsProjectChoice] = {
        []
    }
    @ObservationIgnored var folderIdentity:
        (String) -> FolderIdentityRecord? = { _ in nil }
    @ObservationIgnored var migrationSourceHint:
        (String) -> String? = { _ in nil }
    @ObservationIgnored var reserveNames: ([String]) -> Void = { _ in }
    @ObservationIgnored var releaseNames: ([String]) -> Void = { _ in }
    @ObservationIgnored var rebindTabs: (AdoptedTabRebind) -> Void = { _ in }
    @ObservationIgnored var confirm: (SessionsConfirmation) -> Bool = {
        TmuxSessionsWindowModel.defaultConfirm($0)
    }

    var filters = SessionsFilters()
    var selectedIdentity: TmuxSessionIdentity?
    /// A selection is frozen as identities plus the observed state at the
    /// moment of selection. A later scan cannot silently upgrade an idle
    /// selection into an explicit "may be running" authorization.
    private(set) var frozenSelections:
        [TmuxSessionIdentity: TmuxBulkSelection] = [:]
    var explicitAcknowledged = false
    var isWorking = false
    var statusMessage: String?
    var errorMessage: String?
    private(set) var lastBulkResults: [TmuxSessionIdentity: TmuxActionOutcome] = [:]
    private(set) var bulkCancellation: TmuxBulkCancellation?

    var revealed: TmuxRevealedCapture?
    private(set) var lastBulkRows: [BulkResultRow] = []
    var showingAdoption = false
    var adoptionDestinationID: String?
    var adoptionSourcePath: String?
    private(set) var adoptionPreview: TmuxMigrationPreview?
    private(set) var adoptionResults: [TmuxSessionIdentity: TmuxMigrationOutcome] = [:]
    private var reservedPreviewNames: [String] = []
    private var adoptionGeneration: UInt64 = 0

    init(
        hygiene: TmuxHygieneStore,
        coordinator: TmuxActionCoordinator?,
        archive: TmuxArchiveStore?,
        migration: TmuxMigrationModel = TmuxMigrationModel()
    ) {
        self.hygiene = hygiene
        self.coordinator = coordinator
        self.archive = archive
        self.migration = migration
    }

    var summary: TmuxHygieneSummary { hygiene.summaryCounts }

    var visibleAttributes: [TmuxSessionAttributes] {
        hygiene.attributes.filter { attribute in
            if filters.candidatesOnly, attribute.tier == .excluded {
                return false
            }
            if !filters.showAttached,
               attribute.observation.attachedClients > 0 {
                return false
            }
            if !filters.showShared,
               attribute.observation.sharedWindows {
                return false
            }
            switch attribute.observation.process {
            case .running: return filters.showRunning
            case .noCommandDetected: return filters.showIdle
            case .unknown: return filters.showUnknown
            }
        }
    }

    var selectedAttribute: TmuxSessionAttributes? {
        guard let selectedIdentity else { return nil }
        return hygiene.attributes(for: selectedIdentity)
    }

    var selectedVisibleAttribute: TmuxSessionAttributes? {
        guard let attribute = selectedAttribute,
              visibleAttributes.contains(where: {
                  $0.identity == attribute.identity
              }) else {
            return nil
        }
        return attribute
    }

    var bulkSelection: Set<TmuxSessionIdentity> {
        Set(frozenSelections.keys)
    }

    var bulkExplicitCount: Int {
        frozenSelections.values.filter {
            $0.authorization.tier == .explicitBulk
        }.count
    }

    var canRunBulk: Bool {
        !frozenSelections.isEmpty
            && coordinator != nil
            && (bulkExplicitCount == 0 || explicitAcknowledged)
    }

    var adoptionDestinations: [SessionsProjectChoice] {
        projectChoices()
    }

    var adoptionSourceCandidates: [String] {
        guard let snapshot = hygiene.snapshot else { return [] }
        var paths: Set<String> = []
        for session in snapshot.sessions {
            if let path = session.ownership.verifiedProjectPath {
                paths.insert(TmuxKnownPaths.canonical(path))
            }
        }
        return paths.sorted()
    }

    // MARK: Refresh

    func refresh() async {
        hygiene.knownPaths = knownPathsProvider()
        await hygiene.refresh()
    }

    // MARK: Row actions

    func toggleBulk(_ identity: TmuxSessionIdentity) {
        if frozenSelections.removeValue(forKey: identity) != nil {
            if bulkExplicitCount == 0 {
                explicitAcknowledged = false
            }
            return
        }
        guard let attribute = hygiene.attributes(for: identity),
              attribute.tier != .excluded else {
            return
        }
        frozenSelections[identity] = TmuxBulkSelection(
            identity: identity,
            name: attribute.observation.name,
            authorization: TmuxObservedAuthorization(
                observation: attribute.observation,
                tier: attribute.tier
            )
        )
        if bulkExplicitCount == 0 {
            explicitAcknowledged = false
        }
    }

    func selectIdleCandidates() {
        // Tier 1 only, from the current snapshot. Filters never preselect.
        var next: [TmuxSessionIdentity: TmuxBulkSelection] = [:]
        for attribute in hygiene.attributes
        where attribute.tier == .idleBulk {
            next[attribute.identity] = TmuxBulkSelection(
                identity: attribute.identity,
                name: attribute.observation.name,
                authorization: TmuxObservedAuthorization(
                    observation: attribute.observation,
                    tier: attribute.tier
                )
            )
        }
        frozenSelections = next
        explicitAcknowledged = false
    }

    func clearBulkSelection() {
        frozenSelections.removeAll()
        explicitAcknowledged = false
    }

    func openSelected() {
        guard let attribute = selectedAttribute,
              attribute.permissions.canOpen,
              let observation = hygiene.snapshot?.session(attribute.identity)
        else {
            errorMessage = "Open is available only for sessions whose project is open."
            return
        }
        guard openSession(observation) else {
            errorMessage = "Could not open the project for this session."
            return
        }
    }

    func copyAttachCommand() {
        guard let name = selectedAttribute?.observation.name else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            TmuxCommands.attachShellCommand(name: name),
            forType: .string
        )
        statusMessage = "Copied the attach command."
    }

    func endSelected() async {
        guard !isWorking else { return }
        guard let attribute = selectedAttribute else { return }
        guard let coordinator else {
            errorMessage = "The action coordinator is unavailable."
            return
        }
        guard confirm(.endOne(attribute.observation.name)) else { return }
        isWorking = true
        defer { isWorking = false }
        let outcome = await coordinator.end(attribute: attribute)
        report(outcome, name: attribute.observation.name)
        await refresh()
    }

    func captureAndEndSelected() async {
        guard !isWorking else { return }
        guard let attribute = selectedAttribute,
              let coordinator else {
            return
        }
        guard confirm(.endOne(attribute.observation.name)) else { return }
        isWorking = true
        defer { isWorking = false }
        var outcome = await coordinator.captureAndEnd(
            attribute: attribute,
            acknowledgedIncomplete: false
        )
        if case .skipped = outcome,
           let capture = coordinator.lastCapture,
           !(capture.committed && capture.verdict == .complete) {
            guard confirm(.captureIncomplete(attribute.observation.name))
            else { return }
            outcome = await coordinator.captureAndEnd(
                attribute: attribute,
                acknowledgedIncomplete: true
            )
        }
        report(outcome, name: attribute.observation.name)
        await refresh()
    }

    func reconcileSelected() {
        guard !isWorking else { return }
        guard let identity = selectedIdentity, let coordinator else {
            return
        }
        guard !coordinator.hasCorruptUncertainty else {
            errorMessage =
                "The unresolved-action store is corrupt; fix or remove "
                + "tmux-uncertain.json before reconciling sessions."
            return
        }
        coordinator.reconcile(identity)
        statusMessage = "Reconciled the unresolved action."
        Task { await refresh() }
    }

    func runBulk() async {
        guard !isWorking else { return }
        guard let coordinator else {
            errorMessage = "The action coordinator is unavailable."
            return
        }
        guard canRunBulk else {
            errorMessage = bulkExplicitCount > 0
                ? "Acknowledge that explicit sessions may be running work."
                : "Select at least one session."
            return
        }
        let selections = Array(frozenSelections.values)
        guard !selections.isEmpty else { return }
        let explicitStates = selections
            .filter { $0.authorization.tier == .explicitBulk }
            .map { selection in
                let state: String
                switch selection.authorization.process {
                case .running: state = "running"
                case .unknown: state = "unknown process"
                case .noCommandDetected: state = "idle"
                }
                return "\(selection.name) (\(state)\(selection.authorization.sharedWindows ? ", shared window" : ""))"
            }
        guard confirm(
            .endBulk(
                names: selections.map(\.name),
                explicitStates: explicitStates
            )
        ) else {
            return
        }
        let cancellation = TmuxBulkCancellation()
        bulkCancellation = cancellation
        isWorking = true
        defer {
            isWorking = false
            bulkCancellation = nil
        }
        let results = await coordinator.endBulk(
            selections: selections,
            cancellation: cancellation
        )
        lastBulkResults = results
        let names = Dictionary(
            uniqueKeysWithValues: selections.map {
                ($0.identity, $0.name)
            }
        )
        lastBulkRows = results.map { identity, outcome in
            BulkResultRow(
                id: identity,
                name: names[identity] ?? identity.sessionID,
                outcome: outcome
            )
        }.sorted { $0.name < $1.name }
        let ended = results.values.filter { $0.isSuccess }.count
        let stopped = results.values.contains {
            if case .uncertain = $0 { return true }
            return false
        }
        statusMessage = "Bulk End: \(ended) ended or absent"
            + (stopped ? ", stopped at an uncertain row." : ".")
        frozenSelections = frozenSelections.filter {
            results[$0.key]?.isSuccess != true
        }
        await refresh()
    }

    func cancelBulk() {
        bulkCancellation?.cancel()
    }

    // MARK: Cleanup policy

    var cleanupMode: AutomaticCleanupMode { hygiene.settings.mode }
    var killSwitchEngaged: Bool { hygiene.settings.killSwitchEngaged }
    var captureEnabled: Bool { hygiene.settings.captureEnabled }

    func setCleanupMode(_ mode: AutomaticCleanupMode) {
        if mode == .kill {
            guard captureEnabled else {
                errorMessage =
                    "Enable Capture before End first. Automatic End requires "
                    + "a committed complete capture for every session."
                hygiene.setMode(.preview, riskAcknowledged: false)
                return
            }
            guard confirm(.enableKill) else {
                hygiene.setMode(.preview, riskAcknowledged: false)
                return
            }
            hygiene.setMode(.kill, riskAcknowledged: true)
        } else {
            hygiene.setMode(mode, riskAcknowledged: false)
        }
    }

    func setKillSwitch(_ engaged: Bool) {
        if engaged {
            hygiene.engageKillSwitch()
        } else {
            hygiene.disengageKillSwitch()
        }
    }

    func setCaptureEnabled(_ enabled: Bool) {
        hygiene.setCaptureEnabled(enabled)
        archive?.isEnabled = enabled
        if enabled {
            archive?.reconcile()
        }
    }

    func setRetentionDays(_ days: Int) {
        hygiene.setRetentionDays(days)
        archive?.setRetentionDays(days)
    }

    // MARK: Archive

    func reveal(_ entry: TmuxArchiveIndexEntry) {
        guard let archive else { return }
        do {
            revealed = try archive.reveal(captureID: entry.captureID)
        } catch {
            errorMessage = "The capture could not be decrypted."
        }
    }

    func exportRevealed(to url: URL) {
        guard let revealed, let archive else { return }
        guard confirm(.exportPlaintext) else { return }
        do {
            try archive.exportPlaintext(
                captureID: revealed.metadata.captureID,
                to: url
            )
            statusMessage = "Exported a plaintext copy."
        } catch {
            errorMessage = "The export failed."
        }
    }

    // MARK: Adoption

    func beginAdoption() {
        guard !isWorking else { return }
        adoptionGeneration &+= 1
        showingAdoption = true
        adoptionResults = [:]
        lastBulkRows = []
        if adoptionDestinationID == nil {
            adoptionDestinationID = adoptionDestinations.first?.id
        }
        updateAdoptionDefaults()
    }

    func updateAdoptionDefaults() {
        guard let destinationID = adoptionDestinationID else {
            adoptionSourcePath = nil
            adoptionPreview = nil
            return
        }
        if let hint = migrationSourceHint(destinationID) {
            adoptionSourcePath = hint
        } else if let current = adoptionSourcePath,
                  adoptionSourceCandidates.contains(current) {
            // Keep a valid manual selection.
        } else {
            adoptionSourcePath = adoptionSourceCandidates.first
        }
    }

    func prepareAdoption() async {
        guard !isWorking else { return }
        adoptionGeneration &+= 1
        let generation = adoptionGeneration
        await refresh()
        guard generation == adoptionGeneration, !isWorking else {
            return
        }
        releasePreviewReservations()
        adoptionPreview = nil
        guard let destination = adoptionDestinations.first(where: {
            $0.id == adoptionDestinationID
        }), let snapshot = hygiene.snapshot,
        let sourcePath = adoptionSourcePath else {
            errorMessage = "Choose a destination project and a source."
            return
        }
        let preview = migration.prepare(
            sourcePath: sourcePath,
            destinationPath: destination.id,
            destinationPrefix: destination.prefix,
            snapshot: snapshot,
            destinationIdentity: destination.identity,
            sourceIdentity: folderIdentity(sourcePath)
        )
        adoptionPreview = preview
        reservedPreviewNames = preview.reservedNames
        reserveNames(preview.reservedNames)
    }

    func cancelAdoption() {
        guard !isWorking else { return }
        dismissAdoption()
    }

    /// A picker change invalidates the preview and its reservations. Adopt
    /// must never execute a preview for a different source.
    func adoptionSelectionChanged() {
        guard !isWorking else { return }
        adoptionGeneration &+= 1
        releasePreviewReservations()
        adoptionPreview = nil
    }

    func adoptionSheetDismissed() {
        guard !isWorking else { return }
        // A dismissal during an awaited preparation must still invalidate it.
        dismissAdoption()
    }

    private func dismissAdoption() {
        adoptionGeneration &+= 1
        releasePreviewReservations()
        adoptionPreview = nil
        showingAdoption = false
    }

    private func releasePreviewReservations() {
        guard !reservedPreviewNames.isEmpty else { return }
        releaseNames(reservedPreviewNames)
        reservedPreviewNames = []
    }

    func confirmAdoption() async {
        guard !isWorking else { return }
        guard let preview = adoptionPreview,
              let coordinator,
              let destinationID = adoptionDestinationID else {
            return
        }
        guard let selectedSource = adoptionSourcePath,
              TmuxKnownPaths.canonical(selectedSource)
                == preview.sourcePath else {
            adoptionSelectionChanged()
            errorMessage = "The source changed. Preview again."
            return
        }
        // Own the operation before the first suspension so a second action
        // cannot start and a dismissal cannot release reservations mid-run.
        isWorking = true
        var releaseReservations = true
        defer {
            isWorking = false
            if releaseReservations {
                releasePreviewReservations()
            }
        }
        let generation = adoptionGeneration
        await refresh()
        guard generation == adoptionGeneration,
              adoptionPreview == preview,
              adoptionDestinationID == destinationID,
              adoptionSourcePath == selectedSource else {
            errorMessage = "The adoption selection changed. Preview again."
            return
        }
        guard let destination = adoptionDestinations.first(where: {
            $0.id == destinationID
        }), let snapshot = hygiene.snapshot else {
            errorMessage = "The destination project is no longer open."
            return
        }
        let revalidated = migration.prepare(
            sourcePath: preview.sourcePath,
            destinationPath: destination.id,
            destinationPrefix: destination.prefix,
            snapshot: snapshot,
            destinationIdentity: destination.identity,
            sourceIdentity: folderIdentity(preview.sourcePath)
        )
        guard revalidated == preview else {
            releasePreviewReservations()
            reservedPreviewNames = revalidated.reservedNames
            reserveNames(revalidated.reservedNames)
            adoptionPreview = revalidated
            releaseReservations = false
            errorMessage = "The sessions changed. Review the updated preview."
            return
        }
        guard confirm(
            .adopt(
                names: preview.candidates.map(\.proposedName),
                crossVolume: preview.crossVolume
            )
        ) else {
            // Keep the preview and its reservations for another attempt.
            releaseReservations = false
            return
        }
        let results = await migration.execute(
            preview: preview,
            coordinator: coordinator,
            snapshot: snapshot,
            reserveName: { [weak self] name in
                guard let self else { return }
                self.reservedPreviewNames.append(name)
                self.reserveNames([name])
            },
            rebindTabs: rebindTabs
        )
        adoptionResults = results
        adoptionPreview = nil
        if let error = migration.lastError {
            errorMessage = error
        }
        let renamed = results.values.filter {
            if case .renamed = $0 { return true }
            return false
        }.count
        statusMessage = "Adopted \(renamed) of \(preview.candidates.count) sessions."
        await refresh()
    }

    // MARK: Reporting

    private func report(
        _ outcome: TmuxActionOutcome,
        name: String
    ) {
        switch outcome {
        case .ended:
            statusMessage = "Ended \(name)."
        case .absent:
            statusMessage = "\(name) was already gone."
        case let .skipped(reason):
            errorMessage = "Skipped \(name): \(reason)"
        case let .refused(reason):
            errorMessage = "Refused \(name): \(reason)"
        case let .uncertain(reason):
            errorMessage = "Uncertain \(name): \(reason). Automatic actions are blocked for it."
        case let .notAttempted(reason):
            errorMessage = "Not attempted \(name): \(reason)"
        }
    }

    private static func defaultConfirm(
        _ request: SessionsConfirmation
    ) -> Bool {
        let alert = NSAlert()
        switch request {
        case let .endOne(name):
            alert.messageText = "End \(name)?"
            alert.informativeText =
                "The agent and the processes attached to this tmux session "
                + "will stop. A process started from a window shared with "
                + "another session may keep running."
            alert.addButton(withTitle: "End Session")
        case let .endBulk(names, explicitStates):
            alert.messageText = "End \(names.count) sessions?"
            var text = names.joined(separator: "\n")
            if !explicitStates.isEmpty {
                text += "\n\nMay be running work:\n"
                    + explicitStates.joined(separator: "\n")
            }
            alert.informativeText = text
            alert.addButton(withTitle: "End Sessions")
        case let .captureIncomplete(name):
            alert.messageText = "Capture for \(name) is not committed complete."
            alert.informativeText =
                "Ending now may lose scrollback that could not be captured."
            alert.addButton(withTitle: "End Anyway")
        case .enableKill:
            alert.messageText = "Enable automatic cleanup?"
            alert.informativeText =
                "This cannot prove a shell is idle. A builtin loop or a "
                + "process starting at dispatch can be lost. Only enable if "
                + "you accept that risk."
            alert.addButton(withTitle: "Enable Kill Mode")
        case let .adopt(names, crossVolume):
            alert.messageText = "Adopt \(names.count) sessions?"
            var text = names.joined(separator: "\n")
            if crossVolume {
                text += "\n\nThis spans volumes. Running processes may still "
                    + "operate in the old tree."
            }
            alert.informativeText = text
            alert.addButton(withTitle: "Adopt")
        case .exportPlaintext:
            alert.messageText = "Export a plaintext capture?"
            alert.informativeText =
                "The exported file is not encrypted and is not protected "
                + "by Sonovo. Anyone who can read it can read the terminal "
                + "contents."
            alert.addButton(withTitle: "Export Plaintext")
        }
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Window

struct TmuxSessionsWindow: View {
    @Bindable var model: TmuxSessionsWindowModel
    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header
            Divider()
            if !model.hygiene.isAvailable {
                missingTmux
            } else {
                filtersBar
                Divider()
                content
                Divider()
                bulkBar
                bulkResultsSection
                Divider()
                cleanupSection
            }
            Divider()
            footer
        }
        .frame(
            minWidth: AppTheme.Layout.sessionsMinWidth,
            minHeight: AppTheme.Layout.sessionsDefaultHeight
        )
        .background(AppTheme.Palette.window)
        .task {
            await model.refresh()
        }
        .sheet(isPresented: $model.showingAdoption) {
            adoptionSheet
                .onDisappear {
                    model.adoptionSheetDismissed()
                }
        }
        .sheet(isPresented: revealBinding) {
            revealSheet
        }
        .alert(
            "Sessions",
            isPresented: errorBinding
        ) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "Sessions",
            isPresented: statusBinding
        ) {
            Button("OK", role: .cancel) {
                model.statusMessage = nil
            }
        } message: {
            Text(model.statusMessage ?? "")
        }
    }

    private var revealBinding: Binding<Bool> {
        Binding(
            get: { model.revealed != nil },
            set: { if !$0 { model.revealed = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var statusBinding: Binding<Bool> {
        Binding(
            get: { model.statusMessage != nil },
            set: { if !$0 { model.statusMessage = nil } }
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Sonovo Sessions")
                .font(
                    .system(
                        size: AppTheme.TypeScale.title,
                        weight: .semibold
                    )
                )
            Text(summaryLine)
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppTheme.Spacing.sm) {
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Adopt Sessions…") {
                    model.beginAdoption()
                }
                .controlSize(.small)
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .controlSize(.small)
                .disabled(model.hygiene.isScanning)
                Spacer(minLength: AppTheme.Spacing.zero)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private var summaryLine: String {
        let summary = model.summary
        let completeness: String
        switch model.hygiene.completeness {
        case .complete: completeness = "complete scan"
        case let .incomplete(reason): completeness = "incomplete: \(reason)"
        case .unknown: completeness = "scan unknown"
        }
        let scan = model.hygiene.snapshot.map {
            $0.scannedAt.formatted(date: .omitted, time: .standard)
        } ?? "never"
        var line = "\(summary.total) sessions · \(summary.attached) attached · "
            + "\(summary.running) running · \(summary.noCommand) no command · "
            + "\(summary.unknownProcess) unknown · \(summary.shared) shared · "
            + "\(summary.candidates) candidates · "
            + "\(summary.uncertain) uncertain · last scan \(scan) · "
            + completeness + " · cleanup \(model.cleanupMode.rawValue)"
        if let error = model.hygiene.lastScanError {
            line += " · \(error)"
        }
        return line
    }

    private var filtersBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.sm) {
                filterToggle("Attached", isOn: $model.filters.showAttached)
                filterToggle("Running", isOn: $model.filters.showRunning)
                filterToggle("No Command", isOn: $model.filters.showIdle)
                filterToggle("Unknown", isOn: $model.filters.showUnknown)
                filterToggle("Shared", isOn: $model.filters.showShared)
                filterToggle(
                    "Candidates Only",
                    isOn: $model.filters.candidatesOnly
                )
                Spacer(minLength: AppTheme.Spacing.sm)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs)
        }
    }

    private func filterToggle(
        _ title: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.checkbox)
            .font(.system(size: AppTheme.TypeScale.xxs))
            .controlSize(.mini)
            .fixedSize()
    }

    private var content: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width
                >= AppTheme.Layout.sessionsListMinWidth
                    + AppTheme.Layout.sessionsDetailWidth
            if isWide {
                HStack(spacing: AppTheme.Spacing.zero) {
                    sessionList
                        .frame(
                            minWidth: AppTheme.Layout.sessionsListMinWidth,
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                    Divider()
                    details
                        .frame(
                            minWidth: AppTheme.Layout.sessionsDetailWidth,
                            maxWidth: AppTheme.Layout.sessionsDetailWidth,
                            maxHeight: .infinity
                        )
                }
            } else {
                VStack(spacing: AppTheme.Spacing.zero) {
                    sessionList
                        .frame(
                            minHeight: AppTheme.Layout.sessionsNarrowListMinHeight,
                            maxHeight: .infinity
                        )
                    Divider()
                    details
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private var sessionList: some View {
        List(selection: $model.selectedIdentity) {
            ForEach(model.visibleAttributes) { attribute in
                sessionRow(attribute)
                    .tag(attribute.identity)
            }
            if model.visibleAttributes.isEmpty {
                Text("No sessions match the filters.")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(AppTheme.Spacing.lg)
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, AppTheme.Size.sessionRowMinHeight)
    }

    private func sessionRow(
        _ attribute: TmuxSessionAttributes
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            wideSessionRow(attribute)
            compactSessionRow(attribute)
        }
        .contentShape(Rectangle())
        .contextMenu {
            rowActions(attribute)
        }
    }

    @ViewBuilder
    private func selectionControl(
        _ attribute: TmuxSessionAttributes
    ) -> some View {
        if attribute.tier == .excluded,
           !model.bulkSelection.contains(attribute.identity) {
            Image(systemName: "minus.square")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.tertiary)
                .frame(width: AppTheme.ControlSize.compact)
        } else {
            Button {
                model.toggleBulk(attribute.identity)
            } label: {
                Image(
                    systemName: model.bulkSelection.contains(
                        attribute.identity
                    ) ? "checkmark.square.fill" : "square"
                )
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(
                    model.bulkSelection.contains(attribute.identity)
                        ? Color.accentColor
                        : Color.secondary
                )
            }
            .buttonStyle(.plain)
            .frame(width: AppTheme.ControlSize.compact)
        }
    }

    private func wideSessionRow(
        _ attribute: TmuxSessionAttributes
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            selectionControl(attribute)
            Circle()
                .fill(badgeColor(attribute))
                .frame(
                    width: AppTheme.Size.sessionBadge,
                    height: AppTheme.Size.sessionBadge
                )
            VStack(
                alignment: .leading,
                spacing: AppTheme.Spacing.xxs
            ) {
                Text(attribute.observation.name)
                    .font(.system(size: AppTheme.TypeScale.xs, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(associationSummary(attribute))
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(processLabel(attribute.observation.process))
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.secondary)
                .frame(
                    width: AppTheme.Size.sessionDetailLabelWidth,
                    alignment: .leading
                )
            Text(attribute.observation.sharedWindows ? "shared" : "—")
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(
                    attribute.observation.sharedWindows
                        ? AppTheme.Palette.warning
                        : AppTheme.Palette.tertiaryLabel
                )
                .frame(
                    width: AppTheme.Size.sessionDetailLabelWidth,
                    alignment: .leading
                )
            Text(attribute.idleLabel ?? "—")
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(
                    attribute.thresholdReached
                        && !TmuxIdleThreshold.isSuggestionOnly(
                            attribute.association
                        )
                        ? AppTheme.Palette.warning
                        : AppTheme.Palette.secondaryLabel
                )
                .frame(
                    width: AppTheme.Size.sessionDetailLabelWidth,
                    alignment: .leading
                )
            Text(archiveLabel(attribute))
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.secondary)
                .frame(
                    width: AppTheme.Size.sessionDetailLabelWidth,
                    alignment: .leading
                )
                .help(attribute.permissions.reasons.joined(separator: "\n"))
        }
    }

    private func compactSessionRow(
        _ attribute: TmuxSessionAttributes
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            selectionControl(attribute)
            Circle()
                .fill(badgeColor(attribute))
                .frame(
                    width: AppTheme.Size.sessionBadge,
                    height: AppTheme.Size.sessionBadge
                )
            VStack(
                alignment: .leading,
                spacing: AppTheme.Spacing.xxs
            ) {
                Text(attribute.observation.name)
                    .font(.system(size: AppTheme.TypeScale.xs, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(compactRowDetail(attribute))
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func associationSummary(
        _ attribute: TmuxSessionAttributes
    ) -> String {
        associationLabel(attribute)
            + (attribute.observation.attachedClients > 0
                ? " · attached"
                : "")
    }

    private func compactRowDetail(
        _ attribute: TmuxSessionAttributes
    ) -> String {
        [
            associationSummary(attribute),
            processLabel(attribute.observation.process),
            attribute.observation.sharedWindows ? "shared" : nil,
            attribute.idleLabel.map { "idle \($0)" },
            archiveLabel(attribute)
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    @ViewBuilder
    private func rowActions(
        _ attribute: TmuxSessionAttributes
    ) -> some View {
        Button("End") {
            model.selectedIdentity = attribute.identity
            Task { await model.endSelected() }
        }
        .disabled(model.isWorking)
        Button("Capture & End") {
            model.selectedIdentity = attribute.identity
            Task { await model.captureAndEndSelected() }
        }
        .disabled(model.isWorking)
        if attribute.uncertain {
            Button("Mark Reconciled") {
                model.selectedIdentity = attribute.identity
                model.reconcileSelected()
            }
            .disabled(model.isWorking)
        }
    }

    private var details: some View {
        ScrollView {
            VStack(
                alignment: .leading,
                spacing: AppTheme.Spacing.sm
            ) {
                if let attribute = model.selectedVisibleAttribute {
                    detailHeader(attribute)
                    Divider()
                    detailRow(
                        "Name",
                        attribute.observation.name
                    )
                    detailRow(
                        "Session ID",
                        attribute.observation.sessionID
                    )
                    detailRow(
                        "Socket",
                        attribute.observation.server.socketPath
                    )
                    detailRow(
                        "Server PID",
                        String(attribute.observation.server.pid)
                    )
                    detailRow(
                        "Project",
                        attribute.observation.ownership.verifiedProjectPath
                            ?? "Unverified"
                    )
                    detailRow(
                        "Ownership",
                        ownershipLabel(attribute.observation.ownership)
                    )
                    detailRow(
                        "Association",
                        attribute.association.rawValue
                    )
                    detailRow(
                        "Bulk Tier",
                        attribute.tier == .idleBulk
                            ? "Tier 1 · idle"
                            : attribute.tier == .explicitBulk
                                ? "Tier 2 · explicit"
                                : "Excluded"
                    )
                    detailRow(
                        "Attached",
                        String(attribute.observation.attachedClients)
                    )
                    detailRow(
                        "Windows",
                        String(attribute.observation.windows)
                    )
                    detailRow(
                        "Shared Windows",
                        attribute.observation.sharedWindows ? "Yes" : "No"
                    )
                    detailRow(
                        "Process",
                        processLabel(attribute.observation.process)
                    )
                    detailRow(
                        "First Observed Idle",
                        attribute.observedIdle.map {
                            formatIdle($0)
                        } ?? "—"
                    )
                    detailRow(
                        "Idle Threshold",
                        attribute.idleThreshold.map {
                            formatIdle($0)
                                + (TmuxIdleThreshold.isSuggestionOnly(
                                    attribute.association
                                ) ? " (suggestion)" : "")
                                + (attribute.thresholdReached
                                    ? " · reached"
                                    : "")
                        } ?? "—"
                    )
                    detailRow(
                        "Archive",
                        archiveLabel(attribute)
                    )
                    detailRow(
                        "Active Path",
                        attribute.observation.activePath ?? "—"
                    )
                    detailRow(
                        "Panes",
                        String(attribute.observation.paneCount)
                    )
                    detailRow(
                        "Last Scan",
                        model.hygiene.snapshot.map {
                            $0.scannedAt.formatted(
                                date: .omitted,
                                time: .standard
                            )
                        } ?? "never"
                    )
                    detailRow(
                        "Automatic",
                        attribute.permissions.canAutoEnd
                            ? "Eligible"
                            : attribute.autoEligibility.eligible
                                ? "Eligible in kill mode"
                                : "Not eligible"
                    )
                    if let latest = archiveEntry(attribute) {
                        Button("Reveal Capture…") {
                            model.reveal(latest)
                        }
                        .controlSize(.small)
                    }
                    if !attribute.permissions.reasons.isEmpty {
                        Text(
                            attribute.permissions.reasons
                                .joined(separator: " ")
                        )
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Select a session to see its details.")
                        .font(.system(size: AppTheme.TypeScale.xs))
                        .foregroundStyle(.secondary)
                        .padding(.top, AppTheme.Spacing.lg)
                }
            }
            .padding(AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailHeader(
        _ attribute: TmuxSessionAttributes
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: AppTheme.Spacing.xs
        ) {
            Text("Session")
                .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle()
                    .fill(badgeColor(attribute))
                    .frame(
                        width: AppTheme.Size.sessionBadge,
                        height: AppTheme.Size.sessionBadge
                    )
                Text(attribute.observation.name)
                    .font(.system(size: AppTheme.TypeScale.sm, weight: .semibold))
                    .textSelection(.enabled)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    detailOpenActions(attribute)
                    detailEndActions(attribute)
                }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        detailOpenActions(attribute)
                    }
                    HStack(spacing: AppTheme.Spacing.xs) {
                        detailEndActions(attribute)
                    }
                }
            }
            if !attribute.permissions.canOpen {
                Text(openExplanation(attribute))
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openExplanation(
        _ attribute: TmuxSessionAttributes
    ) -> String {
        if !attribute.observation.ownership.isVerified {
            return "Open requires verified ownership."
        }
        return "Open is available only for the project currently open in the workspace."
    }

    @ViewBuilder
    private func detailOpenActions(
        _ attribute: TmuxSessionAttributes
    ) -> some View {
        Button("Open") {
            model.openSelected()
        }
        .controlSize(.small)
        .disabled(!attribute.permissions.canOpen)
        Button("Copy Attach") {
            model.copyAttachCommand()
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func detailEndActions(
        _ attribute: TmuxSessionAttributes
    ) -> some View {
        Button("End") {
            Task { await model.endSelected() }
        }
        .controlSize(.small)
        .disabled(model.isWorking)
        Button("Capture & End") {
            Task { await model.captureAndEndSelected() }
        }
        .controlSize(.small)
        .disabled(model.isWorking)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(
            alignment: .firstTextBaseline,
            spacing: AppTheme.Spacing.sm
        ) {
            Text(label)
                .font(.system(size: AppTheme.TypeScale.xxs, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(
                    width: AppTheme.Size.sessionDetailLabelWidth,
                    alignment: .leading
                )
            Text(value)
                .font(.system(size: AppTheme.TypeScale.xxs))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bulkBar: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(
                    "\(model.bulkSelection.count) selected"
                        + (model.bulkExplicitCount > 0
                            ? " · \(model.bulkExplicitCount) explicit"
                            : "")
                )
                .font(.system(size: AppTheme.TypeScale.xxs))
                if model.bulkExplicitCount > 0 {
                    Toggle(
                        "May be running work",
                        isOn: $model.explicitAcknowledged
                    )
                    .toggleStyle(.checkbox)
                    .font(.system(size: AppTheme.TypeScale.xxs))
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Button("Select Idle") {
                        model.selectIdleCandidates()
                    }
                    .controlSize(.small)
                    Button("Clear") {
                        model.clearBulkSelection()
                    }
                    .controlSize(.small)
                    .disabled(model.bulkSelection.isEmpty)
                    if model.bulkCancellation != nil {
                        Button("Cancel") {
                            model.cancelBulk()
                        }
                        .controlSize(.small)
                    }
                    Button("End Selected") {
                        Task { await model.runBulk() }
                    }
                    .controlSize(.small)
                    .disabled(!model.canRunBulk || model.isWorking)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    @ViewBuilder
    private var bulkResultsSection: some View {
        if !model.lastBulkRows.isEmpty {
            DisclosureGroup("Last Bulk Result") {
                VStack(
                    alignment: .leading,
                    spacing: AppTheme.Spacing.xxs
                ) {
                    ForEach(model.lastBulkRows) { row in
                        Text(
                            "\(row.name) — \(outcomeLabel(row.outcome))"
                                + (row.outcome.reason.map { ": \($0)" } ?? "")
                        )
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: AppTheme.TypeScale.xxs))
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs)
        }
    }

    private func outcomeLabel(_ outcome: TmuxActionOutcome) -> String {
        switch outcome {
        case .ended: "ended"
        case .absent: "absent"
        case .skipped: "skipped"
        case .refused: "refused"
        case .uncertain: "uncertain"
        case .notAttempted: "not attempted"
        }
    }

    private var cleanupSection: some View {
        VStack(
            alignment: .leading,
            spacing: AppTheme.Spacing.xs
        ) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Automatic Cleanup")
                    .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                Spacer(minLength: AppTheme.Spacing.zero)
                Text(
                    model.killSwitchEngaged
                        ? "New dispatches are blocked."
                        : model.hygiene.settings.isArmed
                            ? "Armed"
                            : "Not armed"
                )
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.secondary)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                Picker("Mode", selection: modeBinding) {
                    Text("Off").tag(AutomaticCleanupMode.off)
                    Text("Preview").tag(AutomaticCleanupMode.preview)
                    Text("Kill").tag(AutomaticCleanupMode.kill)
                }
                .pickerStyle(.segmented)
                .frame(width: AppTheme.Layout.settingsPickerNarrowWidth)
                .labelsHidden()
                Toggle("Capture before End", isOn: captureBinding)
                    .toggleStyle(.checkbox)
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .fixedSize()
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                Toggle("Kill Switch", isOn: killSwitchBinding)
                    .toggleStyle(.checkbox)
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .disabled(model.cleanupMode == .off)
                    .fixedSize()
                Stepper(value: retentionBinding, in: 1...365) {
                    Text("Keep \(model.hygiene.settings.retentionDays)d")
                        .font(.system(size: AppTheme.TypeScale.xxs))
                }
                Spacer(minLength: AppTheme.Spacing.zero)
            }
            if !model.hygiene.previewIdentities.isEmpty {
                Text(
                    "Preview would end: "
                        + model.hygiene.attributes
                        .filter {
                            model.hygiene.previewIdentities.contains(
                                $0.identity
                            )
                        }
                        .map(\.observation.name)
                        .joined(separator: ", ")
                )
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(AppTheme.Palette.warning)
            }
            if model.coordinator?.hasCorruptUncertainty == true {
                Text(
                    "The unresolved-action store is corrupt or could not "
                        + "be written; automatic actions are blocked until "
                        + "it is repaired."
                )
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(AppTheme.Palette.warning)
            }
            if let report = model.hygiene.lastAutomaticReport {
                Text(reportLine(report))
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)
            }
            if let failures = model.archive?.latestPurgeFailures(),
               !failures.isEmpty {
                Text("Archive purge: \(failures.joined(separator: " "))")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(AppTheme.Palette.warning)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    private var modeBinding: Binding<AutomaticCleanupMode> {
        Binding(
            get: { model.cleanupMode },
            set: { model.setCleanupMode($0) }
        )
    }

    private var captureBinding: Binding<Bool> {
        Binding(
            get: { model.captureEnabled },
            set: { model.setCaptureEnabled($0) }
        )
    }

    private var killSwitchBinding: Binding<Bool> {
        Binding(
            get: { model.killSwitchEngaged },
            set: { model.setKillSwitch($0) }
        )
    }

    private var retentionBinding: Binding<Int> {
        Binding(
            get: { model.hygiene.settings.retentionDays },
            set: { model.setRetentionDays($0) }
        )
    }

    private var missingTmux: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "terminal")
                .font(
                    .system(
                        size: AppTheme.TypeScale.display,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(.tertiary)
            Text("tmux is not available")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
            Text("Install with: brew install tmux")
                .font(.system(size: AppTheme.TypeScale.xs))
                .textSelection(.enabled)
            Text(
                "Without tmux, Sonovo starts a direct shell in each tab. "
                    + "Those shells are not persistent and are not listed here."
            )
            .font(.system(size: AppTheme.TypeScale.xxs))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Button("Recheck") {
                Task { await model.refresh() }
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("Only Sonovo sessions are listed.")
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.secondary)
            Spacer()
            if model.hygiene.isScanning {
                Text("Scanning…")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    private var adoptionSheet: some View {
        VStack(
            alignment: .leading,
            spacing: AppTheme.Spacing.sm
        ) {
            adoptionHeader
            adoptionConfiguration
            if let preview = model.adoptionPreview {
                adoptionPreview(preview)
            }
            if !model.adoptionResults.isEmpty {
                adoptionResults
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(
            minWidth: AppTheme.Layout.sessionsMinWidth,
            idealWidth: AppTheme.Layout.settingsWidth
        )
    }

    private var adoptionHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Adopt Sessions")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .semibold))
            Text(
                "Renames sessions and moves ownership to an open project. "
                    + "Running processes are kept; their working directories "
                    + "are not changed."
            )
            .font(.system(size: AppTheme.TypeScale.xxs))
            .foregroundStyle(.secondary)
        }
    }

    private var adoptionConfiguration: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Picker("Destination", selection: $model.adoptionDestinationID) {
                ForEach(model.adoptionDestinations) { choice in
                    Text(choice.name).tag(Optional(choice.id))
                }
            }
            .disabled(model.isWorking)
            .onChange(of: model.adoptionDestinationID) { _, _ in
                model.adoptionSelectionChanged()
                model.updateAdoptionDefaults()
            }
            Picker("Source", selection: $model.adoptionSourcePath) {
                Text("Choose…").tag(String?.none)
                ForEach(model.adoptionSourceCandidates, id: \.self) {
                    path in
                    Text(path).tag(Optional(path))
                }
            }
            .disabled(model.isWorking)
            .onChange(of: model.adoptionSourcePath) { _, _ in
                model.adoptionSelectionChanged()
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Preview") {
                    Task { await model.prepareAdoption() }
                }
                .controlSize(.small)
                .disabled(model.isWorking)
                Button("Cancel") {
                    model.cancelAdoption()
                }
                .controlSize(.small)
                .disabled(model.isWorking)
                Spacer()
                Button("Adopt") {
                    Task { await model.confirmAdoption() }
                }
                .controlSize(.small)
                .disabled(model.adoptionPreview == nil || model.isWorking)
            }
        }
    }

    private func adoptionPreview(
        _ preview: TmuxMigrationPreview
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if preview.excludedNames.isEmpty {
                Text("\(preview.candidates.count) sessions will be renamed.")
                    .font(.system(size: AppTheme.TypeScale.xs))
            } else {
                Text(
                    "Excluded until resolved: "
                        + preview.excludedNames.joined(separator: ", ")
                )
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(AppTheme.Palette.warning)
            }
            if preview.crossVolume {
                Text(
                    "The source and destination are on different volumes. "
                        + "Processes may still operate in the old tree."
                )
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(AppTheme.Palette.warning)
            }
            Text(
                preview.identityMatched
                    ? "Folder identity matched."
                    : "Folder identity is missing or ambiguous; the source "
                        + "was selected manually."
            )
            .font(.system(size: AppTheme.TypeScale.xxs))
            .foregroundStyle(.secondary)
            Text(
                "If a name is taken at commit, one bounded reallocation "
                    + "above the highest destination index is attempted."
            )
            .font(.system(size: AppTheme.TypeScale.xxs))
            .foregroundStyle(.secondary)
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: AppTheme.Spacing.xxs
                ) {
                    ForEach(preview.candidates) { candidate in
                        Text(
                            "\(candidate.currentName) → "
                                + candidate.proposedName
                        )
                        .font(.system(size: AppTheme.TypeScale.xxs))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: AppTheme.Layout.settingsReadingPreviewHeight)
        }
    }

    private var adoptionResults: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Divider()
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: AppTheme.Spacing.xxs
                ) {
                    ForEach(Array(model.adoptionResults), id: \.key) {
                        identity,
                        outcome in
                        Text("\(identity.sessionID): \(outcomeLabel(outcome))")
                            .font(.system(size: AppTheme.TypeScale.xxs))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: AppTheme.Layout.settingsReadingPreviewHeight)
        }
    }

    private var revealSheet: some View {
        VStack(
            alignment: .leading,
            spacing: AppTheme.Spacing.sm
        ) {
            if let revealed = model.revealed {
                Text("Capture \(revealed.metadata.sessionName)")
                    .font(
                        .system(
                            size: AppTheme.TypeScale.lg,
                            weight: .semibold
                        )
                    )
                Text(
                    "\(revealed.metadata.capturedAt.formatted()) · "
                        + "\(revealed.metadata.contentOutcome.rawValue) · "
                        + "\(revealed.metadata.byteCount) bytes"
                )
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.secondary)
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: AppTheme.Spacing.sm
                    ) {
                        ForEach(
                            Array(revealed.panes.enumerated()),
                            id: \.offset
                        ) { _, pane in
                            Text(pane.text)
                                .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )
                        }
                    }
                }
                HStack(spacing: AppTheme.Spacing.sm) {
                    Button("Export Plaintext…") {
                        exportPlaintext(revealed)
                    }
                    .controlSize(.small)
                    Button("Close") {
                        model.revealed = nil
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(
            minWidth: AppTheme.Layout.settingsWidth,
            minHeight: AppTheme.Layout.sessionsDefaultHeight
        )
    }

    private func exportPlaintext(_ revealed: TmuxRevealedCapture) {
        let panel = NSSavePanel()
        panel.title = "Export Plaintext Capture"
        panel.nameFieldStringValue =
            "\(revealed.metadata.sessionName)-capture.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportRevealed(to: url)
    }

    private func badgeColor(_ attribute: TmuxSessionAttributes) -> Color {
        if attribute.uncertain {
            return AppTheme.Palette.warning
        }
        switch attribute.observation.process {
        case .running:
            return AppTheme.Palette.success
        case .noCommandDetected:
            return attribute.observation.attachedClients > 0
                ? AppTheme.Palette.info
                : AppTheme.Palette.tertiaryLabel
        case .unknown:
            return AppTheme.Palette.secondaryLabel
        }
    }

    private func processLabel(_ process: ProcessObservation) -> String {
        switch process {
        case .running: "Running"
        case .noCommandDetected: "No command"
        case .unknown: "Unknown"
        }
    }

    private func ownershipLabel(_ ownership: Ownership) -> String {
        switch ownership {
        case .verified: "Verified"
        case .unmapped: "Unmapped (manual only)"
        case .unrecognized: "Unrecognized name"
        }
    }

    private func associationLabel(
        _ attribute: TmuxSessionAttributes
    ) -> String {
        switch attribute.association {
        case .inWorkspace: "Open project"
        case .recentlyClosed: "Recently closed"
        case .other: "Not in workspace or history"
        case .sample: "Sample"
        case .unknown: "Association unknown"
        }
    }

    private func archiveLabel(_ attribute: TmuxSessionAttributes) -> String {
        guard let archive = model.archive, archive.isEnabled else {
            return "Off"
        }
        if attribute.captureCommitted { return "Complete" }
        if let latest = archive.latestEntry(identity: attribute.identity) {
            return latest.metadata.contentOutcome.rawValue.capitalized
        }
        return "None"
    }

    private func archiveEntry(
        _ attribute: TmuxSessionAttributes
    ) -> TmuxArchiveIndexEntry? {
        model.archive?.latestEntry(identity: attribute.identity)
    }

    private func formatIdle(_ interval: TimeInterval) -> String {
        let days = Int(interval / (24 * 60 * 60))
        let hours = Int(interval / (60 * 60)) % 24
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h"
    }

    private func outcomeLabel(_ outcome: TmuxMigrationOutcome) -> String {
        switch outcome {
        case .renamed: "renamed"
        case .absent: "absent"
        case .nameTaken: "name taken"
        case let .uncertain(reason): "uncertain: \(reason)"
        case let .failed(reason): "failed: \(reason)"
        case let .notAttempted(reason): "not attempted: \(reason)"
        }
    }

    private func reportLine(_ report: TmuxCleanupRunReport) -> String {
        if report.mode == .preview {
            return "Last preview: "
                + (report.previewNames.isEmpty
                    ? "nothing eligible"
                    : report.previewNames.joined(separator: ", "))
        }
        let counts = Dictionary(
            grouping: report.rows,
            by: \.outcome
        ).map { "\($0.key) \($0.value.count)" }
        var line = "Last run: " + (
            counts.isEmpty ? "no rows" : counts.joined(separator: ", ")
        )
        if let failure = report.transportFailure {
            line += " · \(failure)"
        }
        return line
    }
}
