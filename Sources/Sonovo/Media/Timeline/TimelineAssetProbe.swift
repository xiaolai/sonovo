import AVFoundation
import CoreMedia
import Foundation

enum TimelineAssetProbeError: LocalizedError, Equatable {
    case unsupportedKind
    case emptySource

    var errorDescription: String? {
        switch self {
        case .unsupportedKind:
            "Only audio and video project assets can be placed on a timeline."
        case .emptySource:
            "The source has no usable duration."
        }
    }
}

enum TimelineAssetProbe {
    static func duration(for asset: ProjectAsset) async throws -> CMTime {
        guard asset.kind == .audio || asset.kind == .video else {
            throw TimelineAssetProbeError.unsupportedKind
        }
        let source = AVURLAsset(url: asset.url)
        let duration = try await source.load(.duration)
        guard duration.isNumeric,
              duration.seconds > 0 else {
            throw TimelineAssetProbeError.emptySource
        }
        return duration
    }
}
