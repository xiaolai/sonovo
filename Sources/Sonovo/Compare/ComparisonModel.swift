import AppKit
import Foundation
import Observation

enum ComparisonSide: String, CaseIterable, Identifiable, Sendable {
    case leading
    case trailing

    var id: String { rawValue }
}

struct ComparisonMetadataRow: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let leading: String
    let trailing: String
    /// Computed from the raw values, not the formatted strings: two file
    /// sizes that round to the same label are still different files.
    let differs: Bool
}

/// Two images compared without a timeline. The model owns the shared view
/// state; geometry is pure and testable. There is no score, ranking, or
/// recommendation — a comparison shows what is there.
@MainActor
@Observable
final class ComparisonModel {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case sideBySide
        case wipe

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sideBySide: "Side by Side"
            case .wipe: "Wipe"
            }
        }
    }

    nonisolated static let minimumWipeFraction: Double = 0.02
    nonisolated static let maximumWipeFraction: Double = 0.98
    nonisolated static let defaultWipeFraction: Double = 0.5
    nonisolated static let minimumZoom: CGFloat = 0.001
    nonisolated static let maximumZoom: CGFloat = 16

    let leadingAsset: ProjectAsset
    let trailingAsset: ProjectAsset
    let leading: ImageDocumentModel
    let trailing: ImageDocumentModel

    var mode: Mode = .sideBySide
    private(set) var wipeFraction = ComparisonModel.defaultWipeFraction
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    /// A manual anchor for the trailing image, in display points from center.
    /// Different dimensions are aligned by center by default; this offset is
    /// the only registration the feature claims.
    var alignment: CGSize = .zero
    var isAligning = false

    init(
        leading: ProjectAsset,
        trailing: ProjectAsset,
        leadingModel: ImageDocumentModel? = nil
    ) {
        self.leadingAsset = leading
        self.trailingAsset = trailing
        // Reuse the single view's decoded primary instead of decoding the
        // same file twice and holding two full-size bitmaps.
        self.leading = leadingModel ?? ImageDocumentModel(url: leading.url)
        self.trailing = ImageDocumentModel(url: trailing.url)
    }

    func load() async {
        async let leadingLoad: Void = leading.load()
        async let trailingLoad: Void = trailing.load()
        _ = await (leadingLoad, trailingLoad)
    }

    /// Layout uses the source dimensions (with orientation applied), not the
    /// decoded preview's size. A 12,000-pixel image and a 6,000-pixel image
    /// must keep their true relative scale even when both are downsampled.
    var leadingDisplaySize: CGSize? { leading.metadata?.displaySize }
    var trailingDisplaySize: CGSize? { trailing.metadata?.displaySize }

    var canUseActualSize: Bool {
        Self.canUseActualSize(
            leadingReady: leading.image != nil,
            trailingReady: trailing.image != nil,
            leadingDownsampled: leading.isDownsampled,
            trailingDownsampled: trailing.isDownsampled
        )
    }

    nonisolated static func canUseActualSize(
        leadingReady: Bool,
        trailingReady: Bool,
        leadingDownsampled: Bool,
        trailingDownsampled: Bool
    ) -> Bool {
        leadingReady && trailingReady
            && !leadingDownsampled && !trailingDownsampled
    }

    var metadataRows: [ComparisonMetadataRow] {
        Self.metadataRows(
            leading: leading.metadata,
            trailing: trailing.metadata,
            leadingFallbackSize: leadingAsset.size,
            trailingFallbackSize: trailingAsset.size
        )
    }

    // MARK: - View state

    func setWipe(fraction: Double) {
        wipeFraction = Self.clampWipe(fraction)
    }

    func fit() {
        zoom = 1
        pan = .zero
    }

    func actualSize(fit: CGFloat, displayScale: CGFloat) {
        guard canUseActualSize else { return }
        zoom = Self.actualSizeZoom(
            fit: fit,
            displayScale: displayScale
        )
        pan = .zero
    }

    func resetAlignment() {
        alignment = .zero
    }

    func offset(for side: ComparisonSide) -> CGSize {
        switch side {
        case .leading:
            pan
        case .trailing:
            CGSize(
                width: pan.width + alignment.width,
                height: pan.height + alignment.height
            )
        }
    }

    // MARK: - Geometry

    /// Both images render at the same source-pixel scale, computed so the
    /// larger image fits the pane. The smaller image is consequently smaller,
    /// which is the point of a comparison rather than a bug.
    nonisolated static func fitScale(
        leading: CGSize?,
        trailing: CGSize?,
        in pane: CGSize
    ) -> CGFloat {
        let candidates: [CGSize?] = [leading, trailing]
        let sizes: [CGSize] = candidates.compactMap { size -> CGSize? in
            guard let size, size.width > 0, size.height > 0 else {
                return nil
            }
            return size
        }
        guard let width = sizes.map({ $0.width }).max(),
              let height = sizes.map({ $0.height }).max(),
              pane.width > 0,
              pane.height > 0 else {
            return 0
        }
        return min(pane.width / width, pane.height / height)
    }

    nonisolated static func clampWipe(_ value: Double) -> Double {
        min(max(value, minimumWipeFraction), maximumWipeFraction)
    }

    /// One source pixel per physical display pixel. This is not clamped to
    /// the gesture range: a tiny image fitted large needs a zoom below the
    /// ordinary minimum to be genuinely 1:1.
    nonisolated static func actualSizeZoom(
        fit: CGFloat,
        displayScale: CGFloat
    ) -> CGFloat {
        guard fit > 0, displayScale > 0 else { return 1 }
        return 1 / (fit * displayScale)
    }

    nonisolated static func dividerX(
        in width: CGFloat,
        fraction: Double
    ) -> CGFloat {
        width * CGFloat(clampWipe(fraction))
    }

    nonisolated static func wipeClipRect(
        in size: CGSize,
        fraction: Double
    ) -> CGRect {
        let x = dividerX(in: size.width, fraction: fraction)
        return CGRect(
            x: x,
            y: 0,
            width: max(size.width - x, 0),
            height: size.height
        )
    }

    // MARK: - Metadata diff

    nonisolated static func metadataRows(
        leading: ImageDocumentMetadata?,
        trailing: ImageDocumentMetadata?,
        leadingFallbackSize: Int64,
        trailingFallbackSize: Int64
    ) -> [ComparisonMetadataRow] {
        let leadingSize = leading?.fileSize ?? leadingFallbackSize
        let trailingSize = trailing?.fileSize ?? trailingFallbackSize
        return [
            ComparisonMetadataRow(
                id: "dimensions",
                label: "Dimensions",
                leading: dimensions(leading),
                trailing: dimensions(trailing),
                differs: leading?.displaySize != trailing?.displaySize
            ),
            ComparisonMetadataRow(
                id: "profile",
                label: "Color profile",
                leading: profile(leading),
                trailing: profile(trailing),
                differs: profile(leading) != profile(trailing)
            ),
            ComparisonMetadataRow(
                id: "size",
                label: "File size",
                leading: fileSize(leadingSize),
                trailing: fileSize(trailingSize),
                differs: leadingSize != trailingSize
            )
        ]
    }

    nonisolated private static func dimensions(
        _ metadata: ImageDocumentMetadata?
    ) -> String {
        guard let metadata else { return "—" }
        // The displayed size is what the eye compares. A portrait photo whose
        // pixels are stored landscape is 480×640 here, not 640×480.
        let size = metadata.displaySize
        return "\(Int(size.width))×\(Int(size.height))"
    }

    nonisolated private static func profile(
        _ metadata: ImageDocumentMetadata?
    ) -> String {
        guard let metadata else { return "—" }
        return metadata.profileName ?? metadata.colorModel ?? "—"
    }

    nonisolated private static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }
}
