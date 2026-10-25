import Foundation
import Speech
import XCTest
@testable import Sonovo

final class TranscriptImportTests: XCTestCase {
    func testImportedCuesBecomeSourceTimeWords() async throws {
        let subtitle = try makeSubtitle(
            """
            1
            00:00:00,200 --> 00:00:00,400
            Harbor

            2
            00:00:00,500 --> 00:00:00,700
            wakes
            """
        )
        let provider = ImportedSubtitleProvider(subtitleURL: subtitle)
        let revision = AssetRevision(
            fileIdentifier: "revision",
            size: 1,
            modified: nil
        )
        let document = try await provider.transcript(
            assetURL: URL(fileURLWithPath: "/tmp/source.wav"),
            assetID: "source",
            revision: revision,
            locale: Locale(identifier: "en-US")
        )

        XCTAssertEqual(document.provider, .imported)
        XCTAssertEqual(document.words.count, 2)
        XCTAssertEqual(document.segments.count, 2)
        XCTAssertEqual(document.words[0].text, "Harbor")
        XCTAssertEqual(document.words[0].start, 0.2, accuracy: 0.001)
        XCTAssertEqual(document.words[0].end, 0.4, accuracy: 0.001)
        XCTAssertEqual(document.words[1].text, "wakes")
    }

    private func makeSubtitle(_ source: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "transcript-\(UUID().uuidString).srt"
            )
        try Data(source.utf8).write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

final class SpeechTranscriberProviderTests: XCTestCase {
    func testTranscribesARealVoiceTakeWithMonotonicWordRanges() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw XCTSkip("SpeechTranscriber is unavailable on this Mac")
        }
        let wanted = Locale(identifier: "en-US")
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: wanted
        ) else {
            throw XCTSkip("en-US is not supported on this Mac")
        }
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: {
            $0.identifier == locale.identifier
        }) else {
            throw XCTSkip("The en-US speech model is not installed")
        }
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "vo-take-02",
                withExtension: "wav",
                subdirectory: "Fixtures"
            )
        )
        let revision = try XCTUnwrap(MediaStorage.revision(for: url))
        let asset = ProjectAsset(
            id: url.path,
            url: url,
            name: url.lastPathComponent,
            relativePath: url.lastPathComponent,
            kind: .audio,
            size: revision.size,
            modified: revision.modified,
            revision: revision
        )
        let document = try await SpeechTranscriberProvider().transcript(
            assetURL: url,
            assetID: asset.id,
            revision: revision,
            locale: wanted
        )
        XCTAssertFalse(document.words.isEmpty)
        XCTAssertFalse(document.segments.isEmpty)
        XCTAssertEqual(document.provider, .speech)
        var previous = -Double.infinity
        for word in document.words {
            XCTAssertGreaterThanOrEqual(word.start, previous)
            XCTAssertLessThanOrEqual(word.end, 12.4)
            previous = word.start
        }
    }
}

final class TranscriptCacheTests: XCTestCase {
    func testCacheRoundTripsAndInvalidatesByRevision() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "transcript-cache-\(UUID().uuidString)",
                isDirectory: true
            )
        let cache = TranscriptCache(directory: directory)
        let document = makeDocument(revisionToken: "one")
        let key = TranscriptCacheKey(
            assetID: document.assetID,
            revisionToken: document.revisionToken,
            localeIdentifier: document.localeIdentifier,
            provider: document.provider,
            schemaVersion: document.schemaVersion
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        try await cache.store(document, key: key)
        let loaded = await cache.load(key)
        XCTAssertEqual(loaded?.assetID, document.assetID)
        let latest = await cache.latest(
            assetID: document.assetID,
            revisionToken: "one",
            schemaVersion: document.schemaVersion
        )
        XCTAssertEqual(latest?.assetID, document.assetID)
        let missing = await cache.latest(
            assetID: document.assetID,
            revisionToken: "two",
            schemaVersion: document.schemaVersion
        )
        XCTAssertNil(missing)
    }

    private func makeDocument(revisionToken: String) -> TranscriptDocument {
        TranscriptDocument(
            schemaVersion: TranscriptDocument.currentSchemaVersion,
            assetID: "asset",
            revisionToken: revisionToken,
            localeIdentifier: "en_US",
            provider: .speech,
            words: [
                TranscriptWord(
                    id: "w0",
                    text: "Hello",
                    start: 0,
                    end: 0.4,
                    confidence: nil,
                    isFiller: false
                )
            ],
            segments: [
                MediaTranscriptSegment(
                    id: "s0",
                    wordIDs: ["w0"],
                    start: 0,
                    end: 0.4,
                    text: "Hello"
                )
            ],
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }
}

@MainActor
final class TranscriptSessionTests: XCTestCase {
    func testDeletingWordsCutsMediaAndExportsOnlyKeptCaptions() throws {
        let asset = makeAsset()
        let document = MediaEditDocument(asset: asset)
        document.prepare(sourceDuration: 1)
        let session = TranscriptSession(
            asset: asset,
            document: makeTranscript()
        )

        session.toggleSelection(wordID: "w0")
        let result = session.removeSelectedWords(from: document)
        XCTAssertEqual(result, .changed)
        XCTAssertEqual(
            document.editState?.editedDuration ?? 0,
            0.74,
            accuracy: 0.001
        )
        let state = try XCTUnwrap(document.editState)
        XCTAssertTrue(
            session.isRemoved(
                session.document?.word(id: "w0") ?? makeWord(),
                in: state
            )
        )

        session.setCaption("wakes", for: "w1")
        let captions = try session.exportCaptions(in: state)
        XCTAssertFalse(captions.contains("Harbor"))
        XCTAssertTrue(captions.contains("wakes"))
        XCTAssertTrue(captions.contains("-->"))
    }

    func testFillerSelectionAndCaptionExport() throws {
        let asset = makeAsset()
        let document = MediaEditDocument(asset: asset)
        document.prepare(sourceDuration: 1)
        let state = try XCTUnwrap(document.editState)
        let session = TranscriptSession(
            asset: asset,
            document: makeTranscriptWithFiller()
        )
        session.selectFillers(in: state)
        XCTAssertEqual(session.selectedWordIDs, ["w0"])

        let captions = try session.exportCaptions(in: state)
        XCTAssertTrue(captions.contains("um hello"))
        XCTAssertTrue(captions.contains("00:00:00,000"))
    }

    private func makeAsset() -> ProjectAsset {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-source.wav")
        return ProjectAsset(
            id: "transcript-source",
            url: url,
            name: "transcript-source.wav",
            relativePath: "transcript-source.wav",
            kind: .audio,
            size: 1,
            modified: nil,
            revision: AssetRevision(
                fileIdentifier: "revision",
                size: 1,
                modified: nil
            )
        )
    }

    private func makeTranscript() -> TranscriptDocument {
        TranscriptDocument(
            schemaVersion: TranscriptDocument.currentSchemaVersion,
            assetID: "transcript-source",
            revisionToken: "revision|1|0",
            localeIdentifier: "en_US",
            provider: .speech,
            words: [
                makeWord(id: "w0", text: "Harbor", start: 0.2, end: 0.4),
                makeWord(id: "w1", text: "wakes", start: 0.6, end: 0.8)
            ],
            segments: [
                MediaTranscriptSegment(
                    id: "s0",
                    wordIDs: ["w0"],
                    start: 0.2,
                    end: 0.4,
                    text: "Harbor"
                ),
                MediaTranscriptSegment(
                    id: "s1",
                    wordIDs: ["w1"],
                    start: 0.6,
                    end: 0.8,
                    text: "wakes"
                )
            ],
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeTranscriptWithFiller() -> TranscriptDocument {
        TranscriptDocument(
            schemaVersion: TranscriptDocument.currentSchemaVersion,
            assetID: "transcript-source",
            revisionToken: "revision|1|0",
            localeIdentifier: "en_US",
            provider: .speech,
            words: [
                makeWord(id: "w0", text: "um", start: 0, end: 0.2),
                makeWord(id: "w1", text: "hello", start: 0.4, end: 0.8)
            ],
            segments: [
                MediaTranscriptSegment(
                    id: "s0",
                    wordIDs: ["w0", "w1"],
                    start: 0,
                    end: 0.8,
                    text: "um hello"
                )
            ],
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeWord(
        id: String = "w0",
        text: String = "Harbor",
        start: Double = 0.2,
        end: Double = 0.4
    ) -> TranscriptWord {
        TranscriptWord(
            id: id,
            text: text,
            start: start,
            end: end,
            confidence: nil,
            isFiller: text == "um"
        )
    }
}
