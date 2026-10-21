import SwiftUI

struct EditorContentView: View {
    let state: AppState
    let project: Project

    var body: some View {
        Group {
            if let tab = project.selectedTab {
                if project.isDemo {
                    demoContent(for: tab)
                } else {
                    projectContent(for: tab)
                }
            } else {
                EmptyEditorView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func demoContent(for tab: EditorTab) -> some View {
        switch tab.kind {
        case .script:
            ScriptView(project: project)
        case .audio:
            reviewContent(for: tab)
        case .video:
            reviewContent(for: tab)
        case .stills:
            StillsView(state: state, project: project)
        case .subtitle:
            SubtitleWorkspaceView(project: project)
        case .model3d:
            Model3DWorkspaceView(project: project)
        case .html:
            HTMLPreviewView(state: state)
        case .delivery:
            DeliveryView(state: state, project: project)
        case .document, .image, .archive, .other:
            EmptyEditorView()
        }
    }

    @ViewBuilder
    private func projectContent(for tab: EditorTab) -> some View {
        switch tab.kind {
        case .script:
            MarkdownWorkspaceView(workspace: project.markdown)
        case .subtitle:
            SubtitleWorkspaceView(project: project)
        case .model3d:
            Model3DWorkspaceView(project: project)
        case .audio, .video:
            if let asset = project.selectedAsset {
                MediaAssetView(asset: asset)
                    .id("\(asset.id)-\(asset.revision.token)")
            } else {
                ProjectNoFileView()
            }
        case .image, .document, .html:
            if let asset = project.selectedAsset {
                documentContent(for: asset)
            } else {
                ProjectNoFileView()
            }
        case .archive, .other:
            if let asset = project.selectedAsset {
                MetadataAssetView(asset: asset)
                    .id("\(asset.id)-\(asset.revision.token)")
            } else {
                ProjectNoFileView()
            }
        case .stills, .delivery:
            EmptyEditorView()
        }
    }

    @ViewBuilder
    private func documentContent(for asset: ProjectAsset) -> some View {
        switch ViewerRouter.route(for: asset) {
        case .image:
            // The comparison can show any other image, so every image
            // revision participates in this view's identity. Unrelated
            // assets do not, which keeps playback elsewhere undisturbed.
            ImageDocumentView(
                asset: asset,
                comparisonCandidates: project.assets.filter {
                    $0.id != asset.id
                        && ViewerRouter.route(for: $0) == .image
                }
            )
            .id(
                "\(asset.id)-\(asset.revision.token)-"
                    + comparisonToken(excluding: asset)
            )
        case .pdf:
            PDFDocumentView(asset: asset)
                .id("\(asset.id)-\(asset.revision.token)")
        case .localWeb:
            LocalDocumentView(asset: asset)
                .id("\(asset.id)-\(asset.revision.token)")
        case .quickLook:
            QuickLookDocumentView(asset: asset)
                .id("\(asset.id)-\(asset.revision.token)")
        case .metadata:
            MetadataAssetView(asset: asset)
                .id("\(asset.id)-\(asset.revision.token)")
        }
    }

    /// A compact identity for the comparison candidates' revisions. Hashing
    /// keeps the SwiftUI identity short without dropping any candidate.
    private func comparisonToken(excluding asset: ProjectAsset) -> String {
        var hasher = Hasher()
        for candidate in project.assets
        where candidate.id != asset.id
            && ViewerRouter.route(for: candidate) == .image {
            hasher.combine(candidate.id)
            hasher.combine(candidate.revision.token)
        }
        return String(hasher.finalize())
    }

    @ViewBuilder
    private func reviewContent(for tab: EditorTab) -> some View {
        switch state.editorMode {
        case .player:
            if tab.kind == .audio {
                AudioReviewView(state: state, project: project)
            } else {
                VideoReviewView(state: state, project: project)
            }
        case .compare:
            if tab.kind == .audio {
                AudioCompareView(state: state, project: project)
            } else {
                VideoCompareView(state: state, project: project)
            }
        case .transcript:
            TranscriptView(state: state, project: project)
        }
    }
}

struct EmptyEditorView: View {
    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: AppTheme.TypeScale.displayLarge, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("No Editor")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
            Text("Open an asset from the production navigator.")
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The editor content when a tab has no file to show.
struct ProjectNoFileView: View {
    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "doc")
                .font(.system(size: AppTheme.TypeScale.displayLarge, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("No File")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
