import AVFoundation
import CoreMedia
import Foundation

struct TimelineComposition {
    let composition: AVMutableComposition
    let audioMix: AVAudioMix?
    let videoComposition: AVVideoComposition?
    let duration: CMTime
}

enum TimelineCompositionError: LocalizedError, Equatable {
    case sourceIssues([TimelineSourceIssue])
    case unreadableSource(String)
    case missingVideoTrack(String)
    case missingAudioTrack(String)
    case sourceRangeBeyondAsset(String)
    case emptyTimeline

    var errorDescription: String? {
        switch self {
        case let .sourceIssues(issues):
            issues.map(\.message).joined(separator: "\n")
        case let .unreadableSource(path):
            "Could not read \(path)."
        case let .missingVideoTrack(path):
            "\(path) has no video track."
        case let .missingAudioTrack(path):
            "\(path) has no audio track."
        case let .sourceRangeBeyondAsset(path):
            "The stored range is outside \(path)."
        case .emptyTimeline:
            "The timeline has no clips."
        }
    }
}

/// One composition serves preview and export. Video clips are inserted on one
/// video track; voice and music get one audio track each with per-clip volume
/// events. Video clip audio is deliberately not mixed: B-roll is picture, and
/// the separate voice/music tracks are the audible spine.
enum ProjectTimelineCompositionBuilder {
    private struct VideoSegment {
        let range: CMTimeRange
        let instruction: AVVideoCompositionLayerInstruction
    }

    static func build(
        timeline: ProjectTimeline,
        assets: [ProjectAsset]
    ) async throws -> TimelineComposition {
        let issues = timeline.sourceIssues(assets: assets)
        guard issues.isEmpty else {
            throw TimelineCompositionError.sourceIssues(issues)
        }
        guard !timeline.allClips.isEmpty else {
            throw TimelineCompositionError.emptyTimeline
        }
        let byPath = Dictionary(
            assets.map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let voiceTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let musicTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var videoSegments: [VideoSegment] = []
        var voiceParameters: AVMutableAudioMixInputParameters?
        var musicParameters: AVMutableAudioMixInputParameters?

        for (kind, clips) in timeline.tracks {
            for clip in clips {
                guard let asset = byPath[clip.relativePath] else {
                    throw TimelineCompositionError.unreadableSource(
                        clip.relativePath
                    )
                }
                let source = AVURLAsset(url: asset.url)
                let sourceDuration: CMTime
                do {
                    sourceDuration = try await source.load(.duration)
                } catch {
                    throw TimelineCompositionError.unreadableSource(
                        clip.relativePath
                    )
                }
                guard clip.sourceEnd <= sourceDuration else {
                    throw TimelineCompositionError.sourceRangeBeyondAsset(
                        clip.relativePath
                    )
                }
                let sourceRange = CMTimeRange(
                    start: clip.sourceStart.cmTime,
                    duration: clip.sourceDuration.cmTime
                )
                switch kind {
                case .video:
                    guard let compositionVideoTrack = videoTrack else {
                        throw TimelineCompositionError.missingVideoTrack(
                            clip.relativePath
                        )
                    }
                    let tracks = try await source.loadTracks(
                        withMediaType: .video
                    )
                    guard let sourceVideo = tracks.first else {
                        throw TimelineCompositionError.missingVideoTrack(
                            clip.relativePath
                        )
                    }
                    try compositionVideoTrack.insertTimeRange(
                        sourceRange,
                        of: sourceVideo,
                        at: clip.timelineStart.cmTime
                    )
                    let naturalSize = try await sourceVideo.load(.naturalSize)
                    let preferredTransform = try await sourceVideo.load(
                        .preferredTransform
                    )
                    var layerConfiguration =
                        AVVideoCompositionLayerInstruction.Configuration(
                            trackID: compositionVideoTrack.trackID
                        )
                    layerConfiguration.setTransform(
                        aspectFitTransform(
                            naturalSize: naturalSize,
                            preferredTransform: preferredTransform,
                            canvas: CGSize(
                                width: timeline.canvasWidth,
                                height: timeline.canvasHeight
                            )
                        ),
                        at: clip.timelineStart.cmTime
                    )
                    let layer = AVVideoCompositionLayerInstruction(
                        configuration: layerConfiguration
                    )
                    videoSegments.append(
                        VideoSegment(
                            range: CMTimeRange(
                                start: clip.timelineStart.cmTime,
                                duration: clip.sourceDuration.cmTime
                            ),
                            instruction: layer
                        )
                    )
                case .voice, .music:
                    let target: AVMutableCompositionTrack?
                    switch kind {
                    case .voice: target = voiceTrack
                    case .music: target = musicTrack
                    default: target = nil
                    }
                    guard let compositionAudioTrack = target else {
                        throw TimelineCompositionError.missingAudioTrack(
                            clip.relativePath
                        )
                    }
                    let tracks = try await source.loadTracks(
                        withMediaType: .audio
                    )
                    guard let sourceAudio = tracks.first else {
                        throw TimelineCompositionError.missingAudioTrack(
                            clip.relativePath
                        )
                    }
                    try compositionAudioTrack.insertTimeRange(
                        sourceRange,
                        of: sourceAudio,
                        at: clip.timelineStart.cmTime
                    )
                    let parameters: AVMutableAudioMixInputParameters
                    switch kind {
                    case .voice:
                        if voiceParameters == nil {
                            voiceParameters = AVMutableAudioMixInputParameters(
                                track: compositionAudioTrack
                            )
                        }
                        parameters = voiceParameters!
                    case .music:
                        if musicParameters == nil {
                            musicParameters = AVMutableAudioMixInputParameters(
                                track: compositionAudioTrack
                            )
                        }
                        parameters = musicParameters!
                    default:
                        continue
                    }
                    applyVolume(
                        clip: clip,
                        to: parameters
                    )
                }
            }
        }

        guard let videoTrack else {
            throw TimelineCompositionError.emptyTimeline
        }
        videoTrack.preferredTransform = .identity

        var inputParameters: [AVAudioMixInputParameters] = []
        if let voiceParameters { inputParameters.append(voiceParameters) }
        if let musicParameters { inputParameters.append(musicParameters) }
        let mix: AVAudioMix?
        if inputParameters.isEmpty {
            mix = nil
        } else {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = inputParameters
            mix = audioMix
        }

        let videoComposition = makeVideoComposition(
            timeline: timeline,
            trackID: videoTrack.trackID,
            segments: videoSegments
        )
        return TimelineComposition(
            composition: composition,
            audioMix: mix,
            videoComposition: videoComposition,
            duration: timeline.duration
        )
    }

    private static func applyVolume(
        clip: TimelineClip,
        to parameters: AVMutableAudioMixInputParameters
    ) {
        let start = clip.timelineStart.cmTime
        let end = clip.timelineEnd
        let gain = Float(clip.gain)
        let fadeIn = clip.fadeIn.cmTime
        let fadeOut = clip.fadeOut.cmTime
        if fadeIn > .zero {
            parameters.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: gain,
                timeRange: CMTimeRange(start: start, duration: fadeIn)
            )
        } else {
            parameters.setVolume(gain, at: start)
        }
        if fadeOut > .zero {
            let fadeStart = end - fadeOut
            parameters.setVolume(gain, at: fadeStart)
            parameters.setVolumeRamp(
                fromStartVolume: gain,
                toEndVolume: 0,
                timeRange: CMTimeRange(start: fadeStart, duration: fadeOut)
            )
        } else {
            parameters.setVolume(0, at: end)
        }
    }

    private static func makeVideoComposition(
        timeline: ProjectTimeline,
        trackID: CMPersistentTrackID,
        segments: [VideoSegment]
    ) -> AVVideoComposition? {
        guard !segments.isEmpty else { return nil }
        var instructions: [any AVVideoCompositionInstructionProtocol] = []
        var cursor = CMTime.zero
        for segment in segments.sorted(by: {
            $0.range.start < $1.range.start
        }) {
            if segment.range.start > cursor {
                instructions.append(
                    instruction(
                        timeRange: CMTimeRange(
                            start: cursor,
                            duration: segment.range.start - cursor
                        ),
                        layers: []
                    )
                )
            }
            instructions.append(
                instruction(
                    timeRange: segment.range,
                    layers: [segment.instruction]
                )
            )
            cursor = segment.range.end
        }
        if cursor < timeline.duration {
            instructions.append(
                instruction(
                    timeRange: CMTimeRange(
                        start: cursor,
                        duration: timeline.duration - cursor
                    ),
                    layers: []
                )
            )
        }
        let configuration = AVVideoComposition.Configuration(
            animationTool: nil,
            colorPrimaries: nil,
            colorTransferFunction: nil,
            colorYCbCrMatrix: nil,
            customVideoCompositorClass: nil,
            frameDuration: CMTime(
                value: Int64(timeline.frameRateDenominator),
                timescale: timeline.frameRateNumerator
            ),
            instructions: instructions,
            outputBufferDescription: nil,
            renderScale: 1,
            renderSize: CGSize(
                width: timeline.canvasWidth,
                height: timeline.canvasHeight
            ),
            sourceSampleDataTrackIDs: [],
            sourceTrackIDForFrameTiming: trackID,
            spatialVideoConfigurations: []
        )
        return AVVideoComposition(configuration: configuration)
    }

    private static func instruction(
        timeRange: CMTimeRange,
        layers: [AVVideoCompositionLayerInstruction]
    ) -> AVVideoCompositionInstruction {
        let configuration = AVVideoCompositionInstruction.Configuration(
            backgroundColor: nil,
            enablePostProcessing: false,
            layerInstructions: layers,
            requiredSourceSampleDataTrackIDs: [],
            timeRange: timeRange
        )
        return AVVideoCompositionInstruction(configuration: configuration)
    }

    static func aspectFitTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        canvas: CGSize
    ) -> CGAffineTransform {
        guard naturalSize.width > 0, naturalSize.height > 0,
              canvas.width > 0, canvas.height > 0 else {
            return .identity
        }
        let rect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
        let oriented = CGSize(
            width: abs(rect.width),
            height: abs(rect.height)
        )
        let normalized = preferredTransform.concatenating(
            CGAffineTransform(
                translationX: -rect.minX,
                y: -rect.minY
            )
        )
        let scale = min(
            canvas.width / oriented.width,
            canvas.height / oriented.height
        )
        let scaled = CGSize(
            width: oriented.width * scale,
            height: oriented.height * scale
        )
        return normalized
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(
                CGAffineTransform(
                    translationX: (canvas.width - scaled.width) / 2,
                    y: (canvas.height - scaled.height) / 2
                )
            )
    }
}
