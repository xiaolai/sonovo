import Foundation
import Testing
@testable import SonovoCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sonovo-subtitle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private let srtSource = """
1
00:00:01,000 --> 00:00:03,000
Hello

2
00:00:04,000 --> 00:00:06,000
World
"""

@Suite("Subtitle document", .serialized)
@MainActor
struct SubtitleDocumentTests {
    @Test("Loads a file with format, encoding, and parsed cues")
    func load() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srtSource.utf8).write(to: url)

        let document = try SubtitleDocument(loading: url)
        #expect(document.format == .srt)
        #expect(document.encoding == .utf8(hasBOM: false))
        #expect(document.lineEnding == .lf)
        #expect(!document.isDirty)
        #expect(!document.isReadOnly)
        #expect(document.cueCount == 2)
        #expect(document.durationMilliseconds == 6000)
        #expect(document.parsed.cues[0].rawText == "Hello")
    }

    @Test("Saves an edit atomically and clears dirty")
    func saveEdit() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srtSource.utf8).write(to: url)

        let document = try SubtitleDocument(loading: url)
        try document.replaceSource(
            srtSource.replacingOccurrences(of: "Hello", with: "Hi"),
            actionName: "Edit Cue"
        )
        #expect(document.isDirty)
        try await document.save(mode: .explicitOverwrite)
        #expect(!document.isDirty)

        let disk = try String(contentsOf: url, encoding: .utf8)
        #expect(disk.contains("Hi"))
        #expect(disk.contains("World"))
    }

    @Test("Cue edits apply through the document and undo restores the source")
    func applyAndUndo() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srtSource.utf8).write(to: url)

        let document = try SubtitleDocument(loading: url)
        let result = try await document.apply(
            .setText(ordinal: 0, text: "Changed")
        )
        #expect(result.source != srtSource)
        #expect(document.source == result.source)
        #expect(document.isDirty)

        document.undoManager.undo()
        #expect(document.source == srtSource)
        #expect(document.isDirty)
    }

    @Test("An external edit is adopted while the document is clean")
    func adoptExternalEdit() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srtSource.utf8).write(to: url)

        let document = try SubtitleDocument(loading: url)
        let external = srtSource.replacingOccurrences(
            of: "World",
            with: "External"
        )
        try Data(external.utf8).write(to: url)

        let change = try await document.checkExternalChange()
        #expect(change == .adopted)
        #expect(document.source == external)
        #expect(!document.isDirty)
        let parse = await document.parseResultForCurrentSource()
        #expect(parse.cues[1].rawText == "External")

        // A local cue edit now works against the external file's ranges.
        let result = try await document.apply(
            .setText(ordinal: 1, text: "Local")
        )
        #expect(result.source.contains("Local"))
        #expect(result.source.contains("Hello"))
    }

    @Test("A dirty document conflicts instead of overwriting an external edit")
    func conflictOnSave() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srtSource.utf8).write(to: url)

        let document = try SubtitleDocument(loading: url)
        try document.replaceSource(
            srtSource.replacingOccurrences(of: "Hello", with: "Local"),
            actionName: "Edit"
        )
        let external = srtSource.replacingOccurrences(
            of: "World",
            with: "External"
        )
        try Data(external.utf8).write(to: url)

        await #expect(throws: SaveError.self) {
            try await document.save(mode: .explicitOverwrite)
        }
        #expect(document.conflict?.diskText == external)
        #expect(document.isDirty)
    }

    @Test("Reload adopts the external text; keep-local preserves the edit")
    func conflictResolutions() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srtSource.utf8).write(to: url)

        let document = try SubtitleDocument(loading: url)
        try document.replaceSource("local text", actionName: "Edit")
        let external = srtSource.replacingOccurrences(
            of: "World",
            with: "External"
        )
        try Data(external.utf8).write(to: url)
        _ = try await document.checkExternalChange()
        #expect(document.conflict != nil)

        document.resolveExternalChange(.reload)
        #expect(document.source == external)
        #expect(!document.isDirty)
        #expect(document.conflict == nil)

        try document.replaceSource("mine", actionName: "Edit")
        try Data("theirs".utf8).write(to: url)
        _ = try await document.checkExternalChange()
        document.resolveExternalChange(.keepLocal)
        #expect(document.source == "mine")
        try await document.save(mode: .explicitOverwrite)
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine")
    }

    @Test("Autosave is scheduled only for dirty, editable documents")
    func autosaveDelay() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srtSource.utf8).write(to: url)

        let document = try SubtitleDocument(loading: url)
        #expect(document.autosaveDelay() == nil)
        try document.replaceSource(srtSource + "\n", actionName: "Edit")
        let delay = try #require(document.autosaveDelay())
        #expect(delay <= Autosave.idleDelay)
        #expect(delay >= 0)
    }

    @Test("Close flushes pending edits by saving")
    func closeFlush() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("demo.srt")
        try Data(srtSource.utf8).write(to: url)

        let document = try SubtitleDocument(loading: url)
        try document.replaceSource(
            srtSource.replacingOccurrences(of: "Hello", with: "Bye"),
            actionName: "Edit"
        )
        let outcome = await document.flushForClose()
        #expect(outcome == .closed)
        #expect(!document.isDirty)
        #expect(
            try String(contentsOf: url, encoding: .utf8).contains("Bye")
        )
    }

    @Test("Saves preserve BOM, CRLF, and UTF-16 encoding")
    func encodingPreservation() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("demo.srt")

        let original = try SubtitleEncoding.encode(
            srtSource,
            encoding: .utf8(hasBOM: true),
            lineEnding: .crlf
        )
        try original.write(to: url)

        let document = try SubtitleDocument(loading: url)
        #expect(document.encoding == .utf8(hasBOM: true))
        #expect(document.lineEnding == .crlf)
        try document.replaceSource(
            srtSource.replacingOccurrences(of: "Hello", with: "Hi"),
            actionName: "Edit"
        )
        try await document.save(mode: .explicitOverwrite)

        let bytes = try Data(contentsOf: url)
        #expect(bytes.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        #expect(bytes.range(of: Data([0x0D, 0x0A])) != nil)
        let decoded = try SubtitleEncoding.decode(bytes)
        #expect(decoded.encoding == .utf8(hasBOM: true))
        #expect(decoded.lineEnding == .crlf)
        #expect(decoded.text.contains("Hi"))
    }

    @Test("Windows-1252 files round-trip and reject unrepresentable edits")
    func windows1252() async throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("demo.srt")
        let text = srtSource.replacingOccurrences(of: "Hello", with: "Café")
        let data = try SubtitleEncoding.encode(
            text,
            encoding: .windows1252,
            lineEnding: .lf
        )
        try data.write(to: url)

        let document = try SubtitleDocument(loading: url)
        #expect(document.encoding == .windows1252)
        try document.replaceSource(
            text.replacingOccurrences(of: "Café", with: "Café!"),
            actionName: "Edit"
        )
        try await document.save(mode: .explicitOverwrite)
        let saved = try SubtitleEncoding.decode(
            try Data(contentsOf: url)
        )
        #expect(saved.encoding == .windows1252)
        #expect(saved.text.contains("Café!"))

        try document.replaceSource(
            text.replacingOccurrences(of: "Café", with: "Café 🎬"),
            actionName: "Edit"
        )
        await #expect(
            throws: SubtitleEncodingError.cannotRepresent("Windows-1252")
        ) {
            try await document.save(mode: .explicitOverwrite)
        }
        let unchanged = try SubtitleEncoding.decode(
            try Data(contentsOf: url)
        )
        #expect(!unchanged.text.contains("🎬"))
    }

    @Test("Files above the editable limit open read-only")
    func largeFile() throws {
        let directory = try temporaryDirectory()
        defer { cleanup(directory) }
        let url = directory.appendingPathComponent("large.srt")
        let header = "1\n00:00:01,000 --> 00:00:02,000\n"
        let padding = String(
            repeating: "A",
            count: SubtitleLimits.maxEditableBytes + 1
        )
        try Data((header + padding).utf8).write(to: url)

        let document = try SubtitleDocument(loading: url)
        #expect(document.isLarge)
        #expect(document.isReadOnly)
        #expect(throws: SubtitleDocumentError.readOnly) {
            try document.replaceSource("changed")
        }
    }

    @Test("Parse requests coalesce to the newest revision")
    func parseServiceCoalescing() async {
        let service = SubtitleParseService()
        let documentID = UUID()
        await service.markLatest(documentID: documentID, generation: 2)
        let stale = await service.parse(
            documentID: documentID,
            generation: 1,
            source: "1\n00:00:01,000 --> 00:00:02,000\nOld",
            format: .srt
        )
        #expect(stale == nil)
        let fresh = await service.parse(
            documentID: documentID,
            generation: 2,
            source: "1\n00:00:01,000 --> 00:00:02,000\nNew",
            format: .srt
        )
        #expect(fresh?.cues.first?.rawText == "New")
    }
}
