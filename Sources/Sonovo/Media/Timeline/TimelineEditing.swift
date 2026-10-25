import CoreMedia
import Foundation

enum TimelineEditError: LocalizedError, Equatable {
    case unknownClip(String)
    case wrongKind
    case invalidRange
    case overlap
    case notInsideClip

    var errorDescription: String? {
        switch self {
        case let .unknownClip(id):
            "Timeline clip \(id) does not exist."
        case .wrongKind:
            "That asset does not belong on this track."
        case .invalidRange:
            "The clip range is empty or outside its source."
        case .overlap:
            "That drop would overlap another clip on the track."
        case .notInsideClip:
            "The playhead is not inside that clip."
        }
    }
}

extension ProjectTimeline {
    static let minimumClipDuration = CMTime(
        value: 1,
        timescale: ProjectTimeline.defaultTimescale
    )

    /// Adds an asset clip at a project time. The caller probes the source
    /// duration; this method enforces ordering and video non-overlap.
    mutating func addClip(
        asset: ProjectAsset,
        track: TimelineTrackKind,
        at timelineStart: CMTime,
        sourceStart: CMTime = .zero,
        duration: CMTime,
        gain: Double = 1,
        fadeIn: CMTime = .zero,
        fadeOut: CMTime = .zero
    ) throws {
        guard Self.isSafeProjectPath(asset.relativePath) else {
            throw TimelineEditError.invalidRange
        }
        let expected: AssetKind = track == .video ? .video : .audio
        guard asset.kind == expected else {
            throw TimelineEditError.wrongKind
        }
        guard timelineStart.isNumeric, timelineStart.seconds >= 0,
              sourceStart.isNumeric, sourceStart.seconds >= 0,
              duration.isNumeric,
              duration >= Self.minimumClipDuration,
              fadeIn.isNumeric, fadeOut.isNumeric,
              fadeIn.seconds >= 0, fadeOut.seconds >= 0,
              fadeIn + fadeOut <= duration,
              gain >= 0, gain <= 1 else {
            throw TimelineEditError.invalidRange
        }
        let clip = TimelineClip(
            id: UUID().uuidString,
            assetID: asset.id,
            relativePath: asset.relativePath,
            sourceStart: TimelineTimeDTO(sourceStart),
            sourceDuration: TimelineTimeDTO(duration),
            timelineStart: TimelineTimeDTO(timelineStart),
            gain: gain,
            fadeIn: TimelineTimeDTO(fadeIn),
            fadeOut: TimelineTimeDTO(fadeOut),
            sourceRevision: asset.revision.token
        )
        var next = self
        var clips = next.clips(for: track)
        clips.append(clip)
        clips.sort {
            $0.timelineStart.cmTime < $1.timelineStart.cmTime
        }
        next.setClips(clips, for: track)
        do {
            try next.validate()
        } catch TimelineValidationError.overlappingClips {
            throw TimelineEditError.overlap
        }
        self = next
    }

    mutating func moveClip(id: String, to timelineStart: CMTime) throws {
        guard timelineStart.isNumeric, timelineStart.seconds >= 0 else {
            throw TimelineEditError.invalidRange
        }
        var next = self
        guard let track = next.trackContaining(clipID: id) else {
            throw TimelineEditError.unknownClip(id)
        }
        var clips = next.clips(for: track)
        guard let index = clips.firstIndex(where: { $0.id == id }) else {
            throw TimelineEditError.unknownClip(id)
        }
        var clip = clips[index]
        clip = TimelineClip(
            id: clip.id,
            assetID: clip.assetID,
            relativePath: clip.relativePath,
            sourceStart: clip.sourceStart,
            sourceDuration: clip.sourceDuration,
            timelineStart: TimelineTimeDTO(timelineStart),
            gain: clip.gain,
            fadeIn: clip.fadeIn,
            fadeOut: clip.fadeOut,
            sourceRevision: clip.sourceRevision
        )
        clips[index] = clip
        clips.sort {
            $0.timelineStart.cmTime < $1.timelineStart.cmTime
        }
        next.setClips(clips, for: track)
        do {
            try next.validate()
        } catch TimelineValidationError.overlappingClips {
            throw TimelineEditError.overlap
        }
        self = next
    }

    mutating func trimStart(id: String, to timelineTime: CMTime) throws {
        guard timelineTime.isNumeric else {
            throw TimelineEditError.invalidRange
        }
        var next = self
        guard let track = next.trackContaining(clipID: id) else {
            throw TimelineEditError.unknownClip(id)
        }
        var clips = next.clips(for: track)
        guard let index = clips.firstIndex(where: { $0.id == id }) else {
            throw TimelineEditError.unknownClip(id)
        }
        let clip = clips[index]
        let start = clip.timelineStart.cmTime
        let delta = timelineTime - start
        guard delta.isNumeric,
              delta.seconds >= 0,
              clip.sourceStart.cmTime + delta >= .zero,
              clip.sourceDuration.cmTime - delta >= Self.minimumClipDuration else {
            throw TimelineEditError.invalidRange
        }
        clips[index] = TimelineClip(
            id: clip.id,
            assetID: clip.assetID,
            relativePath: clip.relativePath,
            sourceStart: TimelineTimeDTO(clip.sourceStart.cmTime + delta),
            sourceDuration: TimelineTimeDTO(
                clip.sourceDuration.cmTime - delta
            ),
            timelineStart: TimelineTimeDTO(start + delta),
            gain: clip.gain,
            fadeIn: clip.fadeIn,
            fadeOut: clip.fadeOut,
            sourceRevision: clip.sourceRevision
        )
        next.setClips(clips, for: track)
        do {
            try next.validate()
        } catch TimelineValidationError.overlappingClips {
            throw TimelineEditError.overlap
        }
        self = next
    }

    mutating func trimEnd(id: String, to timelineTime: CMTime) throws {
        guard timelineTime.isNumeric else {
            throw TimelineEditError.invalidRange
        }
        var next = self
        guard let track = next.trackContaining(clipID: id) else {
            throw TimelineEditError.unknownClip(id)
        }
        var clips = next.clips(for: track)
        guard let index = clips.firstIndex(where: { $0.id == id }) else {
            throw TimelineEditError.unknownClip(id)
        }
        let clip = clips[index]
        let duration = timelineTime - clip.timelineStart.cmTime
        guard duration.isNumeric,
              duration >= Self.minimumClipDuration,
              duration <= clip.sourceDuration.cmTime,
              clip.fadeIn.cmTime + clip.fadeOut.cmTime <= duration else {
            throw TimelineEditError.invalidRange
        }
        clips[index] = TimelineClip(
            id: clip.id,
            assetID: clip.assetID,
            relativePath: clip.relativePath,
            sourceStart: clip.sourceStart,
            sourceDuration: TimelineTimeDTO(duration),
            timelineStart: clip.timelineStart,
            gain: clip.gain,
            fadeIn: clip.fadeIn,
            fadeOut: clip.fadeOut,
            sourceRevision: clip.sourceRevision
        )
        next.setClips(clips, for: track)
        do {
            try next.validate()
        } catch TimelineValidationError.overlappingClips {
            throw TimelineEditError.overlap
        }
        self = next
    }

    /// Splits at a project time strictly inside the clip. The right side
    /// inherits gain and fades; the left keeps its source start.
    @discardableResult
    mutating func splitClip(
        id: String,
        at timelineTime: CMTime
    ) throws -> String {
        var next = self
        guard let track = next.trackContaining(clipID: id) else {
            throw TimelineEditError.unknownClip(id)
        }
        var clips = next.clips(for: track)
        guard let index = clips.firstIndex(where: { $0.id == id }) else {
            throw TimelineEditError.unknownClip(id)
        }
        let clip = clips[index]
        let offset = timelineTime - clip.timelineStart.cmTime
        guard offset.isNumeric,
              offset >= Self.minimumClipDuration,
              clip.sourceDuration.cmTime - offset
                >= Self.minimumClipDuration else {
            throw TimelineEditError.notInsideClip
        }
        let rightID = UUID().uuidString
        let left = TimelineClip(
            id: clip.id,
            assetID: clip.assetID,
            relativePath: clip.relativePath,
            sourceStart: clip.sourceStart,
            sourceDuration: TimelineTimeDTO(offset),
            timelineStart: clip.timelineStart,
            gain: clip.gain,
            fadeIn: clip.fadeIn,
            fadeOut: TimelineTimeDTO(.zero),
            sourceRevision: clip.sourceRevision
        )
        let right = TimelineClip(
            id: rightID,
            assetID: clip.assetID,
            relativePath: clip.relativePath,
            sourceStart: TimelineTimeDTO(
                clip.sourceStart.cmTime + offset
            ),
            sourceDuration: TimelineTimeDTO(
                clip.sourceDuration.cmTime - offset
            ),
            timelineStart: TimelineTimeDTO(timelineTime),
            gain: clip.gain,
            fadeIn: TimelineTimeDTO(.zero),
            fadeOut: clip.fadeOut,
            sourceRevision: clip.sourceRevision
        )
        clips[index] = left
        clips.append(right)
        clips.sort {
            $0.timelineStart.cmTime < $1.timelineStart.cmTime
        }
        next.setClips(clips, for: track)
        try next.validate()
        self = next
        return rightID
    }

    mutating func deleteClip(id: String) throws {
        var next = self
        guard let track = next.trackContaining(clipID: id) else {
            throw TimelineEditError.unknownClip(id)
        }
        var clips = next.clips(for: track)
        clips.removeAll { $0.id == id }
        next.setClips(clips, for: track)
        self = next
    }

    func clip(id: String) -> TimelineClip? {
        allClips.first { $0.id == id }
    }

    func trackContaining(clipID: String) -> TimelineTrackKind? {
        for kind in TimelineTrackKind.allCases
        where clips(for: kind).contains(where: { $0.id == clipID }) {
            return kind
        }
        return nil
    }

    func clips(for kind: TimelineTrackKind) -> [TimelineClip] {
        switch kind {
        case .video: videoTrack.clips
        case .voice: voiceTrack.clips
        case .music: musicTrack.clips
        }
    }

    mutating func setClips(
        _ clips: [TimelineClip],
        for kind: TimelineTrackKind
    ) {
        switch kind {
        case .video: videoTrack.clips = clips
        case .voice: voiceTrack.clips = clips
        case .music: musicTrack.clips = clips
        }
    }

    /// Project duration is the furthest clip end; gaps before it are real
    /// empty time, not a reason to shorten the ruler.
    var duration: CMTime {
        allClips.reduce(CMTime.zero) { result, clip in
            max(result, clip.timelineEnd)
        }
    }

    func snap(
        _ time: CMTime,
        candidates: [CMTime],
        tolerance: CMTime
    ) -> CMTime {
        var best = time
        var bestDistance = tolerance
        for candidate in candidates where candidate.isNumeric {
            let distance = CMTimeAbsoluteValue(candidate - time)
            if distance <= bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }
}
