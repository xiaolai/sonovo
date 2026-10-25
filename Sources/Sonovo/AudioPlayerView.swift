import SwiftUI

/// The Sample project's audio tab uses the same real media surface as a
/// folder project. The sample takes ship as WAV files and are copied into
/// Application Support on first use; there is no synthetic player or
/// transcript/compare mock behind this tab.
struct AudioPlayerView: View {
    let state: AppState
    let project: Project

    var body: some View {
        if let id = state.selectedAsset?.id,
           let asset = project.sampleAudioAsset(for: id) {
            MediaAssetView(asset: asset)
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
}
