import AppKit
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI

enum QuickLookSupport {
    /// A real thumbnail means the system has a document previewer. The icon
    /// representation is what corrupt or unknown files produce, so it is not
    /// treated as a preview.
    static func canPreview(_ url: URL) async -> Bool {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 512, height: 512),
            scale: 2,
            representationTypes: .all
        )
        let gate = PreviewGate()
        let box = PreviewRequestBox(request: request)
        return await withTaskCancellationHandler {
            // A task cancelled before this point must not submit work at all.
            guard !Task.isCancelled else { return false }
            QLThumbnailGenerator.shared.generateBestRepresentation(
                for: box.request
            ) { representation, _ in
                let available = representation != nil
                    && representation?.type != .icon
                gate.finish(available)
            }
            // Cancellation may have run between the guard and submission;
            // in that case the handler's QL cancel was a no-op.
            if gate.wasCancelled {
                QLThumbnailGenerator.shared.cancel(box.request)
            }
            return await gate.wait()
        } onCancel: {
            // Switching documents must stop the probe now, not after the
            // thumbnail generator finishes a file nobody is looking at.
            QLThumbnailGenerator.shared.cancel(box.request)
            gate.cancel()
        }
    }
}

private struct PreviewRequestBox: @unchecked Sendable {
    let request: QLThumbnailGenerator.Request
}

/// Exactly-once bridge between Quick Look's callback, the caller, and
/// cancellation.
private final class PreviewGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    private var cancelled = false

    func wait() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else if cancelled {
                    lock.unlock()
                    continuation.resume(returning: false)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func finish(_ value: Bool) {
        lock.lock()
        guard result == nil, !cancelled else {
            lock.unlock()
            return
        }
        result = value
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func cancel() {
        lock.lock()
        guard result == nil, !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: false)
    }
}

@MainActor
struct QuickLookDocumentView: View {
    let asset: ProjectAsset

    private enum Check: Equatable {
        case checking
        case preview
        case metadata
    }

    @State private var check: Check = .checking

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header
            Divider()
            switch check {
            case .checking:
                ProgressView("Preparing preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .preview:
                QuickLookPreview(url: asset.url)
            case .metadata:
                metadataState
            }
        }
        .viewerCard()
        .task {
            check = await QuickLookSupport.canPreview(asset.url)
                ? .preview
                : .metadata
        }
    }

    private var header: some View {
        AssetViewerHeader(
            asset: asset,
            subtitle: "System preview · \(asset.fileExtension.uppercased())"
        ) {
            Button("Open in Default App") {
                NSWorkspace.shared.open(asset.url)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var metadataState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "doc")
                .font(
                    .system(
                        size: AppTheme.TypeScale.displayLarge,
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(.tertiary)
            Text("No system preview")
                .font(.system(size: AppTheme.TypeScale.lg, weight: .medium))
            Text(
                "macOS has no Quick Look previewer for this file. "
                    + "Its metadata is available, and the default app can open it."
            )
            .font(.system(size: AppTheme.TypeScale.sm))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: AppTheme.Layout.emptyDescriptionMaxWidth)
            AssetMetadataSummary(
                fields: metadataFields,
                rowSpacing: AppTheme.Spacing.xs
            )
            Button("Open in Default App") {
                NSWorkspace.shared.open(asset.url)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var metadataFields: [AssetMetadataSummary.Field] {
        asset.viewerMetadataFields(
            includeKind: false,
            includeMissingModified: false,
            monospacedValues: true
        )
    }
}

private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            // The system can refuse to create a preview view after a
            // thumbnail suggested one exists. A message beats a crash.
            return unavailableView()
        }
        view.autoresizingMask = [.width, .height]
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let preview = view as? QLPreviewView else { return }
        let current = preview.previewItem as? NSURL as URL?
        if current != url {
            preview.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? QLPreviewView)?.previewItem = nil
    }

    private func unavailableView() -> NSView {
        let container = NSView()
        let label = NSTextField(
            labelWithString: "Preview unavailable — open the file in its default app."
        )
        label.font = .systemFont(ofSize: AppTheme.TypeScale.sm)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }
}
