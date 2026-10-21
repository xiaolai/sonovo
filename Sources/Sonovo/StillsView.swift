import SwiftUI

struct StillsView: View {
    let state: AppState
    let project: Project

    private var selectedAsset: ProductionAsset? {
        state.selectedAsset(in: project)
    }

    private var palettes: [CoastalPalette] { CoastalPalette.stills }

    var body: some View {
        if let asset = selectedAsset {
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
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(asset.name)
                        .font(.system(size: AppTheme.TypeScale.lg, weight: .semibold))
                    StatusBadge(status: state.status(for: asset))
                }

                Text("\(asset.shortDetail) · Display P3")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            if state.status(for: asset) == .approved {
                Label("Approved", systemImage: "checkmark.circle.fill")
                    .font(.system(size: AppTheme.TypeScale.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Palette.approved)
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
            .aspectRatio(AppTheme.Size.stageAspectWidth / AppTheme.Size.stageAspectHeight, contentMode: .fit)
            .overlay {
                ZStack {
                    AppTheme.Palette.black
                    CoastalSceneView(palette: palette, showsBoat: index % 2 == 0)

                    LinearGradient(
                        colors: [AppTheme.Palette.black.opacity(AppTheme.Opacity.dim), Color.clear, AppTheme.Palette.black.opacity(AppTheme.Opacity.secondary)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    VStack {
                        HStack(alignment: .top) {
                            stillLabel(index: index)
                            Spacer()
                            Text("2048 × 1152")
                                .font(.system(size: AppTheme.TypeScale.xxs))
                                .foregroundStyle(AppTheme.Palette.white.opacity(AppTheme.Opacity.bright))
                                .padding(.horizontal, AppTheme.Spacing.sm)
                                .padding(.vertical, AppTheme.Spacing.xs)
                                .background(Capsule().fill(AppTheme.Surface.mediaOverlay))
                        }

                        Spacer()

                        HStack {
                            Text("35mm · f/2.8 · 1/125")
                                .font(.system(size: AppTheme.TypeScale.xxs))
                                .foregroundStyle(AppTheme.Palette.white.opacity(AppTheme.Opacity.bright))
                                .padding(.horizontal, AppTheme.Spacing.sm)
                                .padding(.vertical, AppTheme.Spacing.xs)
                                .background(Capsule().fill(AppTheme.Surface.mediaOverlay))

                            Spacer()

                            Text("Fit")
                                .font(.system(size: AppTheme.TypeScale.xxs, weight: .medium))
                                .foregroundStyle(AppTheme.Palette.white.opacity(AppTheme.Opacity.near))
                                .padding(.horizontal, AppTheme.Spacing.sm)
                                .padding(.vertical, AppTheme.Spacing.xs)
                                .background(Capsule().fill(AppTheme.Surface.mediaOverlay))
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
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.surface, style: .continuous)
                    .strokeBorder(Color.appSeparator, lineWidth: AppTheme.BorderWidth.hairline)
            )
            .appShadow(AppTheme.Shadow.media)
    }

    private func stillLabel(index: Int) -> some View {
        HStack(spacing: AppTheme.Spacing.s5) {
            Circle()
                .fill(selectedAsset.map { state.status(for: $0).color } ?? AppTheme.Palette.needsReview)
                .frame(width: AppTheme.IconSize.dotSmall, height: AppTheme.IconSize.dotSmall)
            Text(String(format: "STILL %02d", index + 1))
                .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                .tracking(AppTheme.Tracking.wide)
            Text("· Harbor at dawn")
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(AppTheme.Palette.white.opacity(AppTheme.Opacity.heavySoft))
        }
        .foregroundStyle(AppTheme.Palette.white)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(Capsule().fill(AppTheme.Surface.mediaOverlay))
    }

    private var previousButton: some View {
        stillNavigationButton(
            systemName: "chevron.left",
            help: "Previous frame"
        ) {
            state.selectedStillIndex = (state.selectedStillIndex - 1 + palettes.count) % palettes.count
        }
    }

    private var nextButton: some View {
        stillNavigationButton(
            systemName: "chevron.right",
            help: "Next frame"
        ) {
            state.selectedStillIndex = (state.selectedStillIndex + 1) % palettes.count
        }
    }

    private func stillNavigationButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.TypeScale.body, weight: .semibold))
                .foregroundStyle(AppTheme.Palette.white)
                .frame(width: AppTheme.Size.compareHandle, height: AppTheme.Size.compareHandle)
                .background(Circle().fill(AppTheme.Surface.mediaOverlay))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var contactSheet: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text("Contact Sheet")
                    .font(.system(size: AppTheme.TypeScale.sm, weight: .semibold))
                Text("8 frames")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Select a frame to review")
                    .font(.system(size: AppTheme.TypeScale.xxs))
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
                                .frame(width: AppTheme.Size.stillThumbnailWidth, height: AppTheme.Size.stillThumbnailHeight)

                                Text(String(format: "%02d", index + 1))
                                    .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                                    .foregroundStyle(AppTheme.Palette.white)
                                    .padding(.horizontal, AppTheme.Spacing.xs)
                                    .padding(.vertical, AppTheme.Spacing.xxs)
                                    .background(Capsule().fill(AppTheme.Palette.black.opacity(AppTheme.Opacity.wash)))
                                    .padding(AppTheme.Spacing.xs)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
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
