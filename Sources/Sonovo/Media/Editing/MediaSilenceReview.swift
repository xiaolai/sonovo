import SwiftUI

/// Small, explicit pause review. Candidate ranges are drawn on the timeline
/// underneath while this popover is open; removing them is one undo entry.
struct MediaSilenceReview: View {
    let data: WaveformData?
    let sourceDuration: Double
    let keepRanges: [MediaTimeRange]
    @Binding var settings: MediaSilenceSettings
    let onCandidates: ([MediaTimeRange]) -> Void
    let onRemove: ([MediaTimeRange]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [MediaTimeRange] = []
    @State private var isRunning = false
    @State private var failure: String?

    private var candidateDuration: Double {
        candidates.reduce(0) { $0 + $1.duration }
    }

    private var retainedDuration: Double {
        keepRanges.reduce(0) { $0 + $1.duration } - candidateDuration
    }

    private var canRemove: Bool {
        !candidates.isEmpty
            && !isRunning
            && retainedDuration >= MediaEditLimits.minimumRetainedDuration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Remove Pauses")
                .font(.system(size: AppTheme.TypeScale.body, weight: .semibold))

            Text(
                "Finds low-energy gaps in the kept audio. Review the highlighted ranges before removing them."
            )
            .font(.system(size: AppTheme.TypeScale.xs))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Threshold \(Int(settings.thresholdDBFS)) dBFS")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
                Slider(
                    value: $settings.thresholdDBFS,
                    in: settings.thresholdRange
                )
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(
                    "Minimum pause \(String(format: "%.2f", settings.minimumPause)) s"
                )
                .font(.system(size: AppTheme.TypeScale.xs))
                .foregroundStyle(.secondary)
                Slider(
                    value: $settings.minimumPause,
                    in: settings.minimumPauseRange
                )
                .controlSize(.small)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(summary)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.secondary)
            }

            if let failure {
                Text(failure)
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(AppTheme.Palette.warning)
            } else if !candidates.isEmpty,
                      retainedDuration < MediaEditLimits.minimumRetainedDuration {
                Text("These pauses would leave too little material.")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(AppTheme.Palette.warning)
            } else if candidates.isEmpty, !isRunning {
                Text("No pauses found. Lower the threshold or shorten the minimum pause.")
                    .font(.system(size: AppTheme.TypeScale.xs))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(candidates.isEmpty ? "Remove" : "Remove \(candidates.count)") {
                    onRemove(candidates)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canRemove)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Size.mediaSilencePopoverWidth)
        .task(id: settings) {
            await detect()
        }
    }

    private var summary: String {
        guard !candidates.isEmpty else {
            return isRunning ? "Analyzing…" : "0 pauses"
        }
        let noun = candidates.count == 1 ? "pause" : "pauses"
        return "\(candidates.count) \(noun) · \(MediaTimecodeFormatter.elapsed(candidateDuration))"
    }

    private func detect() async {
        guard let data, sourceDuration.isFinite, sourceDuration > 0 else {
            candidates = []
            onCandidates([])
            failure = "No audio waveform is available."
            return
        }
        isRunning = true
        failure = nil
        let settings = settings
        let ranges = keepRanges
        let result = await Task.detached(priority: .userInitiated) {
            MediaSilenceDetector.detect(
                data: data,
                settings: settings,
                sourceDuration: sourceDuration,
                keepRanges: ranges
            )
        }.value
        guard !Task.isCancelled else { return }
        candidates = result
        onCandidates(result)
        isRunning = false
    }
}
