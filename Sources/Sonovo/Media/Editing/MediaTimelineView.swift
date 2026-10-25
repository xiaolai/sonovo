import SwiftUI

/// One audio-led timeline for audio and video edit sessions. The waveform is
/// the ruler; zoom and scroll are explicit controls so a trackpad gesture
/// cannot steal the selection drag.
struct MediaTimelineView: View {
    let data: WaveformData?
    let sourceDuration: Double
    let removedRanges: [MediaTimeRange]
    let selection: MediaTimeRange?
    let playhead: Double
    let viewport: MediaTimelineViewport
    var silenceCandidates: [MediaTimeRange] = []
    var compact = false
    var isInteractionEnabled = true
    var thumbnailURL: URL?
    var thumbnailRevision: AssetRevision?
    var showsThumbnails = false
    var thumbnailsEnabled = true
    let onSeek: (Double) -> Void
    let onSelect: (Double, Double) -> Void
    let onNudge: (MediaSelectionEdge, Double) -> Void
    let onViewportChange: (MediaTimelineViewport) -> Void
    let onInteractionChange: (Bool) -> Void

    private var maxStart: Double {
        max(sourceDuration - viewport.duration, 0)
    }

    private var canZoomIn: Bool {
        sourceDuration > 0
            && viewport.duration
                > MediaEditLimits.minimumTimelineVisibleDuration
    }

    private var canZoomOut: Bool {
        sourceDuration > 0 && viewport.duration < sourceDuration
    }

    private var isFullView: Bool {
        viewport.start <= MediaEditLimits.minimumRangeDuration
            && viewport.duration
                >= sourceDuration - MediaEditLimits.minimumRangeDuration
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            zoomRow
            if showsThumbnails,
               let thumbnailURL,
               let thumbnailRevision {
                MediaTimelineThumbnailStrip(
                    url: thumbnailURL,
                    revision: thumbnailRevision,
                    sourceDuration: sourceDuration,
                    viewport: viewport,
                    isEnabled: thumbnailsEnabled
                )
                .frame(height: AppTheme.Size.mediaTimelineThumbnailHeight)
            }
            MediaSelectionWaveformView(
                data: data,
                sourceDuration: sourceDuration,
                removedRanges: removedRanges,
                selection: selection,
                playhead: playhead,
                viewport: viewport,
                silenceCandidates: silenceCandidates,
                compact: compact,
                isInteractionEnabled: isInteractionEnabled,
                onSeek: onSeek,
                onSelect: onSelect,
                onNudge: onNudge,
                onInteractionChange: onInteractionChange
            )
            .frame(
                height: compact
                    ? AppTheme.Size.mediaTimelineCompactHeight
                    : AppTheme.Size.waveformHeight
            )
            if maxStart > 0 {
                Slider(
                    value: Binding(
                        get: { viewport.start },
                        set: { value in
                            onViewportChange(
                                MediaTimelineViewport(
                                    start: value,
                                    duration: viewport.duration
                                ).clamped(to: sourceDuration)
                            )
                        }
                    ),
                    in: 0...maxStart,
                    onEditingChanged: onInteractionChange
                )
                .controlSize(.small)
                .help("Scroll Timeline")
                .accessibilityLabel("Timeline scroll")
            }
        }
    }

    private var zoomRow: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Spacer()
            BarIconButton(
                systemName: "minus.magnifyingglass",
                help: "Zoom Out"
            ) {
                zoom(by: AppTheme.MediaTimeline.zoomOutFactor)
            }
            .disabled(!isInteractionEnabled || !canZoomOut)
            BarIconButton(
                systemName: "arrow.up.left.and.down.right.magnifyingglass",
                help: "Fit Timeline"
            ) {
                onViewportChange(.full(sourceDuration: sourceDuration))
            }
            .disabled(!isInteractionEnabled || isFullView)
            BarIconButton(
                systemName: "plus.magnifyingglass",
                help: "Zoom In"
            ) {
                zoom(by: AppTheme.MediaTimeline.zoomInFactor)
            }
            .disabled(!isInteractionEnabled || !canZoomIn)
        }
    }

    private func zoom(by factor: Double) {
        guard sourceDuration > 0 else { return }
        let anchor = viewport.fraction(forTime: playhead)
        onViewportChange(
            viewport.zoomed(
                by: factor,
                anchorFraction: anchor,
                sourceDuration: sourceDuration
            )
        )
    }
}
