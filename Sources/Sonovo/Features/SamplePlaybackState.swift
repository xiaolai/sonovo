import Foundation
import Observation
import SwiftUI
import SonovoDesignSystem

@MainActor @Observable final class SamplePlaybackState {
    let production = Production.sample
    let transcript = SampleContent.transcript
    var storedEditorMode: EditorMode = .player
    var isPlaying = false
    var playhead: Double = 4.6 // token-exempt: demo playback state
    let duration: Double = 12.4 // token-exempt: demo playback state
    var volume: Double = 0.8 // token-exempt: demo playback state
    var isLooping = false
    var showCaptions = Preferences.captionsDefault {
        didSet {
            UserDefaults.standard.set(
                showCaptions,
                forKey: PreferenceKey.captionsDefault
            )
        }
    }
    var followPlayhead = Preferences.followPlayhead {
        didSet {
            UserDefaults.standard.set(
                followPlayhead,
                forKey: PreferenceKey.followPlayhead
            )
            if followPlayhead {
                selectedTranscriptID = currentTranscript?.id
            }
        }
    }

    var selectedTranscriptID: String? = "seg-2"
    var compareSplit: CGFloat = AppTheme.Layout.compareDefaultSplit
    var selectedStillIndex = 3
    var selectedShotIndex = 2

    var selectedTranscript: TranscriptSegment? {
        transcript.first { $0.id == selectedTranscriptID }
    }

    /// The segment under the playhead. Captions follow playback, skipping,
    /// and scrubbing; `selectedTranscriptID` remains the explicit transcript
    /// selection.
    var currentTranscript: TranscriptSegment? {
        if let active = transcript.first(where: {
            playhead >= $0.start && playhead < $0.end
        }) {
            return active
        }
        return transcript.last { $0.end <= playhead } ?? transcript.first
    }

}
