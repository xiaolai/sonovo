import AVFoundation
import CoreMedia
import Foundation

enum MediaCompositionError: LocalizedError, Equatable {
    case emptyEdit
    case noTracks
    case unreadableSource
    case rangeOutsideTrack

    var errorDescription: String? {
        switch self {
        case .emptyEdit:
            "Every part of this file has been removed. Reset the edit first."
        case .noTracks:
            "This file has no audio or video tracks to edit."
        case .unreadableSource:
            "The source file could not be read."
        case .rangeOutsideTrack:
            "The selected range is outside the source track."
        }
    }
}

struct MediaCompositionBuild {
    let composition: AVMutableComposition
    let hasVideo: Bool
    let hasAudio: Bool
    let duration: Double
    let audioChannelCount: Int?
    let audioTrackCount: Int
}

/// Builds the preview and export asset from the kept source ranges. One
/// composition serves both, so the player and the exporter cannot disagree
/// about what the edit means.
enum MediaCompositionBuilder {
    static func build(
        sourceURL: URL,
        state: MediaEditState
    ) async throws -> MediaCompositionBuild {
        guard !state.keepRanges.isEmpty else {
            throw MediaCompositionError.emptyEdit
        }
        let source = AVURLAsset(url: sourceURL)
        let videoTracks = try? await source.loadTracks(withMediaType: .video)
        let audioTracks = try? await source.loadTracks(withMediaType: .audio)
        let tracks = (videoTracks ?? []) + (audioTracks ?? [])
        guard !tracks.isEmpty else {
            throw MediaCompositionError.noTracks
        }

        let composition = AVMutableComposition()
        var naturalSize: CGSize?
        var audioChannelCount: Int?

        for sourceTrack in tracks {
            let timeRange: CMTimeRange
            do {
                timeRange = try await sourceTrack.load(.timeRange)
            } catch {
                throw MediaCompositionError.unreadableSource
            }
            let trackStart = timeRange.start.seconds
            let trackEnd = timeRange.end.seconds

            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: sourceTrack.mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw MediaCompositionError.unreadableSource
            }
            if let transform = try? await sourceTrack.load(.preferredTransform) {
                compositionTrack.preferredTransform = transform
            }
            if sourceTrack.mediaType == .video {
                if naturalSize == nil,
                   let size = try? await sourceTrack.load(.naturalSize) {
                    naturalSize = size
                }
            } else if sourceTrack.mediaType == .audio,
                      audioChannelCount == nil,
                      let descriptions = try? await sourceTrack.load(
                          .formatDescriptions
                      ),
                      let first = descriptions.first,
                      let stream = CMAudioFormatDescriptionGetStreamBasicDescription(
                          first
                      )?.pointee {
                audioChannelCount = Int(stream.mChannelsPerFrame)
            }

            var cursor = CMTime.zero
            for range in state.keepRanges {
                // Tracks in one file can differ by a few milliseconds at the
                // head or tail (encoder priming, last audio frame). Insert the
                // overlap and keep the cursor on the requested timeline so
                // the following ranges stay aligned.
                let effectiveStart = max(range.start, trackStart)
                let effectiveEnd = min(range.end, trackEnd)
                if effectiveEnd - effectiveStart
                    > MediaEditLimits.minimumRangeDuration {
                    let start = CMTime(
                        seconds: effectiveStart,
                        preferredTimescale: MediaEditLimits.timescale
                    )
                    let duration = CMTime(
                        seconds: effectiveEnd - effectiveStart,
                        preferredTimescale: MediaEditLimits.timescale
                    )
                    // A track that begins after the asset timeline keeps its
                    // offset. Inserting everything at `cursor` would shift a
                    // late audio track onto time zero and break A/V sync.
                    let offset = effectiveStart - range.start
                    let insertAt = cursor + CMTime(
                        seconds: offset,
                        preferredTimescale: MediaEditLimits.timescale
                    )
                    do {
                        try compositionTrack.insertTimeRange(
                            CMTimeRange(start: start, duration: duration),
                            of: sourceTrack,
                            at: insertAt
                        )
                    } catch {
                        throw MediaCompositionError.rangeOutsideTrack
                    }
                }
                cursor = cursor + CMTime(
                    seconds: range.duration,
                    preferredTimescale: MediaEditLimits.timescale
                )
            }
        }

        if let naturalSize {
            composition.naturalSize = naturalSize
        }
        return MediaCompositionBuild(
            composition: composition,
            hasVideo: !(videoTracks ?? []).isEmpty,
            hasAudio: !(audioTracks ?? []).isEmpty,
            duration: composition.duration.seconds,
            audioChannelCount: audioChannelCount,
            audioTrackCount: audioTracks?.count ?? 0
        )
    }
}
