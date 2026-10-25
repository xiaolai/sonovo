import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

enum TimelineAssetProbeError: LocalizedError, Equatable {
    case unsupportedKind
    case emptySource
    case missingStream

    var errorDescription: String? {
        switch self {
        case .unsupportedKind:
            "Only audio and video project assets can be placed on a timeline."
        case .emptySource:
            "The source has no usable duration."
        case .missingStream:
            "The source has no stream for that track."
        }
    }
}

struct TimelineProbedAsset: Sendable {
    let duration: CMTime
    let fingerprint: String
}

enum TimelineAssetProbe {
    static func duration(for asset: ProjectAsset) async throws -> CMTime {
        let probed = try await probe(asset: asset, track: nil)
        return probed.duration
    }

    /// Verifies the media stream the track needs, not just the filename
    /// classification, and captures a content fingerprint for relink and
    /// change detection.
    static func probe(
        asset: ProjectAsset,
        track: TimelineTrackKind?
    ) async throws -> TimelineProbedAsset {
        guard asset.kind == .audio || asset.kind == .video else {
            throw TimelineAssetProbeError.unsupportedKind
        }
        let source = AVURLAsset(url: asset.url)
        let duration = try await source.load(.duration)
        guard duration.isNumeric,
              duration.seconds.isFinite,
              duration.seconds > 0 else {
            throw TimelineAssetProbeError.emptySource
        }
        if let track {
            let mediaType: AVMediaType = track == .video ? .video : .audio
            let tracks = try await source.loadTracks(
                withMediaType: mediaType
            )
            guard !tracks.isEmpty else {
                throw TimelineAssetProbeError.missingStream
            }
        }
        return TimelineProbedAsset(
            duration: duration,
            fingerprint: try fingerprint(for: asset.url)
        )
    }

    static func fingerprint(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20),
              !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
