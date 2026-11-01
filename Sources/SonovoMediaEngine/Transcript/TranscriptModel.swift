import SonovoDocumentSupport
import SonovoFileIO
import SonovoDomainTypes
import Foundation

package enum TranscriptProviderKind: String, Codable, Sendable {
    case imported
    case speech
}

/// One word or cue-level token in source time. The ID is stable within one
/// cached document so selection and caption edits survive view updates.
package struct TranscriptWord: Identifiable, Codable, Sendable, Equatable {
    package let id: String
    package var text: String
    package let start: Double
    package let end: Double
    package let confidence: Float?
    package let isFiller: Bool

    package var sourceRange: MediaTimeRange {
        MediaTimeRange(start: start, end: end)
    }

    package var duration: Double { max(0, end - start) }
}

package struct MediaTranscriptSegment: Identifiable, Codable, Sendable, Equatable {
    package let id: String
    package let wordIDs: [String]
    package let start: Double
    package let end: Double
    package let text: String

    package var sourceRange: MediaTimeRange {
        MediaTimeRange(start: start, end: end)
    }
}

package struct TranscriptDocument: Codable, Sendable, Equatable {
    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    package let assetID: String
    package let revisionToken: String
    package let localeIdentifier: String
    package let provider: TranscriptProviderKind
    package let words: [TranscriptWord]
    package let segments: [MediaTranscriptSegment]
    package let createdAt: Date

    package func word(id: String) -> TranscriptWord? {
        words.first { $0.id == id }
    }

    package func wordIndex(id: String) -> Int? {
        words.firstIndex { $0.id == id }
    }

    package func segment(for wordID: String) -> MediaTranscriptSegment? {
        segments.first { $0.wordIDs.contains(wordID) }
    }

    /// Kept words in source order, with their segment text after caption
    /// edits. Removed words stay in the document so undo can bring them back.
    package func keptWords(in state: MediaEditState) -> [TranscriptWord] {
        words.filter { word in
            state.keepRanges.contains {
                $0.intersection(with: word.sourceRange) != nil
            }
        }
    }
}

package enum TranscriptFiller {
    private static let english: Set<String> = [
        "ah", "erm", "hmm", "mm", "uh", "um", "umm"
    ]

    package static func isFiller(
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
