import AppKit
import SwiftUI

/// Two images, one shared scale and pan. Side-by-side shows both in full;
/// wipe shows A on the left and B on the right of a draggable divider. The
/// manual alignment offset is the only registration this view claims.
@MainActor
struct ComparisonView: View {
    @Bindable var model: ComparisonModel
    let onClose: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var currentFit: CGFloat = 0
    @State private var stageSize: CGSize = .zero
    @State private var zoomStart: CGFloat = 1
    @State private var panStart: CGSize = .zero
    @State private var alignmentStart: CGSize = .zero
    @State private var wipeStart: Double = ComparisonModel.defaultWipeFraction
    @State private var dragClassified = false
    @State private var dragStartedOnDivider = false
    @State private var dividerDragActive = false

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header
            Divider()
            stage
            Divider()
            metadataStrip
        }
        .viewerCard()
        .task {
            await model.load()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            chip("A")
            Text(model.leadingAsset.name)
                .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Image(systemName: "arrow.left.and.right")
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.tertiary)

            chip("B")
            Text(model.trailingAsset.name)
                .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: AppTheme.Spacing.sm)

            Picker("Mode", selection: $model.mode) {
                ForEach(ComparisonModel.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: AppTheme.Comparison.modePickerWidth)

            Button("Fit") {
                resetView()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.leading.image == nil && model.trailing.image == nil)

            Button("1:1") {
                actualSize(fit: currentFit)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.canUseActualSize)

            Text(zoomLabel)
                .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: AppTheme.Comparison.zoomLabelWidth)

            Toggle(isOn: $model.isAligning) {
                Image(
                    systemName: "arrow.up.and.down.and.arrow.left.and.right"
                )
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Drag to shift B, or drag the stage to pan both")
            .accessibilityLabel("Align")

            Button("Center") {
                model.resetAlignment()
                alignmentStart = .zero
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.alignment == .zero)

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Close comparison")
            .accessibilityLabel("Close comparison")
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Layout.subtitleHeaderHeight)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
            .foregroundStyle(AppTheme.Palette.white)
            .padding(.horizontal, AppTheme.Spacing.s6)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.micro,
                    style: .continuous
                )
                .fill(
                    AppTheme.Palette.black.opacity(AppTheme.Opacity.heavy)
                )
            )
    }

    // MARK: - Stage

    private var stage: some View {
        GeometryReader { geometry in
            let container = geometry.size
            let gap = AppTheme.Spacing.xs
            let pane = model.mode == .sideBySide
                ? CGSize(
                    width: max(
                        (container.width - gap) * AppTheme.Comparison.half,
                        AppTheme.Comparison.minimumPaneWidth
                    ),
                    height: container.height
                )
                : container
            let fit = ComparisonModel.fitScale(
                leading: model.leadingDisplaySize,
                trailing: model.trailingDisplaySize,
                in: pane
            )
            Group {
                if model.mode == .sideBySide {
                    sideBySide(
                        container: container,
                        pane: pane,
                        fit: fit,
                        gap: gap
                    )
                } else {
                    wipe(container: container, fit: fit)
                }
            }
            .frame(width: container.width, height: container.height)
            .contentShape(Rectangle())
            .gesture(zoomGesture)
            .simultaneousGesture(panGesture)
            .onTapGesture(count: 2) {
                toggleActualSize(fit: fit)
            }
            .onAppear {
                stageSize = container
                currentFit = fit
            }
            .onChange(of: geometry.size) { _, size in
                stageSize = size
                // `fit` is derived from this size in the body; its own
                // observation updates `currentFit` when the value changes.
            }
            .onChange(of: fit) { _, value in
                currentFit = value
            }
            .onChange(of: model.mode) { _, _ in
                resetView()
            }
        }
        .background(Color.appCanvas)
    }

    private func sideBySide(
        container: CGSize,
        pane: CGSize,
        fit: CGFloat,
        gap: CGFloat
    ) -> some View {
        HStack(spacing: gap) {
            paneView(
                side: .leading,
                asset: model.leadingAsset,
                imageModel: model.leading,
                displaySize: model.leadingDisplaySize,
                fit: fit,
                pane: pane
            )
            paneView(
                side: .trailing,
                asset: model.trailingAsset,
                imageModel: model.trailing,
                displaySize: model.trailingDisplaySize,
                fit: fit,
                pane: pane
            )
        }
        .frame(width: container.width, height: container.height)
    }

    private func paneView(
        side: ComparisonSide,
        asset: ProjectAsset,
        imageModel: ImageDocumentModel,
        displaySize: CGSize?,
        fit: CGFloat,
        pane: CGSize
    ) -> some View {
        ZStack {
            Color.appCanvas
            switch imageModel.state {
            case .idle, .loading:
                ProgressView()
            case .failed(let message):
                paneFailure(asset: asset, message: message)
            case .ready:
                if let image = imageModel.image, let displaySize {
                    imageLayer(
                        image: image,
                        displaySize: displaySize,
                        fit: fit,
                        offset: model.offset(for: side),
                        container: pane
                    )
                } else {
                    paneFailure(
                        asset: asset,
                        message: "The image could not be displayed."
                    )
                }
            }
            VStack {
                HStack {
                    chip(side == .leading ? "A" : "B")
                    Spacer()
                }
                Spacer()
            }
            .padding(AppTheme.Spacing.sm)
        }
        .frame(width: pane.width, height: pane.height)
        .clipped()
    }

    private func paneFailure(
        asset: ProjectAsset,
        message: String
    ) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(
                    .system(
                        size: AppTheme.TypeScale.displaySmall,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(AppTheme.Palette.warning)
            Text(message)
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)
            Button("Open in Default App") {
                NSWorkspace.shared.open(asset.url)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(AppTheme.Spacing.md)
    }

    private func wipe(
        container: CGSize,
        fit: CGFloat
    ) -> some View {
        ZStack {
            stageLayer(
                side: .leading,
                image: model.leading.image,
                displaySize: model.leadingDisplaySize,
                fit: fit,
                container: container
            )
            .clipShape(
                WipeClip(fraction: model.wipeFraction, edge: .leading)
            )
            stageLayer(
                side: .trailing,
                image: model.trailing.image,
                displaySize: model.trailingDisplaySize,
                fit: fit,
                container: container
            )
            .clipShape(
                WipeClip(fraction: model.wipeFraction, edge: .trailing)
            )
            wipeOverlay(container: container)
            if let failure = wipeFailure {
                wipeFailureCard(failure)
            } else if model.leading.image == nil
                || model.trailing.image == nil {
                ProgressView()
                    .padding(AppTheme.Spacing.md)
                    .background(Color.appText.opacity(AppTheme.Opacity.near))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: AppTheme.Radius.panel,
                            style: .continuous
                        )
                    )
            }
        }
        .frame(width: container.width, height: container.height)
        .clipped()
    }

    @ViewBuilder
    private func stageLayer(
        side: ComparisonSide,
        image: NSImage?,
        displaySize: CGSize?,
        fit: CGFloat,
        container: CGSize
    ) -> some View {
        if let image, let displaySize {
            imageLayer(
                image: image,
                displaySize: displaySize,
                fit: fit,
                offset: model.offset(for: side),
                container: container
            )
        } else {
            Color.clear
        }
    }

    private func imageLayer(
        image: NSImage,
        displaySize: CGSize,
        fit: CGFloat,
        offset: CGSize,
        container: CGSize
    ) -> some View {
        Image(nsImage: image)
            .interpolation(
                model.zoom * fit * displayScale >= 1 ? .none : .high
            )
            .resizable()
            .frame(
                width: displaySize.width * fit,
                height: displaySize.height * fit
            )
            .scaleEffect(model.zoom)
            .offset(offset)
            .frame(width: container.width, height: container.height)
    }

    private func wipeOverlay(container: CGSize) -> some View {
        let x = ComparisonModel.dividerX(
            in: container.width,
            fraction: model.wipeFraction
        )
        let midY = container.height * AppTheme.Comparison.half
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(AppTheme.Palette.white)
                .frame(
                    width: AppTheme.BorderWidth.thick,
                    height: container.height
                )
                .overlay(
                    Rectangle().strokeBorder(
                        AppTheme.Palette.black
                            .opacity(AppTheme.Opacity.soft),
                        lineWidth: AppTheme.BorderWidth.hairline
                    )
                )
                .offset(x: x)

            Circle()
                .fill(AppTheme.Palette.white)
                .overlay(
                    Circle().strokeBorder(
                        AppTheme.Palette.black
                            .opacity(AppTheme.Opacity.soft),
                        lineWidth: AppTheme.BorderWidth.hairline
                    )
                )
                .overlay(
                    Image(systemName: "arrow.left.and.right")
                        .font(
                            .system(
                                size: AppTheme.TypeScale.xxs,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(AppTheme.Palette.black)
                )
                .frame(
                    width: AppTheme.Comparison.handleDiameter,
                    height: AppTheme.Comparison.handleDiameter
                )
                .offset(
                    x: x - AppTheme.Comparison.handleRadius,
                    y: midY - AppTheme.Comparison.handleRadius
                )

            Rectangle()
                .fill(Color.clear)
                .frame(
                    width: AppTheme.Comparison.dividerHitWidth,
                    height: container.height
                )
                .offset(x: x - AppTheme.Comparison.dividerHitRadius)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dividerDragActive = true
                            model.setWipe(
                                fraction: wipeStart
                                    + value.translation.width
                                    / max(container.width, 1)
                            )
                        }
                        .onEnded { _ in
                            wipeStart = model.wipeFraction
                            dividerDragActive = false
                        }
                )

            VStack {
                HStack {
                    chip("A")
                    Spacer()
                    chip("B")
                }
                Spacer()
            }
            .padding(AppTheme.Spacing.sm)
        }
        .frame(width: container.width, height: container.height)
    }

    private var wipeFailure: WipeFailure? {
        if case .failed(let message) = model.leading.state {
            return WipeFailure(
                side: .leading,
                asset: model.leadingAsset,
                message: message
            )
        }
        if case .failed(let message) = model.trailing.state {
            return WipeFailure(
                side: .trailing,
                asset: model.trailingAsset,
                message: message
            )
        }
        return nil
    }

    private func wipeFailureCard(_ failure: WipeFailure) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Text(
                failure.side == .leading
                    ? "A could not be displayed"
                    : "B could not be displayed"
            )
            .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
            Text(failure.message)
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)
            Button("Open in Default App") {
                NSWorkspace.shared.open(failure.asset.url)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.panel,
                style: .continuous
            )
            .fill(Color.appText.opacity(AppTheme.Opacity.near))
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.panel,
                style: .continuous
            )
            .strokeBorder(
                Color.appSeparator,
                lineWidth: AppTheme.BorderWidth.hairline
            )
        )
    }

    // MARK: - Metadata

    private var metadataStrip: some View {
        let rows = model.metadataRows
        return HStack(spacing: AppTheme.Spacing.zero) {
            ForEach(Array(rows.enumerated()), id: \.element.id) {
                index,
                row in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(row.label)
                        .font(.system(size: AppTheme.TypeScale.xxs))
                        .foregroundStyle(.secondary)
                    HStack(spacing: AppTheme.Spacing.s5) {
                        Text(row.leading)
                            .foregroundStyle(
                                row.differs
                                    ? AppTheme.Palette.warning
                                    : Color.appLabel
                            )
                        Text("vs")
                            .foregroundStyle(.tertiary)
                        Text(row.trailing)
                            .foregroundStyle(
                                row.differs
                                    ? AppTheme.Palette.warning
                                    : Color.appLabel
                            )
                    }
                    .font(
                        .system(
                            size: AppTheme.TypeScale.xs,
                            design: .monospaced
                        )
                    )
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if index < rows.count - 1 {
                    Divider()
                        .frame(
                            height: AppTheme.Comparison.metadataDividerHeight
                        )
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Comparison.metadataStripHeight)
    }

    // MARK: - Actions

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                // Keep the gesture range around the calculated 1:1 zoom.
                // A fixed range would snap a pinch away from an extreme
                // actual-size scale.
                let target = ComparisonModel.actualSizeZoom(
                    fit: currentFit,
                    displayScale: displayScale
                )
                let floor = min(
                    ComparisonModel.minimumZoom,
                    target * AppTheme.Viewer.zoomFloorFactor
                )
                let ceiling = max(
                    ComparisonModel.maximumZoom,
                    target * AppTheme.Viewer.zoomCeilingFactor
                )
                model.zoom = min(
                    max(zoomStart * value, floor),
                    ceiling
                )
            }
            .onEnded { _ in
                zoomStart = model.zoom
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // The divider's own gesture owns the drag from its first
                // event; do not wait for this parent gesture to classify.
                if dividerDragActive { return }
                if !dragClassified {
                    // Classify once at the start. Rechecking against the
                    // moving divider would let the pan start mid-drag as
                    // soon as the divider left the hit radius.
                    dragClassified = true
                    dragStartedOnDivider = model.mode == .wipe
                        && startsOnDivider(
                            value.startLocation,
                            width: stageSize.width
                        )
                }
                if dragStartedOnDivider {
                    return
                }
                if model.isAligning {
                    model.alignment = CGSize(
                        width: alignmentStart.width
                            + value.translation.width,
                        height: alignmentStart.height
                            + value.translation.height
                    )
                } else {
                    model.pan = CGSize(
                        width: panStart.width + value.translation.width,
                        height: panStart.height + value.translation.height
                    )
                }
            }
            .onEnded { _ in
                if !dragStartedOnDivider {
                    if model.isAligning {
                        alignmentStart = model.alignment
                    } else {
                        panStart = model.pan
                    }
                }
                dragClassified = false
                dragStartedOnDivider = false
            }
    }

    private func startsOnDivider(_ point: CGPoint, width: CGFloat) -> Bool {
        guard width > 0 else { return false }
        let x = ComparisonModel.dividerX(
            in: width,
            fraction: model.wipeFraction
        )
        return abs(point.x - x) <= AppTheme.Comparison.dividerHitRadius
    }

    private func resetView() {
        model.fit()
        panStart = .zero
        zoomStart = 1
        alignmentStart = model.alignment
    }

    private func actualSize(fit: CGFloat) {
        model.actualSize(fit: fit, displayScale: displayScale)
        panStart = .zero
        zoomStart = model.zoom
        alignmentStart = model.alignment
    }

    private func toggleActualSize(fit: CGFloat) {
        guard model.canUseActualSize else { return }
        // Compare against the calculated 1:1 zoom, not against 1. Fit can
        // enlarge a small image, making actual size a zoom below 1; the old
        // check then chose actual size forever.
        let target = ComparisonModel.actualSizeZoom(
            fit: fit,
            displayScale: displayScale
        )
        let tolerance = max(
            AppTheme.Viewer.doubleTapToleranceFloor,
            abs(target) * AppTheme.Viewer.doubleTapToleranceFraction
        )
        if abs(model.zoom - target) <= tolerance {
            resetView()
        } else {
            actualSize(fit: fit)
        }
    }

    private var zoomLabel: String {
        guard currentFit > 0 else { return "—" }
        let percent = Int(
            (currentFit * model.zoom * displayScale * 100).rounded()
        )
        return "\(percent)%"
    }
}

private struct WipeFailure {
    let side: ComparisonSide
    let asset: ProjectAsset
    let message: String
}

private struct WipeClip: Shape {
    enum Edge {
        case leading
        case trailing
    }

    var fraction: Double
    var edge: Edge

    func path(in rect: CGRect) -> Path {
        let divider = ComparisonModel.dividerX(
            in: rect.size.width,
            fraction: fraction
        )
        switch edge {
        case .leading:
            return Path(
                CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: divider,
                    height: rect.size.height
                )
            )
        case .trailing:
            return Path(
                ComparisonModel.wipeClipRect(
                    in: rect.size,
                    fraction: fraction
                )
            )
        }
    }
}
