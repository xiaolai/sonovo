import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Source-time transcript beside the edit timeline. Words are selectable;
/// deleting selected words routes through the media document so audio,
/// picture, and undo stay on the same decision.
struct MediaTranscriptView: View {
    @Bindable var session: TranscriptSession
    let document: MediaEditDocument
    let playhead: Double
    let onSeek: (Double) -> Void

    @State private var captionDraft = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header
            Divider()
            content
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(AppTheme.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xxs)
            }
            footer
        }
        .background(Color.appCard)
        .onAppear {
            syncCaptionDraft()
        }
        .onChange(of: session.selectedWordIDs) { _, _ in
            syncCaptionDraft()
        }
        .onChange(of: session.document) { _, _ in
            syncCaptionDraft()
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Text("Transcript")
                .font(.system(size: AppTheme.TypeScale.sm, weight: .semibold))
            Spacer()
            transcriptButton(
                "square.and.arrow.down",
                help: "Import Captions…"
            ) {
                presentImport()
            }
            if session.isTranscribing {
                transcriptButton(
                    "xmark",
                    help: "Cancel Transcription"
                ) {
                    session.cancel()
                }
            } else {
                transcriptButton(
                    "waveform",
                    help: "Transcribe on Device"
                ) {
                    Task { await session.transcribe() }
                }
                .disabled(session.state == .loading)
            }
            if session.hasDocument {
                transcriptButton(
                    "text.badge.minus",
                    help: "Select Filler Words"
                ) {
                    guard let state = document.editState else { return }
                    session.selectFillers(in: state)
                }
                transcriptButton(
                    "square.and.arrow.up",
                    help: "Export Captions…"
                ) {
                    exportCaptions()
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(height: AppTheme.Layout.subtitleHeaderHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .idle:
            emptyState
        case .loading:
            VStack(spacing: AppTheme.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text(session.statusText)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: AppTheme.TypeScale.lg))
                    .foregroundStyle(AppTheme.Palette.warning)
                Text(message)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            transcriptList
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "captions.bubble")
                .font(.system(size: AppTheme.TypeScale.xl))
                .foregroundStyle(.tertiary)
            Text("No transcript loaded")
                .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
            Text("Import caption cues or transcribe this file on device.")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Import Captions…") { presentImport() }
                Button("Transcribe") {
                    Task { await session.transcribe() }
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                if let document = session.document {
                    ForEach(document.segments) { segment in
                        let words = segment.wordIDs.compactMap {
                            document.word(id: $0)
                        }
                        TranscriptFlowLayout(spacing: AppTheme.Spacing.xxs) {
                            ForEach(words) { word in
                                wordButton(word)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.sm)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            selectionControls
        }
    }

    @ViewBuilder
    private var selectionControls: some View {
        if session.hasDocument {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                if let word = selectedWord {
                    TextField("Caption text", text: $captionDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: AppTheme.TypeScale.xs))
                        .onSubmit {
                            session.setCaption(captionDraft, for: word.id)
                        }
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Button("Apply Caption") {
                            session.setCaption(captionDraft, for: word.id)
                        }
                        Button("Revert") {
                            session.revertCaption(for: word.id)
                            captionDraft = session.captionText(for: word)
                        }
                    }
                    .font(.system(size: AppTheme.TypeScale.xs))
                }
                if !session.selectedWordIDs.isEmpty {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("\(session.selectedWordIDs.count) selected")
                            .font(.system(size: AppTheme.TypeScale.xs))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove Selected", role: .destructive) {
                            removeSelected()
                        }
                        Button("Clear") {
                            session.clearSelection()
                        }
                    }
                    .font(.system(size: AppTheme.TypeScale.xs))
                }
            }
            .padding(AppTheme.Spacing.sm)
            .background(Color.appCanvas)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.appSeparator)
                    .frame(height: AppTheme.BorderWidth.hairline)
            }
        }
    }

    private var footer: some View {
        Text(session.statusText)
            .font(.system(size: AppTheme.TypeScale.xxs))
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedWord: TranscriptWord? {
        guard session.selectedWordIDs.count == 1,
              let id = session.selectedWordIDs.first else {
            return nil
        }
        return session.document?.word(id: id)
    }

    private func wordButton(_ word: TranscriptWord) -> some View {
        let state = document.editState
        let removed = state.map { session.isRemoved(word, in: $0) } ?? false
        let selected = session.selectedWordIDs.contains(word.id)
        let current = playhead >= word.start && playhead < word.end
        return Button {
            let extending = NSEvent.modifierFlags.contains(.shift)
            session.toggleSelection(
                wordID: word.id,
                extending: extending
            )
            onSeek(word.start)
            errorMessage = nil
        } label: {
            Text(session.captionText(for: word))
                .font(
                    .system(
                        size: AppTheme.TypeScale.sm,
                        weight: current ? .semibold : .regular
                    )
                )
                .strikethrough(removed)
                .foregroundStyle(
                    removed
                        ? Color.secondary
                        : word.isFiller
                            ? AppTheme.Palette.warning
                            : Color.primary
                )
                .padding(.horizontal, AppTheme.Spacing.xs)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .background(
                    RoundedRectangle(
                        cornerRadius: AppTheme.Radius.control,
                        style: .continuous
                    )
                    .fill(
                        selected
                            ? Color.accentColor.opacity(AppTheme.Opacity.faint)
                            : Color.appCanvas
                    )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: AppTheme.Radius.control,
                        style: .continuous
                    )
                    .strokeBorder(
                        current ? Color.accentColor : Color.appSeparator,
                        lineWidth: current
                            ? AppTheme.BorderWidth.thin
                            : AppTheme.BorderWidth.hairline
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(removed)
        .help(
            "Click to seek and select; Shift-click to extend the selection."
        )
        .accessibilityLabel(
            removed ? "Removed word \(word.text)" : "Word \(word.text)"
        )
    }

    private func syncCaptionDraft() {
        guard let word = selectedWord else {
            captionDraft = ""
            return
        }
        captionDraft = session.captionText(for: word)
    }

    private func removeSelected() {
        let result = session.removeSelectedWords(from: document)
        switch result {
        case .changed:
            errorMessage = nil
        case .tooShort:
            errorMessage = "Removing these words would leave too little material."
        case .unchanged:
            errorMessage = "No removable words are selected."
        }
    }

    private func presentImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["srt", "vtt", "ass", "ssa"]
            .compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await session.importSubtitle(from: url) }
    }

    private func exportCaptions() {
        guard let state = document.editState else { return }
        do {
            let text = try session.exportCaptions(in: state)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [
                UTType(filenameExtension: "srt")
            ].compactMap { $0 }
            panel.nameFieldStringValue = "Transcribed Captions.srt"
            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }
            try Data(text.utf8).write(to: url, options: .atomic)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func transcriptButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        BarIconButton(
            systemName: systemName,
            help: help,
            iconSize: AppTheme.IconSize.medium,
            width: AppTheme.ControlSize.large,
            height: AppTheme.ControlSize.medium,
            hasRestingBackground: true,
            action: action
        )
    }
}

/// Wraps word chips as prose rather than a fixed grid.
struct TranscriptFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(
            width: proposal.width ?? usedWidth,
            height: y + rowHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: size.width,
                    height: size.height
                )
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
