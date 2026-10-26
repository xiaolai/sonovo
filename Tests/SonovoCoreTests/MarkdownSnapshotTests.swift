import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown snapshot store")
struct MarkdownSnapshotStoreTests {
    private func makeStore(
        byteQuota: Int = 1_000,
        perFileQuota: Int = 2
    ) throws -> (MarkdownSnapshotStore, URL, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-snap-\(UUID().uuidString)")
        let root = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let store = MarkdownSnapshotStore(
            baseDirectory: base.appendingPathComponent(
                "store",
                isDirectory: true
            ),
            projectRoot: root,
            projectByteQuota: byteQuota,
            perFileQuota: perFileQuota
        )
        return (store, base, root)
    }

    @Test("Capture and load round-trips the exact bytes")
    func roundTrip() async throws {
        let (store, base, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let bytes = Data("hello bytes".utf8)
        guard case let .captured(record) = await store.capture(
            rawBytes: bytes,
            relativePath: "a.md"
        ) else {
            Issue.record("capture failed")
            return
        }
        let loaded = await store.load(id: record.id)
        guard case let .bytes(data, _) = loaded else {
            Issue.record("load failed")
            return
        }
        #expect(data == bytes)
        let records = await store.records(for: "a.md")
        #expect(records.count == 1)
    }

    @Test("The per-file quota stops capture")
    func perFileQuota() async throws {
        let (store, base, _) = try makeStore(perFileQuota: 1)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = await store.capture(
            rawBytes: Data("one".utf8),
            relativePath: "a.md"
        )
        let second = await store.capture(
            rawBytes: Data("two".utf8),
            relativePath: "a.md"
        )
        guard case .captured = first else {
            Issue.record("first capture should succeed")
            return
        }
        #expect(second == .evidenceUnavailable)
    }

    @Test("The project byte quota stops capture")
    func projectQuota() async throws {
        let (store, base, _) = try makeStore(
            byteQuota: 20,
            perFileQuota: 10
        )
        defer { try? FileManager.default.removeItem(at: base) }
        let first = await store.capture(
            rawBytes: Data(repeating: 0x61, count: 15),
            relativePath: "a.md"
        )
        let second = await store.capture(
            rawBytes: Data(repeating: 0x62, count: 15),
            relativePath: "b.md"
        )
        guard case .captured = first else {
            Issue.record("first capture should succeed")
            return
        }
        #expect(second == .evidenceUnavailable)
    }

    @Test("A missing blob reads as evidence unavailable")
    func missingBlob() async throws {
        let (store, base, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        guard case let .captured(record) = await store.capture(
            rawBytes: Data("bytes".utf8),
            relativePath: "a.md"
        ) else {
            Issue.record("capture failed")
            return
        }
        let storeDirectory = base.appendingPathComponent(
            "store",
            isDirectory: true
        )
        let projectKey = try #require(
            try FileManager.default.contentsOfDirectory(
                atPath: storeDirectory.path
            ).first
        )
        let blob = storeDirectory
            .appendingPathComponent(projectKey)
            .appendingPathComponent("blobs")
            .appendingPathComponent("\(record.sha256).bin")
        try FileManager.default.removeItem(at: blob)
        #expect(await store.load(id: record.id) == .evidenceUnavailable)
        let recovery = await store.recover()
        #expect(recovery.missingBlobs == [record.id])
    }

    @Test("Recovery removes an orphan blob")
    func orphanRecovery() async throws {
        let (store, base, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        guard case .captured = await store.capture(
            rawBytes: Data("bytes".utf8),
            relativePath: "a.md"
        ) else {
            Issue.record("capture failed")
            return
        }
        let storeDirectory = base.appendingPathComponent(
            "store",
            isDirectory: true
        )
        let projectKey = try #require(
            try FileManager.default.contentsOfDirectory(
                atPath: storeDirectory.path
            ).first
        )
        let orphan = storeDirectory
            .appendingPathComponent(projectKey)
            .appendingPathComponent("blobs")
            .appendingPathComponent("deadbeef.bin")
        try Data([0x00]).write(to: orphan)
        let recovery = await store.recover()
        #expect(recovery.orphanBlobsRemoved == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }
}

@Suite("Markdown snapshot restore")
@MainActor
struct MarkdownSnapshotRestoreTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    @Test("A BOM+CRLF snapshot restores exact bytes and undo/redo")
    func byteExactRestore() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        let current = Data("current\n".utf8)
        try current.write(to: url)

        let snapshot = Data([0xEF, 0xBB, 0xBF])
            + Data("title\r\n\r\nbody\r\n".utf8)
        let document = try MarkdownDocument(loading: url)
        _ = try await document.restore(
            rawBytes: snapshot,
            expectedDiskBytes: current
        )
        #expect(try Data(contentsOf: url) == snapshot)
        #expect(document.hasBOM)
        #expect(document.lineEnding == .crlf)
        #expect(document.source == "title\n\nbody\n")
        #expect(!document.isDirty)

        document.undoManager.undo()
        #expect(document.source == "current\n")
        #expect(!document.hasBOM)
        #expect(document.lineEnding == .lf)
        #expect(document.isDirty)

        document.undoManager.redo()
        #expect(document.source == "title\n\nbody\n")
        #expect(document.hasBOM)
    }

    @Test("A metadata-only restore is dirty and undoable")
    func metadataOnly() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        let current = Data("a\n".utf8)
        try current.write(to: url)

        let document = try MarkdownDocument(loading: url)
        _ = try await document.restore(
            rawBytes: Data("a\r\n".utf8),
            expectedDiskBytes: current
        )
        #expect(document.source == "a\n")
        #expect(document.lineEnding == .crlf)
        // The restore saved through the CAS path, so the document is clean
        // until undo moves it off the saved metadata baseline.
        #expect(!document.isDirty)
        document.undoManager.undo()
        #expect(document.lineEnding == .lf)
        #expect(document.isDirty)
    }

    @Test("A stale disk refuses before mutation")
    func staleDisk() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("now\n".utf8).write(to: url)
        let document = try MarkdownDocument(loading: url)
        await #expect(throws: MarkdownRestoreError.staleDisk) {
            _ = try await document.restore(
                rawBytes: Data("snapshot\n".utf8),
                expectedDiskBytes: Data("different\n".utf8)
            )
        }
        #expect(document.source == "now\n")
    }

    @Test("Mixed and lone-CR encodings refuse")
    func unsupportedEncodings() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("x\n".utf8).write(to: url)
        let document = try MarkdownDocument(loading: url)

        await #expect(throws: MarkdownRestoreError.unsupportedEncoding) {
            _ = try await document.restore(
                rawBytes: Data("a\nb\r\n".utf8),
                expectedDiskBytes: nil
            )
        }
        await #expect(throws: MarkdownRestoreError.unsupportedEncoding) {
            _ = try await document.restore(
                rawBytes: Data("a\rb\n".utf8),
                expectedDiskBytes: nil
            )
        }
    }

    @Test("A 5 MB snapshot restores editable for the session")
    func largeRestore() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("x\n".utf8).write(to: url)
        let document = try MarkdownDocument(loading: url)

        let big = Data(repeating: 0x61, count: 5 * 1024 * 1024)
        _ = try await document.restore(
            rawBytes: big,
            expectedDiskBytes: nil
        )
        #expect(document.isLarge)
        #expect(document.forcedSourceReason == .largeRestored)
        #expect(!document.isReadOnly)
        #expect(try Data(contentsOf: url).count == big.count)

        let reopened = try MarkdownDocument(loading: url)
        #expect(reopened.isReadOnly)
        #expect(reopened.forcedSourceReason == .large)
    }

    @Test("A snapshot over the read cap refuses before mutation")
    func tooLarge() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("x\n".utf8).write(to: url)
        let document = try MarkdownDocument(loading: url)
        let huge = Data(
            repeating: 0x61,
            count: MarkdownLimits.maxReadBytes + 1
        )
        await #expect(throws: MarkdownRestoreError.tooLarge) {
            _ = try await document.restore(
                rawBytes: huge,
                expectedDiskBytes: nil
            )
        }
        #expect(document.source == "x\n")
    }
}
