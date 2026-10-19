import SwiftUI

struct StillsView: View {
    let state: AppState

    private var palettes: [CoastalPalette] { CoastalPalette.stills }

    var body: some View {
        if let asset = state.selectedAsset {
            content(asset)
        } else {
            EmptyEditorView()
        }
    }

    private func content(_ asset: ProductionAsset) -> some View {
        VStack(spacing: AppTheme.Spacing.md) {
            header(asset)

            stage

            contactSheet
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
                    StatusBadge(status: state.status(for: asset))
                }

                Text("\(asset.shortDetail) · Display P3")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            if state.status(for: asset) == .approved {
                Label("Approved", systemImage: "checkmark.circle.fill")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button {
                    state.approve(asset)
                } label: {
                    Label("Approve Frame", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var stage: some View {
        let index = state.selectedStillIndex % palettes.count
        let palette = palettes[index]

        return Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                ZStack {
                    Color.black
                    CoastalSceneView(palette: palette, showsBoat: index % 2 == 0)

                    LinearGradient(
                        colors: [Color.black.opacity(0.30), Color.clear, Color.black.opacity(0.35)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    VStack {
                        HStack(alignment: .top) {
                            stillLabel(index: index)
                            Spacer()
                            Text("2048 × 1152")
                                .font(.system(size: AppTheme.FontSize.xxs))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, AppTheme.Spacing.sm)
                                .padding(.vertical, AppTheme.Spacing.xs)
                                .background(Capsule().fill(.ultraThinMaterial))
                        }

                        Spacer()

                        HStack {
                            Text("35mm · f/2.8 · 1/125")
                                .font(.system(size: AppTheme.FontSize.xxs))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, AppTheme.Spacing.sm)
                                .padding(.vertical, AppTheme.Spacing.xs)
                                .background(Capsule().fill(.ultraThinMaterial))

                            Spacer()

                            Text("Fit")
                                .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, AppTheme.Spacing.sm)
                                .padding(.vertical, AppTheme.Spacing.xs)
                                .background(Capsule().fill(.ultraThinMaterial))
                        }
                    }
                    .padding(AppTheme.Spacing.md)

                    HStack {
                        previousButton
                        Spacer()
                        nextButton
                    }
                    .padding(.horizontal, AppTheme.Spacing.md)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                    .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }

    private func stillLabel(index: Int) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.selectedAsset.map { state.status(for: $0).color } ?? Color.orange)
                .frame(width: 5, height: 5)
            Text(String(format: "STILL %02d", index + 1))
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .tracking(0.8)
            Text("· Harbor at dawn")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(Capsule().fill(.ultraThinMaterial))
    }

    private var previousButton: some View {
        Button {
            state.selectedStillIndex = (state.selectedStillIndex - 1 + palettes.count) % palettes.count
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
        .help("Previous frame")
    }

    private var nextButton: some View {
        Button {
            state.selectedStillIndex = (state.selectedStillIndex + 1) % palettes.count
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
        .help("Next frame")
    }

    private var contactSheet: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text("Contact Sheet")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                Text("8 frames")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Select a frame to review")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(.tertiary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    ForEach(0..<palettes.count, id: \.self) { index in
                        Button {
                            state.selectedStillIndex = index
                        } label: {
                            ZStack(alignment: .bottomLeading) {
                                CoastalSceneView(
                                    palette: palettes[index],
                                    showsBoat: index % 2 == 0
                                )
                                .frame(width: 96, height: 54)

                                Text(String(format: "%02d", index + 1))
                                    .font(.system(size: AppTheme.FontSize.xxs, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.black.opacity(0.45)))
                                    .padding(4)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                                    .strokeBorder(
                                        state.selectedStillIndex == index ? Color.accentColor : Color.clear,
                                        lineWidth: AppTheme.BorderWidth.thick
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Show frame \(index + 1)")
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .appCardStyle()
    }
}
