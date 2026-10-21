import AppKit
import SwiftUI

/// The second image always comes from the same project. There is no
/// cross-project comparison and no ranking — the picker only chooses a file.
@MainActor
struct ComparisonPicker: View {
    let primary: ProjectAsset
    let candidates: [ProjectAsset]
    let onSelect: (ProjectAsset) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header
            Divider()
            if candidates.isEmpty {
                emptyState
            } else {
                candidateList
            }
        }
        .frame(
            width: AppTheme.Comparison.pickerWidth,
            height: AppTheme.Comparison.pickerHeight
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Compare \(primary.name) with")
                    .font(.system(size: AppTheme.TypeScale.md, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Another image in this project")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(AppTheme.Spacing.md)
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(
                    .system(
                        size: AppTheme.TypeScale.displaySmall,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(.tertiary)
            Text("No other images in this project")
                .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
            Text("Add another image to the project folder, then compare again.")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var candidateList: some View {
        ScrollView {
            LazyVStack(spacing: AppTheme.Spacing.zero) {
                ForEach(candidates) { asset in
                    Button {
                        onSelect(asset)
                    } label: {
                        row(for: asset)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private func row(for asset: ProjectAsset) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ProjectAssetThumbnailView(asset: asset)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(asset.name)
                    .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(asset.detail)
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Image(systemName: "chevron.right")
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Comparison.pickerRowHeight)
        .contentShape(Rectangle())
    }
}
