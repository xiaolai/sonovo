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
            size: CGSize(
                width: AppTheme.Size.previewProbe,
                height: AppTheme.Size.previewProbe
            ),
            scale: AppTheme.Size.previewProbeScale,
            representationTypes: .all
        )
        let box = PreviewRequestBox(request: request)
        return await withTaskCancellationHandler {
            // A task cancelled before this point must not submit work at all.
            guard !Task.isCancelled else { return false }
            guard let representation = try? await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: box.request) else {
                return false
            }
            return representation.type != .icon
        } onCancel: {
            // Switching documents must stop the probe now, not after the
            // thumbnail generator finishes a file nobody is looking at.
            QLThumbnailGenerator.shared.cancel(box.request)
        }
    }
}

private struct PreviewRequestBox: @unchecked Sendable {
    let request: QLThumbnailGenerator.Request
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
    @State private var previewUnavailable = false

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header
            Divider()
            switch check {
            case .checking:
                ProgressView("Preparing preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .preview:
                if previewUnavailable {
                    previewUnavailableState
                } else {
                    QuickLookPreview(
                        url: asset.url,
                        isUnavailable: $previewUnavailable
                    )
                }
            case .metadata:
                metadataState
            }
        }
        .viewerCard()
        .task {
            previewUnavailable = false
            check = await QuickLookSupport.canPreview(asset.url)
                ? .preview
                : .metadata
        }
    }

    private var previewUnavailableState: some View {
        Text("Preview unavailable — open the file in its default app.")
            .font(.system(size: AppTheme.TypeScale.sm))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @Binding var isUnavailable: Bool

    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            // The system can refuse to create a preview view after a
            // thumbnail suggested one exists. Switch the card to a SwiftUI
            // message instead of leaving a hand-built AppKit label behind.
            DispatchQueue.main.async {
                isUnavailable = true
            }
            return NSView()
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
}
