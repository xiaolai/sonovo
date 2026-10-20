import SonovoCore
import SwiftUI

/// The subtitle workspace: one document card on the canvas, with a preview,
/// cue cards, and a raw source editor.
struct SubtitleWorkspaceView: View {
    @Bindable var state: AppState

    @State private var selectedOrdinal: Int?
    @State private var editingOrdinal: Int?
    @State private var draftText = ""
    @State private var draftBaseText = ""
    @FocusState private var focusedCue: Int?

    private var workspace: SubtitleWorkspace { state.subtitles }

    var body: some View {
        Group {
            if let document = workspace.selectedDocument {
                page(document)
                    .padding(AppTheme.Spacing.lg)
                    // Draft, selection, and focus are per document. Keep
                    // them from following an ordinal into another file.
                    .id(document.id)
            } else {
                emptyState
                    .padding(AppTheme.Spacing.lg)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appCanvas)
    }

    // MARK: - Page

    private func page(_ document: SubtitleDocument) -> some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header(document)

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

            if let notice = workspace.reloadNotice {
                banner(
                    text: notice,
                    systemImage: "arrow.clockwise",
                    tint: AppTheme.Palette.generating,
                    dismiss: workspace.dismissReloadNotice
                )
            }

            if document.conflict != nil {
                conflictBanner(document)
            }

            if document.parsed.errorCount > 0, document.mode == .cues {
                parseErrorBanner(document)
            }

            content(document)
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
        .onChange(of: document.revision) {
            reconcileState(document)
        }
        .onChange(of: document.parsedRevision) {
            reconcileState(document)
        }
        .onChange(of: editingOrdinal) { old, new in
            guard let new, old != new,
                  let cue = document.parsed.cue(ordinal: new) else {
                return
            }
            draftBaseText = cue.rawText
        }
    }

    private func header(_ document: SubtitleDocument) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            documentMenu(document)

            Text(document.format.displayName)
                .font(
                    .system(
                        size: AppTheme.TypeScale.sm,
                        weight: .medium
                    )
                )
                .foregroundStyle(.secondary)

            Text("·")
                .foregroundStyle(.tertiary)

            Text("\(document.cueCount) cues")
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.tertiary)

            if document.isReadOnly {
                Label("Read-only", systemImage: "lock")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
            }

            if workspace.previewMode == .collapsed {
                SubtitlePlayerBar(
                    workspace: workspace,
                    document: document,
                    layout: .inline
                )
                .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: AppTheme.Spacing.sm)
            }

            modePicker(document)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Layout.subtitleHeaderHeight)
    }

    private func documentMenu(_ document: SubtitleDocument) -> some View {
        Menu {
            if !workspace.documents.isEmpty {
                Section("Open Documents") {
                    ForEach(workspace.documents) { candidate in
                        Button {
                            workspace.select(candidate)
                        } label: {
                            Text(candidate.fileURL.lastPathComponent)
                        }
                    }
                }
                Divider()
            }
            Button("Open Subtitle…") { workspace.presentOpenPanel() }
            Button("Open Media…") {
                workspace.presentOpenMediaPanel(for: document)
            }
            Divider()
            Button("Save") {
                Task { await workspace.save(document) }
            }
            .disabled(!document.isDirty)
            Divider()
            Button("Close Document") {
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

    private func modePicker(_ document: SubtitleDocument) -> some View {
        Picker(
            "Mode",
            selection: Binding(
                get: { document.mode },
                set: { setMode($0, document: document) }
            )
        ) {
            Image(systemName: "list.bullet.rectangle")
                .tag(SubtitleDocumentMode.cues)
                .help("Cues")
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .tag(SubtitleDocumentMode.source)
                .help("Source")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Cues or Source")
        .accessibilityLabel("Cues or Source")
    }

    @ViewBuilder
    private func content(_ document: SubtitleDocument) -> some View {
        switch document.mode {
        case .cues:
            cuesContent(document)
        case .source:
            SubtitleSourceEditor(
                controller: workspace.sourceController(for: document)
            )
        }
    }

    // MARK: - Cues

    private func cuesContent(_ document: SubtitleDocument) -> some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            if workspace.previewMode == .expanded {
                SubtitlePreviewView(
                    workspace: workspace,
                    document: document
                )
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.top, AppTheme.Spacing.md)
                .padding(.bottom, AppTheme.Spacing.sm)
            }

            if document.parsed.warningCount > 0 {
                listToolbar(document)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.sm)
            }

            ScrollViewReader { proxy in
                // Only the cards scroll. The floating player is either over
                // the video above or docked at the bottom, never in the list.
                ScrollView {
                    LazyVStack(spacing: AppTheme.Spacing.zero) {
                        ForEach(document.parsed.cues) { cue in
                            SubtitleCueRow(
                                workspace: workspace,
                                document: document,
                                cue: cue,
                                isActive: activeOrdinals(document)
                                    .contains(cue.ordinal),
                                editingOrdinal: $editingOrdinal,
                                draftText: $draftText,
                                focusedCue: $focusedCue,
                                onSelect: {
                                    selectedOrdinal = cue.ordinal
                                    workspace.seek(
                                        toMilliseconds: cue.startMilliseconds
                                    )
                                },
                                onBeginEditing: {
                                    beginEditing(
                                        cue.ordinal,
                                        in: document
                                    )
                                },
                                onCommitText: {
                                    Task { await commitDraft(document) }
                                },
                                onApplied: { result in
                                    handle(result)
                                }
                            )
                            .id(cue.ordinal)
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.top, AppTheme.Spacing.sm)
                    .padding(.bottom, AppTheme.Spacing.md)
                }
                .onChange(of: activeCueOrdinal(document)) { _, ordinal in
                    // Keep the spoken line in the middle of the list. At the
                    // first and last cues the scroll view clamps naturally.
                    guard workspace.player.isPlaying,
                          editingOrdinal == nil,
                          let ordinal else {
                        return
                    }
                    withAnimation(.easeInOut) {
                        proxy.scrollTo(ordinal, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: AppTheme.Layout.pageMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listToolbar(_ document: SubtitleDocument) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Label(
                "\(document.parsed.warningCount) warnings",
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: AppTheme.TypeScale.xxs))
            .foregroundStyle(AppTheme.Palette.needsReview)
            Spacer(minLength: AppTheme.Spacing.xxs)
        }
        .frame(maxWidth: .infinity)
    }

    private func activeOrdinals(_ document: SubtitleDocument) -> Set<Int> {
        guard workspace.player.isReady else { return [] }
        return Set(
            document.parsed.timeline.activeOrdinals(
                atMilliseconds: workspace.player.currentMilliseconds
            )
        )
    }

    private func activeCueOrdinal(_ document: SubtitleDocument) -> Int? {
        guard workspace.player.isReady else { return nil }
        return document.parsed.timeline.activeOrdinals(
            atMilliseconds: workspace.player.currentMilliseconds
        ).first
    }

    // MARK: - Drafts

    /// Opens a draft, first committing any draft in another card. A focus
    /// change alone would race the commit, so the handoff is explicit.
    private func beginEditing(
        _ ordinal: Int,
        in document: SubtitleDocument
    ) {
        guard let cue = document.parsed.cue(ordinal: ordinal) else {
            return
        }
        if let current = editingOrdinal, current != ordinal {
            Task {
                guard await commitDraft(document) else { return }
                guard let fresh = document.parsed.cue(ordinal: ordinal) else {
                    return
                }
                openDraft(fresh)
            }
            return
        }
        openDraft(cue)
    }

    private func openDraft(_ cue: SubtitleCue) {
        draftText = cue.rawText
        draftBaseText = cue.rawText
        editingOrdinal = cue.ordinal
        DispatchQueue.main.async {
            focusedCue = cue.ordinal
        }
    }

    @discardableResult
    private func commitDraft(_ document: SubtitleDocument) async -> Bool {
        guard let ordinal = editingOrdinal else { return true }
        guard !document.isReadOnly else {
            editingOrdinal = nil
            focusedCue = nil
            return false
        }
        let text = draftText
        editingOrdinal = nil
        focusedCue = nil
        if let result = await workspace.apply(
            .setText(ordinal: ordinal, text: text),
            to: document
        ) {
            selectedOrdinal = result.affectedCueOrdinal
            return true
        }
        // Keep the words on screen so a failed save is not silently lost.
        editingOrdinal = ordinal
        focusedCue = ordinal
        return false
    }

    private func cancelDraft() {
        editingOrdinal = nil
        focusedCue = nil
    }

    private func handle(_ result: SubtitleEditResult) {
        selectedOrdinal = result.affectedCueOrdinal
    }

    private func reconcileState(_ document: SubtitleDocument) {
        if let selected = selectedOrdinal,
           document.parsed.cue(ordinal: selected) == nil {
            selectedOrdinal = nil
        }
        guard let editing = editingOrdinal else { return }
        guard let cue = document.parsed.cue(ordinal: editing),
              cue.rawText == draftBaseText else {
            cancelDraft()
            return
        }
    }

    private func setMode(
        _ mode: SubtitleDocumentMode,
        document: SubtitleDocument
    ) {
        if editingOrdinal != nil {
            Task {
                if await commitDraft(document) {
                    document.mode = mode
                }
            }
            return
        }
        document.mode = mode
    }

    // MARK: - Banners

    private func banner(
        text: String,
        systemImage: String,
        tint: Color,
        dismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: AppTheme.TypeScale.xs))
                .lineLimit(2)
            Spacer(minLength: AppTheme.Spacing.sm)
            if let dismiss {
                BarIconButton(systemName: "xmark", help: "Dismiss") {
                    dismiss()
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(tint.opacity(AppTheme.Opacity.ghostSoft))
    }

    private func conflictBanner(_ document: SubtitleDocument) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(AppTheme.Palette.needsReview)
            Text("This file changed on disk while you had unsaved edits.")
                .font(.system(size: AppTheme.TypeScale.xs))
                .lineLimit(2)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button("Reload") { workspace.reload(document) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Keep Mine") { workspace.keepLocal(document) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(
            AppTheme.Palette.needsReview.opacity(AppTheme.Opacity.ghostSoft)
        )
    }

    private func parseErrorBanner(_ document: SubtitleDocument) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(AppTheme.Palette.needsReview)
            Text(
                "\(document.parsed.errorCount) parsing problems. "
                    + "Cue editing is paused until the source parses."
            )
            .font(.system(size: AppTheme.TypeScale.xs))
            .lineLimit(2)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button("Fix in Source") {
                document.mode = .source
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(
            AppTheme.Palette.needsReview.opacity(AppTheme.Opacity.ghostSoft)
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "captions.bubble")
                .font(
                    .system(
                        size: AppTheme.IconSize.render,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(.tertiary)

            Text("No Subtitle Open")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))

            Text(
                "Open an SRT, WebVTT, ASS, or SSA file to edit cue text "
                    + "and timing beside a real media preview."
            )
            .font(.system(size: AppTheme.TypeScale.sm))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)

            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Open Subtitle…") {
                    workspace.presentOpenPanel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Text("Text and timing edits preserve every other byte of the file.")
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
            .fill(Color.appCard)
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
}
