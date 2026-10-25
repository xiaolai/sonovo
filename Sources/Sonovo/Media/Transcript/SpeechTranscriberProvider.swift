import AVFoundation
import Foundation
import Speech

/// On-device speech transcription through SpeechAnalyzer. The transcriber
/// modules do not send the audio to Apple's servers; the system installs the
/// locale model first.
struct SpeechTranscriberProvider: TranscriptProvider {
    func transcript(
        assetURL: URL,
        assetID: String,
        revision: AssetRevision,
        locale: Locale
    ) async throws -> TranscriptDocument {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptError.unavailable
        }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: locale
        ) else {
            throw TranscriptError.unsupportedLocale(locale.identifier)
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
        }

        let asset = AVURLAsset(url: assetURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw TranscriptError.noAudio
        }
        let provider = try await AssetInputSequenceProvider.provider(
            from: asset,
            track: audioTrack,
            compatibleWith: [transcriber]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [SpeechTranscriber.Result] in
            var results: [SpeechTranscriber.Result] = []
            for try await result in transcriber.results {
                results.append(result)
            }
            return results
        }

        do {
            let last = try await analyzer.analyzeSequence(
                provider.analyzerInputs
            )
            if let last {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        let results = try await collector.value
        let document = Self.document(
            from: results,
            assetID: assetID,
            revision: revision,
            localeIdentifier: supportedLocale.identifier
        )
        guard !document.words.isEmpty else {
            throw TranscriptError.emptyTranscript
        }
        return document
    }

    private static func document(
        from results: [SpeechTranscriber.Result],
        assetID: String,
        revision: AssetRevision,
        localeIdentifier: String
    ) -> TranscriptDocument {
        var words: [TranscriptWord] = []
        var segments: [MediaTranscriptSegment] = []
        for (segmentIndex, result) in results.enumerated() {
            var segmentWords: [TranscriptWord] = []
            for run in result.text.runs {
                let raw = String(result.text[run.range].characters)
                let text = raw.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !text.isEmpty else { continue }
                let range = run[
                    AttributeScopes.SpeechAttributes.TimeRangeAttribute.self
                ] ?? result.range
                guard range.duration.seconds.isFinite,
                      range.duration.seconds > 0 else {
                    continue
                }
                let id = "s\(segmentIndex)-w\(segmentWords.count)"
                segmentWords.append(
                    TranscriptWord(
                        id: id,
                        text: text,
                        start: max(range.start.seconds, 0),
                        end: range.end.seconds,
                        confidence: nil,
                        isFiller: TranscriptFiller.isFiller(
                            text,
                            localeIdentifier: localeIdentifier
                        )
                    )
                )
            }
            guard !segmentWords.isEmpty else { continue }
            let start = segmentWords.map(\.start).min() ?? 0
            let end = segmentWords.map(\.end).max() ?? start
            let segmentID = "segment-\(segmentIndex)"
            for index in segmentWords.indices {
                let word = segmentWords[index]
                segmentWords[index] = TranscriptWord(
                    id: "\(segmentID)-\(word.id)",
                    text: word.text,
                    start: word.start,
                    end: word.end,
                    confidence: word.confidence,
                    isFiller: word.isFiller
                )
            }
            words.append(contentsOf: segmentWords)
            segments.append(
                MediaTranscriptSegment(
                    id: segmentID,
                    wordIDs: segmentWords.map(\.id),
                    start: start,
                    end: end,
                    text: String(result.text.characters)
                )
            )
        }
        return TranscriptDocument(
            schemaVersion: TranscriptDocument.currentSchemaVersion,
            assetID: assetID,
            revisionToken: revision.token,
            localeIdentifier: localeIdentifier,
            provider: .speech,
            words: words,
            segments: segments,
            createdAt: Date()
        )
    }
}
