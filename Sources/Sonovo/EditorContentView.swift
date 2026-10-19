import SwiftUI

struct EditorContentView: View {
    let state: AppState

    var body: some View {
        Group {
            if let tab = state.selectedTab {
                switch tab.kind {
                case .script:
                    ScriptView(state: state)
                case .audio:
                    reviewContent(for: tab)
                case .video:
                    reviewContent(for: tab)
                case .stills:
                    StillsView(state: state)
                case .html:
                    HTMLPreviewView(state: state)
                case .delivery:
                    DeliveryView(state: state)
                }
            } else {
                EmptyEditorView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func reviewContent(for tab: EditorTab) -> some View {
        switch state.editorMode {
        case .player:
            if tab.kind == .audio {
                AudioReviewView(state: state)
            } else {
                VideoReviewView(state: state)
            }
        case .compare:
            if tab.kind == .audio {
                AudioCompareView(state: state)
            } else {
                VideoCompareView(state: state)
            }
        case .transcript:
            TranscriptView(state: state)
        }
    }
}

struct EmptyEditorView: View {
    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("No Editor")
                .font(.system(size: AppTheme.FontSize.lg, weight: .medium))
            Text("Open an asset from the production navigator.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appContent)
    }
}
