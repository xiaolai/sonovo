import CryptoKit
import CoreMedia
import Foundation
@preconcurrency import AVFoundation

struct TimelineExportResult: Sendable {
    let url: URL
    let peak: Float
    let duration: CMTime
}

enum TimelineExportError: LocalizedError, Equatable {
    case peakOverFullScale(Float)
    case sourceChanged
    case invalidOutput(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case let .peakOverFullScale(peak):
            String(
                format: "The mix peaks at %.1f dBFS. Lower a clip gain before exporting.",
                TimelineAudioPeak.decibels(peak)
            )
        case .sourceChanged:
            "A source file changed during export; the output was discarded."
        case let .invalidOutput(reason):
            "The exported timeline is invalid: \(reason)"
        case let .exportFailed(reason):
            "The timeline export failed: \(reason)"
        }
    }
}

private final class TimelineExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

enum TimelineExportService {
    static func export(
        timeline: ProjectTimeline,
        assets: [ProjectAsset],
        destinationDirectory: URL,
        beforeInstall: @Sendable () async throws -> Void = {},
        progress: @escaping @Sendable @MainActor (Double) -> Void
    ) async throws -> TimelineExportResult {
        let sources = referencedSources(timeline: timeline, assets: assets)
        let fingerprints = try sources.mapValues { try fingerprint($0.url) }
        let built = try await ProjectTimelineCompositionBuilder.build(
            timeline: timeline,
            assets: assets
        )
        let peak = try await TimelineAudioPeak.measure(
            asset: built.composition,
            audioMix: built.audioMix
        )
        guard peak <= 1 else {
            throw TimelineExportError.peakOverFullScale(peak)
        }
        let hasVideo = !timeline.videoTrack.clips.isEmpty
        let fileType: AVFileType = hasVideo ? .mov : .m4a
        let fileExtension = hasVideo ? "mov" : "m4a"
        let temporaryDirectory = try exportDirectory()
        let temporaryURL = temporaryDirectory.appendingPathComponent(
            "\(UUID().uuidString).\(fileExtension)"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let presetName = hasVideo
            ? AVAssetExportPresetHighestQuality
            : AVAssetExportPresetAppleM4A
        guard let session = AVAssetExportSession(
            asset: built.composition,
            presetName: presetName
        ) else {
            throw TimelineExportError.exportFailed(
                "No compatible export preset is available."
            )
        }
        if hasVideo {
            session.videoComposition = built.videoComposition
        }
        session.audioMix = built.audioMix
        session.shouldOptimizeForNetworkUse = false
        try await run(
            session: session,
            outputURL: temporaryURL,
            fileType: fileType,
            progress: progress
        )
        try Task.checkCancellation()
        try await validate(
            output: temporaryURL,
            timeline: timeline
        )
        try await beforeInstall()
        try Task.checkCancellation()
        for (path, original) in fingerprints {
            guard let asset = sources[path],
                  try fingerprint(asset.url) == original else {
                throw TimelineExportError.sourceChanged
            }
        }
        let destination = uniqueDestination(
            in: destinationDirectory,
            fileExtension: fileExtension
        )
        try await MediaStorage.installAtomicallyAsync(
            from: temporaryURL,
            to: destination,
            replacing: false
        )
        await progress(1)
        return TimelineExportResult(
            url: destination,
            peak: peak,
            duration: timeline.duration
        )
    }

    private static func referencedSources(
        timeline: ProjectTimeline,
        assets: [ProjectAsset]
    ) -> [String: ProjectAsset] {
        let byPath = Dictionary(
            assets.map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var sources: [String: ProjectAsset] = [:]
        for clip in timeline.allClips {
            if let asset = byPath[clip.relativePath] {
                sources[clip.relativePath] = asset
            }
        }
        return sources
    }

    private static func fingerprint(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20),
              !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func exportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("Sonovo", isDirectory: true)
            .appendingPathComponent("TimelineExports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func uniqueDestination(
        in directory: URL,
        fileExtension: String
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "Timeline-\(formatter.string(from: Date()))"
        var url = directory.appendingPathComponent(
            "\(base).\(fileExtension)"
        )
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(
                "\(base)-\(index).\(fileExtension)"
            )
            index += 1
        }
        return url
    }

    private static func validate(
        output: URL,
        timeline: ProjectTimeline
    ) async throws {
        let asset = AVURLAsset(url: output)
        guard let playable = try? await asset.load(.isPlayable),
              playable else {
            throw TimelineExportError.invalidOutput("not playable")
        }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric,
              abs(duration.seconds - timeline.duration.seconds) < 0.15 else {
            throw TimelineExportError.invalidOutput("duration mismatch")
        }
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        if !timeline.videoTrack.clips.isEmpty, video.isEmpty {
            throw TimelineExportError.invalidOutput("video track missing")
        }
        if !timeline.voiceTrack.clips.isEmpty
            || !timeline.musicTrack.clips.isEmpty {
            if audio.isEmpty {
                throw TimelineExportError.invalidOutput("audio track missing")
            }
        }
    }

    private static func run(
        session: AVAssetExportSession,
        outputURL: URL,
        fileType: AVFileType,
        progress: @escaping @Sendable @MainActor (Double) -> Void
    ) async throws {
        let box = TimelineExportSessionBox(session)
        let exportTask = Task {
            try await box.session.export(to: outputURL, as: fileType)
        }
        let progressTask = Task {
            for await state in box.session.states(updateInterval: 0.1) {
                if case let .exporting(value) = state {
                    await progress(
                        min(max(value.fractionCompleted, 0), 0.99)
                    )
                }
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await exportTask.value
            } onCancel: {
                exportTask.cancel()
            }
        } catch {
            progressTask.cancel()
            if Task.isCancelled {
                throw CancellationError()
            }
            throw TimelineExportError.exportFailed(
                error.localizedDescription
            )
        }
        progressTask.cancel()
    }
}
