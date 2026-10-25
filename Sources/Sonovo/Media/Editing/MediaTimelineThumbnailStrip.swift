import AVFoundation
import SwiftUI

/// Pure tile layout for the filmstrip. Keeping the count and sample times
/// out of the view makes the visible-range policy testable.
struct MediaTimelineThumbnailPlan: Equatable, Sendable {
    let count: Int
    let times: [Double]

    static func make(
        viewport: MediaTimelineViewport,
        sourceDuration: Double,
        width: CGFloat
    ) -> MediaTimelineThumbnailPlan {
        let upper = sourceDuration.isFinite && sourceDuration > 0
            ? sourceDuration
            : 0
        let rawCount = width > 0
            ? Int(
                (width / AppTheme.Size.mediaTimelineThumbnailTileWidth)
                    .rounded()
            )
            : 1
        let count = max(
            1,
            min(MediaEditLimits.thumbnailMaximumTiles, rawCount)
        )
        let times = (0..<count).map { index -> Double in
            let fraction = (
                Double(index)
                    + MediaEditLimits.thumbnailTileCenterFraction
            ) / Double(count)
            let time = viewport.start + fraction * viewport.duration
            return min(max(time, 0), upper)
        }
        return MediaTimelineThumbnailPlan(count: count, times: times)
    }

    /// A fixed 100 ms tolerance collapses every tile to the same frame when
    /// the visible window is only 100 ms wide. Keep the tolerance within half
    /// a tile so deep zoom still shows distinct frames.
    static func tolerance(
        viewport: MediaTimelineViewport,
        count: Int
    ) -> Double {
        let tileDuration = viewport.duration / Double(max(count, 1))
        return min(
            MediaEditLimits.thumbnailTimeTolerance,
            max(
                tileDuration * MediaEditLimits.thumbnailTileCenterFraction,
                MediaEditLimits.minimumRangeDuration
            )
        )
    }
}

/// Visible-range video thumbnails above the audio waveform. Presentation
/// only: the generator, images, and cache never enter the edit decision.
struct MediaTimelineThumbnailStrip: View {
    let url: URL
    let revision: AssetRevision
    let sourceDuration: Double
    let viewport: MediaTimelineViewport
    var isEnabled = true

    @State private var images: [Int64: CGImage] = [:]
    @State private var generation: UInt64 = 0
    @Environment(\.displayScale) private var displayScale

    private struct Request: Equatable {
        let revision: String
        let startMilliseconds: Int64
        let durationMilliseconds: Int64
        let width: Int
        /// Pausing playback must restart the request. Otherwise the task
        /// started while playing is cancelled by its `isEnabled` guard and
        /// never runs again until the viewport changes.
        let isEnabled: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let plan = MediaTimelineThumbnailPlan.make(
                viewport: viewport,
                sourceDuration: sourceDuration,
                width: size.width
            )
            HStack(spacing: AppTheme.Spacing.zero) {
                ForEach(0..<plan.count, id: \.self) { index in
                    tile(
                        time: plan.times[index],
                        width: size.width / CGFloat(plan.count),
                        height: size.height
                    )
                }
            }
            .task(id: request(width: size.width)) {
                await load(
                    plan: plan,
                    width: size.width / CGFloat(plan.count),
                    height: size.height
                )
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.control,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.control,
                style: .continuous
            )
            .strokeBorder(
                Color.appSeparator,
                lineWidth: AppTheme.BorderWidth.hairline
            )
        )
        .onChange(of: revision.token) { _, _ in
            generation &+= 1
            images = [:]
        }
    }

    private func tile(
        time: Double,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let key = timeKey(time)
        return Group {
            if let image = images[key] {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.appCard
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private func request(width: CGFloat) -> Request {
        Request(
            revision: revision.token,
            startMilliseconds: Int64(
                (viewport.start * 1000).rounded()
            ),
            durationMilliseconds: Int64(
                (viewport.duration * 1000).rounded()
            ),
            width: Int(width.rounded()),
            isEnabled: isEnabled
        )
    }

    private func timeKey(_ time: Double) -> Int64 {
        Int64((time * 1000).rounded())
    }

    private func load(
        plan: MediaTimelineThumbnailPlan,
        width: CGFloat,
        height: CGFloat
    ) async {
        guard isEnabled, sourceDuration > 0,
              width > 0, height > 0 else {
            return
        }
        generation &+= 1
        let generation = generation
        let generator = AVAssetImageGenerator(
            asset: AVURLAsset(url: url)
        )
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: width * displayScale,
            height: height * displayScale
        )
        let tolerance = CMTime(
            seconds: MediaTimelineThumbnailPlan.tolerance(
                viewport: viewport,
                count: plan.count
            ),
            preferredTimescale: 600
        )
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        defer { generator.cancelAllCGImageGeneration() }

        for time in plan.times {
            guard generation == self.generation,
                  !Task.isCancelled else {
                return
            }
            let key = timeKey(time)
            if images[key] != nil { continue }
            let requested = CMTime(
                seconds: time,
                preferredTimescale: MediaEditLimits.timescale
            )
            guard let result = try? await generator.image(at: requested)
            else {
                continue
            }
            guard generation == self.generation,
                  !Task.isCancelled else {
                return
            }
            images[key] = result.image
            trimCache()
        }
    }

    private func trimCache() {
        let limit = MediaEditLimits.thumbnailMaximumTiles * 2
        guard images.count > limit else { return }
        for key in images.keys.sorted().prefix(images.count - limit) {
            images.removeValue(forKey: key)
        }
    }
}
