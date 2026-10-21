import SwiftUI

struct DeliveryView: View {
    let state: AppState
    let project: Project

    private var selectedAsset: ProductionAsset? {
        state.selectedAsset(in: project)
    }

    @State private var isRendering = false

    var body: some View {
        if let asset = selectedAsset {
            content(asset)
        } else {
            EmptyEditorView()
        }
    }

    private func content(_ asset: ProductionAsset) -> some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            header(asset)

            VStack(spacing: AppTheme.Spacing.lg) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(AppTheme.Opacity.faint))
                        .frame(width: AppTheme.IconSize.render, height: AppTheme.IconSize.render)
                    Image(systemName: isRendering ? "gearshape.2" : "shippingbox")
                        .font(.system(size: AppTheme.TypeScale.displayMedium, weight: .light))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: AppTheme.Spacing.s5) {
                    Text(isRendering ? "Preparing Render" : "Not Rendered")
                        .font(.system(size: AppTheme.TypeScale.xl, weight: .semibold))

                    Text(isRendering
                         ? "Encoding 1080p · H.264. You can keep reviewing other assets."
                         : "This production has no delivery file yet.")
                        .font(.system(size: AppTheme.TypeScale.sm))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)
                }

                if isRendering {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: AppTheme.Size.progressWidth)
                }

                HStack(spacing: AppTheme.Spacing.sm) {
                    Text("1920 × 1080")
                    Text("·")
                    Text("24 fps")
                    Text("·")
                    Text("H.264")
                    Text("·")
                    Text("AAC")
                }
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.tertiary)

                if isRendering {
                    Button {
                        isRendering = false
                    } label: {
                        Label("Cancel Render", systemImage: "xmark")
                            .frame(minWidth: AppTheme.Size.renderButtonMinWidth)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button {
                        isRendering = true
                    } label: {
                        Label("Render 1080p", systemImage: "play.fill")
                            .frame(minWidth: AppTheme.Size.renderButtonMinWidth)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(AppTheme.Spacing.xxl)
            .frame(maxWidth: AppTheme.Layout.dialogueMaxWidth)
            .appCardStyle()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func header(_ asset: ProductionAsset) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(asset.name)
                        .font(.system(size: AppTheme.TypeScale.lg, weight: .semibold))
                    StatusBadge(status: isRendering ? .generating : state.status(for: asset))
                }

                Text(asset.shortDetail)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}
