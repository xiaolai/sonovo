import Darwin
import Foundation

/// Writes files that may hold user content without ever exposing them with
/// default permissions.
///
/// `Data.write(to:)` creates the file with the process umask, then the caller
/// copies the original file's restrictions. A crash or a failure between
/// those steps leaves sensitive bytes readable by others. Creating the file
/// owner-only first makes the restrictive state the default, and the original
/// permissions are applied afterwards.
enum PrivateFileWriter {
    struct Failure: Error {
        let code: Int32
    }

    /// Creates `url` exclusively with `permissions` and writes `data`.
    ///
    /// Returns `false` when a file already exists at `url`; every other
    /// failure throws. The write is synchronized before returning.
    static func createExclusively(
        _ data: Data,
        at url: URL,
        permissions: mode_t = 0o600
    ) throws -> Bool {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL,
            permissions
        )
        if descriptor < 0 {
            if errno == EEXIST { return false }
            throw Failure(code: errno)
        }

        var code: Int32 = 0
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    code = errno
                    return
                }
                offset += written
            }
            if fsync(descriptor) != 0 {
                code = errno
            }
        }

        if close(descriptor) != 0, code == 0 {
            code = errno
        }

        guard code == 0 else {
            unlink(url.path)
            throw Failure(code: code)
        }
        return true
    }
}
