import SonovoCore
import SwiftUI

/// The Markdown workspace: file browser, tabs, source/viewer switch, rail, and
/// conflict and close flows.
struct MarkdownWorkspaceView: View {
    @Bindable var workspace: MarkdownWorkspace

    var body: some View {
        HStack(spacing: AppTheme.Spacing.zero) {
            if workspace.workspaceRoot != nil {
                fileBrowser
                Divider()
            }

            VStack(spacing: AppTheme.Spacing.zero) {
                documentTabs
                Divider()

                if let document = workspace.selectedDocument {
                    documentContent(document)
                    if document.conflict != nil {
                        conflictBanner(document)
                    }
                } else {
                    emptyState
                }

                statusBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appText)
        // The unsaved-changes alert lives on the window root. This view is
        // mounted only while the Markdown tab is selected, so an alert here
        // would never appear when termination starts from an audio tab.
    }

    // MARK: - Tabs

    private var documentTabs: some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    ForEach(workspace.documents) { document in
                        documentTab(document)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
            }

            Spacer(minLength: AppTheme.Spacing.zero)

            Button {
                workspace.toggleMode()
            } label: {
                Image(
                    systemName: workspace.selectedDocument?.mode == .source
                        ? "eye"
                        : "chevron.left.forwardslash.chevron.right"
                )
                .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Toggle Source/Rendered")
            .accessibilityLabel("Toggle Source or Rendered")

            Menu {
                Button("New Document") { workspace.newDocument() }
                Button("Open…") { workspace.presentOpenPanel() }
                Button("Open Folder…") { workspace.presentOpenFolderPanel() }
                Divider()
                Button("Save") {
                    Task { await workspace.saveSelected() }
                }
                .disabled(!(workspace.selectedDocument?.isDirty ?? false))
                Button("Save As…") {
                    Task { await workspace.saveSelectedAs() }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                    .frame(
                        width: AppTheme.Size.addIcon,
                        height: AppTheme.Size.addIcon
                    )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.trailing, AppTheme.Spacing.sm)
            .help("Document Menu")
            .accessibilityLabel("Document Menu")
        }
        .frame(height: AppTheme.Layout.tabBarHeight)
        .background(Color.appText)
    }

    private func documentTab(_ document: MarkdownDocument) -> some View {
        let selected = workspace.selectedDocumentID == document.id
        return HStack(spacing: AppTheme.Spacing.xs) {
            Button {
                workspace.select(document)
            } label: {
                HStack(spacing: AppTheme.Spacing.s6) {
                    if document.isDirty {
                        Circle()
                            .fill(Color(AppTheme.Palette.needsReview))
                            .frame(
                                width: AppTheme.Size.statusDot,
                                height: AppTheme.Size.statusDot
                            )
                    }
                    Text(document.fileURL?.lastPathComponent ?? "Untitled")
                        .font(.system(size: AppTheme.TypeScale.sm))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Button {
                Task { await workspace.close(document) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close Document")
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.control,
                style: .continuous
            )
            .fill(selected ? Color.appCard : Color.clear)
        )
    }

    // MARK: - Content

    @ViewBuilder
    private func documentContent(_ document: MarkdownDocument) -> some View {
        switch document.mode {
        case .source:
            HStack(spacing: AppTheme.Spacing.zero) {
                MarkdownSourceEditor(
                    document: document,
                    cache: workspace.editorCache,
                    parseService: workspace.parseService
                )
                .id(document.id)
                MarkdownFormattingRail(controller: workspace.controller(for: document))
            }
        case .rendered:
            MarkdownRenderedDocumentView(
                document: document,
                workspace: workspace
            )
            .id(document.id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "doc.text")
                .font(.system(size: AppTheme.TypeScale.displayLarge, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("No Markdown Document")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
            Text("Create a document or open a Markdown file.")
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
            HStack(spacing: AppTheme.Spacing.sm) {
                Button("New Document") { workspace.newDocument() }
                Button("Open…") { workspace.presentOpenPanel() }
                Button("Open Folder…") { workspace.presentOpenFolderPanel() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func conflictBanner(_ document: MarkdownDocument) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color(AppTheme.Palette.needsReview))
            Text("This file changed on disk.")
                .font(.system(size: AppTheme.TypeScale.sm))
            Spacer()
            Button("Reload") { workspace.reload(document) }
            Button("Keep Mine") { workspace.keepLocal(document) }
            Button("Save As…") {
                Task { await workspace.saveAs(document) }
            }
        }
        .padding(AppTheme.Spacing.sm)
        .background(Color(AppTheme.Palette.needsReview).opacity(AppTheme.Opacity.muted))
    }

    // MARK: - File browser

    private var fileBrowser: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(workspace.workspaceRoot?.lastPathComponent ?? "Workspace")
                .font(.system(size: AppTheme.TypeScale.xs, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.top, AppTheme.Spacing.sm)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    ForEach(workspace.workspaceFiles, id: \.self) { url in
                        Button {
                            workspace.open(url: url)
                        } label: {
                            Text(url.lastPathComponent)
                                .font(.system(size: AppTheme.TypeScale.sm))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, AppTheme.Spacing.sm)
                                .padding(.vertical, AppTheme.Spacing.xs)
                                .background(
                                    workspace.selectedDocument?.fileURL?.standardizedFileURL == url
                                        ? Color.appCard
                                        : Color.clear
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(width: AppTheme.Layout.markdownSidebarWidth)
        .background(Color.appContent)
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if let document = workspace.selectedDocument {
                Text(document.fileURL?.path ?? "Untitled")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(document.isDirty ? "Edited" : "Saved")
                Text(document.lineEnding.rawValue.uppercased())
                if document.hasBOM {
                    Text("BOM")
                }
                if document.isReadOnly {
                    Text("Read-only")
                }
                if document.isMissingOnDisk {
                    Text("Missing on disk")
                        .foregroundStyle(
                            Color(AppTheme.Palette.needsReview)
                        )
                }
            }

            Spacer(minLength: AppTheme.Spacing.zero)

            if let error = workspace.lastError {
                Text(error)
                    .lineLimit(1)
                    .foregroundStyle(Color(AppTheme.Palette.needsReview))
            }
        }
        .font(.system(size: AppTheme.TypeScale.xxs))
        .foregroundStyle(.secondary)
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Layout.breadcrumbHeight)
        .background(Color.appText)
    }
}

// MARK: - Rendered document

private struct MarkdownRenderedDocumentView: View {
    let document: MarkdownDocument
    let workspace: MarkdownWorkspace

    @State private var output: MarkdownParseOutput?

    /// Two documents can share a revision number. Keying the task only by
    /// revision leaves the new document displaying the old document's AST.
    private struct ParseTaskKey: Hashable {
        let documentID: UUID
        let revision: UInt64
    }

    var body: some View {
        Group {
            // Keep the previous viewer mounted while a new parse is pending;
            // replacing it with a spinner destroys its expansion state.
            if let output, output.documentID == document.id {
                MarkdownViewer(
                    ast: output.ast,
                    headings: output.headings,
                    documentURL: document.fileURL,
                    workspaceRoot: workspace.workspaceRoot
                        ?? document.fileURL?.deletingLastPathComponent(),
                    wikiLinkState: { link in
                        workspace.wikiState(for: link, in: document)
                    },
                    onOpenWikiLink: { link in
                        Task { await workspace.openWikiLink(link, in: document) }
                    },
                    onOpenLocalLink: { path in
                        Task {
                            await workspace.openLocalLink(path, from: document)
                        }
                    },
                    scrollTarget: Binding(
                        get: { workspace.scrollTargets[document.id] },
                        set: { workspace.scrollTargets[document.id] = $0 }
                    )
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(
            id: ParseTaskKey(
                documentID: document.id,
                revision: document.revision
            )
        ) {
            let result = await workspace.parseService.parse(
                MarkdownParseInput(
                    documentID: document.id,
                    revision: document.revision,
                    source: document.source
                )
            )
            if let result,
               result.documentID == document.id,
               result.revision == document.revision {
                output = result
            }
        }
    }
}

// MARK: - Window close guard

/// Intercepts the window close, flushes dirty documents, and cancels the close
/// when a document still needs a save/discard/cancel decision.
struct WindowCloseGuard: NSViewRepresentable {
    let workspace: MarkdownWorkspace

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace: workspace)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.install(on: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                context.coordinator.install(on: window)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var workspace: MarkdownWorkspace?
        private weak var window: NSWindow?
        private weak var original: NSWindowDelegate?
        private var bypass = false

        init(workspace: MarkdownWorkspace) {
            self.workspace = workspace
            super.init()
        }

        func install(on window: NSWindow) {
            guard self.window !== window else { return }
            uninstall()
            self.window = window
            self.original = window.delegate
            window.delegate = self
        }

        func uninstall() {
            guard let window, window.delegate === self else { return }
            window.delegate = original
            self.window = nil
            self.original = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if bypass { return true }
            guard let workspace, workspace.hasDirtyDocuments else {
                return original?.windowShouldClose?(sender) ?? true
            }

            Task { @MainActor in
                if await workspace.flushAllForTermination() {
                    // The flush saved our documents; the window's own
                    // delegate may still refuse the close.
                    guard self.original?.windowShouldClose?(sender) ?? true else {
                        return
                    }
                    self.bypass = true
                    sender.close()
                }
            }
            return false
        }

        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return original?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if original?.responds(to: aSelector) == true {
                return original
            }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
