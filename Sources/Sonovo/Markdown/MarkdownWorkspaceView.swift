import SonovoCore
import SwiftUI

/// The Markdown workspace: file browser, tabs, source/viewer switch, rail, and
/// conflict and close flows.
struct MarkdownWorkspaceView: View {
    @Bindable var workspace: MarkdownWorkspace
    /// Project-aware availability for `sonovo:` media links. The document
    /// URL is the pane's own, so a relative link resolves against the file
    /// that displays it, not whichever pane has focus.
    var mediaReferenceState: ((MediaReference, URL?) -> MediaReferenceState)?
    var onOpenMedia: ((MediaReference, URL?) -> Void)?

    init(workspace: MarkdownWorkspace) {
        _workspace = Bindable(workspace)
    }

    /// A workspace hosted by a project resolves and opens `sonovo:` media
    /// links through the project's assets, so the rendered availability and
    /// the click route can never disagree.
    init(project: Project) {
        _workspace = Bindable(project.markdown)
        mediaReferenceState = { reference, documentURL in
            project.mediaAsset(
                for: reference,
                documentURL: documentURL
            ) == nil ? .missing : .available
        }
        onOpenMedia = { reference, documentURL in
            project.openMediaReference(reference, documentURL: documentURL)
        }
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.zero) {
            if workspace.workspaceRoot != nil {
                fileBrowser
                Divider()
            }

            if let primary = workspace.primaryDocument {
                paneLayout(primary)
                    .padding(AppTheme.Spacing.lg)
            } else {
                emptyState
                    .padding(AppTheme.Spacing.lg)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appCanvas)
        .sheet(isPresented: $workspace.isHistoryVisible) {
            if let document = workspace.selectedDocument {
                MarkdownHistoryView(document: document, workspace: workspace)
            }
        }
        .sheet(isPresented: $workspace.isReviewVisible) {
            if let document = workspace.selectedDocument {
                MarkdownReviewView(document: document, workspace: workspace)
            }
        }
        .sheet(isPresented: $workspace.isProposalVisible) {
            if let preview = workspace.proposalPreview,
               let document = workspace.selectedDocument {
                MarkdownProposalView(
                    preview: preview,
                    document: document,
                    workspace: workspace
                )
            }
        }
        .sheet(isPresented: $workspace.isQuickOpenVisible) {
            MarkdownQuickOpenView(
                workspace: workspace,
                onClose: { workspace.isQuickOpenVisible = false }
            )
        }
        .sheet(isPresented: $workspace.isPaletteVisible) {
            MarkdownCommandPaletteView(
                entries: workspace.paletteEntries(),
                onExecute: { workspace.executePaletteCommand($0) },
                onClose: { workspace.isPaletteVisible = false }
            )
        }
        // The unsaved-changes alert lives on the window root. This view is
        // mounted only while the Markdown tab is selected, so an alert here
        // would never appear when termination starts from an audio tab.
    }

    // MARK: - Panes

    /// One or two document surfaces. The second pane is either absent or a
    /// different document; duplicate documents are focused, never cloned.
    private func paneLayout(_ primary: MarkdownDocument) -> some View {
        HStack(spacing: AppTheme.Spacing.zero) {
            editorPage(primary)
                .overlay(paneFocusBorder(primary))
                .simultaneousGesture(
                    TapGesture().onEnded { workspace.focus(primary) }
                )
            if let secondary = workspace.secondaryDocument {
                Divider()
                editorPage(secondary)
                    .overlay(paneFocusBorder(secondary))
                    .simultaneousGesture(
                        TapGesture().onEnded { workspace.focus(secondary) }
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func paneFocusBorder(_ document: MarkdownDocument) -> some View {
        if workspace.secondaryDocument != nil,
           workspace.focusedDocument?.id == document.id {
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
            .strokeBorder(
                Color.accentColor,
                lineWidth: AppTheme.BorderWidth.hairline
            )
        }
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
                    tint: AppTheme.Palette.warning,
                    dismiss: workspace.dismissError
                )
            }

            if document.isMissingOnDisk {
                banner(
                    text: "This file is missing on disk.",
                    systemImage: "questionmark.folder",
                    tint: AppTheme.Palette.warning
                )
            }

            if document.conflict != nil {
                conflictBanner(document)
            }

            if let reason = document.forcedSourceReason {
                forcedSourceBanner(document, reason: reason)
            }

            HStack(spacing: AppTheme.Spacing.zero) {
                documentContent(document)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if workspace.reviewComments.isVisible {
                    Divider()
                    MarkdownCommentsView(
                        document: document,
                        workspace: workspace
                    )
                }
                if workspace.isOutlineVisible {
                    Divider()
                    MarkdownOutlinePanel(
                        document: document,
                        workspace: workspace
                    )
                    .frame(width: AppTheme.MarkdownChrome.Outline.width)
                }
            }
                .onAppear {
                    workspace.restoreReadingPosition(for: document)
                }
                .onDisappear {
                    workspace.captureReadingPosition(for: document)
                }
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
            documentMenu(document)

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

            Button {
                workspace.isOutlineVisible.toggle()
            } label: {
                Image(systemName: "list.bullet.indent")
            }
            .buttonStyle(.plain)
            .help("Outline")
            Button {
                workspace.focus(document)
                workspace.isHistoryVisible = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .help("Version History")
            Button {
                workspace.focus(document)
                workspace.isReviewVisible = true
            } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.plain)
            .help("Review Observed Changes")
            Button {
                workspace.focus(document)
                workspace.reviewComments.isVisible.toggle()
            } label: {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Image(systemName: "text.bubble")
                    let count = workspace.reviewComments
                        .openCount(for: document)
                    if count > 0 {
                        Text("\(count)")
                            .font(
                                .system(
                                    size: AppTheme.TypeScale.xxs,
                                    weight: .medium
                                )
                            )
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Comments")
            .accessibilityLabel(
                "Comments, \(workspace.reviewComments.openCount(for: document)) open"
            )
            Button {
                workspace.focus(document)
                workspace.presentProposal(for: document)
            } label: {
                Image(systemName: "arrow.triangle.branch")
            }
            .buttonStyle(.plain)
            .help("Review Proposal")
            .accessibilityLabel("Review proposal")
            secondPaneMenu(document)
            if workspace.secondaryDocument?.id == document.id {
                Button {
                    workspace.closeSplitPane()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close Pane")
                .accessibilityLabel("Close Pane")
            }
            splitControls(document)
            modePicker(document)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(height: AppTheme.Layout.tabBarHeight)
    }

    private func documentMenu(_ document: MarkdownDocument) -> some View {
        Menu {
            if !workspace.documents.isEmpty {
                Section("Open Documents") {
                    ForEach(workspace.documents) { candidate in
                        Button {
                            workspace.show(
                                candidate,
                                inPane: workspace.pane(of: document)
                                    ?? .primary
                            )
                        } label: {
                            Text(
                                candidate.fileURL?.lastPathComponent
                                    ?? "Untitled"
                            )
                        }
                    }
                }
                Divider()
            }
            Button("New Document") {
                workspace.focus(document)
                workspace.newDocument()
            }
            Button("Open…") {
                workspace.focus(document)
                workspace.presentOpenPanel()
            }
            Button("Open Folder…") {
                workspace.focus(document)
                workspace.presentOpenFolderPanel()
            }
            Divider()
            Button("Save") {
                workspace.focus(document)
                Task { await workspace.saveSelected() }
            }
            .disabled(!document.isDirty)
            Button("Save As…") {
                workspace.focus(document)
                Task { await workspace.saveSelectedAs() }
            }
            Divider()
            Button("Close Document") {
                workspace.focus(document)
                Task { await workspace.close(document) }
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

    @ViewBuilder
    private func modePicker(_ document: MarkdownDocument) -> some View {
        if document.isSourceOnly {
            // A source-only document is either read-only (opened large) or
            // editable with Rendered disabled (live growth or a nesting
            // refusal). Offer the route back only when a parse can clear it.
            HStack(spacing: AppTheme.Spacing.xs) {
                Label("Source only", systemImage: "doc.plaintext")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)
                    .help(sourceOnlyHelp(document))
                    .accessibilityLabel("Source only")
                if document.forcedSourceReason == .nestingLimit {
                    Button("Try Rendered") {
                        Task { await workspace.tryRendered(document) }
                    }
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .buttonStyle(.link)
                    .help("Parse again and open Rendered if the nesting is fixed")
                }
            }
        } else {
            Picker(
                "Mode",
                selection: Binding(
                    get: { document.mode },
                    set: {
                        workspace.setSplitView(false, for: document)
                        workspace.setMode($0, for: document)
                    }
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
    }

    @ViewBuilder
    private func secondPaneMenu(_ document: MarkdownDocument) -> some View {
        if workspace.secondaryDocument == nil {
            let candidates = workspace.documents.filter {
                $0.id != document.id
            }
            if !candidates.isEmpty {
                Menu {
                    ForEach(candidates) { candidate in
                        Button(
                            candidate.fileURL?.lastPathComponent
                                ?? "Untitled"
                        ) {
                            workspace.show(candidate, inPane: .secondary)
                        }
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Open a Second Document Pane")
                .accessibilityLabel("Open a second document pane")
            }
        }
    }

    @ViewBuilder
    private func splitControls(_ document: MarkdownDocument) -> some View {
        if !document.isSourceOnly, workspace.secondaryDocument == nil {
            Button {
                workspace.toggleSplitView(for: document)
            } label: {
                Image(systemName: "rectangle.split.2x1")
                    .foregroundStyle(
                        workspace.isSplitView(document)
                            ? Color.accentColor : Color.primary
                    )
            }
            .buttonStyle(.plain)
            .help(
                workspace.isSplitView(document)
                    ? "Close Split View"
                    : "Split Source and Rendered"
            )
            .accessibilityLabel("Split Source and Rendered")
            .accessibilityValue(
                workspace.isSplitView(document) ? "On" : "Off"
            )

            if workspace.isSplitView(document) {
                Button {
                    workspace.isSplitScrollSynced.toggle()
                } label: {
                    Image(systemName: "link")
                        .foregroundStyle(
                            workspace.isSplitScrollSynced
                                ? Color.accentColor : Color.secondary
                        )
                }
                .buttonStyle(.plain)
                .disabled(
                    workspace.splitSyncRefusalReason(for: document) != nil
                )
                .help(
                    workspace.splitSyncRefusalReason(for: document)
                        ?? (workspace.isSplitScrollSynced
                            ? "Turn Scroll Sync Off"
                            : "Turn Scroll Sync On")
                )
                .accessibilityLabel("Scroll Sync")
                .accessibilityValue(
                    workspace.isSplitScrollSynced ? "On" : "Off"
                )
            }
        }
    }

    private func sourceOnlyHelp(_ document: MarkdownDocument) -> String {
        switch document.forcedSourceReason {
        case .large:
            "This file is above the editable size limit. Source is read-only."
        case .largeBuffer:
            "This document grew above the rendered-view limit. Editing and saving still work."
        case .nestingLimit:
            "This document is nested too deeply to render. Source remains editable."
        case .largeRestored:
            "A large snapshot was restored editable for this session. Rendered is off until the next open."
        case .bufferCap:
            "This document exceeds the editing cap. Shrink it before saving."
        case nil:
            "Rendered is unavailable for this document."
        }
    }

    private func forcedSourceBanner(
        _ document: MarkdownDocument,
        reason: ForcedSourceReason
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "doc.plaintext")
                .foregroundStyle(Color(AppTheme.Palette.warning))
            Text(sourceOnlyHelp(document))
                .font(.system(size: AppTheme.TypeScale.xs))
                .lineLimit(2)
            Spacer(minLength: AppTheme.Spacing.sm)
            if reason == .nestingLimit {
                Button("Try Rendered") {
                    Task { await workspace.tryRendered(document) }
                }
                .font(.system(size: AppTheme.TypeScale.xs))
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.s6)
        .background(Color(AppTheme.Palette.warning).opacity(AppTheme.Opacity.muted))
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
        if workspace.isSplitView(document) {
            HStack(spacing: AppTheme.Spacing.zero) {
                sourceContent(document)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                renderedContent(document)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .id(document.id)
        } else {
            // A persisted `.rendered` mode from before the document was
            // known to be large must not reach the parser.
            switch document.isSourceOnly ? .source : document.mode {
            case .source:
                sourceContent(document)
                    .id(document.id)
            case .rendered:
                renderedContent(document)
                    .id(document.id)
            }
        }
    }

    private func sourceContent(_ document: MarkdownDocument) -> some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            MarkdownFrontmatterPanel(
                document: document,
                workspace: workspace
            )
            MarkdownSourceEditor(
                document: document,
                cache: workspace.editorCache,
                parseCoordinator: workspace.parseCoordinator,
                readingAnchor: workspace.sourceReadingAnchor(for: document),
                scrollTargetOffset: Binding(
                    get: { workspace.sourceScrollTargets[document.id] },
                    set: { workspace.sourceScrollTargets[document.id] = $0 }
                ),
                onVisibleAnchorChange: { anchor in
                    workspace.sourceDidScroll(anchor, in: document)
                },
                onFocus: {
                    workspace.focus(document)
                },
                onOpenLocalLink: { path in
                    Task {
                        await workspace.openLocalLink(path, from: document)
                    }
                },
                onOpenMediaLink: onOpenMedia.map { handler in
                    { reference in handler(reference, document.fileURL) }
                },
                onOpenWikiLink: { link in
                    Task { await workspace.openWikiLink(link, in: document) }
                }
            )
        }
    }

    private func renderedContent(_ document: MarkdownDocument) -> some View {
        MarkdownRenderedDocumentView(
            document: document,
            workspace: workspace,
            mediaReferenceState: mediaReferenceState,
            onOpenMedia: onOpenMedia
        )
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            // A failed open has no selected document, so the per-page error
            // banner would otherwise never be shown.
            if let error = workspace.lastError {
                banner(
                    text: error,
                    systemImage: "exclamationmark.triangle",
                    tint: AppTheme.Palette.warning,
                    dismiss: workspace.dismissError
                )
            }
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
                .foregroundStyle(Color(AppTheme.Palette.warning))
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
        .background(Color(AppTheme.Palette.warning).opacity(AppTheme.Opacity.muted))
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

// MARK: - Frontmatter

/// A collapsed marker that expands into a read-only production summary and a
/// raw text editor over exactly the frontmatter range. Only the editor
/// writes; the summary never rewrites a byte of the source.
private struct MarkdownFrontmatterPanel: View {
    let document: MarkdownDocument
    let workspace: MarkdownWorkspace

    @State private var expanded = false
    @State private var text = ""
    /// The frontmatter slice as last loaded, so a revision elsewhere in the
    /// document does not look like a frontmatter change.
    @State private var loadedSlice = ""

    private var frontmatter: Frontmatter? {
        if case .ready(let output) = workspace.parseCoordinator
            .state(for: document.id) {
            return output.ast.frontmatter
        }
        return nil
    }

    var body: some View {
        if let frontmatter {
            panel(range: frontmatter.range)
        }
    }

    private func panel(range: SourceRange) -> some View {
        let sourceRange = range.lowerBound..<range.upperBound
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            Button {
                expanded.toggle()
                if expanded { load(sourceRange) }
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(
                        systemName: expanded
                            ? "chevron.down"
                            : "chevron.right"
                    )
                    .font(.system(size: AppTheme.TypeScale.xs))
                    Text("Frontmatter")
                        .font(.system(size: AppTheme.TypeScale.sm))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs)
            .accessibilityLabel("Frontmatter")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(
                expanded ? "Collapses the frontmatter editor"
                    : "Shows the production fields and frontmatter source"
            )

            if expanded {
                productionFields
                TextEditor(text: $text)
                    .font(
                        .system(
                            size: AppTheme.TypeScale.sm,
                            design: .monospaced
                        )
                    )
                    .frame(
                        height: AppTheme.MarkdownChrome.Frontmatter.height
                    )
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .accessibilityLabel("Frontmatter source")
                    .onExitCommand { load(sourceRange) }
                HStack {
                    Spacer()
                    Button("Revert") { load(sourceRange) }
                        .accessibilityHint(
                            "Reloads the text from the document"
                        )
                    Button("Commit") {
                        workspace.commitFrontmatter(
                            document,
                            range: sourceRange,
                            text: text
                        )
                        expanded = false
                    }
                    .accessibilityHint(
                        "Writes the frontmatter as one undoable edit"
                    )
                    .keyboardShortcut(.return, modifiers: [.command])
                }
                .padding(AppTheme.Spacing.md)
            }
        }
        .background(AppTheme.MarkdownChrome.Popover.background)
        .onChange(of: document.revision) { _, _ in
            guard expanded else { return }
            // Reload only when the authored frontmatter itself changed. A
            // body edit earlier in the document shifts nothing here, and
            // reloading on every revision silently discarded the draft.
            let current = slice(sourceRange)
            if current != loadedSlice { load(sourceRange) }
        }
    }

    private func load(_ range: Range<Int>) {
        loadedSlice = slice(range)
        text = loadedSlice
    }

    private func slice(_ range: Range<Int>) -> String {
        let ns = document.source as NSString
        guard range.lowerBound >= 0,
              range.upperBound <= ns.length else {
            return ""
        }
        return ns.substring(
            with: NSRange(
                location: range.lowerBound,
                length: range.upperBound - range.lowerBound
            )
        )
    }

    /// A read-only summary of the documented production keys. It sits above
    /// the raw editor and never writes: the editor remains the only path
    /// that changes the frontmatter, so unknown keys, comments, order,
    /// anchors, and block scalars are preserved exactly.
    @ViewBuilder
    private var productionFields: some View {
        let model = ProductionFrontmatter(body: frontmatter?.body ?? "")
        if !model.fields.isEmpty || !model.diagnostics.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: AppTheme.Spacing.sm,
                    verticalSpacing: AppTheme.Spacing.xxs
                ) {
                    ForEach(model.fields) { field in
                        GridRow {
                            Text(field.key.displayName)
                                .font(.system(size: AppTheme.TypeScale.xs))
                                .foregroundStyle(
                                    AppTheme.Palette.secondaryLabel
                                )
                            HStack(spacing: AppTheme.Spacing.xxs) {
                                Text(displayValue(field))
                                    .font(.system(size: AppTheme.TypeScale.sm))
                                    .foregroundStyle(
                                        field.isDuplicate
                                            ? AppTheme.Palette.warning
                                            : Color.primary
                                    )
                                    .lineLimit(2)
                                if field.isDuplicate {
                                    Image(
                                        systemName:
                                            "exclamationmark.triangle.fill"
                                    )
                                    .font(
                                        .system(size: AppTheme.TypeScale.xs)
                                    )
                                    .foregroundStyle(
                                        AppTheme.Palette.warning
                                    )
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(fieldLabel(field))
                    }
                }
                ForEach(model.diagnostics) { diagnostic in
                    Text(diagnostic.message)
                        .font(.system(size: AppTheme.TypeScale.xs))
                        .foregroundStyle(AppTheme.Palette.warning)
                        .accessibilityLabel(diagnostic.message)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.bottom, AppTheme.Spacing.xs)
        }
    }

    private func displayValue(
        _ field: ProductionFrontmatter.Field
    ) -> String {
        field.displayValue.isEmpty ? "—" : field.displayValue
    }

    private func fieldLabel(
        _ field: ProductionFrontmatter.Field
    ) -> String {
        let value = field.displayValue.isEmpty ? "empty" : field.displayValue
        if field.isDuplicate {
            return "\(field.key.displayName): \(value), duplicate key"
        }
        return "\(field.key.displayName): \(value)"
    }
}

// MARK: - Rendered document

private struct MarkdownRenderedDocumentView: View {
    let document: MarkdownDocument
    let workspace: MarkdownWorkspace
    let mediaReferenceState: ((MediaReference, URL?) -> MediaReferenceState)?
    let onOpenMedia: ((MediaReference, URL?) -> Void)?

    @State private var parseTimedOut = false

    /// The current parse state is document-owned. While a new revision is
    /// parsing, the last successful output keeps the viewer mounted so its
    /// expansion state survives the edit.
    private var displayedOutput: MarkdownParseOutput? {
        if case .ready(let output) = workspace.parseCoordinator
            .state(for: document.id),
           output.documentID == document.id {
            return output
        }
        return workspace.parseCoordinator
            .lastSuccessfulOutput(for: document.id)
    }

    @AppStorage(PreferenceKey.readingThemeRevision) private var readingThemeRevision = 0

    private var readingTheme: MarkdownTheme {
        // Read the revision so a Settings reload invalidates this body.
        _ = readingThemeRevision
        return MarkdownReadingSettings.currentTheme()
    }

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
            if let output = displayedOutput {
                MarkdownViewer(
                    ast: output.ast,
                    headings: output.headings,
                    theme: readingTheme,
                    documentURL: document.fileURL,
                    workspaceRoot: workspace.workspaceRoot
                        ?? document.fileURL?.deletingLastPathComponent(),
                    wikiLinkState: { link in
                        workspace.wikiState(for: link, in: document)
                    },
                    mediaReferenceState: mediaReferenceState.map { handler in
                        { reference in
                            handler(reference, document.fileURL)
                        }
                    },
                    onOpenWikiLink: { link in
                        Task { await workspace.openWikiLink(link, in: document) }
                    },
                    onOpenMedia: onOpenMedia.map { handler in
                        { reference in
                            handler(reference, document.fileURL)
                        }
                    },
                    onOpenLocalLink: { path in
                        Task {
                            await workspace.openLocalLink(path, from: document)
                        }
                    },
                    onEditInSource: { range in
                        Task {
                            await workspace.editInSource(
                                range: range,
                                expectedSource: output.parsed.source,
                                in: document
                            )
                        }
                    },
                    onSetDetailsOpen: document.isReadOnly ? nil : { range, open in
                        workspace.setDetailsOpenDefault(
                            at: range,
                            expectedSource: output.parsed.source,
                            open: open,
                            in: document
                        )
                    },
                    source: output.parsed.source,
                    onCommitBlockEdit: document.isReadOnly ? nil : {
                        range, expectedSlice, replacement in
                        workspace.commitBlockEdit(
                            range: range,
                            expectedSlice: expectedSlice,
                            replacement: replacement,
                            in: document
                        )
                    },
                    scrollTarget: Binding(
                        get: { workspace.scrollTargets[document.id] },
                        set: { workspace.scrollTargets[document.id] = $0 }
                    ),
                    restoreAnchor: Binding(
                        get: { workspace.pendingRenderedAnchors[document.id] },
                        set: { workspace.pendingRenderedAnchors[document.id] = $0 }
                    ),
                    onReadingAnchorChange: { anchor in
                        workspace.renderedDidScroll(anchor, in: document)
                    },
                    lintDiagnostics: workspace.lintDiagnostics(for: document),
                    find: workspace.renderedFind(for: document),
                    isFocusedPane: workspace.secondaryDocument == nil
                        || workspace.focusedDocument?.id == document.id
                )
            } else if parseTimedOut {
                Text(
                    "Parsing is taking longer than expected. "
                        + "This view updates when the parse finishes."
                )
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            let revision = document.revision
            parseTimedOut = false
            workspace.parseCoordinator.request(
                documentID: document.id,
                identityGeneration: document.identityGeneration,
                revision: revision,
                source: document.source
            )
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                if workspace.parseCoordinator
                    .state(for: document.id).isParsing {
                    parseTimedOut = true
                }
            }
            defer { timeoutTask.cancel() }
            guard let state = await workspace.parseCoordinator.awaitSettled(
                documentID: document.id,
                revision: revision
            ) else {
                return
            }
            switch state {
            case .refused:
                document.setNestingLimit(true)
            case .ready:
                document.setNestingLimit(false)
            case .idle, .parsing:
                break
            }
            parseTimedOut = false
        }
    }
}



// MARK: - Command palette

/// A native overlay over the command registry. Only commands available in
/// the current context are listed; Enter runs the same registry path as the
/// menu.
private struct MarkdownCommandPaletteView: View {
    let entries: [MarkdownCommandCatalog.Entry]
    let onExecute: (MarkdownCommandKind) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var selected = 0
    @FocusState private var fieldFocused: Bool

    private let registry = MarkdownCommandRegistry()

    private var filtered: [MarkdownCommandCatalog.Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { entry in
            let title = registry.title(for: entry.command)
            return title.localizedCaseInsensitiveContains(trimmed)
                || entry.category.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            TextField("Type a command", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.TypeScale.sm))
                .padding(AppTheme.Spacing.md)
                .focused($fieldFocused)
                .accessibilityLabel("Command search")
                .onSubmit { executeSelected() }
                .onChange(of: query) {
                    // A narrower list can leave the old row index past the
                    // end, which made Enter do nothing.
                    selected = 0
                }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                        ForEach(filtered.indices, id: \.self) { index in
                            row(index: index)
                        }
                    }
                }
                .onChange(of: selected) { _, value in
                    proxy.scrollTo(value, anchor: .center)
                }
            }
        }
        .frame(width: AppTheme.MarkdownChrome.PaletteChrome.width)
        .frame(height: AppTheme.MarkdownChrome.PaletteChrome.height)
        .background(AppTheme.MarkdownChrome.PaletteChrome.background)
        .onKeyPress(.downArrow) {
            selected = min(selected + 1, max(filtered.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selected = max(selected - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .onAppear { fieldFocused = true }
    }

    private func row(index: Int) -> some View {
        let entry = filtered[index]
        return Button {
            onExecute(entry.command)
        } label: {
            HStack {
                Text(registry.title(for: entry.command))
                    .font(.system(size: AppTheme.TypeScale.sm))
                Spacer()
                Text(entry.category)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(
                index == selected
                    ? AppTheme.Palette.selection
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(index)
        .accessibilityLabel(registry.title(for: entry.command))
        .accessibilityValue(entry.category)
        .accessibilityHint("Runs this command")
    }

    private func executeSelected() {
        guard !filtered.isEmpty, selected < filtered.count else { return }
        onExecute(filtered[selected].command)
    }
}


// MARK: - Outline

private struct MarkdownOutlinePanel: View {
    let document: MarkdownDocument
    let workspace: MarkdownWorkspace

    @State private var query = ""

    private var output: MarkdownParseOutput? {
        if case .ready(let output) = workspace.parseCoordinator
            .state(for: document.id) {
            return output
        }
        return workspace.parseCoordinator
            .lastSuccessfulOutput(for: document.id)
    }

    private var rows: [TOCRow] {
        guard let output else { return [] }
        return MarkdownOutline.filtered(
            MarkdownOutline.rows(output.headings),
            query: query
        )
    }

    private var activeID: String? {
        guard let output, let selection = document.selection else {
            return nil
        }
        let all = MarkdownOutline.rows(output.headings)
        guard let index = MarkdownOutline.activeIndex(
            all,
            caret: selection.lowerBound
        ) else {
            return nil
        }
        return all[index].scrollID
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.TypeScale.xs))
                .padding(AppTheme.Spacing.sm)
                .accessibilityLabel("Filter headings")
            Divider()
            if rows.isEmpty {
                Text("No headings")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                        ForEach(rows.indices, id: \.self) { index in
                            rowView(rows[index])
                        }
                    }
                }
            }
        }
        .background(AppTheme.Palette.card)
    }

    private func rowView(_ row: TOCRow) -> some View {
        Button {
            workspace.jumpToHeading(row, in: document)
        } label: {
            Text(row.text)
                .font(.system(size: AppTheme.TypeScale.xs))
                .lineLimit(1)
                .padding(.leading, CGFloat(row.indent) * AppTheme.Spacing.sm)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .frame(height: AppTheme.MarkdownChrome.Outline.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    row.scrollID == activeID
                        ? AppTheme.MarkdownChrome.Outline.selection
                        : Color.clear
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.text)
        .accessibilityValue(
            row.scrollID == activeID ? "Current section" : ""
        )
        .accessibilityHint("Scrolls to this heading")
    }
}


// MARK: - Quick Open

private struct MarkdownQuickOpenView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case open = "Open"
        case find = "Find in Files"

        var id: String { rawValue }
    }

    let workspace: MarkdownWorkspace
    let onClose: () -> Void

    @State private var mode: Mode = .open
    @State private var query = ""
    /// The query the current `matches` were produced by. The field stays
    /// editable while results are shown, so reading it at click time would
    /// seed Find with text the results never matched.
    @State private var submittedQuery = ""
    @State private var matches: [CodeSearchMatch] = []
    @State private var searching = false
    @State private var searchGeneration = 0
    @FocusState private var fieldFocused: Bool

    private var entries: [MarkdownQuickOpenEntry] {
        MarkdownQuickOpen.filter(
            workspace.quickOpenEntries(),
            query: query
        )
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .accessibilityLabel(
                    mode == .open
                        ? "Search documents"
                        : "Search file contents"
                )
                .onSubmit { submit() }

            if mode == .find, searching {
                ProgressView()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                    if mode == .open {
                        ForEach(entries) { entry in
                            quickRow(entry)
                        }
                    } else {
                        ForEach(matches) { match in
                            searchRow(match)
                        }
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(width: AppTheme.MarkdownChrome.PaletteChrome.width)
        .frame(height: AppTheme.MarkdownChrome.PaletteChrome.height)
        .background(AppTheme.MarkdownChrome.PaletteChrome.background)
        .onAppear { fieldFocused = true }
    }

    private func quickRow(_ entry: MarkdownQuickOpenEntry) -> some View {
        Button {
            workspace.openQuickEntry(entry)
        } label: {
            HStack {
                Text(entry.title)
                    .font(.system(size: AppTheme.TypeScale.sm))
                Spacer()
                Text(entry.kind == .tab ? "Tab" : entry.relativePath)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.kind == .tab ? "Open tab" : entry.relativePath)
        .accessibilityHint("Opens this document")
    }

    private func searchRow(_ match: CodeSearchMatch) -> some View {
        Button {
            workspace.openResult(
                url: match.url,
                line: match.line,
                column: match.column,
                query: submittedQuery
            )
            onClose()
        } label: {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(match.relativePath + ":" + String(match.line))
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                Text(match.preview)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .lineLimit(1)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(match.relativePath), line \(match.line)")
        .accessibilityValue(match.preview)
        .accessibilityHint("Opens the match in Source")
    }

    private func submit() {
        switch mode {
        case .open:
            if let first = entries.first {
                workspace.openQuickEntry(first)
            }
        case .find:
            let query = query
            submittedQuery = query
            searchGeneration += 1
            let generation = searchGeneration
            searching = true
            Task { @MainActor in
                let result = await workspace.findInFiles(query)
                guard generation == searchGeneration else { return }
                matches = result?.matches ?? []
                searching = false
            }
        }
    }
}


// MARK: - Version history

private struct MarkdownHistoryView: View {
    let document: MarkdownDocument
    let workspace: MarkdownWorkspace

    @State private var records: [MarkdownSnapshotRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Version History")
                .font(.system(size: AppTheme.TypeScale.sm, weight: .semibold))
            Text("Observed snapshots only; a value edited outside Sonovo may not appear.")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
            if records.isEmpty {
                Text("No snapshots yet")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                        ForEach(records) { record in
                            row(record)
                        }
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(width: AppTheme.MarkdownChrome.PaletteChrome.width)
        .frame(height: AppTheme.MarkdownChrome.PaletteChrome.height)
        .background(AppTheme.MarkdownChrome.PaletteChrome.background)
        .task(id: workspace.historyRevision) {
            records = await workspace.historyRecords(for: document)
        }
    }

    private func row(_ record: MarkdownSnapshotRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(
                    record.capturedAt.formatted(
                        date: .abbreviated,
                        time: .standard
                    )
                )
                .font(.system(size: AppTheme.TypeScale.xs))
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: Int64(record.byteCount),
                        countStyle: .file
                    )
                        + (record.hadBOM ? " \u{00B7} BOM" : "")
                        + " \u{00B7} " + record.lineEnding
                )
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore") {
                Task {
                    await workspace.restoreSnapshot(record, in: document)
                    records = await workspace.historyRecords(for: document)
                }
            }
            .accessibilityLabel("Restore snapshot from \(timestamp(record))")
            Button("Delete") {
                Task {
                    await workspace.deleteSnapshot(record)
                    records = await workspace.historyRecords(for: document)
                }
            }
            .accessibilityLabel("Delete snapshot from \(timestamp(record))")
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    private func timestamp(_ record: MarkdownSnapshotRecord) -> String {
        record.capturedAt.formatted(date: .abbreviated, time: .standard)
    }
}

// MARK: - Review queue

private struct MarkdownReviewView: View {
    let document: MarkdownDocument
    let workspace: MarkdownWorkspace

    @State private var transitions: [MarkdownReviewTransition] = []

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Observed Changes")
                .font(.system(size: AppTheme.TypeScale.sm, weight: .semibold))
            Text("Sonovo observes the latest bytes; A to B to C may appear as one change.")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
            if transitions.isEmpty {
                Text("No observed changes")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                        ForEach(transitions) { transition in
                            row(transition)
                        }
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(width: AppTheme.MarkdownChrome.PaletteChrome.width)
        .frame(height: AppTheme.MarkdownChrome.PaletteChrome.height)
        .background(AppTheme.MarkdownChrome.PaletteChrome.background)
        .task(id: workspace.historyRevision) {
            transitions = await workspace.reviewTransitions(for: document)
        }
    }

    private func row(_ transition: MarkdownReviewTransition) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(
                    transition.observedAt.formatted(
                        date: .abbreviated,
                        time: .standard
                    )
                )
                .font(.system(size: AppTheme.TypeScale.xs))
                Text(String(transition.afterSha.prefix(12)))
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Keep") {
                Task {
                    await workspace.keepTransition(transition)
                    transitions = await workspace.reviewTransitions(
                        for: document
                    )
                }
            }
            .accessibilityLabel(
                "Keep change observed \(observed(transition))"
            )
            Button("Revert") {
                Task {
                    await workspace.revertTransition(
                        transition,
                        in: document
                    )
                    transitions = await workspace.reviewTransitions(
                        for: document
                    )
                }
            }
            .accessibilityLabel(
                "Revert change observed \(observed(transition))"
            )
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    private func observed(_ transition: MarkdownReviewTransition) -> String {
        transition.observedAt.formatted(date: .abbreviated, time: .standard)
    }
}
