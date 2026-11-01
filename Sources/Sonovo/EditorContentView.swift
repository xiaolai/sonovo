import SonovoWorkspaceHost
import SonovoFeatureAPI
import SonovoDomainTypes
import SonovoDesignSystem
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
            mediaContent(for: tab)
        case .video:
            mediaContent(for: tab)
        case .stills:
            StillsView(state: state, project: project)
        case .subtitle:
            featureContent(provider: "builtin.subtitle.editor", asset: project.selectedAsset)
        case .model3d:
            featureContent(provider: "builtin.model.editor", asset: project.selectedAsset)
        case .html:
            HTMLPreviewView()
        case .delivery:
            DeliveryView(state: state, project: project)
        case .code, .mdx:
            EmptyEditorView()
        case .timeline:
            featureContent(provider: "builtin.timeline.editor", asset: project.selectedAsset)
        case .document, .image, .archive, .other:
            EmptyEditorView()
        }
    }

    private func projectContent(for tab: EditorTab) -> some View {
        RegisteredProjectEditor(project: project, isVisible: project.isActive && state.terminalPresentation != .full,
            terminalReferences: terminalReferenceService, mediaReplaceRequests: state)
    }

    @ViewBuilder private func featureContent(provider: EditorProviderID, asset: ProjectAsset?) -> some View {
        if let contribution = project.featureEditors.contribution(for: provider) {
            contribution.makeView(EditorRequest(project: project, asset: asset,
                isVisible: project.isActive && state.terminalPresentation != .full,
                terminalReferences: terminalReferenceService, mediaReplaceRequests: state))
        } else {
            Text("Editor unavailable for this file.")
                .font(.system(size: AppTheme.TypeScale.sm))
                .foregroundStyle(.secondary)
        }
    }

    private var terminalReferenceService: TerminalReferenceService {
        TerminalReferenceService(recipientTitle: { project.terminalSessions.selectedSession?.title },
            delivery: { state.codeReferenceDelivery(for: project) })
    }

    @ViewBuilder
    private func mediaContent(for tab: EditorTab) -> some View {
        switch state.editorMode {
        case .player:
            if tab.kind == .audio {
                AudioPlayerView(state: state, project: project)
            } else {
                VideoPlayerView(state: state, project: project)
            }
        case .compare:
            if tab.kind == .audio {
                AudioPlayerView(state: state, project: project)
            } else {
                VideoCompareView(state: state, project: project)
            }
        case .transcript:
            if tab.kind == .audio {
                AudioPlayerView(state: state, project: project)
            } else {
                TranscriptView(state: state, project: project)
            }
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
