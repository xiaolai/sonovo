import SwiftUI

struct DeliveryView: View {
    let state: AppState

    @State private var isRendering = false

    var body: some View {
        if let asset = state.selectedAsset {
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
                        .fill(Color.accentColor.opacity(0.08))
                        .frame(width: 66, height: 66)
                    Image(systemName: isRendering ? "gearshape.2" : "shippingbox")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: 5) {
                    Text(isRendering ? "Preparing Render" : "Not Rendered")
                        .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))

                    Text(isRendering
                         ? "Encoding 1080p · H.264. You can keep reviewing other assets."
                         : "This production has no delivery file yet.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }

                if isRendering {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 180)
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
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(.tertiary)

                if isRendering {
                    Button {
                        isRendering = false
                    } label: {
                        Label("Cancel Render", systemImage: "xmark")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button {
                        isRendering = true
                    } label: {
                        Label("Render 1080p", systemImage: "play.fill")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(AppTheme.Spacing.xxl)
            .frame(maxWidth: 440)
            .appCardStyle()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func header(_ asset: ProductionAsset) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(asset.name)
                        .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                    StatusBadge(status: isRendering ? .generating : state.status(for: asset))
                }

                Text(asset.shortDetail)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}
