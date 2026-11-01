#if SONOVO_MODULAR_E2E_PROBE
import AppKit
import Darwin
import ApplicationServices
import AVFoundation
import PDFKit
import QuickLookUI
import WebKit
import SonovoDomainTypes
import SonovoFeatureAPI
import SonovoWorkspaceHost
import SonovoMarkdownEngine
import SonovoMarkdownFeature
import SonovoCodeFeature
import SonovoSubtitleFeature
import SonovoMDXFeature
import SonovoModel3DFeature
import SonovoMediaEngine
import SonovoMediaUI
import SonovoTimelineFeature
import SonovoTerminalFeature

/// Opt-in acceptance instrumentation for the actual application window.
/// It accepts only an explicitly marked synthetic fixture directory. No
/// second host, application state, live service factory, or source fixture
/// is substituted. This code is absent from normal builds.
@MainActor enum ModularArchitectureProbe {
    private static var root: URL!
    private static var failures = 0
    private static func log(_ text: String) {
        let url = root.appendingPathComponent("acceptance.log")
        let data = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else { try? data.write(to: url) }
    }
    private static func check(_ condition: Bool, _ name: String) {
        if !condition { failures += 1 }
        log((condition ? "PASS " : "FAIL ") + name)
    }
    private static func pause(_ milliseconds: Int = 700) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
    private static func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<120 {
            if condition() { return true }
            await pause(100)
        }
        return condition()
    }
    private static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
    private static func visibleViews<T: NSView>(_ type: T.Type, in window: NSWindow) -> [T] {
        guard let content = window.contentView else { return [] }
        return views(type, in: content).filter { !$0.isHiddenOrHasHiddenAncestor }
    }
    private static func shot(_ name: String, window: NSWindow) async {
        await pause()
        let acknowledgement = root.appendingPathComponent(name + ".captured")
        let request: [String: Any] = ["name": name, "window": window.windowNumber]
        do {
            try JSONSerialization.data(withJSONObject: request).write(to: root.appendingPathComponent("capture-request.json"), options: .atomic)
            let received = await wait { FileManager.default.fileExists(atPath: acknowledgement.path) }
            let result = try? String(contentsOf: acknowledgement, encoding: .utf8)
            check(received && result == "ok\n", "screenshot " + name)
        } catch { check(false, "screenshot " + name) }
    }
    private static func terminalIdentity(_ name: String) async -> TmuxSessionIdentity? {
        await Task.detached(priority: .utility) { LiveTmux.shared.sessionIdentity(named: name) }.value
    }
    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
    private static func axStrings(_ element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { key in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
            return value as? String
        }
    }
    private static func axWalk(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 25 else { return [] }
        return [element] + axChildren(element).flatMap { axWalk($0, depth: depth + 1) }
    }
    private static func axLabels() -> [String] { axWalk(AXUIElementCreateApplication(getpid())).flatMap(axStrings) }
    private static func press(_ label: String) -> Bool {
        for element in axWalk(AXUIElementCreateApplication(getpid())) {
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard role as? String == kAXButtonRole else { continue }
            let own = axStrings(element) + axChildren(element).flatMap(axStrings)
            if own.contains(where: { $0 == label || $0.contains(label) }) {
                return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            }
        }
        return false
    }
    private static func openMenu(_ title: String) -> Bool {
        for element in axWalk(AXUIElementCreateApplication(getpid())) {
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if role as? String == kAXMenuBarItemRole, axStrings(element).contains(title) {
                return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            }
        }
        return false
    }
    private static func menu(_ title: String, in menu: NSMenu?) -> Bool {
        guard let menu else { return false }
        menu.update()
        for (index, item) in menu.items.enumerated() {
            if item.title.hasPrefix("Save") { log("DETAIL native menu \(item.title) enabled=\(item.isEnabled)") }
            if item.title == title, item.isEnabled { menu.performActionForItem(at: index); return true }
            if self.menu(title, in: item.submenu) { return true }
        }
        return false
    }
    private static func js(_ script: String, in web: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            web.evaluateJavaScript(script) { result, _ in continuation.resume(returning: result as? String) }
        }
    }
    private static func open(_ name: String, project: Project) async -> ProjectAsset? {
        guard let asset = project.assets.first(where: { $0.name == name }) else { check(false, "fixture indexed " + name); return nil }
        project.openAsset(asset); await pause(); return asset
    }
    static func run() {
        guard let path = ProcessInfo.processInfo.environment["SONOVO_MODULAR_E2E_ROOT"] else { return }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        guard candidate.lastPathComponent == "e2e",
              (try? String(contentsOf: candidate.appendingPathComponent(".sonovo-modular-e2e"), encoding: .utf8)) == "synthetic-only\n" else { return }
        root = candidate
        Task { @MainActor in await matrix() }
    }
    private static func matrix() async {
        guard let state = AppStateRegistry.active else { check(false, "actual app state"); return }
        _ = await wait { NSApp.windows.contains { $0.isVisible && $0.contentView != nil } }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { check(false, "actual app window"); return }
        // token-exempt: dedicated acceptance window geometry, not product design
        window.setContentSize(NSSize(width: 1280, height: 850))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        log("WINDOW " + String(window.windowNumber))
        let firstRoot = root.appendingPathComponent("modular-a")
        guard let a = state.openProject(at: firstRoot) else { check(false, "open fixture project A"); return }
        await a.load(); await a.awaitScanSettled()
        if ProcessInfo.processInfo.environment["SONOVO_MODULAR_E2E_PHASE"] == "resume" {
            await reconnect(state: state, project: a, window: window); return
        }
        guard let b = state.openProject(at: root.appendingPathComponent("modular-b")) else { check(false, "open fixture project B"); return }
        await b.load(); await b.awaitScanSettled()
        state.activateProject(a)
        _ = await open("Reader.md", project: a)
        a.markdown.selectedDocument?.mode = .rendered
        await pause(1800)
        check(a.featureSessions.sessions.count == BuiltInFeatureComposition.metadata.count, "all real sessions retained")
        check(a.markdown.selectedDocument?.source.contains("Modular acceptance") == true, "packaged Markdown document")
        await shot("01-markdown-diagrams", window: window)
        guard let container = visibleViews(ProjectEditorHostContainer.self, in: window).first,
              let hostA = container.registry.entries[ObjectIdentifier(a)]?.host else { check(false, "actual retained host"); return }
        var visibilityEvents: [Bool] = []
        a.featureSessions.visibilityProbe = { visibilityEvents.append($0) }
        check(press("Documents"), "folder sidebar group collapses")
        state.activateProject(b); _ = await open("Second.swift", project: b)
        check(await wait { hostA.isHidden && container.registry.entries[ObjectIdentifier(a)]?.context.isVisible == false }, "hidden host publishes invisible")
        state.activateProject(a); await pause()
        check(container.registry.entries[ObjectIdentifier(a)]?.host === hostA && !hostA.isHidden, "project switch retains actual host")
        check(visibilityEvents == [false, true], "retained native host delivers one visibility event per transition")
        a.featureSessions.visibilityProbe = nil
        // A collapsed folder group retains its expansion state on a project
        // switch; expand it again for the remaining presentation checks.
        check(!axLabels().contains("Document.pdf"), "sidebar collapse survives folder project switch")
        check(press("Documents"), "folder sidebar group expands again")

        _ = await open("Code.swift", project: a)
        check(await wait { a.code.selectedDocument?.isReady == true }, "code editor decoded fixture")
        if let document = a.code.selectedDocument {
            check(document.hasBOM && document.lineEnding == .crlf, "code exact encoding baseline")
            do { try document.replaceSource(document.source + "\n// saved through native menu\n") }
            catch { check(false, "edit code fixture") }
            await pause(100)
            check(state.canSaveSelectedDocument, "actual selected document Save enabled")
            check(openMenu("File"), "native File menu opens")
            await pause(100)
            check(menu("Save", in: NSApp.mainMenu), "native Save menu dispatched")
            NSApp.mainMenu?.cancelTracking()
            check(await wait { !document.isDirty }, "native Save settled")
            let bytes = try? Data(contentsOf: document.fileURL)
            check(bytes?.starts(with: [0xEF, 0xBB, 0xBF]) == true && bytes?.contains(0x0D) == true, "native save retained BOM and CRLF")
            let snapshot = bytes
            state.terminalPresentation = .full
            check(!state.canSaveSelectedDocument && !state.canPerformEditorCommand(.find), "terminal-full command gates")
            await state.saveSelectedDocument()
            check((try? Data(contentsOf: document.fileURL)) == snapshot, "hidden editor Save is inert")
            state.terminalPresentation = .hidden
        }
        await shot("02-code", window: window)

        _ = await open("image-a.png", project: a)
        await pause(1200)
        let pressedActualSize = press("1:1"); await pause()
        check(pressedActualSize && axLabels().contains("100%"), "actual image zoom reaches 1:1")
        state.activateProject(b); await pause(); state.activateProject(a); await pause()
        check(axLabels().contains("100%"), "image zoom survives project switch")
        if let image = a.assets.first(where: { $0.name == "image-a.png" }) {
            let token = image.revision.token
            let tag = Array("acceptance-tag".utf8)
            let result = tag.withUnsafeBytes { setxattr(image.url.path, "com.sonovo.acceptance", $0.baseAddress, $0.count, 0, 0) }
            await a.refreshNow(); await a.awaitScanSettled(); await pause()
            check(result == 0 && a.assets.first(where: { $0.id == image.id })?.revision.token == token
                  && axLabels().contains("100%"), "metadata-only rescan preserves actual image zoom and identity")
        }
        await shot("03-image-zoom", window: window)
        if press("Compare") {
            await pause()
            check(press("image-b.png"), "real comparison picker chooses sibling image")
            await pause(1200)
            check(axLabels().contains("Close comparison"), "real image comparison is rendered")
            await shot("04-image-comparison", window: window)
            _ = press("Close comparison")
        } else { check(false, "real image comparison opens") }

        _ = await open("Document.pdf", project: a)
        check(await wait { visibleViews(PDFView.self, in: window).first?.document?.pageCount == 2 }, "packaged PDF renders two pages")
        if let pdf = visibleViews(PDFView.self, in: window).first, let page = pdf.document?.page(at: 1) {
            pdf.go(to: page); pdf.autoScales = false; pdf.scaleFactor = 2
            state.activateProject(b); await pause(); state.activateProject(a); await pause()
            check(visibleViews(PDFView.self, in: window).first === pdf && pdf.currentPage === page && pdf.scaleFactor == 2, "PDF page and scale survive switch")
        }
        await shot("05-pdf", window: window)
        _ = await open("Preview.html", project: a)
        check(await wait { !visibleViews(WKWebView.self, in: window).isEmpty }, "local HTML has actual WebKit view")
        await shot("06-local-html", window: window)
        _ = await open("Notes.rtf", project: a)
        check(await wait { visibleViews(QLPreviewView.self, in: window).first?.previewItem != nil }, "system Quick Look receives fixture")
        await shot("06b-quicklook", window: window)
        _ = await open("Captions.srt", project: a)
        check(await wait { a.subtitles.selectedDocument?.cueCount == 2 }, "actual subtitle workspace opens cues")
        await shot("06c-subtitle", window: window)
        _ = await open("Movie.mov", project: a)
        check(await wait { visibleViews(PlayerHostView.self, in: window).first?.playerLayer.player?.currentItem?.status == .readyToPlay }, "actual video player becomes ready")
        if let playerView = visibleViews(PlayerHostView.self, in: window).first, let player = playerView.playerLayer.player {
            player.isMuted = true
            let duration = player.currentItem?.duration.seconds ?? 0
            let target = min(2, duration / 2)
            await withCheckedContinuation { continuation in
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in continuation.resume() }
            }
            player.play(); await pause(250)
            state.activateProject(b); await pause()
            check(player.rate == 0, "hidden video pauses actual AVPlayer")
            let position = player.currentTime().seconds
            state.activateProject(a); await pause()
            check(visibleViews(PlayerHostView.self, in: window).first === playerView && abs(player.currentTime().seconds - position) < 1, "media player identity and position survive switch")
        }
        await shot("06d-video", window: window)
        _ = await open("Triangle.obj", project: a)
        check(await wait { a.models.selectedDocument?.state == .ready }, "packaged 3D resources load OBJ")
        if let web = visibleViews(WKWebView.self, in: window).first {
            let script = "JSON.stringify(Object.keys(sessionStorage).filter(k=>k.startsWith('sonovo.model.camera')).map(k=>sessionStorage.getItem(k)))"
            let before = await js(script, in: web)
            state.activateProject(b); await pause(); state.activateProject(a); await pause()
            let after = await js(script, in: web)
            check(visibleViews(WKWebView.self, in: window).first === web && after == before, "3D WebKit and stored camera survive switch")
        }
        await shot("07-model", window: window)
        _ = await open("Component.mdx", project: a)
        if let document = a.mdx.selectedDocument {
            a.mdx.setPreviewEnabled(true)
            await a.mdx.compileNow(document)
            if case .ready = a.mdx.previewState(for: document) { check(true, "packaged MDX helper compiled") }
            else { check(false, "packaged MDX helper compiled") }
        } else { check(false, "MDX source document") }
        await shot("08-mdx", window: window)
        _ = await open("voice.wav", project: a)
        await pause(1200)
        if let asset = a.selectedAsset {
            let before = try? Data(contentsOf: asset.url)
            let document = a.mediaEdits.document(for: asset)
            let duration = (try? await AVURLAsset(url: asset.url).load(.duration).seconds) ?? 0
            document.prepare(sourceDuration: duration)
            _ = document.setSelection(start: 1, end: 2)
            _ = document.deleteSelection()
            a.mediaEdits.activate(document)
            do {
                let exported = try await a.exportMedia(document, mode: .newTake)
                check(FileManager.default.fileExists(atPath: exported.url.path), "actual app registers exported take")
                check((try? Data(contentsOf: asset.url)) == before, "media take leaves source bytes untouched")
            } catch { log("DETAIL fixture media export: \(error.localizedDescription)"); check(false, "actual app media export") }
        }
        await shot("09-media", window: window)
        if let source = a.assets.first(where: { $0.name == "voice.wav" }) {
            do {
                let values = try source.url.resourceValues(forKeys: [.fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey])
                let revision = AssetRevision(fileIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
                    size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
                let released = ProjectAsset(id: source.id, url: source.url, name: source.name, relativePath: source.relativePath,
                    kind: source.kind, size: source.size, modified: source.modified, revision: revision)
                var timeline = ProjectTimeline(name: "Released timeline compatibility")
                try timeline.addClip(asset: released, track: .voice, at: .zero,
                    duration: CMTime(seconds: 1, preferredTimescale: 600_000))
                let path = root.appendingPathComponent("modular-a/Released.timeline.json")
                try JSONEncoder().encode(timeline).write(to: path)
                await a.refreshAssetsForNavigation()
                if let indexed = a.assets.first(where: { $0.url == path }) { a.openAsset(indexed) }
                await pause()
                check(a.selectedTab?.kind == .timeline && a.selectedTab?.url == path,
                      "released timeline opens through the real navigator editor")
                let loaded = a.timelines.document?.timeline
                check(loaded?.voiceTrack.clips.first?.sourceRevision == revision.token,
                      "actual app loads released timeline JSON without token migration")
                let built = try await ProjectTimelineCompositionBuilder.build(timeline: loaded ?? timeline, assets: a.assets)
                check(built.duration.seconds == 1, "actual app builds released timeline composition without relink")
                await shot("09b-released-timeline", window: window)
            } catch { check(false, "released timeline compatibility") }
        }
        let previousTimelineURL = a.timelines.document?.url
        state.newTimeline()
        check(await wait { a.timelines.document != nil && a.timelines.document?.url != previousTimelineURL
            && a.selectedTab?.url == a.timelines.document?.url }, "registered New Timeline creates visible document")
        if let document = a.timelines.document {
            do { try document.mutate { $0.name = "Modular timeline" }; try await document.flush() }
            catch { check(false, "timeline mutation and atomic autosave") }
            let identity = document
            state.activateProject(b); await pause(); state.activateProject(a); await pause()
            check(a.timelines.document === identity && document.timeline?.name == "Modular timeline", "timeline document survives switch")
        }
        await shot("10-timeline", window: window)
        state.activateProject(state.workspace.demoProject)
        state.openAsset("stills")
        await shot("11-native-sample", window: window)
        state.activateProject(a)
        let dirty = a.markdown.newDocument()
        do { try dirty.replaceSource("# Unsaved acceptance fixture") } catch { check(false, "create dirty fixture") }
        await a.closeAllTabs()
        check(a.markdown.pendingClose === dirty && !a.openTabs.isEmpty, "mixed bulk close stops at save decision")
        state.cancelPendingClose()
        check(a.markdown.pendingClose == nil && dirty.isDirty, "cancel leaves dirty document retained")
        a.markdown.discardAndClose(dirty)
        check(await state.flushAllBeforeClose(), "real multi-project flush settles")
        state.terminalPresentation = .split
        check(await wait { a.terminalSessions.selectedSession?.view.processAlive == true }, "actual terminal surface launches")
        if let name = a.terminalSessions.selectedSession?.tmuxSessionName,
           let identity = await terminalIdentity(name), URL(fileURLWithPath: identity.server.socketPath).resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path) {
            try? Data(name.utf8).write(to: root.appendingPathComponent("session-name.txt"))
            check(true, "tmux session belongs to isolated fixture socket")
        } else {
            log("DETAIL tmux available=\(LiveTmux.shared.isAvailable) socket=\(LiveTmux.shared.socketPath) name=\(a.terminalSessions.selectedSession?.tmuxSessionName ?? "nil")")
            check(false, "tmux session belongs to isolated fixture socket")
        }
        await shot("12-terminal", window: window)
        log("READY-FOR-FORCE-QUIT failures=\(failures)")
    }
    private static func reconnect(state: AppState, project: Project, window: NSWindow) async {
        state.terminalPresentation = .split
        let name = (try? String(contentsOf: root.appendingPathComponent("session-name.txt"), encoding: .utf8)) ?? ""
        check(await wait { project.terminalSessions.sessions.contains { $0.tmuxSessionName == name } }, "force-quit session reattaches on relaunch")
        await shot("13-terminal-reattached", window: window)
        guard ProcessInfo.processInfo.environment["TMUX_TMPDIR"] == root.appendingPathComponent("tmux").path else {
            check(false, "refuse cleanup outside isolated tmux socket"); return
        }
        if let session = project.terminalSessions.sessions.first(where: { $0.tmuxSessionName == name }),
           let identity = await terminalIdentity(name), URL(fileURLWithPath: identity.server.socketPath).resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path) {
            await project.terminalSessions.endSession(session.id, confirmed: true)
            let exists = await Task.detached(priority: .utility) { LiveTmux.shared.sessionExists(name: name) }.value
            check(exists == false, "explicit End uses coordinator and ends fixture identity")
        } else { check(false, "explicit End fixture identity") }
        // The only other sessions reachable here belong to this invocation's
        // isolated server, including its synthetic Sample initial tab.
        for project in state.workspace.allProjects { await project.terminalSessions.endAllAttachedSessions() }
        check(await state.flushAllBeforeClose(), "final flush")
        log("COMPLETE failures=\(failures)")
        NSApp.terminate(nil)
    }
}
#endif
