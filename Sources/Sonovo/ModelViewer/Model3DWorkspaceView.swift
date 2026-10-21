import AppKit
import SwiftUI

/// The model viewer page: one read-only document card, a WebKit viewport, and
/// native controls that never depend on the page rendering its own chrome.
struct Model3DWorkspaceView: View {
    @Bindable var state: AppState

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("sonovo.model3D.grid") private var grid = true
    @AppStorage("sonovo.model3D.wireframe") private var wireframe = false

    @State private var showLog = false

    private var workspace: Model3DWorkspace { state.models }

    var body: some View {
        Group {
            if let document = workspace.selectedDocument {
                page(document)
                    .id(document.id)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appCanvas)
    }

    // MARK: - Page

    private func page(_ document: Model3DDocument) -> some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header(document)

            if let error = workspace.lastError {
                banner(
                    text: error,
                    systemImage: "exclamationmark.triangle",
                    tint: AppTheme.Palette.needsReview,
                    dismiss: workspace.dismissError
                )
            }

            if document.hasExternalChange {
                externalChangeBanner(document)
            }

            if let warning = document.warning {
                banner(
                    text: warning,
                    systemImage: "exclamationmark.circle",
                    tint: AppTheme.Palette.needsReview,
                    dismiss: document.dismissWarning
                )
            }

            stage(document)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
            .fill(Color.appText)
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
            .strokeBorder(
                Color.appSeparator,
                lineWidth: AppTheme.BorderWidth.hairline
            )
        )
        .padding(AppTheme.Spacing.lg)
        .sheet(isPresented: $showLog) {
            logSheet(document)
        }
    }

    private func header(_ document: Model3DDocument) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            documentMenu(document)

            Text(document.format.displayName)
                .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                .foregroundStyle(.secondary)

            Text("·")
                .foregroundStyle(.tertiary)

            if let stats = document.stats, document.state.isReady {
                Text("\(stats.triangles.formatted()) triangles")
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(.tertiary)
            } else {
                Text(stateLabel(document))
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(.tertiary)
            }

            Text("·")
                .foregroundStyle(.tertiary)

            Text(document.fileSizeLabel)
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.tertiary)

            if document.isConverted {
                Text("Converted from \(document.displayName)")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if document.sceneNames.count > 1 {
                sceneMenu(document)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            BarIconButton(
                systemName: "arrow.clockwise",
                help: "Reload"
            ) {
                workspace.reload(document)
            }
            .disabled(document.state.isConverting)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Layout.subtitleHeaderHeight)
    }

    private func stateLabel(_ document: Model3DDocument) -> String {
        switch document.state {
        case .needsConversion: "Needs conversion"
        case .converting: "Converting…"
        case .conversionFailed: "Conversion failed"
        case .loading: "Loading…"
        case .ready: "Ready"
        case .failed: "Could not load"
        }
    }

    private func documentMenu(_ document: Model3DDocument) -> some View {
        Menu {
            if workspace.documents.count > 1 {
                Section("Open Models") {
                    ForEach(workspace.documents) { candidate in
                        Button {
                            workspace.select(candidate)
                        } label: {
                            Text(candidate.displayName)
                        }
                    }
                }
                Divider()
            }
            Button("Open Model…") { workspace.presentOpenPanel() }
            Button("Reload") { workspace.reload(document) }
                .disabled(document.state.isConverting)
            if document.format.canConvertWithBlender {
                Button("Convert with Blender…") {
                    workspace.convert(document)
                }
                .disabled(
                    workspace.blenderInstallation == nil
                        || document.state.isConverting
                )
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [document.sourceURL]
                )
            }
            Divider()
            Button("Close Model") {
                Task { await workspace.close(document) }
            }
        } label: {
            Image(systemName: "cube.transparent")
                .font(.system(size: AppTheme.TypeScale.sm, weight: .medium))
                .frame(
                    width: AppTheme.ControlSize.medium,
                    height: AppTheme.ControlSize.regular
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Models")
        .accessibilityLabel("Models")
    }

    private func sceneMenu(_ document: Model3DDocument) -> some View {
        Menu {
            ForEach(Array(document.sceneNames.enumerated()), id: \.offset) {
                index, name in
                Button {
                    document.selectScene(index)
                } label: {
                    if index == document.selectedScene {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: AppTheme.TypeScale.xxs))
                Text(currentSceneName(document))
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.TypeScale.micro))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Scene")
        .accessibilityLabel("Scene")
    }

    private func currentSceneName(_ document: Model3DDocument) -> String {
        guard document.sceneNames.indices.contains(document.selectedScene) else {
            return "Scene"
        }
        return document.sceneNames[document.selectedScene]
    }

    // MARK: - Stage

    @ViewBuilder
    private func stage(_ document: Model3DDocument) -> some View {
        switch document.state {
        case .needsConversion, .converting, .conversionFailed:
            conversionCard(document)
        case .loading, .ready, .failed:
            viewport(document)
        }
    }

    private func viewport(_ document: Model3DDocument) -> some View {
        ZStack {
            if document.renderableURL != nil {
                ModelWebView(
                    document: document,
                    theme: colorScheme,
                    grid: grid,
                    wireframe: wireframe,
                    upAxis: document.upAxis,
                    playing: document.isAnimationPlaying,
                    clip: document.selectedClip,
                    scene: document.selectedScene,
                    fitRequest: document.fitRequest
                )
                .id("\(document.id)-\(document.loadGeneration)")
            } else {
                AppTheme.Palette.black
            }

            viewportOverlay(document)
        }
        // The stage fills the card edge to edge. Insetting and separately
        // clipping the web view stacked a second container inside the card,
        // which exposed its backdrop as a gray band below the header.
    }

    @ViewBuilder
    private func viewportOverlay(_ document: Model3DDocument) -> some View {
        ZStack {
            if document.state.isLoading {
                loadingOverlay(document)
            }

            if case .failed(let message) = document.state {
                errorOverlay(message, document: document)
            }

            VStack {
                Spacer()
                HStack(alignment: .bottom, spacing: AppTheme.Spacing.sm) {
                    if !document.animations.isEmpty,
                       document.state.isReady {
                        animationBar(document)
                    }
                    Spacer(minLength: AppTheme.Spacing.sm)
                    viewBar(document)
                }
            }
            .padding(AppTheme.Spacing.md)
        }
        .environment(\.colorScheme, .dark)
    }

    private func loadingOverlay(_ document: Model3DDocument) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
                .tint(AppTheme.Palette.white)
            Text("Loading \(document.displayName)…")
                .font(.system(size: AppTheme.TypeScale.xs, weight: .medium))
                .foregroundStyle(
                    AppTheme.Palette.white.opacity(AppTheme.Opacity.near)
                )
            if case .loading(let progress) = document.state,
               let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(AppTheme.Palette.white)
                    .frame(width: AppTheme.Model3D.conversionCardMaxWidth)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.panel,
                style: .continuous
            )
            .fill(AppTheme.Palette.black.opacity(AppTheme.Opacity.heavySoft))
        )
    }

    private func errorOverlay(
        _ message: String,
        document: Model3DDocument
    ) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: AppTheme.IconSize.render, weight: .light))
                .foregroundStyle(AppTheme.Palette.needsReview)
            Text("Could not display this model")
                .font(.system(size: AppTheme.TypeScale.md, weight: .semibold))
                .foregroundStyle(AppTheme.Palette.white)
            Text(message)
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(
                    AppTheme.Palette.white.opacity(AppTheme.Opacity.heavySoft)
                )
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: AppTheme.Model3D.conversionCardMaxWidth)
            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Reload") { workspace.reload(document) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [document.sourceURL]
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if document.format.canConvertWithBlender,
                   workspace.blenderInstallation != nil {
                    Button("Convert with Blender…") {
                        workspace.convert(document)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .background(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.panel,
                style: .continuous
            )
            .fill(AppTheme.Palette.black.opacity(AppTheme.Opacity.heavySoft))
        )
    }

    private func viewBar(_ document: Model3DDocument) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            ViewportIconButton(
                systemName: "arrow.up.left.and.arrow.down.right",
                help: "Fit model"
            ) {
                document.requestFit()
            }
            ViewportIconButton(
                systemName: "square.grid.3x3",
                help: grid ? "Hide grid" : "Show grid",
                isSelected: grid
            ) {
                grid.toggle()
            }
            ViewportIconButton(
                systemName: "triangle",
                help: wireframe ? "Hide wireframe" : "Show wireframe",
                isSelected: wireframe
            ) {
                wireframe.toggle()
            }
            ViewportIconButton(
                systemName: "arrow.up.and.down",
                help: "Up axis: \(document.upAxis.label)",
                isSelected: false,
                label: document.upAxis.shortLabel
            ) {
                document.setUpAxis(
                    document.upAxis == .y ? .z : .y
                )
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xxs)
        .padding(.vertical, AppTheme.Spacing.xxs)
        .background(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.panel,
                style: .continuous
            )
            .fill(AppTheme.Palette.black.opacity(AppTheme.Opacity.heavySoft))
        )
    }

    private func animationBar(_ document: Model3DDocument) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ViewportIconButton(
                systemName: document.isAnimationPlaying
                    ? "pause.fill"
                    : "play.fill",
                help: document.isAnimationPlaying
                    ? "Pause animation"
                    : "Play animation"
            ) {
                document.isAnimationPlaying.toggle()
            }

            Menu {
                ForEach(document.animations) { animation in
                    Button {
                        document.selectClip(animation.index)
                        document.isAnimationPlaying = true
                    } label: {
                        if animation.index == document.selectedClip {
                            Label(
                                "\(animation.name) · \(animation.durationLabel)",
                                systemImage: "checkmark"
                            )
                        } else {
                            Text("\(animation.name) · \(animation.durationLabel)")
                        }
                    }
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(currentClipName(document))
                        .font(.system(size: AppTheme.TypeScale.xs))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: AppTheme.TypeScale.micro))
                }
                .foregroundStyle(
                    AppTheme.Palette.white.opacity(AppTheme.Opacity.near)
                )
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Animation")
        }
        .padding(.horizontal, AppTheme.Spacing.xs)
        .padding(.vertical, AppTheme.Spacing.xxs)
        .background(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.panel,
                style: .continuous
            )
            .fill(AppTheme.Palette.black.opacity(AppTheme.Opacity.heavySoft))
        )
    }

    private func currentClipName(_ document: Model3DDocument) -> String {
        document.animations.first {
            $0.index == document.selectedClip
        }?.name ?? "Animation"
    }

    // MARK: - Conversion

    private func conversionCard(_ document: Model3DDocument) -> some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "cube.transparent")
                .font(
                    .system(
                        size: AppTheme.IconSize.render,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(.tertiary)

            Text(document.displayName)
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
                .lineLimit(1)

            Text(conversionExplanation(document))
            .font(.system(size: AppTheme.TypeScale.sm))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: AppTheme.Model3D.conversionCardMaxWidth)

            blenderStatus

            conversionStateActions(document)

            Text(
                "Shape keys are preserved when present; modifiers are applied "
                    + "only when no shape keys exist. All scenes are exported, "
                    + "and procedural node materials may look different."
            )
            .font(.system(size: AppTheme.TypeScale.xxs))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: AppTheme.Model3D.conversionCardMaxWidth)
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appText)
    }

    @ViewBuilder
    private func conversionStateActions(_ document: Model3DDocument) -> some View {
        switch document.state {
        case .converting:
            HStack(spacing: AppTheme.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Converting with Blender…")
                    .font(.system(size: AppTheme.TypeScale.sm))
                Button("Cancel") {
                    workspace.cancelConversion(document)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .conversionFailed(let message):
            VStack(spacing: AppTheme.Spacing.xs) {
                Text(message)
                    .font(.system(size: AppTheme.TypeScale.sm))
                    .foregroundStyle(AppTheme.Palette.needsReview)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                HStack(spacing: AppTheme.Spacing.sm) {
                    Button("Convert Again") {
                        workspace.convert(document)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(
                        workspace.blenderInstallation == nil
                            || document.state.isConverting
                    )
                    if !document.conversionLog.isEmpty {
                        Button("Show Log") { showLog = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        case .needsConversion:
            Button("Convert with Blender…") {
                workspace.convert(document)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                workspace.blenderInstallation == nil
                    || document.state.isConverting
            )
        case .loading, .ready, .failed:
            EmptyView()
        }
    }

    private func conversionExplanation(
        _ document: Model3DDocument
    ) -> String {
        if document.format.isUSD {
            return "The built-in USD loader could not display this file. "
                + "Blender can import it and export a temporary GLB; the "
                + "original USD file is never modified."
        }
        return "Blender files are converted to glTF in a temporary folder "
            + "before they can be displayed. The .blend file is never "
            + "modified."
    }

    @ViewBuilder
    private var blenderStatus: some View {
        if let installation = workspace.blenderInstallation {
            Label(
                installation.executableURL.path,
                systemImage: "checkmark.circle"
            )
            .font(.system(size: AppTheme.TypeScale.xs))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: AppTheme.Model3D.conversionCardMaxWidth)
        } else {
            Label(
                "Blender not found. Install Blender or set SONOVO_BLENDER_PATH.",
                systemImage: "questionmark.circle"
            )
            .font(.system(size: AppTheme.TypeScale.xs))
            .foregroundStyle(AppTheme.Palette.needsReview)
            .multilineTextAlignment(.center)
            .frame(maxWidth: AppTheme.Model3D.conversionCardMaxWidth)
        }
    }

    private func logSheet(_ document: Model3DDocument) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("Blender Log")
                    .font(.system(size: AppTheme.TypeScale.md, weight: .semibold))
                Spacer()
                Button("Close") { showLog = false }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(
                    document.conversionLog.isEmpty
                        ? "No output was captured."
                        : document.conversionLog
                )
                .font(
                    .system(
                        size: AppTheme.TypeScale.xs,
                        design: .monospaced
                    )
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppTheme.Spacing.sm)
            }
            .frame(
                width: AppTheme.Model3D.logSheetWidth,
                height: AppTheme.Model3D.logSheetHeight
            )
            .background(
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.control,
                    style: .continuous
                )
                .fill(Color.appCard)
            )
        }
        .padding(AppTheme.Spacing.lg)
    }

    // MARK: - Banners and empty state

    private func externalChangeBanner(_ document: Model3DDocument) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(AppTheme.Palette.generating)
            Text("This file changed on disk.")
                .font(.system(size: AppTheme.TypeScale.xs))
                .lineLimit(2)
            Spacer(minLength: AppTheme.Spacing.sm)
            if document.format.isConvertible || document.isConverted {
                Button("Convert Again") {
                    workspace.convert(document)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(
                    workspace.blenderInstallation == nil
                        || document.state.isConverting
                )
            } else {
                Button("Reload") {
                    workspace.reload(document)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Palette.generating.opacity(AppTheme.Opacity.ghostSoft))
    }

    private func banner(
        text: String,
        systemImage: String,
        tint: Color,
        dismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: AppTheme.TypeScale.xs))
                .lineLimit(2)
            Spacer(minLength: AppTheme.Spacing.sm)
            if let dismiss {
                BarIconButton(systemName: "xmark", help: "Dismiss") {
                    dismiss()
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(tint.opacity(AppTheme.Opacity.ghostSoft))
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "cube.transparent")
                .font(
                    .system(
                        size: AppTheme.IconSize.render,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(.tertiary)

            Text("No 3D Model Open")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))

            Text(
                "Open a GLB, glTF, STL, 3MF, OBJ, PLY, FBX, DAE, or USD file to "
                    + "inspect it locally. Blender files convert to glTF with "
                    + "one explicit step."
            )
            .font(.system(size: AppTheme.TypeScale.sm))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)

            Button("Open Model…") {
                workspace.presentOpenPanel()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let error = workspace.lastError {
                Text(error)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(AppTheme.Palette.needsReview)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)
            }

            Text("Local files only · No network")
                .font(.system(size: AppTheme.TypeScale.xxs))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
            .fill(Color.appCard)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.surface,
                style: .continuous
            )
            .strokeBorder(
                Color.appSeparator,
                lineWidth: AppTheme.BorderWidth.hairline
            )
        )
        .padding(AppTheme.Spacing.lg)
    }
}

private struct ViewportIconButton: View {
    let systemName: String
    let help: String
    var isSelected = false
    var label: String?
    let action: () -> Void

    init(
        systemName: String,
        help: String,
        isSelected: Bool = false,
        label: String? = nil,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.help = help
        self.isSelected = isSelected
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let label {
                    Text(label)
                } else {
                    Image(systemName: systemName)
                }
            }
            .font(.system(size: AppTheme.TypeScale.xs, weight: .semibold))
            .foregroundStyle(
                AppTheme.Palette.white.opacity(
                    isSelected ? AppTheme.Opacity.near : AppTheme.Opacity.heavySoft
                )
            )
            .frame(
                width: AppTheme.ControlSize.medium,
                height: AppTheme.ControlSize.regular
            )
            .background(
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.micro,
                    style: .continuous
                )
                .fill(
                    isSelected
                        ? AppTheme.Palette.white.opacity(AppTheme.Opacity.ghostSoft)
                        : Color.clear
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
