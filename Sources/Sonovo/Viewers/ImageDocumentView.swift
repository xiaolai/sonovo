import AppKit
import SwiftUI

@MainActor
struct ImageDocumentView: View {
    let asset: ProjectAsset
    let comparisonCandidates: [ProjectAsset]

    @State private var model: ImageDocumentModel
    @State private var comparison: ComparisonModel?
    @State private var showComparisonPicker = false
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var currentFit: CGFloat = 1
    @Environment(\.displayScale) private var displayScale

    init(
        asset: ProjectAsset,
        comparisonCandidates: [ProjectAsset] = []
    ) {
        self.asset = asset
        self.comparisonCandidates = comparisonCandidates
        _model = State(initialValue: ImageDocumentModel(url: asset.url))
    }

    var body: some View {
        if let comparison {
            ComparisonView(
                model: comparison,
                onClose: { self.comparison = nil }
            )
        } else {
            singleView
        }
    }

    private var singleView: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header
            Divider()
            content
        }
        .viewerCard()
        .task {
            await model.load()
        }
        .sheet(isPresented: $showComparisonPicker) {
            ComparisonPicker(
                primary: asset,
                candidates: comparisonCandidates,
                onSelect: { candidate in
                    showComparisonPicker = false
                    comparison = ComparisonModel(
                        leading: asset,
                        trailing: candidate,
                        leadingModel: model
                    )
                },
                onCancel: { showComparisonPicker = false }
            )
        }
    }

    private var header: some View {
        AssetViewerHeader(
            asset: asset,
            subtitle: metadataLine,
            subtitleLineLimit: 1
        ) {
            if model.isDownsampled {
                Text("Preview (downsampled)")
                    .font(.system(size: AppTheme.TypeScale.xxs, weight: .medium))
                    .foregroundStyle(AppTheme.Palette.warning)
            }

            Text(zoomLabel)
                .font(.system(size: AppTheme.TypeScale.xxs, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize()

            Button("Fit") {
                resetView()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Fit the image to the window")

            Button("1:1") {
                actualSize()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isDownsampled)
            .help(
                model.isDownsampled
                    ? "Full-size zoom is unavailable for a downsampled preview"
                    : "One source pixel per display pixel"
            )

            Button("Compare") {
                showComparisonPicker = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(comparisonCandidates.isEmpty)
            .help(
                comparisonCandidates.isEmpty
                    ? "No other image in this project"
                    : "Compare with another image"
            )
        }
    }

    private var metadataLine: String {
        guard let metadata = model.metadata else {
            return asset.fileExtension.uppercased()
        }
        var parts = [
            "\(metadata.pixelWidth)×\(metadata.pixelHeight)"
        ]
        if let model = metadata.colorModel { parts.append(model) }
        if let profile = metadata.profileName { parts.append(profile) }
        if let dpi = metadata.dpiWidth,
           dpi.isFinite,
           dpi > 0,
           let rounded = Int(exactly: dpi.rounded()) {
            // `Int(exactly:)` rejects 2^63, which `Double(Int.max)` rounds
            // up to; a `< Double(Int.max)` bound would still trap there.
            parts.append("\(rounded) dpi")
        }
        if let exif = metadata.exifSummary {
            parts.append(exif)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            VStack(spacing: AppTheme.Spacing.md) {
                ProgressView()
                Text("Loading image…")
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            failureState(message)
        case .ready:
            if let image = model.image {
                imageStage(image: image)
            } else {
                failureState("The image could not be displayed.")
            }
        }
    }

    private func imageStage(image: NSImage) -> some View {
        GeometryReader { geometry in
            // The decoded image already has its EXIF orientation applied, so
            // its size can differ from the stored pixel dimensions (a portrait
            // photo is stored landscape). Frame by the displayed size; using
            // the raw dimensions would squash the image.
            let displaySize = image.size
            let fit = fitScale(
                size: displaySize,
                in: geometry.size
            )
            let baseWidth = displaySize.width * fit
            let baseHeight = displaySize.height * fit

            Image(nsImage: image)
                .interpolation(
                    zoom * fit * displayScale >= 1 ? .none : .high
                )
                .resizable()
                .frame(width: baseWidth, height: baseHeight)
                .scaleEffect(zoom)
                .offset(offset)
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height
                )
                // Zooming and panning must not paint over the header or the
                // surrounding card chrome.
                .clipped()
                .contentShape(Rectangle())
                .onAppear {
                    currentFit = fit
                }
                .onChange(of: geometry.size) { _, _ in
                    currentFit = fit
                }
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            zoom = clampZoom(lastZoom * value)
                        }
                        .onEnded { _ in
                            lastZoom = zoom
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: lastOffset.width
                                    + value.translation.width,
                                height: lastOffset.height
                                    + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .onTapGesture(count: 2) {
                    // Compare against the calculated 1:1 zoom. Fit can
                    // enlarge a small image, so the old `zoom > 1` test
                    // never returned to fit.
                    let tolerance = max(0.001, abs(actualSizeZoom) * 0.01)
                    if abs(zoom - actualSizeZoom) <= tolerance {
                        resetView()
                    } else {
                        actualSize()
                    }
                }
        }
        .background(Color.appCanvas)
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(
                    .system(
                        size: AppTheme.TypeScale.displayLarge,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(AppTheme.Palette.warning)
            Text("Could not display this image")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
            Text(message)
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)
            Button("Open in Default App") {
                NSWorkspace.shared.open(asset.url)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fitScale(
        size displaySize: CGSize,
        in size: CGSize
    ) -> CGFloat {
        let width = max(displaySize.width, 1)
        let height = max(displaySize.height, 1)
        return min(
            max(size.width, 1) / width,
            max(size.height, 1) / height
        )
    }

    private func resetView() {
        zoom = 1
        lastZoom = 1
        offset = .zero
        lastOffset = .zero
    }

    private func actualSize() {
        guard model.metadata != nil, !model.isDownsampled else { return }
        // One source pixel per physical display pixel. The base image is
        // fitted in points, then multiplied by zoom; displayScale converts
        // points back to device pixels. Do not clamp this to the gesture
        // range: a small image fitted large needs a zoom below the ordinary
        // minimum to be genuinely 1:1.
        zoom = 1 / max(currentFit * displayScale, 0.0001)
        lastZoom = zoom
        offset = .zero
        lastOffset = .zero
    }

    private var actualSizeZoom: CGFloat {
        1 / max(currentFit * displayScale, 0.0001)
    }

    /// A tiny image fitted large can need a 1:1 zoom far below any fixed
    /// floor. Keep the gesture range below it so a pinch does not jump.
    private var zoomFloor: CGFloat {
        min(0.001, actualSizeZoom * 0.5)
    }

    /// A very large image's true 1:1 zoom can exceed the ordinary maximum.
    /// Keep the gesture range around it instead of snapping down on a pinch.
    private var zoomCeiling: CGFloat {
        max(16, actualSizeZoom * 1.5)
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, zoomFloor), zoomCeiling)
    }

    private var zoomLabel: String {
        guard model.metadata != nil else { return "—" }
        let percent = Int(
            (currentFit * zoom * displayScale * 100).rounded()
        )
        // A downsampled decode shows preview pixels, not source pixels.
        // Comparison measures source pixels, so the label must say which
        // basis it is using.
        return model.isDownsampled
            ? "Preview \(percent)%"
            : "\(percent)%"
    }
}
