import AppKit
import SwiftUI

@MainActor
struct MetadataAssetView: View {
    let asset: ProjectAsset

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header
            Divider()
            VStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: asset.kind.icon)
                    .font(
                        .system(
                            size: AppTheme.TypeScale.displayLarge,
                            weight: .ultraLight
                        )
                    )
                    .foregroundStyle(.tertiary)
                Text(asset.name)
                    .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
                    .lineLimit(1)
                Text(
                    "No preview is available for this file. Its metadata is "
                        + "shown here and the default app can open it."
                )
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)

                AssetMetadataSummary(
                    fields: asset.viewerMetadataFields(
                        includeKind: true,
                        includeMissingModified: true,
                        monospacedValues: false
                    ),
                    maxWidth: AppTheme.Layout.documentMetadataCardWidth,
                    rowSpacing: AppTheme.Spacing.s5
                )

                Button("Open in Default App") {
                    NSWorkspace.shared.open(asset.url)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(AppTheme.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .viewerCard()
    }

    private var header: some View {
        AssetViewerHeader(asset: asset) {
            Text(asset.fileExtension.uppercased())
                .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

}
