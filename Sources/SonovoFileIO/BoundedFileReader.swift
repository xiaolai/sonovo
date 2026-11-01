import Foundation

public enum FileReadError: Error, Equatable {
    case fileTooLarge(byteCount: Int)
    case tooManyLines(Int)
    case invalidLimits
}

/// Allocation bounds are supplied by the document family, never a Markdown
/// default. Counting LF bytes deliberately preserves the existing read policy.
public enum BoundedFileReader {
    public static func read(
        _ url: URL,
        maximumBytes: Int,
        maximumLines: Int? = nil
    ) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max,
              maximumLines.map({ $0 >= 0 }) ?? true else {
            throw FileReadError.invalidLimits
        }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maximumBytes {
            throw FileReadError.fileTooLarge(byteCount: size)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let cap = maximumBytes + 1
        var data = Data()
        var lines = 0
        while data.count < cap {
            let chunk = try handle.read(upToCount: min(1 << 18, cap - data.count))
            guard let chunk, !chunk.isEmpty else { break }
            if let maximumLines {
                for byte in chunk where byte == 0x0A {
                    lines += 1
                    if lines > maximumLines {
                        throw FileReadError.tooManyLines(lines)
                    }
                }
            }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else {
            throw FileReadError.fileTooLarge(byteCount: data.count)
        }
        return data
    }
}
