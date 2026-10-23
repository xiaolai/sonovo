import AppKit
import QuickLookThumbnailing
import SonovoCore
import SwiftUI

private struct ThumbnailRequestBox: @unchecked Sendable {
    let request: QLThumbnailGenerator.Request
}

@MainActor
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    /// One shared Quick Look generation. Its lifetime is owned by the set
    /// of callers waiting on it, not by whichever caller created it.
    @MainActor
    private final class Generation {
        let task: Task<NSImage?, Never>
        var waiters = 0
        var isCompleted = false

        init(task: Task<NSImage?, Never>) {
            self.task = task
        }
    }

    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private let limit = 200
    private var inFlight: [String: Generation] = [:]

    func thumbnail(
        for url: URL,
        size: CGSize,
        revision: AssetRevision? = nil
    ) async -> NSImage? {
        let key = cacheKey(for: url, size: size, revision: revision)
        if let cached = cache[key] {
            return cached
        }
        // One Quick Look request per key, shared by every caller looking at
        // the same row and revision. No single caller owns its lifetime.
        let generation: Generation
        if let existing = inFlight[key] {
            generation = existing
        } else {
            let task = Task { @MainActor [weak self] in
                guard let self else { return nil as NSImage? }
                let image = await Self.generate(for: url, size: size)
                if let image {
                    self.store(image, key: key)
                }
                return image
            }
            generation = Generation(task: task)
            inFlight[key] = generation
        }
        generation.waiters += 1

        let waiter = ThumbnailWaiter()
        Task { @MainActor [weak self] in
            let image = await generation.task.value
            generation.isCompleted = true
            if self?.inFlight[key] === generation {
                self?.inFlight[key] = nil
            }
            waiter.finish(image)
        }
        let image = await waiter.wait()
        generation.waiters -= 1
        if waiter.wasCancelled,
           generation.waiters <= 0,
           !generation.isCompleted {
            // Every caller left. Cancel the shared request so it does not
            // keep decoding a row nobody is looking at.
            if inFlight[key] === generation {
                inFlight[key] = nil
            }
            generation.task.cancel()
        }
        return image
    }

    @MainActor
    private static func generate(
        for url: URL,
        size: CGSize
    ) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 2,
            representationTypes: .all
        )
        let box = ThumbnailRequestBox(request: request)
        let gate = ThumbnailWaiter()
        return await withTaskCancellationHandler {
            QLThumbnailGenerator.shared.generateBestRepresentation(
                for: request
            ) { representation, _ in
                let image: NSImage?
                if let representation,
                   representation.type != .icon {
                    image = NSImage(
                        cgImage: representation.cgImage,
                        size: NSSize(
                            width: representation.cgImage.width,
                            height: representation.cgImage.height
                        )
                    )
                } else {
                    image = nil
                }
                Task { @MainActor in
                    gate.finish(image)
                }
            }
            return await gate.wait()
        } onCancel: {
            // A cancelled Quick Look request does not guarantee its
            // completion handler runs; resume the gate ourselves.
            QLThumbnailGenerator.shared.cancel(box.request)
            Task { @MainActor in
                gate.cancel()
            }
        }
    }

    private func cacheKey(
        for url: URL,
        size: CGSize,
        revision: AssetRevision?
    ) -> String {
        let identity: String
        if let revision {
            identity = revision.token
        } else {
            // A caller without a revision still needs more than mtime: a
            // same-timestamp replacement must not reuse the old thumbnail.
            let values = try? url.resourceValues(
                forKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .fileResourceIdentifierKey
                ]
            )
            let modified = values?.contentModificationDate?
                .timeIntervalSince1970 ?? 0
            let fileBytes = values?.fileSize ?? 0
            let identifier = values?.fileResourceIdentifier.map {
                String(describing: $0)
            } ?? "-"
            identity = "\(modified)|\(fileBytes)|\(identifier)"
        }
        let width = NumericConversion.int(size.width) ?? 0
        let height = NumericConversion.int(size.height) ?? 0
        return "\(url.path)|\(identity)|\(width)x\(height)"
    }

    private func store(_ image: NSImage, key: String) {
        cache[key] = image
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}

/// One caller's wait for shared thumbnail work. Cancellation resolves only
/// this continuation; the shared generation keeps running for other callers.
@MainActor
private final class ThumbnailWaiter {
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var result: NSImage?
    private var isFinished = false
    private var isCancelled = false
    private(set) var wasCancelled = false

    func wait() async -> NSImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isCancelled {
                    continuation.resume(returning: nil)
                } else if isFinished {
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func finish(_ image: NSImage?) {
        guard !isFinished, !isCancelled else { return }
        isFinished = true
        result = image
        continuation?.resume(returning: image)
        continuation = nil
    }

    func cancel() {
        guard !isFinished, !isCancelled else { return }
        isCancelled = true
        wasCancelled = true
        continuation?.resume(returning: nil)
        continuation = nil
    }
}

struct ProjectAssetThumbnailView: View {
    let asset: ProjectAsset

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: asset.kind.icon)
                    .font(.system(size: AppTheme.TypeScale.body))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: AppTheme.IconSize.row, height: AppTheme.IconSize.row)
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppTheme.Radius.micro,
                style: .continuous
            )
        )
        .task(id: asset.revision.token) {
            // A new revision invalidates the image on screen immediately.
            // Otherwise an asset that changed to an excluded kind would keep
            // the old thumbnail forever, because the early return below
            // never replaces it.
            image = nil
            guard shouldLoadThumbnail else { return }
            let result = await ThumbnailProvider.shared.thumbnail(
                for: asset.url,
                size: CGSize(
                    width: AppTheme.Size.rowThumbnail,
                    height: AppTheme.Size.rowThumbnail
                ),
                revision: asset.revision
            )
            // The revision changed while this request ran; do not let the
            // older thumbnail overwrite the newer one.
            guard !Task.isCancelled else { return }
            image = result
        }
    }

    private var shouldLoadThumbnail: Bool {
        switch asset.kind {
        case .image, .video, .document:
            true
        default:
            false
        }
    }
}
