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
@Observable
final class AppState {
    let production = Production.sample
    let transcript = SampleContent.transcript
    let markdown = MarkdownWorkspace()

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
    /// Explicit review decisions, keyed by asset. Reopening an asset that
    /// shipped as approved must be able to move it back to needs-review;
    /// removing an "approved" flag cannot do that.
    var reviewStatusOverrides: [String: ReviewStatus] = [:]

    var activityText: String {
        if isPlaying {
            return "Playing \(selectedAsset?.name ?? "media")"
        }
        return production.updated
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

    /// The name the top chrome should show for a tab. A script tab hosts the
    /// Markdown workspace, whose open document is the file actually being
    /// edited; the production asset name would describe the demo slot, not
    /// the file.
    func displayName(for tab: EditorTab) -> String {
        guard tab.kind == .script,
              tab.id == selectedTabID,
              let document = markdown.selectedDocument else {
            return tab.title
        }
        return document.fileURL?.lastPathComponent ?? "Untitled"
    }

    func displayName(for asset: ProductionAsset) -> String {
        guard asset.kind == .script,
              selectedTab?.assetID == asset.id,
              let document = markdown.selectedDocument else {
            return asset.name
        }
        return document.fileURL?.lastPathComponent ?? "Untitled"
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

    var canUseReviewModes: Bool {
        guard let kind = selectedTab?.kind else { return false }
        return kind == .audio || kind == .video
    }

    func status(for asset: ProductionAsset) -> ReviewStatus {
        reviewStatusOverrides[asset.id] ?? asset.status
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
        if let existing = openTabs.first(where: { $0.assetID == id }) {
            selectTab(existing.id)
        } else {
            let tab = EditorTab(asset: asset)
            openTabs.append(tab)
            selectTab(tab.id)
        }
    }

    func selectTab(_ id: String) {
        guard let tab = openTabs.first(where: { $0.id == id }) else { return }
        selectedTabID = id
        selectedAssetID = tab.assetID
        // One eligibility rule for every navigation path: review modes
        // require an audio or video asset.
        if !canUseReviewModes {
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
        reviewStatusOverrides[asset.id] = .approved
    }

    func reopen(_ asset: ProductionAsset) {
        reviewStatusOverrides[asset.id] = .needsReview
    }

    func requestChange(for asset: ProductionAsset) {
        insertNote("Requested a change to \(asset.name).")
        inspectorVisible = true
        inspectorTab = .notes
    }

    /// Brings the Markdown workspace's tab to the front. Menu commands that
    /// create or open a document must not leave it hidden behind an audio or
    /// delivery tab.
    func showMarkdownWorkspace() {
        if let tab = openTabs.first(where: { $0.assetID == "script-md" }) {
            selectTab(tab.id)
        } else if production.asset(id: "script-md") != nil {
            openAsset("script-md")
        }
    }

    /// Brings a Markdown document to the front so a save started from another
    /// tab fails where the document and its error are visible.
    func revealMarkdownDocument(_ document: MarkdownDocument) {
        showMarkdownWorkspace()
        if terminalPresentation == .full {
            terminalPresentation = .hidden
        }
        markdown.select(document)
    }

    func closeAllTabs() {
        openTabs.removeAll()
        selectedTabID = ""
        selectedAssetID = nil
    }

    func addNote() {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        insertNote(trimmed)
        noteDraft = ""
    }

    private func insertNote(_ text: String) {
        let timecode = TranscriptSegment.timecode(for: playhead)
        notes.insert(
            ReviewNote(
                id: "note-\(notes.count + 1)-\(Int(playhead * 100))",
                timecode: timecode,
                text: text,
                author: "You",
                createdAt: "Just now",
                isResolved: false
            ),
            at: 0
        )
    }

    func toggleNoteResolved(_ id: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].isResolved.toggle()
    }
}
