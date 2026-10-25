import Foundation

enum TranscriptProviderKind: String, Codable, Sendable {
    case imported
    case speech
}

/// One word or cue-level token in source time. The ID is stable within one
/// cached document so selection and caption edits survive view updates.
struct TranscriptWord: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var text: String
    let start: Double
    let end: Double
    let confidence: Float?
    let isFiller: Bool

    var sourceRange: MediaTimeRange {
        MediaTimeRange(start: start, end: end)
    }

    var duration: Double { max(0, end - start) }
}

struct MediaTranscriptSegment: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let wordIDs: [String]
    let start: Double
    let end: Double
    let text: String

    var sourceRange: MediaTimeRange {
        MediaTimeRange(start: start, end: end)
    }
}

struct TranscriptDocument: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let assetID: String
    let revisionToken: String
    let localeIdentifier: String
    let provider: TranscriptProviderKind
    let words: [TranscriptWord]
    let segments: [MediaTranscriptSegment]
    let createdAt: Date

    func word(id: String) -> TranscriptWord? {
        words.first { $0.id == id }
    }

    func wordIndex(id: String) -> Int? {
        words.firstIndex { $0.id == id }
    }

    func segment(for wordID: String) -> MediaTranscriptSegment? {
        segments.first { $0.wordIDs.contains(wordID) }
    }

    /// Kept words in source order, with their segment text after caption
    /// edits. Removed words stay in the document so undo can bring them back.
    func keptWords(in state: MediaEditState) -> [TranscriptWord] {
        words.filter { word in
            state.keepRanges.contains {
                $0.intersection(with: word.sourceRange) != nil
            }
        }
    }
}

enum TranscriptFiller {
    private static let english: Set<String> = [
        "ah", "erm", "hmm", "mm", "uh", "um", "umm"
    ]

    static func isFiller(
        _ text: String,
        localeIdentifier: String
    ) -> Bool {
        guard localeIdentifier.lowercased().hasPrefix("en") else {
            return false
        }
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return english.contains(normalized)
    }
}
