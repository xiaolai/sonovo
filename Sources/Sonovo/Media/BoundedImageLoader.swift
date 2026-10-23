import AppKit
import ImageIO

/// Limits for content that is decoded into a native bitmap.
enum MediaLimits {
    /// Reject an image before decoding it. Compressed data can expand by
    /// hundreds of times; the byte cap is the first line of defence.
    static let maxImageBytes = 16 * 1024 * 1024
    /// The largest side ImageIO may produce. A larger source is downsampled
    /// instead of allocating its full native bitmap.
    static let maxImagePixelDimension = 4_096
}

/// Decodes user-supplied images through ImageIO with a byte cap and a pixel
/// cap. `NSImage(contentsOf:)` and a TIFF round trip both allocate the full
/// native bitmap first, which a crafted image can turn into gigabytes.
enum BoundedImageLoader {
    static func image(at url: URL) -> NSImage? {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey]
        ),
        let size = values.fileSize,
        size <= MediaLimits.maxImageBytes else {
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }
        return image(from: source)
    }

    static func image(from data: Data) -> NSImage? {
        guard data.count <= MediaLimits.maxImageBytes else { return nil }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }
        return image(from: source)
    }

    static func pngData(from data: Data) -> Data? {
        guard let image = image(from: data),
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return representation.representation(using: .png, properties: [:])
    }

    static func pngData(at url: URL) -> Data? {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey]
        ),
        let size = values.fileSize,
        size <= MediaLimits.maxImageBytes,
        let data = try? Data(contentsOf: url) else {
            return nil
        }
        return pngData(from: data)
    }

    private static func image(from source: CGImageSource) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize:
                MediaLimits.maxImagePixelDimension
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
