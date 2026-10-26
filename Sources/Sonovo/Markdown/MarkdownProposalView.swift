import SonovoCore
import SwiftUI

/// The proposal diff sheet: each hunk is accepted or rejected independently,
/// and Apply writes one undoable source edit through the document's save
/// path. The sheet refuses when the document no longer matches the base the
/// proposal was written against.
struct MarkdownProposalView: View {
    let preview: MarkdownWorkspace.ProposalPreview
    let document: MarkdownDocument
    let workspace: MarkdownWorkspace

    @State private var accepted: Set<Int>

    init(
        preview: MarkdownWorkspace.ProposalPreview,
        document: MarkdownDocument,
        workspace: MarkdownWorkspace
    ) {
        self.preview = preview
        self.document = document
        self.workspace = workspace
        _accepted = State(
            initialValue: Set(preview.proposal.hunks.map(\.id))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            header
            Divider()
            if let error = workspace.proposalError {
                errorBanner(error)
            }
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: AppTheme.Spacing.sm
                ) {
                    ForEach(preview.proposal.hunks) { hunk in
                        hunkCard(hunk)
                    }
                }
                .padding(AppTheme.Spacing.md)
            }
            Divider()
            footer
        }
        .frame(width: AppTheme.MarkdownChrome.Proposal.width)
        .frame(height: AppTheme.MarkdownChrome.Proposal.height)
        .background(AppTheme.MarkdownChrome.PaletteChrome.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposal diff")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("Proposal")
                    .font(
                        .system(size: AppTheme.TypeScale.sm, weight: .semibold)
                    )
                Text("for \(preview.proposal.documentName)")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("base verified")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(AppTheme.Palette.success)
            }
            Text(preview.fileURL.lastPathComponent)
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(AppTheme.Palette.warning)
            Text(text)
                .font(.system(size: AppTheme.TypeScale.xs))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: AppTheme.Spacing.zero)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(AppTheme.Palette.warning.opacity(AppTheme.Opacity.faint))
    }

    private func hunkCard(_ hunk: ProposalHunk) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Toggle(
                    "Hunk \(hunk.id)",
                    isOn: acceptance(hunk.id)
                )
                .toggleStyle(.checkbox)
                .font(.system(size: AppTheme.TypeScale.xs, weight: .medium))
                Text(
                    "−\(hunk.oldCount) +\(hunk.newCount) · "
                        + "line \(hunk.oldStart)"
                )
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.secondary)
                if !hunk.section.isEmpty {
                    Text(hunk.section)
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                ForEach(
                    Array(hunk.displayLines.enumerated()),
                    id: \.offset
                ) { _, line in
                    lineRow(line)
                }
            }
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(AppTheme.Palette.text)
            .clipShape(
                RoundedRectangle(cornerRadius: AppTheme.Radius.micro)
            )
        }
        .padding(AppTheme.Spacing.sm)
        .background(AppTheme.Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control))
        .accessibilityElement(children: .contain)
    }

    private func lineRow(_ line: ProposalLine) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text(marker(line))
                .font(
                    .system(
                        size: AppTheme.TypeScale.xxs,
                        design: .monospaced
                    )
                )
                .foregroundStyle(color(line))
                .frame(width: AppTheme.MarkdownChrome.Proposal.lineNumberWidth)
            Text(line.text.isEmpty ? " " : line.text)
                .font(
                    .system(
                        size: AppTheme.TypeScale.xs,
                        design: .monospaced
                    )
                )
                .foregroundStyle(textColor(line))
                // The sheet is a fixed width and has no horizontal scroll;
                // wrapping is what keeps a long line fully reviewable.
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: AppTheme.Spacing.zero)
        }
        .padding(.horizontal, AppTheme.Spacing.xs)
        .background(color(line).opacity(AppTheme.Opacity.ghostSoft))
    }

    private var footer: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("\(accepted.count) of \(preview.proposal.hunks.count) hunks")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
                workspace.dismissProposal()
            }
            Button("Apply Selected") {
                let selection = accepted
                Task {
                    await workspace.applyProposal(
                        accepting: selection,
                        in: document
                    )
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(accepted.isEmpty)
        }
        .padding(AppTheme.Spacing.md)
    }

    private func acceptance(_ id: Int) -> Binding<Bool> {
        Binding(
            get: { accepted.contains(id) },
            set: { isOn in
                if isOn {
                    accepted.insert(id)
                } else {
                    accepted.remove(id)
                }
            }
        )
    }

    private func marker(_ line: ProposalLine) -> String {
        switch line {
        case .context:
            return " "
        case .removed:
            return "−"
        case .added:
            return "+"
        case let .endOfFile(added):
            return added ? "+" : "−"
        }
    }

    private func color(_ line: ProposalLine) -> Color {
        switch line {
        case .context:
            return AppTheme.Palette.tertiaryLabel
        case .removed:
            return AppTheme.MarkdownChrome.Proposal.removed
        case .added:
            return AppTheme.MarkdownChrome.Proposal.added
        case let .endOfFile(added):
            return added
                ? AppTheme.MarkdownChrome.Proposal.added
                : AppTheme.MarkdownChrome.Proposal.removed
        }
    }

    private func textColor(_ line: ProposalLine) -> Color {
        switch line {
        case .context:
            return AppTheme.Palette.secondaryLabel
        case .removed, .added, .endOfFile:
            return AppTheme.Palette.label
        }
    }
}
