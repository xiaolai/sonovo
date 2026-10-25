import Foundation
import SonovoCore

enum TranscriptError: LocalizedError, Equatable {
    case noAudio
    case unavailable
    case unsupportedLocale(String)
    case emptyTranscript
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudio:
            "This file has no audio track to transcribe."
        case .unavailable:
            "On-device transcription is not available on this Mac."
        case let .unsupportedLocale(identifier):
            "No speech model is available for \(identifier)."
        case .emptyTranscript:
            "No speech was recognized in this file."
        case let .readFailed(message):
            message
        }
    }
}

protocol TranscriptProvider: Sendable {
    func transcript(
        assetURL: URL,
        assetID: String,
        revision: AssetRevision,
        locale: Locale
    ) async throws -> TranscriptDocument
}

/// Converts existing subtitle cues into the same source-time transcript
/// model. Imported cues are cue-level only, so the UI must not claim
/// word-level precision for them.
struct ImportedSubtitleProvider: TranscriptProvider {
    let subtitleURL: URL
    var fileStore = SubtitleFileStore()

    func transcript(
        assetURL: URL,
        assetID: String,
        revision: AssetRevision,
        locale: Locale
    ) async throws -> TranscriptDocument {
        let loaded: LoadedSubtitle
        do {
            loaded = try fileStore.read(subtitleURL)
        } catch {
            throw TranscriptError.readFailed(error.localizedDescription)
        }
        let parsed = SubtitleParser.parse(
            loaded.contents.text,
            format: loaded.format
        )
        var words: [TranscriptWord] = []
        var segments: [MediaTranscriptSegment] = []
        for cue in parsed.cues where cue.hasValidTiming {
            let text = SubtitleText.plainText(
                cue.rawText,
                format: loaded.format
            )
            guard !text.isEmpty else { continue }
            let id = "cue-\(cue.ordinal)"
            let start = Double(cue.startMilliseconds) / 1000
            let end = Double(cue.endMilliseconds) / 1000
            words.append(
                TranscriptWord(
                    id: id,
                    text: text,
                    start: start,
                    end: end,
                    confidence: nil,
                    isFiller: TranscriptFiller.isFiller(
                        text,
                        localeIdentifier: locale.identifier
                    )
                )
            )
            segments.append(
                MediaTranscriptSegment(
                    id: "segment-\(cue.ordinal)",
                    wordIDs: [id],
                    start: start,
                    end: end,
                    text: text
                )
            )
        }
        guard !words.isEmpty else { throw TranscriptError.emptyTranscript }
        return TranscriptDocument(
            schemaVersion: TranscriptDocument.currentSchemaVersion,
            assetID: assetID,
            revisionToken: revision.token,
            localeIdentifier: locale.identifier,
            provider: .imported,
            words: words,
            segments: segments,
            createdAt: Date()
        )
    }
}
