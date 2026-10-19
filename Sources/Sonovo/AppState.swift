import CoreGraphics
import Foundation
import Observation
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
@Observable
final class AppState {
    let production = Production.sample
    let transcript = SampleContent.transcript

    var navigatorMode: NavigatorMode = .production
    var columnVisibility: NavigationSplitViewVisibility = .all
    var selectedAssetID: String? = "vo-take-03"
    var openTabs: [EditorTab]
    var selectedTabID: String
    var editorMode: EditorMode = .player
    var inspectorVisible = true
    var inspectorTab: InspectorTab = .info
    var filterText = ""
    var showTabBar = true
    var showBreadcrumbs = true

    var terminalPresentation: TerminalPresentation = .hidden
    var terminalDock: TerminalDock = .automatic
    var terminalFraction: CGFloat = AppTheme.Layout.terminalDefaultFraction
    var terminalWorkingDirectory = "~"
    let terminalSessions = TerminalSessionsStore()

    var isPlaying = false
    var playhead: Double = 4.6
    let duration: Double = 12.4
    var volume: Double = 0.8
    var isLooping = false
    var showCaptions = true

    var selectedTranscriptID: String? = "seg-2"
    var notes = SampleContent.notes
    var noteDraft = ""
    var compareSplit: CGFloat = AppTheme.Layout.compareDefaultSplit
    var selectedStillIndex = 3
    var selectedShotIndex = 2
    var previewQuality = "1080p"
    var scriptRendered = true
    var approvedAssetIDs: Set<String> = []

    var activityText: String {
        isPlaying ? "Playing Take 03" : production.updated
    }

    init() {
        let sample = Production.sample
        let initialAssets = ["script-md", "vo-take-03", "take-03", "stills", "storyboard-html"]
        openTabs = initialAssets.compactMap { id in
            sample.asset(id: id).map(EditorTab.init(asset:))
        }
        selectedTabID = "vo-take-03"

        if let demoAssetID = ProcessInfo.processInfo.environment["SONOVO_DEMO_TAB"],
           let asset = sample.asset(id: demoAssetID) {
            if !openTabs.contains(where: { $0.assetID == demoAssetID }) {
                openTabs.append(EditorTab(asset: asset))
            }
            selectedTabID = demoAssetID
            selectedAssetID = demoAssetID
        }

        if let rawMode = ProcessInfo.processInfo.environment["SONOVO_DEMO_MODE"],
           let mode = EditorMode(rawValue: rawMode) {
            editorMode = mode
        }

        if let rawTerminal = ProcessInfo.processInfo.environment["SONOVO_DEMO_TERMINAL"] {
            let normalized = rawTerminal == "half" ? "split" : rawTerminal
            if let presentation = TerminalPresentation(rawValue: normalized) {
                terminalPresentation = presentation
            }
        }
    }

    var selectedAsset: ProductionAsset? {
        selectedAssetID.flatMap(production.asset(id:))
    }

    var selectedTab: EditorTab? {
        openTabs.first { $0.id == selectedTabID }
    }

    var selectedTranscript: TranscriptSegment? {
        transcript.first { $0.id == selectedTranscriptID }
    }

    var canUseReviewModes: Bool {
        guard let kind = selectedTab?.kind else { return false }
        return kind == .audio || kind == .video
    }

    func status(for asset: ProductionAsset) -> ReviewStatus {
        approvedAssetIDs.contains(asset.id) ? .approved : asset.status
    }

    var needsReviewCount: Int {
        production.allAssets.filter { status(for: $0) == .needsReview }.count
    }

    var filteredStages: [ProductionStage] {
        guard !filterText.isEmpty else { return production.stages }
        return production.stages.compactMap { stage in
            let matches = stage.assets.filter {
                $0.name.localizedCaseInsensitiveContains(filterText)
                    || $0.detail.localizedCaseInsensitiveContains(filterText)
            }
            return matches.isEmpty ? nil : ProductionStage(id: stage.id, title: stage.title, assets: matches)
        }
    }

    func openAsset(_ id: String?) {
        guard let id, let asset = production.asset(id: id) else { return }
        selectedAssetID = id
        if let existing = openTabs.first(where: { $0.assetID == id }) {
            selectedTabID = existing.id
        } else {
            let tab = EditorTab(asset: asset)
            openTabs.append(tab)
            selectedTabID = tab.id
        }
        if !canUseReviewModes {
            editorMode = .player
        }
    }

    func selectTab(_ id: String) {
        guard let tab = openTabs.first(where: { $0.id == id }) else { return }
        selectedTabID = id
        selectedAssetID = tab.assetID
        if tab.kind != .audio && tab.kind != .video && tab.kind != .delivery {
            editorMode = .player
        }
    }

    func closeTab(_ id: String) {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTabID == id
        openTabs.remove(at: index)
        guard wasSelected else { return }
        if openTabs.isEmpty {
            selectedTabID = ""
            selectedAssetID = nil
        } else {
            let nextIndex = min(index, openTabs.count - 1)
            selectTab(openTabs[nextIndex].id)
        }
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

    func newTake() {
        if let asset = selectedAsset ?? production.asset(id: "vo-take-03") {
            requestChange(for: asset)
        }
    }

    func approve(_ asset: ProductionAsset) {
        approvedAssetIDs.insert(asset.id)
    }

    func reopen(_ asset: ProductionAsset) {
        approvedAssetIDs.remove(asset.id)
    }

    func requestChange(for asset: ProductionAsset) {
        let timecode = TranscriptSegment.timecode(for: playhead)
        notes.insert(
            ReviewNote(
                id: "note-\(notes.count + 1)-\(Int(playhead * 100))",
                timecode: timecode,
                text: "Requested a change to \(asset.name).",
                author: "You",
                createdAt: "Just now",
                isResolved: false
            ),
            at: 0
        )
        inspectorVisible = true
        inspectorTab = .notes
    }

    func closeAllTabs() {
        openTabs.removeAll()
        selectedTabID = ""
        selectedAssetID = nil
    }

    func addNote() {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let timecode = TranscriptSegment.timecode(for: playhead)
        notes.insert(
            ReviewNote(
                id: "note-\(notes.count + 1)-\(Int(playhead * 100))",
                timecode: timecode,
                text: trimmed,
                author: "You",
                createdAt: "Just now",
                isResolved: false
            ),
            at: 0
        )
        noteDraft = ""
    }

    func toggleNoteResolved(_ id: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].isResolved.toggle()
    }
}
