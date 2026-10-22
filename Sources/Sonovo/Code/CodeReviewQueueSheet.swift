import SwiftUI

/// The project review queue: changed files since the last acknowledged
/// baseline, each bound to the version it was compared against.
struct CodeReviewQueueSheet: View {
    let workspace: CodeWorkspace
    let project: Project

    @Environment(\.dismiss) private var dismiss
    @State private var busyPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("Project Changes")
                    .font(
                        .system(
                            size: AppTheme.TypeScale.lg,
                            weight: .semibold
                        )
                    )
                Spacer()
                Button {
                    Task { await workspace.refreshReviewQueue() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(workspace.isReviewQueueScanning)
            }

            coverage

            if workspace.isReviewQueueScanning {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let error = workspace.reviewQueueError {
                Text(error)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(Color(AppTheme.Palette.warning))
            }

            if let queue = workspace.reviewQueue,
               !queue.establishedBaseline,
               queue.items.isEmpty {
                Text("No changes since the last baseline.")
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(.secondary)
            } else if let queue = workspace.reviewQueue,
                      queue.establishedBaseline {
                Text(
                    "Baseline established for \(queue.coveredFiles) files. "
                        + "Changes appear here after they differ from it."
                )
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
            } else if let queue = workspace.reviewQueue {
                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: AppTheme.Spacing.xs
                    ) {
                        ForEach(queue.items) { item in
                            row(item)
                        }
                    }
                }
                .frame(height: AppTheme.Code.reviewQueueHeight)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Code.reviewSheetWidth)
        .task {
            await workspace.refreshReviewQueue()
        }
    }

    private var coverage: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(
                "Code and plain-text files only. Hidden files, ignored "
                    + "folders, symlinks, and unreadable files are excluded."
            )
            .font(.system(size: AppTheme.TypeScale.xs))
            .foregroundStyle(.secondary)
            if let queue = workspace.reviewQueue {
                HStack(spacing: AppTheme.Spacing.md) {
                    Text("\(queue.coveredFiles) inspected")
                    if queue.changedFileCount > 0 {
                        Text("\(queue.changedFileCount) changed")
                    }
                    if queue.unavailableFiles > 0 {
                        Text("\(queue.unavailableFiles) unavailable")
                    }
                    if queue.truncated {
                        Text(
                            "limited to \(CodeLimits.discoveryFiles) files"
                        )
                        .foregroundStyle(Color(AppTheme.Palette.warning))
                    }
                }
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ item: CodeReviewQueueItem) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: item.status.symbol)
                .font(.system(size: AppTheme.TypeScale.xs, weight: .medium))
                .foregroundStyle(color(for: item.status))
                .frame(width: AppTheme.ControlSize.mini)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(item.path)
                    .font(
                        .system(
                            size: AppTheme.TypeScale.sm,
                            design: .monospaced
                        )
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(item.status.label)
                        .font(
                            .system(
                                size: AppTheme.TypeScale.xs,
                                weight: .medium
                            )
                        )
                        .foregroundStyle(color(for: item.status))
                    if let note = item.decision?.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: AppTheme.TypeScale.xs))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            if busyPath == item.path {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Review") {
                    busyPath = item.path
                    Task {
                        _ = await workspace.beginQueueReview(item)
                        busyPath = nil
                        dismiss()
                    }
                }
                .disabled(!item.canReviewContent)
                Button(
                    item.status == .deleted ? "Forget" : "Set Baseline"
                ) {
                    busyPath = item.path
                    Task {
                        await workspace.acknowledgeQueueItem(item)
                        busyPath = nil
                    }
                }
            }
        }
        .padding(.vertical, AppTheme.Spacing.xxs)
    }

    private func color(for status: CodeReviewQueueStatus) -> Color {
        switch status {
        case .unreviewed, .seen:
            return Color.secondary
        case .changesRequested, .stale:
            return Color(AppTheme.Palette.warning)
        case .deleted:
            return Color(AppTheme.Palette.tertiaryLabel)
        }
    }
}
