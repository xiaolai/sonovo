import SonovoDomainTypes
import AppKit
import CoreImage
import Foundation
import ImageIO
import Observation

package struct ImageDocumentMetadata: Equatable, Sendable {

    package init(
        pixelWidth: Int,
        pixelHeight: Int,
        colorModel: String?,
        profileName: String?,
        dpiWidth: Double?,
        dpiHeight: Double?,
        orientation: Int?,
        exifSummary: String?,
        fileSize: Int64
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.colorModel = colorModel
        self.profileName = profileName
        self.dpiWidth = dpiWidth
        self.dpiHeight = dpiHeight
        self.orientation = orientation
        self.exifSummary = exifSummary
        self.fileSize = fileSize
    }

    package let pixelWidth: Int
    package let pixelHeight: Int
    package let colorModel: String?
    package let profileName: String?
    package let dpiWidth: Double?
    package let dpiHeight: Double?
    package let orientation: Int?
    package let exifSummary: String?
    package let fileSize: Int64

    /// The size the image occupies once EXIF orientation is applied. Stored
    /// pixels stay raw; a portrait photo is 480×640 here, not 640×480.
    package var displaySize: CGSize {
        let width = CGFloat(pixelWidth)
        let height = CGFloat(pixelHeight)
        switch orientation ?? 1 {
        case 5, 6, 7, 8:
            return CGSize(width: height, height: width)
        default:
            return CGSize(width: width, height: height)
        }
    }
}

@MainActor
@Observable
package final class ImageDocumentModel {
    package enum State: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    package nonisolated static let downsampleThreshold = 60_000_000
    package nonisolated static let maximumFullDimension = 8_192
    package nonisolated static let previewDimension = 4_096

    package private(set) var state: State = .idle
    package private(set) var image: NSImage?
    package private(set) var metadata: ImageDocumentMetadata?
    package private(set) var isDownsampled = false

    package let url: URL
    private var loadTask: Task<DecodeResult, Never>?
    private var loadToken: UInt64 = 0

    package init(url: URL) {
        self.url = url
    }

    package func load() async {
        if state == .ready { return }
        var retriedCancellation = false
        while true {
            let outcome = await loadOnce()
            guard outcome == .cancelled else { return }
            if Task.isCancelled || retriedCancellation {
                return
            }
            // A caller can join a decode that its owner already cancelled.
            // Retrying once prevents a visible viewer from staying idle.
            retriedCancellation = true
        }
    }

    /// Re-reads the file, discarding the cached decode. Used when the
    /// underlying asset's revision changes on disk.
    package func reload() async {
        loadTask?.cancel()
        loadTask = nil
        loadToken &+= 1
        state = .idle
        image = nil
        metadata = nil
        isDownsampled = false
        await load()
    }

    private enum LoadOutcome {
        case finished
        case cancelled
    }

    private func loadOnce() async -> LoadOutcome {
        if state == .ready { return .finished }
        // Coalesce concurrent callers onto one decode. Two loads started
        // during `.loading` could otherwise finish out of order and let an
        // older read overwrite a newer one.
        let task: Task<DecodeResult, Never>
        let token: UInt64
        if let existing = loadTask {
            task = existing
            token = loadToken
        } else {
            state = .loading
            loadToken &+= 1
            token = loadToken
            let url = self.url
            task = Task.detached(priority: .userInitiated) {
                Self.decode(url: url)
            }
            loadTask = task
        }
        // Wait for the shared decode even if this caller is cancelled. A
        // waiter must not cancel work that other visible viewers are still
        // awaiting; the decode is bounded and publishes once.
        let result = await task.value
        // A waiter from the previous decode can resume after a retry has
        // started; only the current token may publish.
        guard token == loadToken else { return .finished }
        loadTask = nil
        switch result {
        case .cancelled:
            if state == .loading { state = .idle }
            return .cancelled
        case .success(let decoded):
            image = NSImage(
                cgImage: decoded.image,
                size: NSSize(
                    width: decoded.image.width,
                    height: decoded.image.height
                )
            )
            metadata = decoded.metadata
            isDownsampled = decoded.downsampled
            state = .ready
            return .finished
        case .failure(let message):
            image = nil
            metadata = nil
            state = .failed(message)
            return .finished
        }
    }

    package nonisolated static func displayPolicy(
        width: Int,
        height: Int
    ) -> (maxPixel: Int, downsampled: Bool) {
        let pixels = width.multipliedReportingOverflow(by: height)
        let tooManyPixels = pixels.overflow
            || pixels.partialValue > downsampleThreshold
        let tooWide = max(width, height) > maximumFullDimension
        if tooManyPixels || tooWide {
            return (previewDimension, true)
        }
        return (max(width, height), false)
    }

    // MARK: - Decoding (off the main actor)

    private struct Decoded: @unchecked Sendable {
        let image: CGImage
        let metadata: ImageDocumentMetadata
        let downsampled: Bool
    }

    private enum DecodeResult: @unchecked Sendable {
        case success(Decoded)
        case failure(String)
        case cancelled
    }

    nonisolated private static let rawExtensions: Set<String> = [
        "dng", "cr3", "arw", "nef"
    ]

    nonisolated private static func decode(url: URL) -> DecodeResult {
        if Task.isCancelled { return .cancelled }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))
            .flatMap(\.fileSize).map(Int64.init) ?? 0
        let extensionName = url.pathExtension.lowercased()

        if rawExtensions.contains(extensionName),
           let image = decodeRAW(url: url, fileSize: fileSize) {
            return image
        }

        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return .failure(
                "This image format is not supported by the system decoder."
            )
        }
        if Task.isCancelled { return .cancelled }
        let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            nil
        ) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else {
            return .failure("The image has no readable dimensions.")
        }
        let policy = displayPolicy(width: width, height: height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: policy.maxPixel
        ]
        if Task.isCancelled { return .cancelled }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return .failure(
                "This image could not be decoded. It may be corrupt or use "
                    + "an unsupported codec."
            )
        }
        if Task.isCancelled { return .cancelled }
        return .success(
            Decoded(
                image: cgImage,
                metadata: metadata(
                    properties: properties,
                    width: width,
                    height: height,
                    fileSize: fileSize
                ),
                downsampled: policy.downsampled
            )
        )
    }

    nonisolated private static func decodeRAW(
        url: URL,
        fileSize: Int64
    ) -> DecodeResult? {
        if Task.isCancelled { return .cancelled }
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let native = filter.nativeSize
        guard native.width > 0, native.height > 0 else { return nil }
        guard let width = NumericConversion.int(native.width),
              let height = NumericConversion.int(native.height),
              width > 0, height > 0 else {
            // A RAW decoder can report a non-finite native size.
            return nil
        }
        let policy = displayPolicy(width: width, height: height)
        if policy.downsampled {
            filter.scaleFactor = Float(
                Double(policy.maxPixel) / Double(max(width, height))
            )
        }
        if Task.isCancelled { return .cancelled }
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(
            output,
            from: output.extent
        ) else {
            return nil
        }
        if Task.isCancelled { return .cancelled }
        return .success(
            Decoded(
                image: cgImage,
                metadata: ImageDocumentMetadata(
                    pixelWidth: width,
                    pixelHeight: height,
                    colorModel: filter.properties["ColorModel"] as? String,
                    profileName: nil,
                    dpiWidth: nil,
                    dpiHeight: nil,
                    orientation: nil,
                    exifSummary: nil,
                    fileSize: fileSize
                ),
                downsampled: policy.downsampled
            )
        )
    }

    nonisolated private static func metadata(
        properties: [CFString: Any]?,
        width: Int,
        height: Int,
        fileSize: Int64
    ) -> ImageDocumentMetadata {
        ImageDocumentMetadata(
            pixelWidth: width,
            pixelHeight: height,
            colorModel: properties?[kCGImagePropertyColorModel] as? String,
            profileName: properties?[kCGImagePropertyProfileName] as? String,
            dpiWidth: properties?[kCGImagePropertyDPIWidth] as? Double,
            dpiHeight: properties?[kCGImagePropertyDPIHeight] as? Double,
            orientation: properties?[kCGImagePropertyOrientation] as? Int,
            exifSummary: exifSummary(from: properties),
            fileSize: fileSize
        )
    }

    nonisolated private static func exifSummary(
        from properties: [CFString: Any]?
    ) -> String? {
        let tiff = dictionary(
            properties?[kCGImagePropertyTIFFDictionary]
        )
        let exif = dictionary(
            properties?[kCGImagePropertyExifDictionary]
        )

        var parts: [String] = []
        let make = (tiff?[kCGImagePropertyTIFFMake as String] as? String)?
            .trimmingCharacters(in: .whitespaces)
        let model = (tiff?[kCGImagePropertyTIFFModel as String] as? String)?
            .trimmingCharacters(in: .whitespaces)
        if let model, !model.isEmpty {
            // Many cameras repeat the maker in the model; print it once.
            if let make, !make.isEmpty,
               !model.lowercased().hasPrefix(make.lowercased()) {
                parts.append("\(make) \(model)")
            } else {
                parts.append(model)
            }
        } else if let make, !make.isEmpty {
            parts.append(make)
        }

        if let exposure = exif?[kCGImagePropertyExifExposureTime as String]
            as? Double,
           exposure.isFinite,
           exposure > 0 {
            if exposure < 1 {
                let reciprocal = (1 / exposure).rounded()
                if reciprocal.isFinite, reciprocal < Double(Int.max) {
                    parts.append("1/\(Int(reciprocal))s")
                }
            } else if exposure < Double(Int.max) {
                parts.append(String(format: "%.1fs", exposure))
            }
        }
        if let aperture = exif?[kCGImagePropertyExifFNumber as String]
            as? Double,
           aperture > 0 {
            parts.append(String(format: "f/%.1f", aperture))
        }
        let isoValues = exif?[kCGImagePropertyExifISOSpeedRatings as String]
        if let values = isoValues as? [NSNumber],
           let iso = values.first {
            parts.append("ISO \(iso.intValue)")
        } else if let values = isoValues as? [Int],
                  let iso = values.first {
            parts.append("ISO \(iso)")
        }
        if let focal = exif?[kCGImagePropertyExifFocalLength as String]
            as? Double,
           focal.isFinite,
           focal > 0,
           focal.rounded() < Double(Int.max) {
            parts.append("\(Int(focal.rounded())) mm")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    nonisolated private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let value = value as? [String: Any] {
            return value
        }
        if let value = value as? [CFString: Any] {
            var converted: [String: Any] = [:]
            for (key, element) in value {
                converted[key as String] = element
            }
            return converted
        }
        return nil
    }
}
