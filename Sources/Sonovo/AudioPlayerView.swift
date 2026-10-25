import SwiftUI

/// The Sample project's audio tab uses the same real media surface as a
/// folder project. The sample takes ship as WAV files and are copied into
/// Application Support on first use; there is no synthetic player or
/// transcript/compare mock behind this tab.
struct AudioPlayerView: View {
    let state: AppState
    let project: Project
    @State private var mediaRefreshToken: UInt64 = 0

    var body: some View {
        Group {
            if let id = project.selectedAssetID,
               let asset = project.sampleMediaAsset(for: id) {
                MediaAssetView(
                    asset: asset,
                    project: project,
                    appState: state
                )
                .id("\(asset.id)-\(mediaRefreshToken)")
            } else {
                ContentUnavailableView(
                    "Audio Unavailable",
                    systemImage: "waveform.slash",
                    description: Text(
                        "The bundled sample audio file could not be prepared."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The Sample project has no folder scan. Recreate the media surface
        // after this project creates or replaces a file so it resolves the
        // current bytes and revision.
        .onChange(of: project.mediaGeneration) { _, _ in
            mediaRefreshToken &+= 1
        }
    }
}
