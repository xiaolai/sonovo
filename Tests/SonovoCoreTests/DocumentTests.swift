import Darwin
import Foundation
import Testing
@testable import SonovoCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sonovo-document-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Pauses a save at a hook so a test can edit the document mid-write.
private final class SaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var released = false

    func markEntered() {
        lock.lock(); entered = true; lock.unlock()
    }

    var hasEntered: Bool {
        lock.lock(); defer { lock.unlock() }
        return entered
    }

    func release() {
        lock.lock(); released = true; lock.unlock()
    }

    var isReleased: Bool {
        lock.lock(); defer { lock.unlock() }
        return released
    }
}

@Suite("Encoding")
struct EncodingTests {
    @Test("Decodes LF, CRLF, BOM, and mixed line endings")
    func decodeConventions() throws {
        let lf = try MarkdownEncoding.decode(Data("a\nb\n".utf8))
        #expect(lf.canonicalText == "a\nb\n")
        #expect(lf.lineEnding == .lf)
        #expect(!lf.hasBOM)

        let crlf = try MarkdownEncoding.decode(Data("a\r\nb\r\n".utf8))
        #expect(crlf.canonicalText == "a\nb\n")
        #expect(crlf.lineEnding == .crlf)

        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(contentsOf: Data("a\n".utf8))
        let withBOM = try MarkdownEncoding.decode(bom)
        #expect(withBOM.hasBOM)
        #expect(withBOM.canonicalText == "a\n")

        let mixed = try MarkdownEncoding.decode(Data("a\r\nb\nc\r\n".utf8))
        #expect(mixed.hadMixedLineEndings)
        #expect(mixed.lineEnding == .crlf)
        #expect(mixed.canonicalText == "a\nb\nc\n")
    }

    @Test("A BOM followed by a U+FEFF keeps that content character")
    func bomAndContentCharacter() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("\u{FEFF}hello\n".utf8))

        let contents = try MarkdownEncoding.decode(data)
        #expect(contents.hasBOM)
        #expect(contents.canonicalText == "\u{FEFF}hello\n")
    }

    @Test("Rejects invalid UTF-8")
    func invalidUTF8() {
        #expect(throws: MarkdownEncodingError.invalidUTF8) {
            _ = try MarkdownEncoding.decode(Data([0xFF, 0xFE, 0x00]))
        }
    }

    @Test("Re-emits BOM and CRLF")
    func encodeConventions() throws {
        let bytes = MarkdownEncoding.encode(
            "a\nb\n",
            hasBOM: true,
            lineEnding: .crlf
        )
        #expect(bytes.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        let decoded = try MarkdownEncoding.decode(bytes)
        #expect(decoded.canonicalText == "a\nb\n")
        #expect(decoded.hasBOM)
        #expect(decoded.lineEnding == .crlf)
    }

    @Test("Soft comparison ignores a trailing newline")
    func softComparison() {
        #expect(MarkdownEncoding.softEqual("a\n", "a"))
        #expect(MarkdownEncoding.softEqual("a\n\n", "a"))
        #expect(!MarkdownEncoding.softEqual("a", "a\nb"))
    }
}

@Suite("File store")
struct FileStoreTests {
    @Test("Creates a new file without replacing an existing one")
    func createNewFile() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("new.md")

        let store = MarkdownFileStore()
        let request = SaveRequest(
            documentID: UUID(),
            identityGeneration: 0,
            sourceRevision: 0,
            destination: url,
            expectedDisk: nil,
            data: Data("# New\n".utf8),
            mode: .automatic
        )
        let outcome = try store.save(request)
        #expect(try Data(contentsOf: url) == Data("# New\n".utf8))
        #expect(outcome.snapshot.bytes == Data("# New\n".utf8))
    }

    @Test("Compare-and-swap refuses after an external write")
    func comparesAndSwaps() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("one".utf8).write(to: url)

        let snapshot = try #require(try MarkdownFileStore().diskSnapshot(at: url))
        try Data("external".utf8).write(to: url)

        let request = SaveRequest(
            documentID: UUID(),
            identityGeneration: 0,
            sourceRevision: 1,
            destination: url,
            expectedDisk: snapshot,
            data: Data("two".utf8),
            mode: .automatic
        )
        #expect(throws: SaveError.self) {
            _ = try MarkdownFileStore().save(request)
        }
        #expect(try Data(contentsOf: url) == Data("external".utf8))
    }

    @Test("An unconditional overwrite refuses a destination past its limit")
    func boundedOverwrite() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("big.md")
        let original = Data(repeating: 0x61, count: 2_048)
        try original.write(to: url)

        let request = SaveRequest(
            documentID: UUID(),
            identityGeneration: 0,
            sourceRevision: 1,
            destination: url,
            expectedDisk: nil,
            data: Data("new".utf8),
            mode: .explicitOverwrite,
            maximumReplacedBytes: 1_024
        )
        #expect(throws: SaveError.self) {
            _ = try MarkdownFileStore().save(request)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("A grown destination is a conflict without an unbounded read")
    func boundedCompare() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("one".utf8).write(to: url)
        let snapshot = try #require(try MarkdownFileStore().diskSnapshot(at: url))
        let grown = Data(repeating: 0x61, count: 2_048)
        try grown.write(to: url)

        let request = SaveRequest(
            documentID: UUID(),
            identityGeneration: 0,
            sourceRevision: 1,
            destination: url,
            expectedDisk: snapshot,
            data: Data("two".utf8),
            mode: .automatic,
            maximumReplacedBytes: 1_024
        )
        #expect(throws: SaveError.self) {
            _ = try MarkdownFileStore().save(request)
        }
        #expect(try Data(contentsOf: url) == grown)
    }

    @Test("A late growth is refused on the no-swap path")
    func lateGrowthWithoutSwapIsBounded() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data().write(to: url)
        let store = MarkdownFileStore(
            options: FileStoreOptions(supportsAtomicSwap: false)
        )
        let request = SaveRequest(
            documentID: UUID(),
            identityGeneration: 0,
            sourceRevision: 1,
            destination: url,
            expectedDisk: nil,
            data: Data("new".utf8),
            mode: .explicitOverwrite,
            hooks: SaveHooks(beforeRename: { target in
                try? Data(repeating: 0x61, count: 2_048).write(to: target)
            }),
            maximumReplacedBytes: 1_024
        )
        #expect(throws: SaveError.self) {
            _ = try store.save(request)
        }
        #expect(try Data(contentsOf: url).count == 2_048)
    }

    @Test("A displaced file above the save limit is kept for recovery")
    func lateGrowthAcrossASwapIsKept() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data().write(to: url)
        let store = MarkdownFileStore()
        let request = SaveRequest(
            documentID: UUID(),
            identityGeneration: 0,
            sourceRevision: 1,
            destination: url,
            expectedDisk: nil,
            data: Data("new".utf8),
            mode: .explicitOverwrite,
            hooks: SaveHooks(beforeRename: { target in
                try? Data(repeating: 0x61, count: 2_048).write(to: target)
            }),
            maximumReplacedBytes: 1_024
        )
        do {
            _ = try store.save(request)
            Issue.record("a displaced file above the limit needs recovery")
        } catch let error as SaveError {
            guard case .recoveryRequired(let path) = error else {
                Issue.record("expected recoveryRequired, got \(error)")
                return
            }
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)).count == 2_048)
        }
    }

    @Test("A successful swap verifies the target and keeps artifacts")
    func swapArtifacts() throws {        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("old".utf8).write(to: url)

        let store = MarkdownFileStore()
        let snapshot = try #require(try store.diskSnapshot(at: url))
        let request = SaveRequest(
            documentID: UUID(),
            identityGeneration: 0,
            sourceRevision: 1,
            destination: url,
            expectedDisk: snapshot,
            data: Data("new".utf8),
            mode: .automatic
        )
        let outcome = try store.save(request)

        #expect(try Data(contentsOf: url) == Data("new".utf8))
        let displaced = try #require(outcome.artifacts.displaced)
        let newContent = try #require(outcome.artifacts.newContent)
        #expect(try Data(contentsOf: displaced) == Data("old".utf8))
        #expect(try Data(contentsOf: newContent) == Data("new".utf8))
    }

    @Test("An external write after the swap fails verification and preserves artifacts")
    func externalWriteAfterSwap() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("old".utf8).write(to: url)

        let store = MarkdownFileStore()
        let snapshot = try #require(try store.diskSnapshot(at: url))
        let hooks = SaveHooks(afterSwap: { destination in
            try? Data("intruder".utf8).write(to: destination)
        })
        let request = SaveRequest(
            documentID: UUID(),
            identityGeneration: 0,
            sourceRevision: 1,
            destination: url,
            expectedDisk: snapshot,
            data: Data("new".utf8),
            mode: .automatic,
            hooks: hooks
        )

        do {
            _ = try store.save(request)
            Issue.record("expected verification failure")
        } catch let SaveError.verificationFailed(artifacts) {
            let displaced = try #require(artifacts.displaced)
            #expect(try Data(contentsOf: displaced) == Data("old".utf8))
        }
    }

    @Test("A swapped-out file that cannot be read is kept for recovery")
    func unreadableDisplacedFileIsKept() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("old".utf8).write(to: url)

        let store = MarkdownFileStore()
        let snapshot = try #require(try store.diskSnapshot(at: url))
        let hooks = SaveHooks(afterSwap: { destination in
            let folder = destination.deletingLastPathComponent()
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: folder.path
            )) ?? []
            for name in names where name.contains(".sonovo-tmp-") {
                _ = chmod(folder.appendingPathComponent(name).path, 0o000)
            }
        })
        let request = SaveRequest(
            documentID: UUID(),
            identityGeneration: 0,
            sourceRevision: 1,
            destination: url,
            expectedDisk: snapshot,
            data: Data("new".utf8),
            mode: .automatic,
            hooks: hooks
        )

        do {
            _ = try store.save(request)
            Issue.record("expected recoveryRequired")
        } catch let SaveError.recoveryRequired(path) {
            // The only remaining copy of the displaced bytes must survive
            // cleanup, even though reading it failed during the save.
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(chmod(path, 0o600) == 0)
            #expect(
                try Data(contentsOf: URL(fileURLWithPath: path))
                    == Data("old".utf8)
            )
        }
    }

    @Test("A verification failure preserves the actually displaced bytes")
    func verificationKeepsDisplacedRace() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("old".utf8).write(to: url)

        let store = MarkdownFileStore()
        let snapshot = try #require(try store.diskSnapshot(at: url))
        let hooks = SaveHooks(
            beforeRename: { destination in
                try? Data("external".utf8).write(to: destination)
            },
            afterSwap: { destination in
                try? Data("intruder".utf8).write(to: destination)
            }
        )
        let request = SaveRequest(
            documentID: UUID(),
            identityGeneration: 0,
            sourceRevision: 1,
            destination: url,
            expectedDisk: snapshot,
            data: Data("new".utf8),
            mode: .automatic,
            hooks: hooks
        )

        do {
            _ = try store.save(request)
            Issue.record("expected verification failure")
        } catch let SaveError.verificationFailed(artifacts) {
            let displaced = try #require(artifacts.displaced)
            #expect(try Data(contentsOf: displaced) == Data("external".utf8))
        }
    }

    @Test("A detected swap conflict restores the displaced destination")
    func swapConflictRestoresExternal() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("old".utf8).write(to: url)

        let store = MarkdownFileStore()
        let snapshot = try #require(try store.diskSnapshot(at: url))
        let hooks = SaveHooks(beforeRename: { destination in
            try? Data("external".utf8).write(to: destination)
        })
        let request = SaveRequest(
            documentID: UUID(),
            identityGeneration: 0,
            sourceRevision: 1,
            destination: url,
            expectedDisk: snapshot,
            data: Data("new".utf8),
            mode: .automatic,
            hooks: hooks
        )

        do {
            _ = try store.save(request)
            Issue.record("expected a disk-changed conflict")
        } catch let SaveError.diskChanged(artifacts) {
            #expect(try Data(contentsOf: url) == Data("external".utf8))
            let displaced = try #require(artifacts.displaced)
            #expect(try Data(contentsOf: displaced) == Data("external".utf8))
        }
    }

    @Test("The explicit fallback detects a late external write")
    func fallbackDetectsLateWrite() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("old".utf8).write(to: url)

        let store = MarkdownFileStore(
            options: FileStoreOptions(supportsAtomicSwap: false)
        )
        let snapshot = try #require(try store.diskSnapshot(at: url))
        let hooks = SaveHooks(beforeRename: { destination in
            try? Data("external".utf8).write(to: destination)
        })
        let request = SaveRequest(
            documentID: UUID(),
            identityGeneration: 0,
            sourceRevision: 1,
            destination: url,
            expectedDisk: snapshot,
            data: Data("new".utf8),
            mode: .explicitOverwrite,
            hooks: hooks
        )

        do {
            _ = try store.save(request)
            Issue.record("expected a disk-changed conflict")
        } catch let SaveError.diskChanged(artifacts) {
            #expect(try Data(contentsOf: url) == Data("external".utf8))
            let displaced = try #require(artifacts.displaced)
            #expect(try Data(contentsOf: displaced) == Data("external".utf8))
        }
    }

    @Test("Automatic save refuses a filesystem without atomic swap")
    func swapUnavailable() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("old".utf8).write(to: url)

        let store = MarkdownFileStore(options: FileStoreOptions(supportsAtomicSwap: false))
        let snapshot = try #require(try store.diskSnapshot(at: url))
        let request = SaveRequest(
            documentID: UUID(),
            identityGeneration: 0,
            sourceRevision: 1,
            destination: url,
            expectedDisk: snapshot,
            data: Data("new".utf8),
            mode: .automatic
        )

        #expect(throws: SaveError.swapUnavailable) {
            _ = try store.save(request)
        }
        #expect(try Data(contentsOf: url) == Data("old".utf8))
    }

    @Test("Explicit resolution replaces without swap and preserves the old bytes")
    func explicitWithoutSwap() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("old".utf8).write(to: url)

        let store = MarkdownFileStore(options: FileStoreOptions(supportsAtomicSwap: false))
        let snapshot = try #require(try store.diskSnapshot(at: url))
        let request = SaveRequest(
            documentID: UUID(),
            identityGeneration: 0,
            sourceRevision: 1,
            destination: url,
            expectedDisk: snapshot,
            data: Data("new".utf8),
            mode: .explicitOverwrite
        )
        let outcome = try store.save(request)
        #expect(try Data(contentsOf: url) == Data("new".utf8))
        let displaced = try #require(outcome.artifacts.displaced)
        #expect(try Data(contentsOf: displaced) == Data("old".utf8))
    }
}

@Suite("Document")
@MainActor
struct MarkdownDocumentTests {
    @Test("Editing marks dirty, saving clears it, and saving a clean document skips the write")
    func editAndSave() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("# One\n".utf8).write(to: url)

        let document = try MarkdownDocument(loading: url)
        #expect(!document.isDirty)

        try document.replaceSource("# Two\n")
        #expect(document.isDirty)
        #expect(document.revision == 1)

        let outcome = try await document.save()
        #expect(outcome != nil)
        #expect(!document.isDirty)
        #expect(try Data(contentsOf: url) == Data("# Two\n".utf8))

        let skipped = try await document.save()
        #expect(skipped == nil)
    }

    @Test("Undo restores the previous source")
    func undo() throws {
        let document = MarkdownDocument(untitledWith: MarkdownFileStore())
        try document.replaceSource("a")
        try document.replaceSource("ab")
        #expect(document.source == "ab")

        document.undoManager.undo()
        #expect(document.source == "a")
        document.undoManager.redo()
        #expect(document.source == "ab")
    }

    @Test("A save completion cannot clear a newer revision")
    func staleRevision() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("start\n".utf8).write(to: url)

        let document = try MarkdownDocument(loading: url)
        try document.replaceSource("first\n")

        // The hook runs on the detached save task. A lock-backed gate lets
        // the async test wait without blocking an async context.
        let gate = SaveGate()
        let hooks = SaveHooks(beforeRename: { _ in
            gate.markEntered()
            while !gate.isReleased {
                Thread.sleep(forTimeInterval: 0.01)
            }
        })

        let saveTask = Task { try await document.save(hooks: hooks) }
        for _ in 0..<500 where !gate.hasEntered {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.hasEntered)
        try document.replaceSource("second\n")
        gate.release()
        _ = try await saveTask.value

        #expect(document.isDirty)
        #expect(document.source == "second\n")
    }

    @Test("Save As switches identity only after the write succeeds")
    func saveAs() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let destination = directory.appendingPathComponent("saved.md")

        let document = MarkdownDocument(untitledWith: MarkdownFileStore())
        try document.replaceSource("# Untitled\n")
        #expect(document.isDirty)

        let outcome = try await document.saveAs(to: destination)
        #expect(document.fileURL == destination)
        #expect(document.identityGeneration == 1)
        #expect(!document.isDirty)
        #expect(try Data(contentsOf: destination) == Data("# Untitled\n".utf8))
        #expect(outcome.artifacts.newContent != nil)
    }

    @Test("Save As keeps a live-grown buffer editable")
    func saveAsKeepsLiveGrowthEditable() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let destination = directory.appendingPathComponent("big.md")

        let document = MarkdownDocument(untitledWith: MarkdownFileStore())
        let big = String(
            repeating: "a",
            count: MarkdownLimits.maxEditableDocumentBytes + 1
        )
        try document.replaceSource(big)
        #expect(document.isLarge)
        #expect(!document.isReadOnly)

        _ = try await document.saveAs(to: destination)
        #expect(document.isLarge)
        #expect(!document.isReadOnly)
        #expect(document.forcedSourceReason == .largeBuffer)

        try document.replaceSource("small")
        #expect(!document.isLarge)
        #expect(!document.isReadOnly)
    }

    @Test("Save As recomputes size from the buffer, not the saved bytes")
    func saveAsSizeFollowsBufferDuringWrite() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let destination = directory.appendingPathComponent("saved.md")
        try Data("old\n".utf8).write(to: destination)

        let document = MarkdownDocument(untitledWith: MarkdownFileStore())
        try document.replaceSource("first\n")

        let gate = SaveGate()
        let hooks = SaveHooks(beforeRename: { _ in
            gate.markEntered()
            while !gate.isReleased {
                Thread.sleep(forTimeInterval: 0.01)
            }
        })

        let saveTask = Task {
            try await document.saveAs(to: destination, hooks: hooks)
        }
        for _ in 0..<500 where !gate.hasEntered {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.hasEntered)
        let big = String(
            repeating: "a",
            count: MarkdownLimits.maxEditableDocumentBytes + 1
        )
        try document.replaceSource(big)
        gate.release()
        _ = try await saveTask.value

        // The saved bytes were small; the buffer is not.
        #expect(document.isLarge)
        #expect(!document.isReadOnly)
        #expect(document.forcedSourceReason == .largeBuffer)
        try document.replaceSource("small")
        #expect(!document.isLarge)
    }

    @Test("Save As does not mark edits made during the write as saved")
    func saveAsDuringEdit() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let destination = directory.appendingPathComponent("saved.md")
        try Data("old\n".utf8).write(to: destination)

        let document = MarkdownDocument(untitledWith: MarkdownFileStore())
        try document.replaceSource("first\n")

        let gate = SaveGate()
        let hooks = SaveHooks(beforeRename: { _ in
            gate.markEntered()
            while !gate.isReleased {
                Thread.sleep(forTimeInterval: 0.01)
            }
        })

        let saveTask = Task {
            try await document.saveAs(to: destination, hooks: hooks)
        }
        for _ in 0..<500 where !gate.hasEntered {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.hasEntered)
        try document.replaceSource("second\n")
        gate.release()
        _ = try await saveTask.value

        #expect(document.isDirty)
        #expect(document.source == "second\n")
        #expect(try Data(contentsOf: destination) == Data("first\n".utf8))
    }

    @Test("A failed Save As keeps the old identity and dirty content")
    func failedSaveAs() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let original = directory.appendingPathComponent("original.md")
        try Data("old\n".utf8).write(to: original)

        let document = try MarkdownDocument(loading: original)
        try document.replaceSource("new\n")

        // A directory is not a valid file destination.
        let invalid = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) {
            _ = try await document.saveAs(to: invalid)
        }
        #expect(document.fileURL == original)
        #expect(document.identityGeneration == 0)
        #expect(document.isDirty)
        #expect(try Data(contentsOf: original) == Data("old\n".utf8))
    }

    @Test("A clean document adopts an external change")
    func adoptExternalChange() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("one\n".utf8).write(to: url)

        let document = try MarkdownDocument(loading: url)
        try Data("two\n".utf8).write(to: url)

        let change = try await document.checkExternalChange()
        #expect(change == .adopted)
        #expect(document.source == "two\n")
        #expect(!document.isDirty)
    }

    @Test("A dirty document reports a conflict and offers resolution")
    func conflictResolution() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("one\n".utf8).write(to: url)

        let document = try MarkdownDocument(loading: url)
        try document.replaceSource("local\n")
        try Data("external\n".utf8).write(to: url)

        let change = try await document.checkExternalChange()
        guard case let .conflict(conflict) = change else {
            Issue.record("expected a conflict, got \(change)")
            return
        }
        #expect(conflict.diskText == "external\n")

        document.resolveExternalChange(.reload)
        #expect(document.source == "external\n")
        #expect(!document.isDirty)
        #expect(document.conflict == nil)
    }

    @Test("Reloading a conflict adopts the disk encoding and size state")
    func conflictReloadAdoptsEncoding() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("one\n".utf8).write(to: url)

        let document = try MarkdownDocument(loading: url)
        try document.replaceSource("local\n")
        var external = Data([0xEF, 0xBB, 0xBF])
        external.append(Data("external\r\n".utf8))
        try external.write(to: url)

        let change = try await document.checkExternalChange()
        guard case .conflict = change else {
            Issue.record("expected a conflict, got \(change)")
            return
        }
        document.resolveExternalChange(.reload)

        #expect(document.lineEnding == .crlf)
        #expect(document.hasBOM)
        #expect(document.source == "external\n")
    }

    @Test("Reloading a conflict clears undo history")
    func reloadClearsUndo() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("one\n".utf8).write(to: url)

        let document = try MarkdownDocument(loading: url)
        try document.replaceSource("local\n")
        #expect(document.undoManager.canUndo)

        try Data("external\n".utf8).write(to: url)
        _ = try await document.checkExternalChange()
        document.resolveExternalChange(.reload)
        #expect(!document.undoManager.canUndo)
        #expect(document.source == "external\n")
    }

    @Test("An EOL-only rewrite is not an external edit")
    func eolRewrite() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("one\ntwo\n".utf8).write(to: url)

        let document = try MarkdownDocument(loading: url)
        try Data("one\r\ntwo\r\n".utf8).write(to: url)

        let change = try await document.checkExternalChange()
        #expect(change == .none)
        #expect(document.source == "one\ntwo\n")
    }

    @Test("Close refuses an untitled dirty document and flushes a saved one")
    func closeFlush() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("one\n".utf8).write(to: url)

        let untitled = MarkdownDocument(untitledWith: MarkdownFileStore())
        try untitled.replaceSource("draft")
        #expect(await untitled.flushForClose() == .needsDecision(.untitled))

        let saved = try MarkdownDocument(loading: url)
        try saved.replaceSource("two\n")
        #expect(await saved.flushForClose() == .closed)
        #expect(!saved.isDirty)
    }

    @Test("Autosave uses a one-second idle delay and a five-second ceiling")
    func autosavePolicy() {
        #expect(Autosave.idleDelay == 1.0)
        #expect(Autosave.maxDelay == 5.0)

        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let idle = try? #require(
            Autosave.delay(
                lastEdit: start,
                firstPendingEdit: start,
                now: start.addingTimeInterval(0.4)
            )
        )
        #expect(abs((idle ?? 0) - 0.6) < 0.0001)

        let ceiling = try? #require(
            Autosave.delay(
                lastEdit: start.addingTimeInterval(4.8),
                firstPendingEdit: start,
                now: start.addingTimeInterval(4.9)
            )
        )
        #expect(abs((ceiling ?? 0) - 0.1) < 0.0001)
    }

    @Test("An oversized Markdown file is refused before reading")
    func oversizedFileIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("large.md")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(
            atOffset: UInt64(MarkdownLimits.maxReadBytes + 1)
        )
        try handle.close()

        #expect(throws: MarkdownFileStoreError.self) {
            _ = try MarkdownDocument(loading: url)
        }
    }

    @Test("A file over the line budget is refused before parsing")
    func tooManyLinesIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("lines.md")
        let source = String(
            repeating: "a\n",
            count: MarkdownLimits.maxSourceLines + 1
        )
        try source.write(to: url, atomically: true, encoding: .utf8)

        #expect {
            _ = try MarkdownDocument(loading: url)
        } throws: { error in
            guard let storeError = error as? MarkdownFileStoreError,
                  case .tooManyLines = storeError else {
                return false
            }
            return true
        }
    }

    @Test("Undo history is bounded by the shared level limit")
    func undoHistoryIsBounded() throws {
        let document = MarkdownDocument(
            untitledWith: MarkdownFileStore()
        )
        for index in 0..<(DocumentHistoryLimits.undoLevels + 5) {
            try document.replaceSource("v\(index)")
        }
        var undoCount = 0
        while document.undoManager.canUndo {
            document.undoManager.undo()
            undoCount += 1
        }
        #expect(undoCount <= DocumentHistoryLimits.undoLevels)
    }

    @Test("An oversized replacement is rejected")
    func oversizedReplacementIsRejected() throws {
        let document = MarkdownDocument(
            untitledWith: MarkdownFileStore()
        )
        let oversized = String(
            repeating: "x",
            count: DocumentHistoryLimits.maxReplacementBytes + 1
        )
        #expect(throws: DocumentError.editTooLarge) {
            try document.replaceSource(oversized)
        }
    }
}

@Suite("File watcher")
struct FileWatcherTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func waitFor(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<60 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test("Watches the parent directory through replace, delete, and recreate")
    func lifecycle() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("one".utf8).write(to: url)

        let counter = Counter()
        let watcher = MarkdownFileWatcher(fileURL: url) {
            counter.increment()
        }
        watcher.start()
        defer { watcher.stop() }

        try Data("two".utf8).write(to: url)
        #expect(await waitFor { counter.count > 0 })

        let beforeReplace = counter.count
        let replacement = directory.appendingPathComponent("replacement.tmp")
        try Data("three".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        #expect(await waitFor { counter.count > beforeReplace })

        let beforeDelete = counter.count
        try FileManager.default.removeItem(at: url)
        #expect(await waitFor { counter.count > beforeDelete })

        let beforeRecreate = counter.count
        try Data("four".utf8).write(to: url)
        #expect(await waitFor { counter.count > beforeRecreate })
    }
}

@Suite("Asset store")
struct AssetStoreTests {
    @Test("Deduplicates identical image bytes")
    func deduplicates() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let document = root.appendingPathComponent("doc.md")
        FileManager.default.createFile(atPath: document.path, contents: Data())

        let store = MarkdownAssetStore()
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
        let first = try store.store(
            imageData: data,
            fileExtension: "png",
            relativeTo: document,
            workspaceRoot: root
        )
        let second = try store.store(
            imageData: data,
            fileExtension: "PNG!",
            relativeTo: document,
            workspaceRoot: root
        )
        #expect(first == second)
        #expect(first.hasPrefix("assets/image-"))
        #expect(first.hasSuffix(".png"))

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("assets").path
        )
        #expect(contents.count == 1)
    }

    @Test("Rejects documents outside the workspace root")
    func rejectsOutsideWorkspace() throws {
        let base = try temporaryDirectory()
        defer { cleanup(base) }
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let document = outside.appendingPathComponent("doc.md")
        FileManager.default.createFile(atPath: document.path, contents: Data())

        #expect(throws: MarkdownAssetError.outsideWorkspace) {
            _ = try MarkdownAssetStore().store(
                imageData: Data([1]),
                fileExtension: "png",
                relativeTo: document,
                workspaceRoot: root
            )
        }
    }
}
