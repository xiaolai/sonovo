import CoreMedia
import Foundation

enum TimelineSourceIssueReason: String, Sendable, Equatable {
    case missing
    case wrongKind
    case changed
}

struct TimelineSourceIssue: Identifiable, Hashable, Sendable, Equatable {
    let clipID: String
    let track: TimelineTrackKind
    let relativePath: String
    let reason: TimelineSourceIssueReason

    var id: String { clipID }

    var message: String {
        switch reason {
        case .missing:
            "\(relativePath) is missing."
        case .wrongKind:
            "\(relativePath) has the wrong media kind for the \(track.rawValue) track."
        case .changed:
            "\(relativePath) changed since it was placed."
        }
    }
}

enum TimelineRelinkError: LocalizedError, Equatable {
    case unknownClip(String)
    case wrongKind
    case rangeBeyondSource
    case invalidPath

    var errorDescription: String? {
        switch self {
        case let .unknownClip(id):
            "Timeline clip \(id) does not exist."
        case .wrongKind:
            "The replacement has the wrong media kind for this track."
        case .rangeBeyondSource:
            "The replacement is shorter than the clip's stored source range."
        case .invalidPath:
            "The replacement is not inside the project."
        }
    }
}

extension ProjectTimeline {
    /// Checks every clip against the project's current scan. Revision is only
    /// compared when the clip recorded one; a nil revision is a legacy clip,
    /// not a changed source.
    func sourceIssues(assets: [ProjectAsset]) -> [TimelineSourceIssue] {
        let byPath = Dictionary(
            assets.map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var issues: [TimelineSourceIssue] = []
        for (kind, clips) in tracks {
            let expected: AssetKind = kind == .video ? .video : .audio
            for clip in clips {
                guard let asset = byPath[clip.relativePath] else {
                    issues.append(
                        TimelineSourceIssue(
                            clipID: clip.id,
                            track: kind,
                            relativePath: clip.relativePath,
                            reason: .missing
                        )
                    )
                    continue
                }
                guard asset.kind == expected else {
                    issues.append(
                        TimelineSourceIssue(
                            clipID: clip.id,
                            track: kind,
                            relativePath: clip.relativePath,
                            reason: .wrongKind
                        )
                    )
                    continue
                }
                if let sourceRevision = clip.sourceRevision,
                   sourceRevision != asset.revision.token {
                    issues.append(
                        TimelineSourceIssue(
                            clipID: clip.id,
                            track: kind,
                            relativePath: clip.relativePath,
                            reason: .changed
                        )
                    )
                }
            }
        }
        return issues
    }

    /// Relinks one clip to a replacement asset. The replacement must be the
    /// right media kind and long enough to cover the clip's stored source
    /// range; the clip keeps its timeline position, source start, gain, and
    /// fades.
    mutating func relink(
        clipID: String,
        to asset: ProjectAsset,
        sourceDuration: CMTime,
        sourceFingerprint: String? = nil
    ) throws {
        guard Self.isSafeProjectPath(asset.relativePath) else {
            throw TimelineRelinkError.invalidPath
        }
        for (kind, clips) in tracks {
            guard let index = clips.firstIndex(where: { $0.id == clipID }) else {
                continue
            }
            let expected: AssetKind = kind == .video ? .video : .audio
            guard asset.kind == expected else {
                throw TimelineRelinkError.wrongKind
            }
            var clip = clips[index]
            guard sourceDuration.isNumeric,
                  sourceDuration >= clip.sourceEnd else {
                throw TimelineRelinkError.rangeBeyondSource
            }
            clip = TimelineClip(
                id: clip.id,
                assetID: asset.id,
                relativePath: asset.relativePath,
                sourceStart: clip.sourceStart,
                sourceDuration: clip.sourceDuration,
                timelineStart: clip.timelineStart,
                gain: clip.gain,
                fadeIn: clip.fadeIn,
                fadeOut: clip.fadeOut,
                sourceRevision: asset.revision.token,
                sourceFingerprint: sourceFingerprint
            )
            switch kind {
            case .video:
                videoTrack.clips[index] = clip
            case .voice:
                voiceTrack.clips[index] = clip
            case .music:
                musicTrack.clips[index] = clip
            }
            try validate()
            return
        }
        throw TimelineRelinkError.unknownClip(clipID)
    }
}

extension ProjectTimeline {
    /// Re-hashes the stored content fingerprints off the main actor. The
    /// project directory is a trust boundary, so metadata identity alone is
    /// not enough for a same-size replacement.
    func contentFingerprintIssues(
        assets: [ProjectAsset]
    ) async -> [TimelineSourceIssue] {
        let byPath = Dictionary(
            assets.map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let clips = allClips.compactMap { clip -> (
            TimelineClip,
            ProjectAsset,
            TimelineTrackKind
        )? in
            guard let expected = clip.sourceFingerprint,
                  let asset = byPath[clip.relativePath],
                  let track = trackContaining(clipID: clip.id) else {
                return nil
            }
            _ = expected
            return (clip, asset, track)
        }
        return await Task.detached(priority: .utility) {
            var checksums: [String: String] = [:]
            var issues: [TimelineSourceIssue] = []
            for (clip, asset, track) in clips {
                guard let expected = clip.sourceFingerprint else { continue }
                let current: String?
                if let cached = checksums[clip.relativePath] {
                    current = cached
                } else {
                    current = try? TimelineAssetProbe.fingerprint(
                        for: asset.url
                    )
                    if let current {
                        checksums[clip.relativePath] = current
                    }
                }
                if current != expected {
                    issues.append(
                        TimelineSourceIssue(
                            clipID: clip.id,
                            track: track,
                            relativePath: clip.relativePath,
                            reason: .changed
                        )
                    )
                }
            }
            return issues
        }.value
    }
}
