import SonovoMediaUI
import SonovoMediaEngine
import SonovoDesignSystem
import SonovoFeatureAPI
import SonovoDocumentSupport
import SonovoFileIO
import SonovoDomainTypes
import CoreMedia
import Foundation

/// The canonical project time serialization. Seconds are display values;
/// timeline arithmetic stays on CMTime with an explicit timescale.
package struct TimelineTimeDTO: Codable, Hashable, Sendable, Equatable {
    package var value: Int64
    package var timescale: Int32

    package init(_ time: CMTime) {
        value = time.value
        timescale = time.timescale
    }

    package init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    package var cmTime: CMTime {
        CMTime(value: value, timescale: timescale)
    }

    package var seconds: Double { cmTime.seconds }
}

package enum TimelineTrackKind: String, Codable, Sendable, Hashable, CaseIterable {
    case video
    case voice
    case music
}

package struct TimelineClip: Codable, Identifiable, Hashable, Sendable, Equatable {
    package let id: String
    package let assetID: String
    package let relativePath: String
    package let sourceStart: TimelineTimeDTO
    package let sourceDuration: TimelineTimeDTO
    package let timelineStart: TimelineTimeDTO
    package var gain: Double
    package let fadeIn: TimelineTimeDTO
    package let fadeOut: TimelineTimeDTO
    /// The source revision the clip was placed against. Optional so early
    /// timeline files remain readable; a present value that no longer
    /// matches the project scan marks the clip stale.
    package var sourceRevision: String? = nil
    /// Content hash captured when the clip was placed or relinked. New clips
    /// use it to detect a same-size, same-mtime source replacement; legacy
    /// clips without it fall back to revision metadata.
    package var sourceFingerprint: String? = nil

    package var sourceRange: MediaTimeRange {
        MediaTimeRange(
            start: sourceStart.seconds,
            duration: sourceDuration.seconds
        )
    }

    package var timelineEnd: CMTime {
        timelineStart.cmTime + sourceDuration.cmTime
    }

    package var sourceEnd: CMTime {
        sourceStart.cmTime + sourceDuration.cmTime
    }
}

package struct TimelineTrack: Codable, Sendable, Equatable {
    package var kind: TimelineTrackKind
    package var clips: [TimelineClip]
}

package enum TimelineValidationError: LocalizedError, Equatable {
    case schemaVersion(Int)
    case wrongTrackKind(expected: TimelineTrackKind, actual: TimelineTrackKind)
    case invalidTime(String)
    case emptyClipID
    case duplicateClipID(String)
    case invalidPath(String)
    case invalidGain(String)
    case invalidFade(String)
    case overlappingClips(String)
    case clipsNotSorted(String)

    package var errorDescription: String? {
        switch self {
        case let .schemaVersion(version):
            "Timeline schema \(version) is not supported."
        case let .wrongTrackKind(expected, actual):
            "The \(expected.rawValue) track contains a \(actual.rawValue) track."
        case let .invalidTime(clip):
            "Clip \(clip) has an invalid time or range."
        case .emptyClipID:
            "A timeline clip has no identity."
        case let .duplicateClipID(id):
            "Clip identity \(id) appears more than once."
        case let .invalidPath(path):
            "The clip path is not a safe project-relative path: \(path)"
        case let .invalidGain(clip):
            "Clip \(clip) has gain outside 0...1."
        case let .invalidFade(clip):
            "Clip \(clip) has a fade longer than its source."
        case let .overlappingClips(track):
            "Clips overlap on the \(track) track."
        case let .clipsNotSorted(track):
            "Clips are not sorted on the \(track) track."
        }
    }
}

package struct ProjectTimeline: Codable, Sendable, Equatable {
    package static let currentSchemaVersion = 1
    package static let defaultTimescale: CMTimeScale = 600_000

    package var schemaVersion: Int
    package var id: String
    package var name: String
    package var videoTrack: TimelineTrack
    package var voiceTrack: TimelineTrack
    package var musicTrack: TimelineTrack
    package var canvasWidth: Int
    package var canvasHeight: Int
    package var frameRateNumerator: Int32
    package var frameRateDenominator: Int32

    package init(
        name: String,
        id: String = UUID().uuidString,
        canvasWidth: Int = 1920,
        canvasHeight: Int = 1080,
        frameRateNumerator: Int32 = 30,
        frameRateDenominator: Int32 = 1
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        videoTrack = TimelineTrack(kind: .video, clips: [])
        voiceTrack = TimelineTrack(kind: .voice, clips: [])
        musicTrack = TimelineTrack(kind: .music, clips: [])
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.frameRateNumerator = frameRateNumerator
        self.frameRateDenominator = frameRateDenominator
    }

    package var allClips: [TimelineClip] {
        videoTrack.clips + voiceTrack.clips + musicTrack.clips
    }

    package var tracks: [(TimelineTrackKind, [TimelineClip])] {
        [
            (.video, videoTrack.clips),
            (.voice, voiceTrack.clips),
            (.music, musicTrack.clips)
        ]
    }

    package func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw TimelineValidationError.schemaVersion(schemaVersion)
        }
        try validateTrack(videoTrack, expected: .video)
        try validateTrack(voiceTrack, expected: .voice)
        try validateTrack(musicTrack, expected: .music)
        guard canvasWidth > 0, canvasHeight > 0,
              frameRateNumerator > 0, frameRateDenominator > 0 else {
            throw TimelineValidationError.invalidTime("project")
        }
        var ids = Set<String>()
        for clip in allClips {
            guard !clip.id.isEmpty else {
                throw TimelineValidationError.emptyClipID
            }
            guard ids.insert(clip.id).inserted else {
                throw TimelineValidationError.duplicateClipID(clip.id)
            }
        }
        guard Self.isFiniteTime(duration),
              duration.seconds >= 0 else {
            throw TimelineValidationError.invalidTime("project")
        }
    }

    private static func isFiniteTime(_ time: CMTime) -> Bool {
        time.isNumeric && time.seconds.isFinite
    }

    private func validateTrack(
        _ track: TimelineTrack,
        expected: TimelineTrackKind
    ) throws {
        guard track.kind == expected else {
            throw TimelineValidationError.wrongTrackKind(
                expected: expected,
                actual: track.kind
            )
        }
        for clip in track.clips {
            guard clip.sourceStart.timescale > 0,
                  clip.sourceDuration.timescale > 0,
                  clip.timelineStart.timescale > 0,
                  clip.fadeIn.timescale > 0,
                  clip.fadeOut.timescale > 0,
                  clip.sourceStart.cmTime.isNumeric,
                  clip.sourceDuration.cmTime.isNumeric,
                  clip.timelineStart.cmTime.isNumeric,
                  Self.isFiniteTime(clip.fadeIn.cmTime),
                  Self.isFiniteTime(clip.fadeOut.cmTime),
                  Self.isFiniteTime(clip.sourceEnd),
                  Self.isFiniteTime(clip.timelineEnd),
                  clip.sourceStart.seconds >= 0,
                  clip.sourceDuration.seconds > 0,
                  clip.timelineStart.seconds >= 0 else {
                throw TimelineValidationError.invalidTime(clip.id)
            }
            guard clip.gain >= 0, clip.gain <= 1 else {
                throw TimelineValidationError.invalidGain(clip.id)
            }
            guard clip.fadeIn.seconds >= 0,
                  clip.fadeOut.seconds >= 0,
                  clip.fadeIn.cmTime + clip.fadeOut.cmTime
                    <= clip.sourceDuration.cmTime else {
                throw TimelineValidationError.invalidFade(clip.id)
            }
            guard Self.isSafeProjectPath(clip.relativePath) else {
                throw TimelineValidationError.invalidPath(clip.relativePath)
            }
        }
        for (index, clip) in track.clips.enumerated() {
            if index > 0 {
                let previous = track.clips[index - 1]
                guard clip.timelineStart.seconds
                    >= previous.timelineStart.seconds else {
                    throw TimelineValidationError.clipsNotSorted(
                        track.kind.rawValue
                    )
                }
                guard clip.timelineStart.cmTime
                    >= previous.timelineEnd else {
                    throw TimelineValidationError.overlappingClips(
                        track.kind.rawValue
                    )
                }
            }
        }
    }

    package static func isSafeProjectPath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return !components.contains { component in
            component.isEmpty || component == "." || component == ".."
        }
    }
}
