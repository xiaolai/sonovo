import Foundation
import Testing
@testable import SonovoCore

@Suite("Review sidecar")
struct ReviewSidecarTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func writeDocument(
        _ text: String,
        in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent("doc.md")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func sampleAnchor(
        in source: String,
        quote: String = "note"
    ) throws -> ReviewAnchor {
        let ns = source as NSString
        let found = ns.range(of: quote)
        return try #require(
            ReviewAnchorResolver.makeAnchor(
                source: source,
                selection: found.location..<(found.location + found.length)
            )
        )
    }

    @Test("A missing sidecar loads as an empty review document")
    func missingSidecar() throws {
        let directory = try makeDirectory()
        defer { cleanup(directory) }
        let doc = try writeDocument("note\n", in: directory)
        let loaded = try ReviewSidecar.load(
            for: doc,
            documentIdentity: "identity"
        )
        #expect(loaded.document.threads.isEmpty)
        #expect(loaded.document.documentName == "doc.md")
        #expect(loaded.document.documentIdentity == "identity")
        #expect(loaded.state == .missing)
    }

    @Test("A save writes only the sidecar, atomically, with no leftover files")
    func saveIsAtomicAndBesideTheDocument() throws {
        let directory = try makeDirectory()
        defer { cleanup(directory) }
        let original = "alpha note beta\n"
        let doc = try writeDocument(original, in: directory)
        let loaded = try ReviewSidecar.load(for: doc, documentIdentity: "id")
        var review = loaded.document
        let added = review.addThread(
            anchor: try sampleAnchor(in: original),
            author: "example-author",
            body: "Check this."
        )
        let thread = try #require(added)
        let state = try ReviewSidecar.save(
            review,
            for: doc,
            ifUnchangedSince: loaded.state
        )
        #expect(state.exists)
        #expect(state.fingerprint != nil)

        let names = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ).sorted()
        // The lock file is infrastructure: hidden, empty, and never deleted,
        // because unlinking it would let a third writer take a fresh inode
        // while another still waits on the old one.
        #expect(
            names == [
                ".doc.md.review.json",
                ".doc.md.review.json.lock",
                "doc.md"
            ]
        )
        let sidecarURL = ReviewAnchorResolver.sidecarURL(for: doc)
        let data = try Data(contentsOf: sidecarURL)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"threads\""))
        #expect(text.contains(thread.id.uuidString))

        // The document's bytes are untouched.
        #expect(try Data(contentsOf: doc) == Data(original.utf8))

        let reloaded = try ReviewSidecar.load(for: doc, documentIdentity: "id")
        #expect(reloaded.document == review)
        #expect(reloaded.state == state)
    }

    @Test("Corrupt JSON is refused, left on disk, and never overwritten")
    func corruptSidecarFailsClosed() throws {
        let directory = try makeDirectory()
        defer { cleanup(directory) }
        let doc = try writeDocument("note\n", in: directory)
        let sidecarURL = ReviewAnchorResolver.sidecarURL(for: doc)
        let corrupt = Data("{\"version\": 1, \"threads\": [".utf8)
        try corrupt.write(to: sidecarURL)

        #expect(throws: ReviewSidecarError.corrupt(
            sidecarURL.lastPathComponent
        )) {
            try ReviewSidecar.load(for: doc, documentIdentity: "id")
        }
        // A caller that ignored the failure and tried to start fresh is
        // refused too: the file exists and does not match the empty state.
        var review = ReviewDocument(
            documentName: "doc.md",
            documentIdentity: "id"
        )
        _ = review.addThread(
            anchor: try sampleAnchor(in: "note\n"),
            author: "a",
            body: "b"
        )
        #expect(throws: ReviewSidecarError.externalChange) {
            try ReviewSidecar.save(
                review,
                for: doc,
                ifUnchangedSince: .missing
            )
        }
        #expect(try Data(contentsOf: sidecarURL) == corrupt)
    }

    @Test("A newer sidecar format is refused")
    func unsupportedVersion() throws {
        let directory = try makeDirectory()
        defer { cleanup(directory) }
        let doc = try writeDocument("note\n", in: directory)
        let sidecar = ReviewDocument(
            version: ReviewDocument.currentVersion + 1,
            documentName: "doc.md",
            documentIdentity: "id"
        )
        try sidecar.encoded().write(
            to: ReviewAnchorResolver.sidecarURL(for: doc)
        )
        #expect(throws: ReviewSidecarError.unsupportedVersion(2)) {
            try ReviewSidecar.load(for: doc, documentIdentity: "id")
        }
    }

    @Test("An oversized sidecar is refused before decoding")
    func oversizedSidecar() throws {
        let directory = try makeDirectory()
        defer { cleanup(directory) }
        let doc = try writeDocument("note\n", in: directory)
        let url = ReviewAnchorResolver.sidecarURL(for: doc)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(
            atOffset: UInt64(ReviewSidecar.maximumBytes + 1)
        )
        try handle.close()
        #expect(throws: ReviewSidecarError.corrupt(url.lastPathComponent)) {
            try ReviewSidecar.load(for: doc, documentIdentity: "id")
        }
    }

    @Test("An external edit between load and save is refused")
    func externalEditRefusesSave() throws {
        let directory = try makeDirectory()
        defer { cleanup(directory) }
        let doc = try writeDocument("note\n", in: directory)
        let loaded = try ReviewSidecar.load(for: doc, documentIdentity: "id")
        var local = loaded.document
        _ = local.addThread(
            anchor: try sampleAnchor(in: "note\n"),
            author: "local",
            body: "Mine."
        )
        // Another writer updates the sidecar after this caller loaded it.
        var other = loaded.document
        _ = other.addThread(
            anchor: try sampleAnchor(in: "note\n"),
            author: "other",
            body: "Theirs."
        )
        try ReviewSidecar.save(
            other,
            for: doc,
            ifUnchangedSince: loaded.state
        )
        let externalBytes = try Data(
            contentsOf: ReviewAnchorResolver.sidecarURL(for: doc)
        )

        #expect(throws: ReviewSidecarError.externalChange) {
            try ReviewSidecar.save(
                local,
                for: doc,
                ifUnchangedSince: loaded.state
            )
        }
        #expect(
            try Data(contentsOf: ReviewAnchorResolver.sidecarURL(for: doc))
                == externalBytes
        )
    }

    @Test("A sidecar deleted after loading is an external change")
    func externalDeleteRefusesSave() throws {
        let directory = try makeDirectory()
        defer { cleanup(directory) }
        let doc = try writeDocument("note\n", in: directory)
        let empty = ReviewDocument(
            documentName: "doc.md",
            documentIdentity: "id"
        )
        let state = try ReviewSidecar.save(
            empty,
            for: doc,
            ifUnchangedSince: .missing
        )
        try FileManager.default.removeItem(
            at: ReviewAnchorResolver.sidecarURL(for: doc)
        )
        #expect(throws: ReviewSidecarError.externalChange) {
            try ReviewSidecar.save(empty, for: doc, ifUnchangedSince: state)
        }
    }

    @Test("A sidecar that appeared after loading is an external change")
    func externalAppearanceRefusesSave() throws {
        let directory = try makeDirectory()
        defer { cleanup(directory) }
        let doc = try writeDocument("note\n", in: directory)
        var review = ReviewDocument(
            documentName: "doc.md",
            documentIdentity: "id"
        )
        _ = review.addThread(
            anchor: try sampleAnchor(in: "note\n"),
            author: "a",
            body: "b"
        )
        try review.encoded().write(
            to: ReviewAnchorResolver.sidecarURL(for: doc)
        )
        #expect(throws: ReviewSidecarError.externalChange) {
            try ReviewSidecar.save(
                review,
                for: doc,
                ifUnchangedSince: .missing
            )
        }
    }

    @Test("Two writers: the first save wins and the second must reload")
    func concurrentWriters() throws {
        let directory = try makeDirectory()
        defer { cleanup(directory) }
        let doc = try writeDocument("note\n", in: directory)
        let first = try ReviewSidecar.load(for: doc, documentIdentity: "id")
        let second = try ReviewSidecar.load(for: doc, documentIdentity: "id")
        var firstReview = first.document
        _ = firstReview.addThread(
            anchor: try sampleAnchor(in: "note\n"),
            author: "first",
            body: "one"
        )
        var secondReview = second.document
        _ = secondReview.addThread(
            anchor: try sampleAnchor(in: "note\n"),
            author: "second",
            body: "two"
        )
        let firstState = try ReviewSidecar.save(
            firstReview,
            for: doc,
            ifUnchangedSince: first.state
        )
        #expect(throws: ReviewSidecarError.externalChange) {
            try ReviewSidecar.save(
                secondReview,
                for: doc,
                ifUnchangedSince: second.state
            )
        }
        let reloaded = try ReviewSidecar.load(
            for: doc,
            documentIdentity: "id"
        )
        #expect(reloaded.state == firstState)
        #expect(reloaded.document.threads.map(\.author) == ["first"])
    }

    @Test("Document identity follows content")
    func documentIdentity() {
        let one = ReviewAnchorResolver.documentIdentity(of: "alpha")
        let two = ReviewAnchorResolver.documentIdentity(of: "alpha")
        let three = ReviewAnchorResolver.documentIdentity(of: "alpha\n")
        #expect(one == two)
        #expect(one != three)
        #expect(one.count == 64)
    }

    @Test("The write lock admits one holder at a time")
    func writeLockIsExclusive() throws {
        let directory = try makeDirectory()
        defer { cleanup(directory) }
        let lockURL = directory.appendingPathComponent(
            ".doc.md.review.json.lock"
        )

        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? ReviewSidecar.withExclusiveLock(at: lockURL) {
                firstEntered.signal()
                releaseFirst.wait()
            }
            firstFinished.signal()
        }
        try #require(firstEntered.wait(timeout: .now() + 5) == .success)

        let secondEntered = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? ReviewSidecar.withExclusiveLock(at: lockURL) {
                secondEntered.signal()
            }
            secondFinished.signal()
        }
        // Held by the first holder: the second must not enter.
        #expect(secondEntered.wait(timeout: .now() + 0.3) == .timedOut)
        releaseFirst.signal()
        #expect(secondEntered.wait(timeout: .now() + 5) == .success)
        #expect(firstFinished.wait(timeout: .now() + 5) == .success)
        #expect(secondFinished.wait(timeout: .now() + 5) == .success)
    }

    @Test("A save waits for the lock before reading the sidecar")
    func saveTakesTheLock() throws {
        let directory = try makeDirectory()
        defer { cleanup(directory) }
        let doc = try writeDocument("note\n", in: directory)
        let loaded = try ReviewSidecar.load(for: doc, documentIdentity: "id")
        let lockURL = ReviewSidecar.lockURL(
            for: ReviewAnchorResolver.sidecarURL(for: doc)
        )

        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? ReviewSidecar.withExclusiveLock(at: lockURL) {
                held.signal()
                release.wait()
            }
        }
        try #require(held.wait(timeout: .now() + 5) == .success)

        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            _ = try? ReviewSidecar.save(
                loaded.document,
                for: doc,
                ifUnchangedSince: loaded.state
            )
            finished.signal()
        }
        try #require(started.wait(timeout: .now() + 5) == .success)
        // With the lock held, a save that honours it cannot finish.
        #expect(finished.wait(timeout: .now() + 0.3) == .timedOut)

        release.signal()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(
            try ReviewSidecar.currentState(for: doc).exists
        )
    }
}
