import CoreMedia
import Foundation

/// The canonical project time serialization. Seconds are display values;
/// timeline arithmetic stays on CMTime with an explicit timescale.
struct TimelineTimeDTO: Codable, Hashable, Sendable, Equatable {
    var value: Int64
    var timescale: Int32

    init(_ time: CMTime) {
        value = time.value
        timescale = time.timescale
    }

    init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    var cmTime: CMTime {
        CMTime(value: value, timescale: timescale)
    }

    var seconds: Double { cmTime.seconds }
}

enum TimelineTrackKind: String, Codable, Sendable, CaseIterable {
    case video
    case voice
    case music
}

struct TimelineClip: Codable, Identifiable, Hashable, Sendable, Equatable {
    let id: String
    let assetID: String
    let relativePath: String
    let sourceStart: TimelineTimeDTO
    let sourceDuration: TimelineTimeDTO
    let timelineStart: TimelineTimeDTO
    var gain: Double
    let fadeIn: TimelineTimeDTO
    let fadeOut: TimelineTimeDTO
    /// The source revision the clip was placed against. Optional so early
    /// timeline files remain readable; a present value that no longer
    /// matches the project scan marks the clip stale.
    var sourceRevision: String? = nil

    var sourceRange: MediaTimeRange {
        MediaTimeRange(
            start: sourceStart.seconds,
            duration: sourceDuration.seconds
        )
    }

    var timelineEnd: CMTime {
        timelineStart.cmTime + sourceDuration.cmTime
    }

    var sourceEnd: CMTime {
        sourceStart.cmTime + sourceDuration.cmTime
    }
}

struct TimelineTrack: Codable, Sendable, Equatable {
    var kind: TimelineTrackKind
    var clips: [TimelineClip]
}

enum TimelineValidationError: LocalizedError, Equatable {
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

    var errorDescription: String? {
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

struct ProjectTimeline: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    static let defaultTimescale: CMTimeScale = 600_000

    var schemaVersion: Int
    var id: String
    var name: String
    var videoTrack: TimelineTrack
    var voiceTrack: TimelineTrack
    var musicTrack: TimelineTrack
    var canvasWidth: Int
    var canvasHeight: Int
    var frameRateNumerator: Int32
    var frameRateDenominator: Int32

    init(
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

    var allClips: [TimelineClip] {
        videoTrack.clips + voiceTrack.clips + musicTrack.clips
    }

    var tracks: [(TimelineTrackKind, [TimelineClip])] {
        [
            (.video, videoTrack.clips),
            (.voice, voiceTrack.clips),
            (.music, musicTrack.clips)
        ]
    }

    func validate() throws {
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
                  clip.fadeIn.seconds + clip.fadeOut.seconds
                    <= clip.sourceDuration.seconds else {
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

    static func isSafeProjectPath(_ path: String) -> Bool {
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
