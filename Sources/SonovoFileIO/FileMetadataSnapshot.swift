import Foundation
import Darwin

/// Identity and timestamps of one file revision, read with `stat` so it cannot
/// be served from the URL resource cache. A rename changes `ctime` while
/// preserving `mtime`; an in-place write changes both.
package struct FileMetadataSnapshot: Equatable, Sendable {
    package init(device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64,
                 changedSeconds: Int64, changedNanoseconds: Int64) {
        self.device = device; self.inode = inode; self.size = size
        self.modifiedSeconds = modifiedSeconds; self.modifiedNanoseconds = modifiedNanoseconds
        self.changedSeconds = changedSeconds; self.changedNanoseconds = changedNanoseconds
    }
    package let device: UInt64
    package let inode: UInt64
    package let size: Int64
    package let modifiedSeconds: Int64
    package let modifiedNanoseconds: Int64
    package let changedSeconds: Int64
    package let changedNanoseconds: Int64

    /// The same file with the same bytes, ignoring the `ctime` update that a
    /// rename itself performs.
    package func sameRevision(as other: FileMetadataSnapshot) -> Bool {
        device == other.device
            && inode == other.inode
            && size == other.size
            && modifiedSeconds == other.modifiedSeconds
            && modifiedNanoseconds == other.modifiedNanoseconds
    }

    package static func read(_ url: URL) -> FileMetadataSnapshot? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation {
            path -> Int32 in
            guard let path else { return Int32(-1) }
            return stat(path, &info)
        }
        guard result == 0 else { return nil }
        return FileMetadataSnapshot(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

}
