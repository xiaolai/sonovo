import Foundation
import SonovoDomainTypes
import SonovoFileIO
import SonovoFeatureAPI
import SonovoWorkspaceHost
import SonovoMarkdownEngine
import SonovoSubtitleEngine
import SonovoMarkdownFeature
import SonovoSubtitleFeature
import SonovoCodeFeature
import SonovoMDXFeature
import SonovoModel3DFeature
import SonovoMediaEngine
import SonovoMediaFeature
import SonovoTimelineFeature
import SonovoTerminalFeature

extension Project {
    private func builtInSession<S: ProjectFeatureSession>(_ id: FeatureID, as type: S.Type) -> S {
        guard let session = featureSessions.session(for: id) as? S else { preconditionFailure("Missing built-in session: \(id)") }
        return session
    }
    var markdown: MarkdownWorkspace { builtInSession("builtin.markdown", as: MarkdownFeatureSession.self).workspace }
    var subtitles: SubtitleWorkspace { builtInSession("builtin.subtitle", as: SubtitleFeatureSession.self).workspace }
    var models: Model3DWorkspace { builtInSession("builtin.model", as: Model3DFeatureSession.self).workspace }
    var code: CodeWorkspace { builtInSession("builtin.code", as: CodeFeatureSession.self).workspace }
    var mdx: MDXWorkspace { builtInSession("builtin.mdx", as: MDXFeatureSession.self).workspace }
    var timelines: TimelineWorkspace { builtInSession("builtin.timeline", as: TimelineFeatureSession.self).workspace }
    var terminalSessions: TerminalSessionsStore { builtInSession("builtin.terminal", as: TerminalFeatureSession.self).workspace }
    var mediaFeature: MediaFeatureSession { builtInSession("builtin.media", as: MediaFeatureSession.self) }
    var mediaEdits: MediaEditWorkspace { mediaFeature.workspace }
    var mediaError: String? { mediaFeature.mediaError }
    var mediaGeneration: UInt64 { mediaFeature.mediaGeneration }
    private var sampleContent: SampleProjectContent? { externalContent as? SampleProjectContent }
    var sampleMedia: SampleMediaRegistry? { sampleContent?.media }
    private var sampleDocuments: SampleProjectDocuments? { sampleContent?.documents }
    var demoProduction: Production? { sampleContent?.production }
    var sampleStages: [ProductionStage] { sampleContent?.groups ?? [] }
    var filteredStages: [ProductionStage] {
        let query = trimmedFilterText
        guard !query.isEmpty else { return sampleStages }
        return sampleStages.compactMap { stage in
            let assets = stage.assets.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }
            return assets.isEmpty ? nil : ProductionStage(id: stage.id, title: stage.title, assets: assets)
        }
    }
    func sampleStage(for id: String) -> ProductionStage? { sampleStages.first { $0.assets.contains { $0.id == id } } }
    func openSampleAsset(_ asset: ProductionAsset) { openExternalAsset(asset) }
    private convenience init(
        id: String, name: String, root: URL?, isDemo: Bool, demoProduction: Production?,
        markdown: MarkdownWorkspace, subtitles: SubtitleWorkspace, models: Model3DWorkspace,
        code: CodeWorkspace, mdx: MDXWorkspace, terminalSessions: TerminalSessionsStore,
        openTabs: [EditorTab], selectedTabID: String, selectedAssetID: String?, availability: Availability,
        expectedVolumeIdentifier: String?, scanner: any ProjectScanning,
        watchFactory: @escaping ProjectWatchFactory, sampleDocuments: SampleProjectDocuments?
    ) {
        let mediaEdits = MediaEditWorkspace()
        let timelines = TimelineWorkspace()
        let sessions = BuiltInFeatureComposition.makeSessions(code: code, markdown: markdown, subtitles: subtitles,
            mdx: mdx, models: models, timelines: timelines, mediaEdits: mediaEdits, terminalSessions: terminalSessions)
        guard let mediaFeature = sessions.session(for: "builtin.media") as? MediaFeatureSession else {
            preconditionFailure("Missing built-in media session")
        }
        let external = demoProduction.map { SampleProjectContent(production: $0, documents: sampleDocuments,
            markdown: markdown, subtitles: subtitles, generation: { [weak mediaFeature] in mediaFeature?.mediaGeneration ?? 0 }) }
        self.init(id: id, name: name, root: root, isDemo: isDemo, featureSessions: sessions,
            externalContent: external, openTabs: openTabs, selectedTabID: selectedTabID, selectedAssetID: selectedAssetID,
            availability: availability, expectedVolumeIdentifier: expectedVolumeIdentifier,
            scanner: scanner, watchFactory: watchFactory)
        mediaFeature.attachEditorProject(self)
        mediaFeature.attachProject(MediaProjectServices(projectName: name,
            destinationDirectory: { [weak self] in self?.mediaDestinationDirectory },
            canRecord: { [weak self] in self?.canRecordAudio == true },
            registerCreatedMedia: { [weak self] url, kind, open in
                self?.registerCreatedMedia(at: url, kind: kind, openWhenFinished: open)
            }, replacedAsset: { [weak self] url, original in
                guard let self else { return nil }
                if self.isDemo {
                    self.sampleMedia?.refresh()
                    guard let asset = self.sampleMediaAsset(for: original.id) else { return nil }
                    self.openAsset(id: asset.id)
                    return asset
                }
                await self.refreshNow()
                await self.waitForScanSettlement()
                let canonical = FilePathPolicy.canonical(url)
                let asset = self.assets.first { FilePathPolicy.canonical($0.url) == canonical }
                    ?? self.syntheticAsset(for: canonical, kind: original.kind)
                self.openAsset(asset)
                return asset
            }))
    }
    convenience init(
        folderURL: URL,
        expectedVolumeIdentifier: String? = nil,
        scanner: any ProjectScanning = ProjectScanner(),
        watchFactory: @escaping ProjectWatchFactory = {
            FSEventSource(root: $0, onChange: $1)
        },
        terminalEnvironment: TerminalEnvironment = .disabled
    ) {
        self.init(
            folderBackedRoot: MarkdownSecurity.canonical(folderURL),
            availability: .scanning,
            expectedVolumeIdentifier: expectedVolumeIdentifier,
            scanner: scanner,
            watchFactory: watchFactory,
            terminalEnvironment: terminalEnvironment
        )
    }

    convenience init(
        offlinePath: String,
        reason: String,
        expectedVolumeIdentifier: String? = nil,
        scanner: any ProjectScanning = ProjectScanner(),
        watchFactory: @escaping ProjectWatchFactory = {
            FSEventSource(root: $0, onChange: $1)
        },
        terminalEnvironment: TerminalEnvironment = .disabled
    ) {
        self.init(
            folderBackedRoot: URL(fileURLWithPath: offlinePath)
                .standardizedFileURL,
            availability: .offline(reason),
            expectedVolumeIdentifier: expectedVolumeIdentifier,
            scanner: scanner,
            watchFactory: watchFactory,
            terminalEnvironment: terminalEnvironment
        )
    }

    /// Folder and offline projects differ only in availability and how their
    /// root is canonicalized; everything else is shared.
    private convenience init(
        folderBackedRoot root: URL,
        availability: Availability,
        expectedVolumeIdentifier: String?,
        scanner: any ProjectScanning,
        watchFactory: @escaping ProjectWatchFactory,
        terminalEnvironment: TerminalEnvironment
    ) {
        self.init(
            id: root.path,
            name: root.lastPathComponent,
            root: root,
            isDemo: false,
            demoProduction: nil,
            markdown: MarkdownWorkspace(readsDemoEnvironment: false),
            subtitles: SubtitleWorkspace(readsDemoEnvironment: false),
            models: Model3DWorkspace(opensDemoModel: false),
            code: CodeWorkspace(readsDemoEnvironment: false),
            mdx: MDXWorkspace(),
            terminalSessions: TerminalSessionsStore(
                workingDirectory: root.path,
                projectKey: root.path,
                projectName: root.lastPathComponent,
                terminalEnvironment: terminalEnvironment
            ),
            openTabs: [],
            selectedTabID: "",
            selectedAssetID: nil,
            availability: availability,
            expectedVolumeIdentifier: expectedVolumeIdentifier,
            scanner: scanner,
            watchFactory: watchFactory,
            sampleDocuments: nil
        )
    }

    static func demo(
        production: Production,
        markdown: MarkdownWorkspace,
        subtitles: SubtitleWorkspace,
        models: Model3DWorkspace,
        terminalSessions: TerminalSessionsStore,
        sampleDocuments: SampleProjectDocuments?,
        code: CodeWorkspace = CodeWorkspace(readsDemoEnvironment: false),
        mdx: MDXWorkspace = MDXWorkspace()
    ) -> Project {
        let initialIDs = [
            "script-md", "captions-srt", "vo-take-03", "take-03", "stills",
            "storyboard-html"
        ]
        let tabs = initialIDs.compactMap { id in
            production.asset(id: id).map(EditorTab.init(asset:))
        }
        return Project(
            id: "demo",
            name: production.title,
            root: nil,
            isDemo: true,
            demoProduction: production,
            markdown: markdown,
            subtitles: subtitles,
            models: models,
            code: code,
            mdx: mdx,
            terminalSessions: terminalSessions,
            openTabs: tabs,
            selectedTabID: "vo-take-03",
            selectedAssetID: "vo-take-03",
            availability: .available,
            expectedVolumeIdentifier: nil,
            scanner: ProjectScanner(),
            watchFactory: { _, _ in
                // The demo project has no folder to watch.
                NoopProjectWatcher()
            },
            sampleDocuments: sampleDocuments
        )
    }


    func sampleAudioAsset(for id: String) -> ProjectAsset? { sampleContent?.audioAsset(id: id) }
    func sampleMediaAsset(for id: String) -> ProjectAsset? { sampleContent?.resourceAsset(id: id) }
    func sampleProductionAsset(id: String) -> ProductionAsset? { sampleContent?.asset(id: id) }

    var mediaDestinationDirectory: URL? {
        if isDemo { return sampleDocuments?.destinationDirectory }
        return root
    }

    var canRecordAudio: Bool {
        guard mediaDestinationDirectory != nil else { return false }
        if case .offline = availability { return false }
        return true
    }

    var isRecordingAudio: Bool {
        mediaFeature.isRecordingAudio
    }

    func clearMediaError() { mediaFeature.clearMediaError() }

    func startAudioRecording() async -> Bool { await mediaFeature.startAudioRecording() }
    @discardableResult func stopAudioRecording(openWhenFinished: Bool = true) -> ProjectAsset? {
        mediaFeature.stopAudioRecording(openWhenFinished: openWhenFinished)
    }
    func cancelAudioRecording() { mediaFeature.cancelAudioRecording() }
    func exportMedia(_ document: MediaEditDocument, mode: MediaExportMode) async throws -> ProjectAsset {
        try await mediaFeature.exportMedia(document, mode: mode)
    }

    private func registerCreatedMedia(
        at url: URL,
        kind: AssetKind,
        openWhenFinished: Bool
    ) -> ProjectAsset? {
        if isDemo {
            guard let asset = sampleMedia?.register(url: url) else {
                return nil
            }
            if openWhenFinished {
                openAsset(id: asset.id)
            }
            return asset
        }
        let asset = syntheticAsset(
            for: MarkdownSecurity.canonical(url),
            kind: kind
        )
        if openWhenFinished {
            openAsset(asset)
        }
        // The watcher would discover the file on its own; an immediate scan
        // makes the new asset authoritative before the next user action.
        Task { @MainActor [weak self] in
            await self?.refreshNow()
        }
        return asset
    }

}

private final class NoopProjectWatcher: ProjectWatching {
    var isRunning = true
    func start() {}
    func stop() { isRunning = false }
}

extension EditorTab { var sampleAsset: ProductionAsset? { externalAsset } }
