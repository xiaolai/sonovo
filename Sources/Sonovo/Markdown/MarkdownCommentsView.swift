import SonovoCore
import SwiftUI

/// The review-comment panel: add a thread anchored at the source selection,
/// then reply, resolve, reveal, or delete threads.
///
/// The panel never edits the document. A thread's anchor is resolved against
/// the current source on every read, so an edited quote either follows its
/// text or reports that it cannot be placed.
struct MarkdownCommentsView: View {
    let document: MarkdownDocument
    let workspace: MarkdownWorkspace

    @State private var draft = ""
    @State private var replies: [UUID: String] = [:]
    /// A write is in flight; duplicate submissions are disabled.
    @State private var isSubmitting = false
    /// Bumped when the panel switches documents. A completion for an older
    /// document must not clear the new document's draft, even when the text
    /// happens to match.
    @State private var draftGeneration = 0

    private var state: ReviewCommentsController.DocumentState {
        workspace.reviewComments.state(for: document)
    }

    private var placements: [ReviewThreadPlacement] {
        workspace.reviewComments.placements(for: document)
    }

    private var openCount: Int {
        placements.count(where: \.isOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            header
            Divider()
            if let error = state.error {
                banner(
                    text: error,
                    tint: AppTheme.Palette.warning
                )
            }
            if state.externalChange {
                externalChangeActions
            }
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: AppTheme.Spacing.sm
                ) {
                    addSection
                    if placements.isEmpty {
                        Text("No comments yet.")
                            .font(.system(size: AppTheme.TypeScale.xs))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, AppTheme.Spacing.md)
                    } else {
                        ForEach(placements) { placement in
                            threadRow(placement)
                        }
                    }
                }
                .padding(.vertical, AppTheme.Spacing.sm)
            }
        }
        .frame(width: AppTheme.MarkdownChrome.Comments.panelWidth)
        .frame(
            minHeight: AppTheme.MarkdownChrome.Comments.panelMinHeight,
            maxHeight: .infinity
        )
        .background(AppTheme.MarkdownChrome.PaletteChrome.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comments")
        .task(id: document.id) {
            await workspace.loadReviewComments(for: document)
        }
        // A draft belongs to the document it was written for; the panel is
        // one view recycled across documents, so switching must not carry
        // text — or a pending reply — onto another document's selection.
        .onChange(of: document.id) {
            draft = ""
            replies = [:]
            isSubmitting = false
            draftGeneration &+= 1
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text("Comments")
                .font(.system(size: AppTheme.TypeScale.sm, weight: .semibold))
            if openCount > 0 {
                Text("\(openCount) open")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await workspace.reloadReviewComments(for: document) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Reload comments from disk")
            .accessibilityLabel("Reload comments from disk")
            Button {
                workspace.reviewComments.isVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close comments")
            .accessibilityLabel("Close comments")
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Layout.tabBarHeight)
    }

    private func banner(text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: AppTheme.TypeScale.xxs))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: AppTheme.Spacing.zero)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(tint.opacity(AppTheme.Opacity.faint))
    }

    private var externalChangeActions: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("Reload") {
                Task { await workspace.reloadReviewComments(for: document) }
            }
            Button("Overwrite") {
                Task { await workspace.overwriteReviewComments(for: document) }
            }
        }
        .font(.system(size: AppTheme.TypeScale.xs))
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.bottom, AppTheme.Spacing.xs)
    }

    // MARK: - Add

    @ViewBuilder
    private var addSection: some View {
        if document.fileURL == nil {
            Text("Save the document before adding comments.")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppTheme.Spacing.md)
        } else if state.isCorrupt {
            Text("Comments are read-only until the sidecar is repaired.")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppTheme.Spacing.md)
        } else if let quote = selectionQuote {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(quote)
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)
                    .lineLimit(AppTheme.MarkdownChrome.Comments.quoteLineLimit)
                TextField(
                    "Comment on the selection…",
                    text: $draft,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(
                    AppTheme.MarkdownChrome.Comments.quoteLineLimit,
                    reservesSpace: true
                )
                .accessibilityLabel("New comment")
                HStack {
                    Text("as \(workspace.reviewComments.author)")
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Add Comment") {
                        let body = draft
                        // The panel can outlive a document switch; the
                        // completion must not clear another document's
                        // draft that happens to hold the same text. The
                        // generation belongs to this panel view, so it
                        // changes exactly when the document does.
                        let generation = draftGeneration
                        isSubmitting = true
                        Task {
                            let added = await workspace.addReviewComment(
                                to: document,
                                body: body
                            )
                            guard generation == draftGeneration else {
                                return
                            }
                            isSubmitting = false
                            if added, draft == body {
                                draft = ""
                            }
                        }
                    }
                    .disabled(
                        isSubmitting
                            || draft.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                    )
                }
            }
            .padding(AppTheme.Spacing.sm)
            .background(
                AppTheme.MarkdownChrome.Comments.open
                    .opacity(AppTheme.MarkdownChrome.Comments.selectionTint)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control))
            .padding(.horizontal, AppTheme.Spacing.md)
        } else {
            Text("Select text in Source to add a comment.")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppTheme.Spacing.md)
        }
    }

    private var selectionQuote: String? {
        guard let selection = document.selection,
              selection.lowerBound < selection.upperBound else {
            return nil
        }
        let ns = document.source as NSString
        guard selection.upperBound <= ns.length else { return nil }
        let text = ns.substring(
            with: NSRange(
                location: selection.lowerBound,
                length: selection.count
            )
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Threads

    private func threadRow(_ placement: ReviewThreadPlacement) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.xs) {
                statusChip(placement)
                if let range = placement.range {
                    Text("Line \(lineNumber(at: range.lowerBound))")
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Line \(placement.thread.anchor.line) at creation")
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if placement.range != nil {
                    Button {
                        workspace.revealReviewComment(
                            placement.id,
                            in: document
                        )
                    } label: {
                        Image(systemName: "scope")
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Source")
                    .accessibilityLabel("Reveal comment in Source")
                }
                Button {
                    Task {
                        await workspace.setReviewCommentResolved(
                            !placement.thread.resolved,
                            threadID: placement.id,
                            in: document
                        )
                    }
                } label: {
                    Image(
                        systemName: placement.thread.resolved
                            ? "arrow.uturn.backward.circle"
                            : "checkmark.circle"
                    )
                }
                .buttonStyle(.plain)
                .help(
                    placement.thread.resolved
                        ? "Reopen comment"
                        : "Resolve comment"
                )
                .accessibilityLabel(
                    placement.thread.resolved
                        ? "Reopen comment"
                        : "Resolve comment"
                )
                Button {
                    Task {
                        await workspace.deleteReviewComment(
                            placement.id,
                            from: document
                        )
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Delete comment thread")
                .accessibilityLabel("Delete comment thread")
            }

            Text("“\(placement.thread.anchor.quote)”")
                .font(.system(size: AppTheme.TypeScale.xs))
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(AppTheme.MarkdownChrome.Comments.quoteLineLimit)

            ForEach(placement.thread.comments) { comment in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Text(comment.author)
                            .font(
                                .system(
                                    size: AppTheme.TypeScale.xxs,
                                    weight: .semibold
                                )
                            )
                        Text(
                            comment.createdAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .foregroundStyle(.tertiary)
                    }
                    Text(comment.body)
                        .font(.system(size: AppTheme.TypeScale.xs))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !placement.thread.resolved {
                HStack(spacing: AppTheme.Spacing.xs) {
                    TextField(
                        "Reply…",
                        text: replyBinding(placement.id)
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Reply to comment")
                    Button("Reply") {
                        let body = replies[placement.id] ?? ""
                        let generation = draftGeneration
                        isSubmitting = true
                        Task {
                            // Keep the text until the write succeeds, and
                            // never clear a line the user has since edited.
                            let replied = await workspace.replyToReviewComment(
                                placement.id,
                                in: document,
                                body: body
                            )
                            guard generation == draftGeneration else {
                                return
                            }
                            isSubmitting = false
                            if replied, (replies[placement.id] ?? "") == body {
                                replies[placement.id] = ""
                            }
                        }
                    }
                    .disabled(
                        isSubmitting
                            || (replies[placement.id] ?? "")
                                .trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty
                    )
                }
            }
        }
        .padding(AppTheme.Spacing.sm)
        .background(
            workspace.reviewComments.selectedThreadID == placement.id
                ? AppTheme.MarkdownChrome.Comments.open
                    .opacity(AppTheme.MarkdownChrome.Comments.selectionTint)
                : AppTheme.Palette.card
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control))
        .padding(.horizontal, AppTheme.Spacing.md)
        .accessibilityElement(children: .contain)
    }

    private func statusChip(_ placement: ReviewThreadPlacement) -> some View {
        let status = status(placement)
        return Text(status.label)
            .font(.system(size: AppTheme.TypeScale.xxs, weight: .medium))
            .foregroundStyle(status.color)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(status.color.opacity(AppTheme.Opacity.tint))
            .clipShape(Capsule())
    }

    private func status(
        _ placement: ReviewThreadPlacement
    ) -> (label: String, color: Color) {
        if placement.thread.resolved {
            return (
                "Resolved",
                AppTheme.MarkdownChrome.Comments.resolved
            )
        }
        switch placement.resolution {
        case .exact:
            return ("Open", AppTheme.MarkdownChrome.Comments.open)
        case .drifted:
            return ("Open · moved", AppTheme.MarkdownChrome.Comments.open)
        case .unresolved(.missing):
            return (
                "Quote not found",
                AppTheme.MarkdownChrome.Comments.unresolved
            )
        case .unresolved(.ambiguous):
            return (
                "Ambiguous anchor",
                AppTheme.MarkdownChrome.Comments.unresolved
            )
        }
    }

    private func lineNumber(at offset: Int) -> Int {
        ReviewAnchorResolver.lineNumber(at: offset, in: document.source)
    }

    private func replyBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { replies[id] ?? "" },
            set: { replies[id] = $0 }
        )
    }
}
