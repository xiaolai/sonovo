import CoreGraphics
import Foundation
import Observation
import SonovoCore
import SwiftUI

enum TerminalPresentation: String, CaseIterable, Hashable, Identifiable, Sendable {
    case hidden
    case split
    case full

    var id: String { rawValue }
}

enum TerminalDock: String, CaseIterable, Hashable, Identifiable, Sendable {
    case automatic
    case right
    case bottom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .right: "Right"
        case .bottom: "Bottom"
        }
    }
}

enum TerminalDockPosition: Sendable {
    case right
    case bottom
    case full
}

@MainActor
enum AppStateRegistry {
    static weak var active: AppState?
}

@MainActor
@Observable
final class AppState {
    let production = Production.sample
    let transcript = SampleContent.transcript
    let workspace: Workspace

    var navigatorMode: NavigatorMode = .production
    var columnVisibility: NavigationSplitViewVisibility = .all
    var editorMode: EditorMode = .player
    var inspectorVisible = true
    var showTabBar = true
    var showBreadcrumbs = true

    var terminalPresentation: TerminalPresentation = .hidden
    var terminalDock: TerminalDock = .automatic
    var terminalFraction: CGFloat = AppTheme.Layout.terminalDefaultFraction

    var isPlaying = false
    var playhead: Double = 4.6
    let duration: Double = 12.4
    var volume: Double = 0.8
    var isLooping = false
    var showCaptions = true

    var selectedTranscriptID: String? = "seg-2"
    var compareSplit: CGFloat = AppTheme.Layout.compareDefaultSplit
    var selectedStillIndex = 3
    var selectedShotIndex = 2
    var previewQuality = "1080p"

    var liveProject: Project { workspace.liveProject }

    /// The one activation path for UI and commands. Leaving the demo must
    /// stop its transport; a hidden demo host must not keep playing audio.
    func activateProject(_ project: Project) {
        if liveProject.isDemo, !project.isDemo {
            isPlaying = false
        }
        workspace.activate(project)
    }

    @discardableResult
    func openProject(at url: URL) -> Project? {
        let wasDemo = liveProject.isDemo
        guard let project = workspace.openProject(at: url) else {
            return nil
        }
        if wasDemo, !workspace.liveProject.isDemo {
            isPlaying = false
        }
        return project
    }

    func activateNextProject() {
        let wasDemo = liveProject.isDemo
        guard let next = workspace.activateNext() else { return }
        if wasDemo, !next.isDemo {
            isPlaying = false
        }
    }

    func activatePreviousProject() {
        let wasDemo = liveProject.isDemo
        guard let previous = workspace.activatePrevious() else { return }
        if wasDemo, !previous.isDemo {
            isPlaying = false
        }
    }
    var markdown: MarkdownWorkspace { liveProject.markdown }
    var subtitles: SubtitleWorkspace { liveProject.subtitles }
    var models: Model3DWorkspace { liveProject.models }
    var code: CodeWorkspace { liveProject.code }
    var terminalSessions: TerminalSessionsStore {
        liveProject.terminalSessions
    }
    var openTabs: [EditorTab] { liveProject.openTabs }
    var selectedTabID: String { liveProject.selectedTabID }
    var selectedAssetID: String? {
        get { liveProject.selectedAssetID }
        set { liveProject.selectedAssetID = newValue }
    }
    var filterText: String {
        get { liveProject.filterText }
        set { liveProject.filterText = newValue }
    }

    var activityText: String {
        if liveProject.isDemo {
            if isPlaying {
                return "Playing \(selectedAsset?.name ?? "media")"
            }
            return production.updated
        }
        if let reason = liveProject.offlineReason { return reason }
        return "\(liveProject.assets.count) files"
    }

    var windowTitle: String {
        liveProject.isDemo
            ? "\(production.title) — \(production.episode)"
            : liveProject.name
    }

    init() {
        let terminalEnvironment = Self.isRunningTests
            ? TerminalEnvironment.disabled
            : TerminalEnvironment.live(isEnabled: {
                UserDefaults.standard.object(
                    forKey: "sonovo.terminals.tmux"
                ) as? Bool ?? true
            })
        let demo = Project.demo(
            production: production,
            markdown: MarkdownWorkspace(),
            subtitles: SubtitleWorkspace(),
            models: Model3DWorkspace(),
            terminalSessions: TerminalSessionsStore(
                workingDirectory: "~",
                projectKey: "sample",
                projectName: "Sample",
                terminalEnvironment: terminalEnvironment
            ),
            sampleDocuments: SampleProjectDocuments.live()
        )
        workspace = Workspace(
            demoProject: demo,
            terminalEnvironment: terminalEnvironment
        )
        AppStateRegistry.active = self

        let environment = ProcessInfo.processInfo.environment
        let demoMode = environment["SONOVO_DEMO_TAB"] != nil
            || environment["SONOVO_DEMO_MODEL"] != nil
            || environment["SONOVO_DEMO_MARKDOWN"] != nil
            || environment["SONOVO_DEMO_SUBTITLE"] != nil
        if !Self.isRunningTests, !demoMode {
            workspace.restore()
        }

        if demoMode {
            workspace.activateDemo()
        }
        if let demoAssetID = environment["SONOVO_DEMO_TAB"],
           production.asset(id: demoAssetID) != nil {
            demo.openAsset(id: demoAssetID)
        }

        if let rawMode = environment["SONOVO_DEMO_MODE"],
           let mode = EditorMode(rawValue: rawMode) {
            editorMode = mode
        }

        if let rawTerminal = environment["SONOVO_DEMO_TERMINAL"] {
            let normalized = rawTerminal == "half" ? "split" : rawTerminal
            if let presentation = TerminalPresentation(rawValue: normalized) {
                terminalPresentation = presentation
            }
        }

        if environment["SONOVO_DEMO_MODEL"] != nil {
            showModel3DWorkspace()
        }
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]
            != nil
            || NSClassFromString("XCTestCase") != nil
    }

    var selectedAsset: ProductionAsset? {
        selectedAsset(in: liveProject)
    }

    /// Resolve a demo asset against a specific project. A hidden demo host
    /// must not read the active project's selection.
    func selectedAsset(in project: Project) -> ProductionAsset? {
        guard project.isDemo, let id = project.selectedAssetID else {
            return nil
        }
        return production.asset(id: id)
    }

    var selectedTab: EditorTab? {
        liveProject.selectedTab
    }

    /// The name the top chrome should show for a tab. A script or subtitle
    /// tab hosts a file workspace, whose open document is the file actually
    /// being edited; the production asset name would describe the demo slot.
    func displayName(for tab: EditorTab) -> String {
        liveProject.displayName(for: tab)
    }

    func displayName(for asset: ProductionAsset) -> String {
        displayName(for: asset, in: liveProject)
    }

    func displayName(
        for asset: ProductionAsset,
        in project: Project
    ) -> String {
        guard project.isDemo,
              project.selectedTab?.assetID == asset.id else {
            return asset.name
        }
        switch asset.kind {
        case .script:
            guard let document = project.markdown.selectedDocument else {
                return asset.name
            }
            return document.fileURL?.lastPathComponent ?? "Untitled"
        case .subtitle:
            guard let document = project.subtitles.selectedDocument else {
                return asset.name
            }
            return document.fileURL.lastPathComponent
        case .model3d:
            guard let document = project.models.selectedDocument else {
                return asset.name
            }
            return document.displayName
        default:
            return asset.name
        }
    }

    /// Counts words the way an editor footer should: whitespace-separated
    /// runs, with CJK characters counted individually because they are not
    /// space-delimited.
    func markdownWordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                inWord = false
            } else if Self.isCJK(scalar) {
                count += 1
                inWord = false
            } else if !inWord {
                count += 1
                inWord = true
            }
        }
        return count
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana and Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0x20000...0x2FA1F: // CJK Extension B and later
            return true
        default:
            return false
        }
    }

    var selectedTranscript: TranscriptSegment? {
        transcript.first { $0.id == selectedTranscriptID }
    }

    /// The segment under the playhead. Captions follow playback, skipping,
    /// and scrubbing; `selectedTranscriptID` remains the explicit transcript
    /// selection.
    var currentTranscript: TranscriptSegment? {
        if let active = transcript.first(where: {
            playhead >= $0.start && playhead < $0.end
        }) {
            return active
        }
        return transcript.last { $0.end <= playhead } ?? transcript.first
    }

    var canUseMediaModes: Bool {
        // Compare and Transcript are demo surfaces; folder projects open
        // media in the player. Enabling the controls there changed state
        // without changing the editor.
        guard liveProject.isDemo,
              let kind = selectedTab?.kind else { return false }
        return kind == .audio || kind == .video
    }

    var filteredStages: [ProductionStage] {
        liveProject.filteredStages
    }

    func openAsset(_ id: String?) {
        liveProject.openAsset(id: id)
    }

    func selectTab(_ id: String) {
        liveProject.selectTab(id)
        // One eligibility rule for every navigation path: media modes
        // require an audio or video asset.
        if !canUseMediaModes {
            editorMode = .player
        }
    }

    func closeTab(_ id: String) async {
        await liveProject.closeTab(id)
    }

    func selectTranscript(_ id: String) {
        selectedTranscriptID = id
        if let segment = transcript.first(where: { $0.id == id }) {
            playhead = segment.start + AppTheme.Layout.transcriptPlayheadOffset
        }
    }

    func togglePlayback() {
        isPlaying.toggle()
    }

    /// Brings the Markdown workspace's tab to the front. Menu commands that
    /// create or open a document must not leave it hidden behind an audio or
    /// delivery tab.
    func showMarkdownWorkspace() {
        showWorkspace(.script, demoAssetID: "script-md")
    }

    func showSubtitleWorkspace() {
        showWorkspace(.subtitle, demoAssetID: "captions-srt")
    }

    func showModel3DWorkspace() {
        showWorkspace(.model3d, demoAssetID: "model-3d")
    }

    private func showWorkspace(_ kind: AssetKind, demoAssetID: String) {
        if terminalPresentation == .full {
            terminalPresentation = .hidden
        }
        if liveProject.isDemo {
            if let tab = openTabs.first(where: {
                $0.assetID == demoAssetID
            }) {
                selectTab(tab.id)
            } else if production.asset(id: demoAssetID) != nil {
                openAsset(demoAssetID)
            }
        } else {
            liveProject.showWorkspace(kind)
        }
    }

    /// Brings a subtitle document to the front so a save started from another
    /// tab fails where the document and its error are visible.
    func revealSubtitleDocument(_ document: SubtitleDocument) {
        let owner = workspace.allProjects.first { project in
            project.subtitles.documents.contains { $0 === document }
        }
        revealDocument(
            kind: .subtitle,
            url: document.fileURL,
            owner: owner
        ) { project in
            project.subtitles.select(document)
        }
    }

    /// ⌘S dispatches on the visible editor. Saving a hidden workspace would
    /// report success for a file the user cannot see.
    var canSaveSelectedDocument: Bool {
        guard terminalPresentation != .full else { return false }
        switch selectedTab?.kind {
        case .script:
            return true
        case .subtitle:
            return subtitles.selectedDocument != nil
        case .code:
            return code.selectedDocument?.canAttemptSave == true
        default:
            return false
        }
    }

    func saveSelectedDocument() async {
        switch selectedTab?.kind {
        case .script:
            await markdown.saveSelected()
        case .subtitle:
            await subtitles.saveSelected()
        case .code:
            await code.saveSelected()
        default:
            break
        }
    }

    var canSaveSelectedDocumentAs: Bool {
        guard terminalPresentation != .full else { return false }
        switch selectedTab?.kind {
        case .script:
            return true
        case .code:
            return code.selectedDocument != nil
        default:
            return false
        }
    }

    func saveSelectedDocumentAs() async {
        switch selectedTab?.kind {
        case .script:
            await markdown.saveSelectedAs()
        case .code:
            await code.saveAsSelected()
        default:
            break
        }
    }

    /// Saves every project's workspaces before the window closes. Subtitle
    /// files always have a path, so they never ask for a save/discard
    /// decision; a failed subtitle save cancels the close and leaves the
    /// failing project active and visible.
    func flushAllBeforeClose() async -> Bool {
        let ordered = [liveProject] + workspace.allProjects.filter {
            $0 !== liveProject
        }
        // A document saved early can become dirty again while later saves
        // run. Recheck the whole set and make another pass before allowing
        // the window to close.
        for _ in 0..<3 {
            for project in ordered {
                if project.subtitles.hasDirtyDocuments {
                    let saved = await project.subtitles.flushAllForTermination()
                    guard saved else {
                        activateProject(project)
                        if let document = project.subtitles.selectedDocument {
                            revealSubtitleDocument(document)
                        }
                        return false
                    }
                }
                if project.markdown.hasDirtyDocuments {
                    let saved = await project.markdown.flushAllForTermination()
                    guard saved else {
                        activateProject(project)
                        if let document = project.markdown.pendingClose
                            ?? project.markdown.selectedDocument {
                            revealMarkdownDocument(document)
                        }
                        return false
                    }
                }
                if project.code.hasDirtyDocuments {
                    let saved = await project.code.flushAllForTermination()
                    guard saved else {
                        activateProject(project)
                        if let document = project.code.pendingClose
                            ?? project.code.selectedDocument {
                            revealCodeDocument(document)
                        }
                        return false
                    }
                }
            }
            if !workspace.hasDirtyDocuments {
                return true
            }
        }
        return false
    }

    /// The workspace that owns a pending Markdown save decision. It need not
    /// be the active project; switching projects must not hide the alert or
    /// send its buttons to the wrong workspace.
    var pendingCloseOwner: Project? {
        workspace.allProjects.first { $0.markdown.pendingClose != nil }
    }

    var pendingCloseDocument: MarkdownDocument? {
        pendingCloseOwner?.markdown.pendingClose
    }

    var pendingCodeCloseOwner: Project? {
        workspace.allProjects.first { $0.code.pendingClose != nil }
    }

    var pendingCodeCloseDocument: CodeDocument? {
        pendingCodeCloseOwner?.code.pendingClose
    }

    var hasPendingCloseDecision: Bool {
        pendingCloseDocument != nil || pendingCodeCloseDocument != nil
    }

    func savePendingClose() {
        if let owner = pendingCloseOwner,
           let document = owner.markdown.pendingClose {
            revealMarkdownDocument(document)
            Task { await owner.markdown.saveAndClose(document) }
            return
        }
        if let owner = pendingCodeCloseOwner,
           let document = owner.code.pendingClose {
            revealCodeDocument(document)
            Task { await owner.code.saveAndClose(document) }
        }
    }

    func discardPendingClose() {
        if let owner = pendingCloseOwner,
           let document = owner.markdown.pendingClose {
            owner.markdown.discardAndClose(document)
            return
        }
        if let owner = pendingCodeCloseOwner,
           let document = owner.code.pendingClose {
            owner.code.discardAndClose(document)
        }
    }

    func cancelPendingClose() {
        if let owner = pendingCloseOwner {
            owner.markdown.cancelPendingClose()
            // A bulk close that stopped at this decision stays stopped; its
            // remaining tabs must not close later when this document is
            // closed for some other reason.
            owner.cancelBulkClose()
        }
        if let owner = pendingCodeCloseOwner {
            owner.code.cancelPendingClose()
            owner.cancelBulkClose()
        }
    }

    var hasDirtyDocuments: Bool {
        workspace.hasDirtyDocuments
    }

    func prepareForTermination() {
        workspace.prepareForTermination()
    }

    /// Brings a Markdown document to the front so a save started from another
    /// tab fails where the document and its error are visible.
    func revealMarkdownDocument(_ document: MarkdownDocument) {
        let owner = workspace.allProjects.first { project in
            project.markdown.documents.contains { $0 === document }
        }
        revealDocument(
            kind: .script,
            url: document.fileURL,
            owner: owner
        ) { project in
            project.markdown.select(document)
        }
    }

    /// Brings a code document to the front for the same reason.
    func revealCodeDocument(_ document: CodeDocument) {
        let owner = workspace.allProjects.first { project in
            project.code.documents.contains { $0 === document }
        }
        revealDocument(
            kind: .code,
            url: document.fileURL,
            owner: owner
        ) { project in
            project.code.select(document)
        }
    }

    /// The production sink for a code reference. The active project and the
    /// selected terminal session are captured synchronously; the sink never
    /// creates a session.
    func codeReferenceDelivery(for project: Project) -> CodeReferenceDelivery {
        var send: ((String) -> Bool)?
        if terminalPresentation != .hidden,
           project === liveProject,
           let session = project.terminalSessions.selectedSession {
            send = { text in
                session.view.insertLiteral(text)
            }
        }
        return CodeReferenceDelivery(
            send: send,
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        )
    }

    /// The shared path for revealing a document: leave full-screen terminal,
    /// activate its owning project when known, select the tab that names it,
    /// and fall back to the workspace when the document has no owner tab.
    private func revealDocument(
        kind: AssetKind,
        url: URL?,
        owner: Project?,
        select: (Project) -> Void
    ) {
        if terminalPresentation == .full {
            terminalPresentation = .hidden
        }
        if let owner {
            activateProject(owner)
            revealTab(in: owner, kind: kind, url: url)
            select(owner)
            return
        }
        switch kind {
        case .script:
            showMarkdownWorkspace()
        case .subtitle:
            showSubtitleWorkspace()
        case .model3d:
            showModel3DWorkspace()
        default:
            break
        }
        select(liveProject)
    }

    /// Select the tab that shows this document, or a workspace tab that
    /// follows the selected document. Selecting the first tab of the kind
    /// could point the breadcrumb and inspector at a different file.
    private func revealTab(in project: Project, kind: AssetKind, url: URL?) {
        let canonical = url.map { MarkdownSecurity.canonical($0).path }
        if let canonical,
           let tab = project.openTabs.first(where: { tab in
               guard tab.kind == kind, let tabURL = tab.url else {
                   return false
               }
               return MarkdownSecurity.canonical(tabURL).path == canonical
           }) {
            project.selectTab(tab.id)
            return
        }
        if let tab = project.openTabs.first(where: { tab in
            guard tab.kind == kind else { return false }
            if case .workspace(let tabKind) = tab.content {
                return tabKind == kind
            }
            return false
        }) {
            project.selectTab(tab.id)
            return
        }
        project.selectWorkspaceTab(kind)
    }

    func closeAllTabs() async {
        await liveProject.closeAllTabs()
    }
}
