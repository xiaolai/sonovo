import AppKit
import SwiftUI

/// The header every document-like viewer shares: kind glyph, file name, an
/// optional subtitle, and a trailing control. Layout wrappers stay with each
/// viewer; this owns the row itself.
@MainActor
struct AssetViewerHeader<Trailing: View>: View {
    let asset: ProjectAsset
    let subtitle: String?
    let subtitleLineLimit: Int?
    private let trailing: Trailing

    init(
        asset: ProjectAsset,
        subtitle: String? = nil,
        subtitleLineLimit: Int? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.asset = asset
        self.subtitle = subtitle
        self.subtitleLineLimit = subtitleLineLimit
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: asset.kind.icon)
                .font(.system(size: AppTheme.TypeScale.body))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(asset.name)
                    .font(.system(size: AppTheme.TypeScale.md, weight: .semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: AppTheme.TypeScale.xs))
                        .foregroundStyle(.secondary)
                        .lineLimit(subtitleLineLimit)
                }
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            trailing
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Layout.subtitleHeaderHeight)
    }
}

extension AssetViewerHeader where Trailing == EmptyView {
    init(
        asset: ProjectAsset,
        subtitle: String? = nil,
        subtitleLineLimit: Int? = nil
    ) {
        self.init(
            asset: asset,
            subtitle: subtitle,
            subtitleLineLimit: subtitleLineLimit
        ) {
            EmptyView()
        }
    }
}

/// A label/value card for files without a visual preview. `QuickLookPreview`
/// and `MetadataAssetView` render the same information; only value
/// typography and card width differ.
@MainActor
struct AssetMetadataSummary: View {
    struct Field: Identifiable, Hashable {
        let label: String
        let value: String
        var monospaced = false

        var id: String { label }
    }

    let fields: [Field]
    var maxWidth: CGFloat?
    var rowSpacing: CGFloat = AppTheme.Spacing.md

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(fields) { field in
                HStack(
                    alignment: .firstTextBaseline,
                    spacing: AppTheme.Spacing.sm
                ) {
                    Text(field.label)
                        .font(.system(size: AppTheme.TypeScale.xs))
                        .foregroundStyle(.secondary)
                        .frame(
                            width: AppTheme.Size.metadataLabelWidth,
                            alignment: .leading
                        )
                    Text(field.value)
                        .font(
                            .system(
                                size: AppTheme.TypeScale.xs,
                                design: field.monospaced ? .monospaced : .default
                            )
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: AppTheme.Spacing.zero)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.panel,
                style: .continuous
            )
            .fill(Color.appCanvas)
        )
    }
}

/// One builder for the metadata fields both metadata-capable viewers show.
/// Callers choose only the differences in meaning: whether the kind row is
/// useful, whether a missing date gets an em dash, and value typography.
extension ProjectAsset {
    func viewerMetadataFields(
        includeKind: Bool,
        includeMissingModified: Bool,
        monospacedValues: Bool
    ) -> [AssetMetadataSummary.Field] {
        var fields: [AssetMetadataSummary.Field] = []
        if includeKind {
            fields.append(
                .init(
                    label: "Kind",
                    value: kind.projectGroup.title,
                    monospaced: monospacedValues
                )
            )
        }
        fields.append(
            .init(
                label: "Format",
                value: fileExtension.uppercased(),
                monospaced: monospacedValues
            )
        )
        fields.append(
            .init(
                label: "Size",
                value: ByteCountFormatter.string(
                    fromByteCount: size,
                    countStyle: .file
                ),
                monospaced: monospacedValues
            )
        )
        let modified = modified?.formatted(
            date: .abbreviated,
            time: .shortened
        )
        if let modified {
            fields.append(
                .init(
                    label: "Modified",
                    value: modified,
                    monospaced: monospacedValues
                )
            )
        } else if includeMissingModified {
            fields.append(
                .init(
                    label: "Modified",
                    value: "—",
                    monospaced: monospacedValues
                )
            )
        }
        fields.append(
            .init(
                label: "Path",
                value: relativePath,
                monospaced: monospacedValues
            )
        )
        return fields
    }
}
