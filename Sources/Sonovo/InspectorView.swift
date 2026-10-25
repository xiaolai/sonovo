import SonovoCore
import SwiftUI

enum InspectorPlacement: Equatable {
    case right
    case bottom
    case hidden
}

struct InspectorView: View {
    @Bindable var state: AppState
    var placement: InspectorPlacement = .right

    var body: some View {
        Group {
            if placement == .bottom {
                bottomBody
            } else {
                rightBody
            }
        }
    }

    private var rightBody: some View {
        infoContent
            .background(Color.appText)
    }

    private var bottomBody: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            bottomHeader
            bottomContent
                .padding(.top, AppTheme.Spacing.sm)
        }
        .background(Color.appText)
    }

    private var bottomHeader: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if !state.liveProject.isDemo {
                if let asset = state.liveProject.selectedAsset {
                    Text(asset.name)
                        .font(
                            .system(
                                size: AppTheme.TypeScale.sm,
                                weight: .semibold
                            )
                        )
                        .lineLimit(1)
                    Text(asset.kind.projectGroup.title)
                        .font(.system(size: AppTheme.TypeScale.xs))
                        .foregroundStyle(.secondary)
                }
            } else if let asset = state.selectedAsset {
                Text(state.displayName(for: asset))
                    .font(
                        .system(
                            size: AppTheme.TypeScale.sm,
                            weight: .semibold
                        )
                    )
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Size.bottomHeaderHeight)
    }

    @ViewBuilder
    private var bottomContent: some View {
        if !state.liveProject.isDemo {
            if let asset = state.liveProject.selectedAsset {
                // The bottom panel is short; the project metadata card
                // must scroll rather than clip its lower rows.
                ScrollView {
                    projectInfo(for: asset)
                }
            } else {
                noSelection
            }
        } else if let asset = state.selectedAsset {
            bottomInfo(asset)
        } else {
            noSelection
        }
    }

    private func bottomInfo(_ asset: ProductionAsset) -> some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.xl) {
                bottomInfoColumn(
                    "File",
                    rows: metadataRows(for: asset)
                )
                bottomInfoColumn(
                    "Provenance",
                    rows: provenanceRows(for: asset)
                )
            }
            .padding(AppTheme.Spacing.md)
        }
    }

    private func bottomInfoColumn(_ title: String, rows: [MetadataItem]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s6) {
            Text(title.uppercased())
                .font(.system(size: AppTheme.TypeScale.xxs, weight: .semibold))
                .tracking(AppTheme.Tracking.normal)
                .foregroundStyle(.tertiary)

            ForEach(rows) { item in
                MetadataRow(label: item.label, value: item.value)
            }
        }
        .frame(minWidth: AppTheme.Size.bottomInfoColumnMinWidth, alignment: .leading)
    }

    private var infoContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.s18) {
                if !state.liveProject.isDemo {
                    if let asset = state.liveProject.selectedAsset {
                        projectInfo(for: asset)
                    } else {
                        noSelection
                    }
                } else if let asset = state.selectedAsset {
                    demoInfo(for: asset)
                } else {
                    noSelection
                }
            }
            .padding(AppTheme.Spacing.lg)
        }
    }

    @ViewBuilder
    private func demoInfo(for asset: ProductionAsset) -> some View {
        assetHeader(asset)

        InspectorSection("File") {
            ForEach(metadataRows(for: asset)) { item in
                MetadataRow(label: item.label, value: item.value)
            }
        }

        InspectorSection("Provenance") {
            ForEach(provenanceRows(for: asset)) { item in
                MetadataRow(label: item.label, value: item.value)
            }
        }
    }

    @ViewBuilder
    private func projectInfo(for asset: ProjectAsset) -> some View {
        projectAssetHeader(asset)

        InspectorSection("File") {
            MetadataRow(
                label: "Kind",
                value: asset.kind.projectGroup.title
            )
            MetadataRow(
                label: "Format",
                value: asset.fileExtension.uppercased()
            )
            MetadataRow(
                label: "Size",
                value: ByteCountFormatter.string(
                    fromByteCount: asset.size,
                    countStyle: .file
                )
            )
            MetadataRow(
                label: "Modified",
                value: asset.modified?.formatted(
                    date: .abbreviated,
                    time: .shortened
                ) ?? "—"
            )
            MetadataRow(label: "Path", value: asset.relativePath)
        }

        if asset.kind == .code,
           let document = state.code.selectedDocument,
           MarkdownSecurity.canonical(document.fileURL)
            == MarkdownSecurity.canonical(asset.url) {
            InspectorSection("Code") {
                MetadataRow(
                    label: "Language",
                    value: document.language.displayName
                )
                if document.isReady {
                    MetadataRow(
                        label: "Lines",
                        value: "\(document.source.components(separatedBy: "\n").count)"
                    )
                    MetadataRow(
                        label: "Encoding",
                        value: document.hasBOM ? "UTF-8 BOM" : "UTF-8"
                    )
                    MetadataRow(
                        label: "Line endings",
                        value: document.lineEnding == .crlf ? "CRLF" : "LF"
                    )
                }
                MetadataRow(
                    label: "State",
                    value: codeStateLabel(document)
                )
            }
        }
    }

    private func codeStateLabel(_ document: CodeDocument) -> String {
        if let refusal = document.refusal {
            return refusal.explanation
        }
        if !document.isReady {
            return "Loading"
        }
        if let reason = document.readOnlyReason {
            return reason.explanation
        }
        if document.isDirty {
            return "Unsaved changes"
        }
        if document.pendingReview {
            return "Changed on disk"
        }
        return "Ready"
    }

    private var noSelection: some View {
        ContentUnavailableView(
            "No Selection",
            systemImage: "sidebar.right",
            description: Text("Select an asset to inspect it.")
        )
        .padding(.top, AppTheme.Spacing.s40)
    }

    private func projectAssetHeader(_ asset: ProjectAsset) -> some View {
        inspectorHeader(
            icon: asset.kind.icon,
            title: asset.name,
            subtitle: asset.kind.projectGroup.title
        )
    }

    private func assetHeader(_ asset: ProductionAsset) -> some View {
        inspectorHeader(
            icon: asset.kind.icon,
            title: state.displayName(for: asset),
            subtitle: asset.shortDetail,
            subtitleLineLimit: 1
        )
    }

    private func inspectorHeader(
        icon: String,
        title: String,
        subtitle: String,
        subtitleLineLimit: Int? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: AppTheme.Radius.panel,
                    style: .continuous
                )
                .fill(Color.accentColor.opacity(AppTheme.Opacity.tint))
                Image(systemName: icon)
                    .font(
                        .system(
                            size: AppTheme.TypeScale.title,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: AppTheme.Size.avatar, height: AppTheme.Size.avatar)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.s3) {
                Text(title)
                    .font(
                        .system(size: AppTheme.TypeScale.md, weight: .semibold)
                    )
                    .lineLimit(2)

                Text(subtitle)
                    .font(.system(size: AppTheme.TypeScale.xxs))
                    .foregroundStyle(.secondary)
                    .lineLimit(subtitleLineLimit)
            }

            Spacer(minLength: AppTheme.Spacing.zero)
        }
    }

    private func demoAudioMetadataRows(
        for asset: ProductionAsset
    ) -> [MetadataItem] {
        let sample = state.liveProject.sampleMediaAsset(for: asset.id)
        let size = sample.map {
            ByteCountFormatter.string(
                fromByteCount: $0.size,
                countStyle: .file
            )
        } ?? "—"
        guard let sample,
              let audio = MediaAudioMetadata.describe(url: sample.url) else {
            return [
                MetadataItem(label: "Kind", value: "WAV audio"),
                MetadataItem(label: "Size", value: size)
            ]
        }
        return [
            MetadataItem(label: "Kind", value: "WAV audio"),
            MetadataItem(label: "Duration", value: audio.durationText),
            MetadataItem(label: "Sample rate", value: audio.sampleRateText),
            MetadataItem(label: "Channels", value: audio.channelText),
            MetadataItem(
                label: "Bit depth",
                value: audio.bitDepth.map { "\($0)-bit" } ?? "—"
            ),
            MetadataItem(label: "Size", value: size)
        ]
    }

    private func metadataRows(for asset: ProductionAsset) -> [MetadataItem] {
        if asset.kind == .script,
           state.selectedTab?.kind == .script,
           state.selectedTab?.assetID == asset.id,
           let document = state.markdown.selectedDocument {
            return [
                MetadataItem(label: "Kind", value: "Markdown"),
                MetadataItem(
                    label: "Words",
                    value: state.markdownWordCount(document.source).formatted()
                ),
                MetadataItem(
                    label: "Encoding",
                    value: document.hasBOM ? "UTF-8 BOM" : "UTF-8"
                ),
                MetadataItem(
                    label: "Modified",
                    value: modifiedDescription(for: document)
                )
            ]
        }
        if asset.kind == .subtitle,
           state.selectedTab?.kind == .subtitle,
           state.selectedTab?.assetID == asset.id,
           let document = state.subtitles.selectedDocument {
            return [
                MetadataItem(label: "Kind", value: document.format.displayName),
                MetadataItem(label: "Cues", value: document.cueCount.formatted()),
                MetadataItem(
                    label: "Duration",
                    value: SubtitleTimecode.display(document.durationMilliseconds)
                ),
                MetadataItem(
                    label: "Words",
                    value: state.markdownWordCount(document.plainText).formatted()
                ),
                MetadataItem(label: "Encoding", value: document.encoding.displayName),
                MetadataItem(
                    label: "Modified",
                    value: modifiedDescription(
                        isDirty: document.isDirty,
                        url: document.fileURL
                    )
                )
            ]
        }
        return switch asset.kind {
        case .audio: demoAudioMetadataRows(for: asset)
        case .video:
            [
                MetadataItem(label: "Kind", value: "H.264 video"),
                MetadataItem(label: "Resolution", value: "1920 × 1080"),
                MetadataItem(label: "Frame rate", value: "24 fps"),
                MetadataItem(label: "Duration", value: "00:12.40"),
                MetadataItem(label: "Color", value: "Rec. 709"),
                MetadataItem(label: "Size", value: "18.6 MB")
            ]
        case .script, .subtitle:
            []
        case .model3d:
            modelMetadataRows()
        case .stills:
            [
                MetadataItem(label: "Kind", value: "PNG image"),
                MetadataItem(label: "Dimensions", value: "2048 × 1152"),
                MetadataItem(label: "Frames", value: "8"),
                MetadataItem(label: "Color", value: "Display P3")
            ]
        case .html:
            [
                MetadataItem(label: "Kind", value: "HTML document"),
                MetadataItem(label: "Scenes", value: "8"),
                MetadataItem(label: "Resources", value: "Inline"),
                MetadataItem(label: "Network", value: "Blocked")
            ]
        case .delivery:
            [
                MetadataItem(label: "Kind", value: "MP4 video"),
                MetadataItem(label: "Resolution", value: "1920 × 1080"),
                MetadataItem(label: "Codec", value: "H.264"),
                MetadataItem(label: "Status", value: "Not rendered")
            ]
        case .document, .image, .archive, .other, .code:
            []
        }
    }

    private func modifiedDescription(for document: MarkdownDocument) -> String {
        modifiedDescription(isDirty: document.isDirty, url: document.fileURL)
    }

    private func modifiedDescription(isDirty: Bool, url: URL?) -> String {
        if isDirty {
            return "Unsaved changes"
        }
        guard let url,
              let values = try? url.resourceValues(
                  forKeys: [.contentModificationDateKey]
              ),
              let date = values.contentModificationDate else {
            return "Not saved"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func provenanceRows(for asset: ProductionAsset) -> [MetadataItem] {
        switch asset.kind {
        case .audio:
            if let sample = state.liveProject.sampleMediaAsset(for: asset.id) {
                let source = asset.id.hasPrefix("recording-")
                    ? "Microphone or edit export"
                    : "Sample audio file"
                return [
                    MetadataItem(label: "Source", value: source),
                    MetadataItem(label: "Path", value: sample.url.path),
                    MetadataItem(
                        label: "Modified",
                        value: sample.modified?.formatted(
                            date: .abbreviated,
                            time: .shortened
                        ) ?? "—"
                    )
                ]
            }
            return [
                MetadataItem(label: "Generated by", value: "Voice Studio"),
                MetadataItem(label: "Model", value: "Sonovo Voice v3"),
                MetadataItem(label: "Voice", value: "Narrator · Calm"),
                MetadataItem(label: "Seed", value: "4821"),
                MetadataItem(label: "Created", value: "Today, 21:12")
            ]
        case .video:
            return [
                MetadataItem(label: "Generated by", value: "Video Studio"),
                MetadataItem(label: "Model", value: "Sonovo Motion v2"),
                MetadataItem(label: "Shot", value: "Harbor dawn"),
                MetadataItem(label: "Seed", value: "9314"),
                MetadataItem(label: "Created", value: "Today, 21:08")
            ]
        case .script:
            return [
                MetadataItem(label: "Drafted with", value: "Sonovo Writer"),
                MetadataItem(label: "Model", value: "Sonovo Text v2"),
                MetadataItem(label: "Prompt", value: "Coastal dawn, 12 seconds"),
                MetadataItem(label: "Created", value: "Today, 20:54")
            ]
        case .subtitle:
            return subtitleProvenanceRows()
        case .model3d:
            return modelProvenanceRows()
        case .stills:
            return [
                MetadataItem(label: "Generated by", value: "Image Studio"),
                MetadataItem(label: "Model", value: "Sonovo Image v4"),
                MetadataItem(label: "Prompt", value: "Harbor at dawn, fog, 35mm"),
                MetadataItem(label: "Seed", value: "2048"),
                MetadataItem(label: "Created", value: "Today, 21:02")
            ]
        case .html:
            return [
                MetadataItem(label: "Generated by", value: "Storyboard"),
                MetadataItem(label: "Model", value: "Sonovo Web v1"),
                MetadataItem(label: "Source", value: "8 scene cards"),
                MetadataItem(label: "Created", value: "Today, 21:15")
            ]
        case .delivery:
            return [
                MetadataItem(label: "Rendered by", value: "Sonovo Render"),
                MetadataItem(label: "Preset", value: "1080p · H.264"),
                MetadataItem(label: "Status", value: "Not rendered")
            ]
        case .document, .image, .archive, .other, .code:
            return []
        }
    }

    private func subtitleProvenanceRows() -> [MetadataItem] {
        guard state.selectedTab?.kind == .subtitle,
              let document = state.subtitles.selectedDocument else {
            return []
        }
        return [
            MetadataItem(label: "Path", value: document.fileURL.path),
            MetadataItem(
                label: "Media",
                value: state.subtitles.mediaURL(for: document)?
                    .lastPathComponent ?? "None"
            ),
            MetadataItem(
                label: "Line endings",
                value: document.lineEnding == .crlf ? "CRLF" : "LF"
            )
        ]
    }

    private func modelMetadataRows() -> [MetadataItem] {
        guard state.selectedTab?.kind == .model3d,
              let document = state.models.selectedDocument else {
            return []
        }
        var rows = [
            MetadataItem(label: "Format", value: document.format.displayName),
            MetadataItem(label: "Size", value: document.fileSizeLabel)
        ]
        if let stats = document.stats {
            rows.append(
                contentsOf: [
                    MetadataItem(
                        label: "Triangles",
                        value: stats.triangles.formatted()
                    ),
                    MetadataItem(
                        label: "Vertices",
                        value: stats.vertices.formatted()
                    ),
                    MetadataItem(
                        label: "Meshes",
                        value: stats.meshes.formatted()
                    ),
                    MetadataItem(
                        label: "Materials",
                        value: stats.materials.formatted()
                    ),
                    MetadataItem(
                        label: "Textures",
                        value: stats.textures.formatted()
                    ),
                    MetadataItem(
                        label: "Animations",
                        value: stats.animations.formatted()
                    )
                ]
            )
            if let bounds = stats.bounds {
                rows.append(
                    MetadataItem(
                        label: "Bounds",
                        value: bounds.displayString
                    )
                )
            }
        } else {
            rows.append(
                MetadataItem(label: "State", value: modelStateLabel(document))
            )
        }
        rows.append(
            MetadataItem(
                label: "Modified",
                value: modifiedDescription(
                    isDirty: false,
                    url: document.sourceURL
                )
            )
        )
        return rows
    }

    private func modelStateLabel(_ document: Model3DDocument) -> String {
        switch document.state {
        case .needsConversion: "Needs Blender conversion"
        case .converting: "Converting with Blender…"
        case .conversionFailed: "Conversion failed"
        case .loading: "Loading…"
        case .ready: "Ready"
        case .failed: "Could not load"
        }
    }

    private func modelProvenanceRows() -> [MetadataItem] {
        guard state.selectedTab?.kind == .model3d,
              let document = state.models.selectedDocument else {
            return []
        }
        var rows = [
            MetadataItem(label: "Path", value: document.sourceURL.path),
            MetadataItem(
                label: "Renderer",
                value: document.stats.map {
                    "three.js r\($0.rendererRevision)"
                } ?? "three.js"
            ),
            MetadataItem(label: "Network", value: "Blocked")
        ]
        if document.isConverted {
            let version = document.blenderVersion.map { " · Blender \($0)" } ?? ""
            rows.insert(
                MetadataItem(
                    label: "Converted",
                    value: "\(document.displayName)\(version)"
                ),
                at: 1
            )
        }
        return rows
    }
}
