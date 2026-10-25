import Foundation
import Observation

/// Per-media transcript state. The transcript is derived from the source
/// revision; destructive edits still go through `MediaEditDocument`.
@MainActor
@Observable
final class TranscriptSession {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var document: TranscriptDocument?
    private(set) var sourceLabel: String?
    private(set) var selectedWordIDs: Set<String> = []
    private(set) var captionEdits: [String: String] = [:]
    private(set) var isTranscribing = false

    let asset: ProjectAsset
    private let cache: TranscriptCache
    private var task: Task<Void, Never>?
    private var selectionAnchor: String?

    init(
        asset: ProjectAsset,
        document: TranscriptDocument? = nil,
        cache: TranscriptCache = .shared
    ) {
        self.asset = asset
        self.cache = cache
        self.document = document
        if let document {
            state = .ready
            sourceLabel = label(for: document)
        }
    }

    var hasDocument: Bool { document != nil }

    var statusText: String {
        switch state {
        case .idle:
            "No transcript loaded"
        case .loading:
            isTranscribing ? "Transcribing on device…" : "Loading…"
        case .ready:
            sourceLabel ?? "Transcript ready"
        case let .failed(message):
            message
        }
    }

    func loadCached() async {
        guard document == nil, task == nil else { return }
        state = .loading
        if let cached = await cache.latest(
            assetID: asset.id,
            revisionToken: asset.revision.token,
            schemaVersion: TranscriptDocument.currentSchemaVersion
        ) {
            document = cached
            sourceLabel = label(for: cached)
            state = .ready
        } else {
            state = .idle
        }
    }

    func importSubtitle(from url: URL) async {
        task?.cancel()
        isTranscribing = false
        state = .loading
        let provider = ImportedSubtitleProvider(subtitleURL: url)
        let job = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let document = try await provider.transcript(
                    assetURL: self.asset.url,
                    assetID: self.asset.id,
                    revision: self.asset.revision,
                    locale: Locale.current
                )
                await self.accept(
                    document,
                    label: "Imported: \(url.lastPathComponent) · cue-level"
                )
            } catch {
                self.fail(error)
            }
        }
        task = job
        await job.value
        task = nil
    }

    func transcribe(locale: Locale = .current) async {
        task?.cancel()
        isTranscribing = true
        state = .loading
        let provider = SpeechTranscriberProvider()
        let job = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let document = try await provider.transcript(
                    assetURL: self.asset.url,
                    assetID: self.asset.id,
                    revision: self.asset.revision,
                    locale: locale
                )
                await self.accept(
                    document,
                    label: "On-device: \(document.localeIdentifier)"
                )
            } catch {
                self.fail(error)
            }
        }
        task = job
        await job.value
        task = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        isTranscribing = false
        if case .loading = state {
            state = .idle
        }
    }

    func toggleSelection(
        wordID: String,
        extending: Bool = false
    ) {
        if extending, let anchor = selectionAnchor,
           let start = document?.wordIndex(id: anchor),
           let end = document?.wordIndex(id: wordID) {
            let lower = min(start, end)
            let upper = max(start, end)
            guard let words = document?.words else { return }
            selectedWordIDs = Set(words[lower...upper].map(\.id))
            return
        }
        if selectedWordIDs.contains(wordID) {
            selectedWordIDs.remove(wordID)
        } else {
            selectedWordIDs.insert(wordID)
        }
        selectionAnchor = wordID
    }

    func clearSelection() {
        selectedWordIDs.removeAll()
        selectionAnchor = nil
    }

    func selectFillers(in state: MediaEditState) {
        guard let document else { return }
        selectedWordIDs = Set(
            document.words.filter {
                $0.isFiller && !isRemoved($0, in: state)
            }.map(\.id)
        )
        selectionAnchor = document.words.first {
            selectedWordIDs.contains($0.id)
        }?.id
    }

    func isRemoved(
        _ word: TranscriptWord,
        in state: MediaEditState
    ) -> Bool {
        !state.keepRanges.contains {
            $0.intersection(with: word.sourceRange) != nil
        }
    }

    func captionText(for word: TranscriptWord) -> String {
        captionEdits[word.id] ?? word.text
    }

    func setCaption(_ text: String, for wordID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == document?.word(id: wordID)?.text {
            captionEdits.removeValue(forKey: wordID)
        } else {
            captionEdits[wordID] = trimmed
        }
    }

    func revertCaption(for wordID: String) {
        captionEdits.removeValue(forKey: wordID)
    }

    @discardableResult
    func removeSelectedWords(
        from document: MediaEditDocument
    ) -> MediaEditRemovalResult {
        guard let transcript = document.editState,
              let transcriptDocument = self.document,
              !selectedWordIDs.isEmpty else {
            return .unchanged
        }
        let indices = transcriptDocument.words.indices.filter {
            selectedWordIDs.contains(transcriptDocument.words[$0].id)
                && !isRemoved(
                    transcriptDocument.words[$0],
                    in: transcript
                )
        }
        guard !indices.isEmpty else { return .unchanged }
        var ranges: [MediaTimeRange] = []
        var cursor = 0
        while cursor < indices.count {
            let firstIndex = indices[cursor]
            var lastIndex = firstIndex
            while cursor + 1 < indices.count,
                  indices[cursor + 1] == lastIndex + 1 {
                cursor += 1
                lastIndex = indices[cursor]
            }
            let firstWord = transcriptDocument.words[firstIndex]
            let lastWord = transcriptDocument.words[lastIndex]
            let previousEnd = firstIndex > 0
                ? transcriptDocument.words[firstIndex - 1].end
                : 0
            let nextStart = lastIndex + 1 < transcriptDocument.words.count
                ? transcriptDocument.words[lastIndex + 1].start
                : transcript.sourceDuration
            let lower = max(
                0,
                firstWord.start - MediaEditLimits.transcriptGuardPadding,
                previousEnd
            )
            let upper = min(
                transcript.sourceDuration,
                lastWord.end + MediaEditLimits.transcriptGuardPadding,
                nextStart
            )
            if upper - lower > MediaEditLimits.minimumRangeDuration {
                ranges.append(MediaTimeRange(start: lower, end: upper))
            }
            cursor += 1
        }
        guard !ranges.isEmpty else { return .unchanged }
        let result = document.removeRanges(ranges)
        if result == .changed {
            clearSelection()
        }
        return result
    }

    /// Builds SRT in edited time, using only kept words. It never writes to
    /// the source subtitle file.
    func exportCaptions(in state: MediaEditState) throws -> String {
        guard let document else { throw TranscriptError.emptyTranscript }
        var cues: [(start: Double, end: Double, text: String)] = []
        for segment in document.segments {
            let kept = segment.wordIDs.compactMap { document.word(id: $0) }
                .filter { !isRemoved($0, in: state) }
            guard let first = kept.first, let last = kept.last else {
                continue
            }
            let start = state.editedTime(forSourceTime: first.start)
            let end = max(
                state.editedTime(forSourceTime: last.end),
                start + MediaEditLimits.minimumRangeDuration
            )
            let text = kept
                .map { captionText(for: $0) }
                .joined(separator: " ")
            guard !text.isEmpty else { continue }
            cues.append((start, end, text))
        }
        guard !cues.isEmpty else { throw TranscriptError.emptyTranscript }
        var output = ""
        for (index, cue) in cues.enumerated() {
            output += "\(index + 1)\n"
            output += "\(Self.timestamp(cue.start)) --> "
            output += "\(Self.timestamp(cue.end))\n"
            output += cue.text
            output += "\n\n"
        }
        return output
    }

    private func accept(
        _ document: TranscriptDocument,
        label: String
    ) async {
        self.document = document
        sourceLabel = label
        selectedWordIDs.removeAll()
        captionEdits.removeAll()
        selectionAnchor = nil
        state = .ready
        isTranscribing = false
        let key = TranscriptCacheKey(
            assetID: document.assetID,
            revisionToken: document.revisionToken,
            localeIdentifier: document.localeIdentifier,
            provider: document.provider,
            schemaVersion: document.schemaVersion
        )
        try? await cache.store(document, key: key)
    }

    private func fail(_ error: Error) {
        if error is CancellationError {
            state = .idle
        } else {
            state = .failed(error.localizedDescription)
        }
        isTranscribing = false
    }

    private func label(for document: TranscriptDocument) -> String {
        switch document.provider {
        case .imported:
            "Imported transcript"
        case .speech:
            "On-device: \(document.localeIdentifier)"
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        let bounded = max(seconds, 0)
        let totalMilliseconds = Int((bounded * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let secondsPart = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        return String(
            format: "%02d:%02d:%02d,%03d",
            hours, minutes, secondsPart, milliseconds
        )
    }
}
