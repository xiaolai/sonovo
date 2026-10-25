import Foundation

/// User-adjustable pause detector settings. RMS thresholds are absolute
/// dBFS values; the UI exposes the threshold because a quiet room and a
/// noisy one cannot share one fixed number.
struct MediaSilenceSettings: Equatable, Sendable {
    var thresholdDBFS: Double = MediaEditLimits.silenceThresholdDBFS
    var minimumPause: Double = MediaEditLimits.silenceMinimumPause

    var thresholdRange: ClosedRange<Double> {
        MediaEditLimits.silenceThresholdRange
    }

    var minimumPauseRange: ClosedRange<Double> {
        MediaEditLimits.silenceMinimumPauseRange
    }
}

/// Finds low-energy runs in the cached analysis waveform. The waveform is
/// already a mono downmix at a fixed bucket resolution, so detection is a
/// single pass with no audio decode. A zero-filled bucket means "this asset
/// has no audio here", not silence: it is never proposed for removal.
enum MediaSilenceDetector {
    static func detect(
        data: WaveformData,
        settings: MediaSilenceSettings,
        sourceDuration: Double,
        keepRanges: [MediaTimeRange],
        within scope: MediaTimeRange? = nil
    ) -> [MediaTimeRange] {
        guard data.sampleRate.isFinite,
              data.sampleRate > 0,
              data.bucketFrames > 0,
              !data.peaks.isEmpty,
              !keepRanges.isEmpty else {
            return []
        }
        let searchRanges: [MediaTimeRange]
        if let scope {
            searchRanges = keepRanges.compactMap {
                $0.intersection(with: scope)
            }
        } else {
            searchRanges = keepRanges
        }
        guard !searchRanges.isEmpty else { return [] }
        let duration = sourceDuration.isFinite && sourceDuration > 0
            ? sourceDuration
            : data.duration
        guard duration.isFinite, duration > 0 else { return [] }

        let threshold = settings.thresholdDBFS.isFinite
            ? settings.thresholdDBFS
            : MediaEditLimits.silenceThresholdDBFS
        let minimumPause = settings.minimumPause.isFinite
            ? max(settings.minimumPause, 0)
            : MediaEditLimits.silenceMinimumPause
        let entry = amplitude(forDBFS: threshold)
        let exit = amplitude(
            forDBFS: threshold + MediaEditLimits.silenceHysteresisDB
        )
        let guardPadding = max(MediaEditLimits.silenceGuardPadding, 0)

        var silentRuns: [MediaTimeRange] = []
        var runStart: Double?
        var index = 0
        while index < data.peaks.count {
            let bucketStart = Double(index * data.bucketFrames)
                / data.sampleRate
            guard bucketStart < duration else { break }
            let rms = data.rms(at: index)
            if let rms {
                if runStart == nil {
                    if rms <= entry {
                        runStart = bucketStart
                    }
                } else if let start = runStart, rms >= exit {
                    appendRun(
                        from: start,
                        to: bucketStart,
                        into: &silentRuns
                    )
                    runStart = nil
                }
            } else {
                // Missing audio is not a pause candidate.
                if let start = runStart {
                    appendRun(from: start, to: bucketStart, into: &silentRuns)
                    runStart = nil
                }
            }
            index += 1
        }
        if let start = runStart {
            appendRun(from: start, to: duration, into: &silentRuns)
        }

        let sortedKeep = searchRanges.sorted { $0.start < $1.start }
        var candidates: [MediaTimeRange] = []
        var keepIndex = 0
        for run in silentRuns {
            while keepIndex < sortedKeep.count,
                  sortedKeep[keepIndex].end <= run.start {
                keepIndex += 1
            }
            var probe = keepIndex
            while probe < sortedKeep.count,
                  sortedKeep[probe].start < run.end {
                if let overlap = run.intersection(with: sortedKeep[probe]) {
                    let guardedStart = overlap.start + guardPadding
                    let guardedEnd = overlap.end - guardPadding
                    let pause = guardedEnd - guardedStart
                    // Bucket boundaries are floating-point; a pause at the
                    // exact minimum must not vanish because of a 1e-16 error.
                    if pause + MediaEditLimits.minimumRangeDuration
                        >= minimumPause {
                        candidates.append(
                            MediaTimeRange(
                                start: guardedStart,
                                duration: pause
                            )
                        )
                    }
                }
                probe += 1
            }
        }
        return candidates
    }

    private static func appendRun(
        from start: Double,
        to end: Double,
        into runs: inout [MediaTimeRange]
    ) {
        guard end - start
            > MediaEditLimits.minimumRangeDuration else {
            return
        }
        runs.append(MediaTimeRange(start: start, duration: end - start))
    }

    private static func amplitude(forDBFS value: Double) -> Float {
        Float(pow(10, value / 20))
    }
}
