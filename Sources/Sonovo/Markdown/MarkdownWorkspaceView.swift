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

            if let document = workspace.selectedDocument {
                editorPage(document)
                    .padding(AppTheme.Spacing.lg)
            } else {
                emptyState
                    .padding(AppTheme.Spacing.lg)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appCanvas)
        // The unsaved-changes alert lives on the window root. This view is
        // mounted only while the Markdown tab is selected, so an alert here
        // would never appear when termination starts from an audio tab.
    }

    // MARK: - Editor page

    /// One document surface on the canvas, built like the audio page: a
    /// rounded card at `Radius.surface` with its controls in a header strip.
    private func editorPage(_ document: MarkdownDocument) -> some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            editorToolbar(document)
            Divider()

            if let error = workspace.lastError {
                banner(
                    text: error,
                    systemImage: "exclamationmark.triangle",
                    tint: AppTheme.Palette.needsReview,
                    dismiss: workspace.dismissError
                )
            }

            if document.isMissingOnDisk {
                banner(
                    text: "This file is missing on disk.",
                    systemImage: "questionmark.folder",
                    tint: AppTheme.Palette.needsReview
                )
            }

            if document.conflict != nil {
                conflictBanner(document)
            }

            documentContent(document)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
            .fill(Color.appText)
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
            .strokeBorder(
                Color.appSeparator,
                lineWidth: AppTheme.BorderWidth.hairline
            )
        )
    }

    /// Document actions and the editing controls. The file name stays in the
    /// window's tab bar, so this strip never repeats it.
    private func editorToolbar(_ document: MarkdownDocument) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            documentMenu

            if document.isReadOnly {
                Label("Read-only", systemImage: "lock")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            if document.mode == .source, !document.isReadOnly {
                MarkdownFormattingToolbar(
                    controller: workspace.controller(for: document)
                )
                Divider()
                    .frame(height: AppTheme.Size.toolbarDividerHeight)
            }

            modePicker(document)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(height: AppTheme.Layout.tabBarHeight)
    }

    private var documentMenu: some View {
        Menu {
            if !workspace.documents.isEmpty {
                Section("Open Documents") {
                    ForEach(workspace.documents) { document in
                        Button {
                            workspace.select(document)
                        } label: {
                            Text(
                                document.fileURL?.lastPathComponent
                                    ?? "Untitled"
                            )
                        }
                    }
                }
                Divider()
            }
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
            if let document = workspace.selectedDocument {
                Divider()
                Button("Close Document") {
                    Task { await workspace.close(document) }
                }
            }
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                .frame(
                    width: AppTheme.ControlSize.medium,
                    height: AppTheme.ControlSize.regular
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Documents")
        .accessibilityLabel("Documents")
    }

    private func modePicker(_ document: MarkdownDocument) -> some View {
        Picker(
            "Mode",
            selection: Binding(
                get: { document.mode },
                set: { document.mode = $0 }
            )
        ) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .tag(MarkdownDocumentMode.source)
                .help("Source")
            Image(systemName: "eye")
                .tag(MarkdownDocumentMode.rendered)
                .help("Rendered")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Source or Rendered")
        .accessibilityLabel("Source or Rendered")
    }

    private func banner(
        text: String,
        systemImage: String,
        tint: Color,
        dismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: AppTheme.TypeScale.xs))
                .lineLimit(2)
            Spacer(minLength: AppTheme.Spacing.sm)
            if let dismiss {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.s6)
        .background(tint.opacity(AppTheme.Opacity.muted))
    }

    // MARK: - Content

    @ViewBuilder
    private func documentContent(_ document: MarkdownDocument) -> some View {
        switch document.mode {
        case .source:
            MarkdownSourceEditor(
                document: document,
                cache: workspace.editorCache,
                parseService: workspace.parseService
            )
            .id(document.id)
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
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.s6)
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
