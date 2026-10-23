import Foundation
import WebKit

/// A local preview has no reason to buffer an arbitrarily large file; 64 MiB
/// is far above any image, font, or stylesheet a document loads.
private let maximumLocalDocumentBytes: Int64 = 64 * 1024 * 1024

@MainActor
final class LocalDocumentSchemeHandler: NSObject, WKURLSchemeHandler {
    private let resolver: LocalDocumentResolver
    /// The document directory, pinned once. Every resource is opened
    /// relative to this descriptor, so replacing an intermediate directory
    /// with a symlink cannot redirect a read outside the root.
    private let rootDescriptor: Int32
    private var activeTasks: Set<ObjectIdentifier> = []
    private var readTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(resolver: LocalDocumentResolver) {
        self.resolver = resolver
        rootDescriptor = resolver.canonicalRootPath.withCString { path in
            Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC
            )
        }
        super.init()
    }

    deinit {
        if rootDescriptor >= 0 {
            close(rootDescriptor)
        }
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(task)
        activeTasks.insert(identifier)

        guard (task.request.httpMethod ?? "GET").uppercased() == "GET" else {
            respond(
                task,
                identifier: identifier,
                status: 405,
                headers: ["Allow": "GET"],
                body: Data()
            )
            return
        }
        guard let url = task.request.url else {
            activeTasks.remove(identifier)
            return
        }

        switch resolver.resolve(url) {
        case .badRequest:
            respond(task, identifier: identifier, status: 400, body: Data())
        case .forbidden, .notFound:
            respond(task, identifier: identifier, status: 404, body: Data())
        case .unsupportedType:
            respond(task, identifier: identifier, status: 415, body: Data())
        case .file(let resource):
            read(resource, for: task, identifier: identifier)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(task)
        readTasks.removeValue(forKey: identifier)?.cancel()
        activeTasks.remove(identifier)
    }

    private func read(
        _ resource: LocalDocumentResolver.Resource,
        for task: WKURLSchemeTask,
        identifier: ObjectIdentifier
    ) {
        switch validate(resource) {
        case .invalid(let status):
            respond(
                task,
                identifier: identifier,
                status: status,
                body: Data()
            )
        case .valid(let descriptor):
            startReading(
                descriptor,
                resource: resource,
                task: task,
                identifier: identifier
            )
        }
    }

    private enum DescriptorValidation {
        case valid(Int32)
        /// Every rejection closes its descriptor in `validate`, so the
        /// caller only has to turn the status into a response.
        case invalid(status: Int)
    }

    /// Opens and verifies the resource descriptor in one place. The identity
    /// and size checks share the same cleanup, so no rejection path can
    /// leak the descriptor.
    private func validate(
        _ resource: LocalDocumentResolver.Resource
    ) -> DescriptorValidation {
        // Open synchronously, immediately after the resolver validated the
        // path. The descriptor's identity is compared with the validated
        // inode/device, so a swap between validation and open is detected
        // before any byte is read.
        // Each component is opened with O_NOFOLLOW from the pinned root
        // descriptor; a swapped symlink anywhere in the path fails instead
        // of redirecting the read.
        let descriptor = openResource(at: resource.url)
        guard descriptor >= 0 else {
            return .invalid(status: 500)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_dev == resource.fileDevice,
              info.st_ino == resource.fileInode else {
            return reject(descriptor, status: 403)
        }
        guard info.st_size >= 0,
              info.st_size <= maximumLocalDocumentBytes else {
            return reject(descriptor, status: 413)
        }
        guard resolver.revalidates(
            resource,
            device: info.st_dev,
            inode: info.st_ino
        ) else {
            return reject(descriptor, status: 403)
        }
        return .valid(descriptor)
    }

    /// The single rejection exit: every failed check closes the descriptor
    /// before returning its status.
    private func reject(
        _ descriptor: Int32,
        status: Int
    ) -> DescriptorValidation {
        close(descriptor)
        return .invalid(status: status)
    }

    private func startReading(
        _ descriptor: Int32,
        resource: LocalDocumentResolver.Resource,
        task: WKURLSchemeTask,
        identifier: ObjectIdentifier
    ) {
        let work = Task { @MainActor [weak self] in
            defer { self?.readTasks[identifier] = nil }
            let data: Data
            do {
                data = try await Self.readData(descriptor: descriptor)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.activeTasks.contains(identifier) else {
                    return
                }
                let status: Int
                if let error = error as? POSIXError,
                   error.code == .EFBIG {
                    status = 413
                } else {
                    status = 500
                }
                self.respond(
                    task,
                    identifier: identifier,
                    status: status,
                    body: Data()
                )
                return
            }
            guard let self, self.activeTasks.contains(identifier) else {
                return
            }
            self.respond(
                task,
                identifier: identifier,
                status: 200,
                headers: [
                    "Content-Type": resource.mimeType,
                    "Content-Security-Policy":
                        self.resolver.contentSecurityPolicy
                ],
                body: data
            )
        }
        readTasks[identifier] = work
    }

    /// Opens a canonical resource path relative to the pinned root. The
    /// final component and every intermediate directory must be real
    /// entries, not symlinks.
    private func openResource(at url: URL) -> Int32 {
        guard rootDescriptor >= 0 else { return -1 }
        let rootPath = resolver.canonicalRootPath
        guard url.path.hasPrefix(rootPath) else { return -1 }
        let components = url.path.dropFirst(rootPath.count)
            .split(separator: "/")
            .map(String.init)
        guard let name = components.last else { return -1 }

        var directory = dup(rootDescriptor)
        guard directory >= 0 else { return -1 }
        for component in components.dropLast() {
            let next = component.withCString {
                Darwin.openat(
                    directory,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            close(directory)
            guard next >= 0 else { return -1 }
            directory = next
        }
        let descriptor = name.withCString {
            // O_NONBLOCK keeps a FIFO swapped in after validation from
            // blocking the main actor before fstat can reject its type.
            Darwin.openat(
                directory,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            )
        }
        close(directory)
        return descriptor
    }

    /// Chunked so cancellation is observed for a large document. The
    /// descriptor is opened and identity-checked by the caller; this
    /// function owns closing it.
    nonisolated private static func readData(
        descriptor: Int32
    ) async throws -> Data {
        let work = Task.detached(priority: .userInitiated) {
            defer { close(descriptor) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(
                        descriptor,
                        bytes.baseAddress,
                        bytes.count
                    )
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
                if count == 0 { break }
                data.append(contentsOf: buffer[0..<count])
                // The descriptor's initial size was bounded, but a writer
                // can grow the file while it is read. Stop at the same cap;
                // memory stays bounded by the cap plus one chunk.
                if data.count > Int(maximumLocalDocumentBytes) {
                    throw POSIXError(.EFBIG)
                }
            }
            return data
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func respond(
        _ task: WKURLSchemeTask,
        identifier: ObjectIdentifier,
        status: Int,
        headers: [String: String] = [:],
        body: Data
    ) {
        guard activeTasks.contains(identifier) else { return }
        var responseHeaders = headers
        responseHeaders["Content-Length"] = String(body.count)
        responseHeaders["Cache-Control"] = "no-store"
        responseHeaders["X-Content-Type-Options"] = "nosniff"

        guard let response = HTTPURLResponse(
            url: task.request.url ?? URL(string: "\(LocalDocumentResolver.scheme)://\(LocalDocumentResolver.host)/")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: responseHeaders
        ) else {
            activeTasks.remove(identifier)
            return
        }
        task.didReceive(response)
        if !body.isEmpty {
            task.didReceive(body)
        }
        task.didFinish()
        activeTasks.remove(identifier)
    }
}
