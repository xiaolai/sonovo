import AVFoundation
import CoreMedia
import Foundation
import Observation

enum MediaExportMode: String, Sendable {
    case newTake
    case replaceOriginal
}

struct MediaExportOutcome: Sendable {
    let url: URL
    let backupURL: URL?
}

enum MediaExportError: LocalizedError, Equatable {
    case busy
    case unsupportedContainer(String)
    case exportFailed(String)
    case noAudioTrack
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .busy:
            "Another export is already running."
        case let .unsupportedContainer(extensionName):
            "This file’s .\(extensionName) container cannot be replaced by a lossless edit."
        case let .exportFailed(message):
            message
        case .noAudioTrack:
            "The edited file has no audio track."
        case .missingOutput:
            "The exporter did not produce a file."
        }
    }
}

/// One export at a time. The source is never touched until the temp export is
/// complete; replacement installs through a hidden sibling and keeps a
/// timestamped backup outside the project tree.
@MainActor
@Observable
final class MediaExportService {
    enum Status: Equatable, Sendable {
        case idle
        case preparing
        case exporting(progress: Double)
        case failed(String)

        var progress: Double? {
            if case let .exporting(progress) = self { return progress }
            return nil
        }
    }

    private(set) var status: Status = .idle
    private(set) var isBusy = false
    private var task: Task<MediaExportOutcome, Error>?

    var progress: Double? { status.progress }

    func cancel() {
        task?.cancel()
    }

    static func canReplace(source: ProjectAsset) -> Bool {
        switch source.kind {
        case .audio:
            return source.fileExtension == "wav"
        case .video:
            return ["mov", "mp4", "m4v"].contains(source.fileExtension)
        default:
            return false
        }
    }

    static func newTakeExtension(for source: ProjectAsset, hasVideo: Bool) -> String {
        guard hasVideo else { return "wav" }
        let sourceExtension = source.fileExtension
        return ["mov", "mp4", "m4v"].contains(sourceExtension)
            ? sourceExtension
            : "mov"
    }

    func export(
        source: ProjectAsset,
        state: MediaEditState,
        destinationDirectory: URL,
        projectName: String,
        mode: MediaExportMode
    ) async throws -> MediaExportOutcome {
        guard !isBusy else { throw MediaExportError.busy }
        isBusy = true
        status = .preparing
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.perform(
                source: source,
                state: state,
                destinationDirectory: destinationDirectory,
                projectName: projectName,
                mode: mode
            )
        }
        self.task = task
        defer {
            self.task = nil
            isBusy = false
        }
        do {
            let outcome = try await task.value
            status = .idle
            return outcome
        } catch is CancellationError {
            status = .idle
            throw CancellationError()
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    private func perform(
        source: ProjectAsset,
        state: MediaEditState,
        destinationDirectory: URL,
        projectName: String,
        mode: MediaExportMode
    ) async throws -> MediaExportOutcome {
        guard MediaStorage.matches(source.revision, url: source.url) else {
            throw MediaStorageError.sourceChanged(source.name)
        }
        let build = try await MediaCompositionBuilder.build(
            sourceURL: source.url,
            state: state
        )
        let composition = build.composition
        try Task.checkCancellation()

        let hasVideo = build.hasVideo
        let outputExtension = Self.newTakeExtension(
            for: source,
            hasVideo: hasVideo
        )
        if mode == .replaceOriginal {
            guard Self.canReplace(source: source),
                  outputExtension == source.fileExtension else {
                throw MediaExportError.unsupportedContainer(
                    source.fileExtension
                )
            }
        }

        let temporary = try MediaStorage.makeTemporaryURL(
            pathExtension: outputExtension
        )
        defer { MediaStorage.removeIfPresent(temporary) }

        if hasVideo {
            let fileType = Self.fileType(for: outputExtension)
            try await MediaVideoExporter.export(
                composition: composition,
                outputURL: temporary,
                fileType: fileType
            ) { [weak self] value in
                self?.status = .exporting(progress: value)
            }
        } else {
            try await MediaAudioExporter.export(
                composition: composition,
                outputURL: temporary
            ) { [weak self] value in
                self?.status = .exporting(progress: value)
            }
        }
        try Task.checkCancellation()
        guard MediaStorage.fileSize(for: temporary) > 0 else {
            throw MediaExportError.missingOutput
        }
        guard MediaStorage.matches(source.revision, url: source.url) else {
            throw MediaStorageError.sourceChanged(source.name)
        }

        switch mode {
        case .newTake:
            let name = Self.newTakeName(
                source: source,
                extension: outputExtension
            )
            let destination = MediaStorage.uniqueURL(
                in: destinationDirectory,
                preferredName: name
            )
            try await MediaStorage.installAtomicallyAsync(
                from: temporary,
                to: destination,
                replacing: false
            )
            return MediaExportOutcome(url: destination, backupURL: nil)
        case .replaceOriginal:
            try Task.checkCancellation()
            let backupDirectory = try MediaStorage.backupDirectory(
                projectName: projectName
            )
            let backupName = "\(MediaStorage.timestamp())-\(source.name)"
            let backup = MediaStorage.uniqueURL(
                in: backupDirectory,
                preferredName: backupName
            )
            try await MediaStorage.copyItemAsync(
                from: source.url,
                to: backup
            )
            try Task.checkCancellation()
            do {
                try await MediaStorage.installAtomicallyAsync(
                    from: temporary,
                    to: source.url,
                    replacing: true
                )
            } catch {
                throw MediaExportError.exportFailed(
                    error.localizedDescription
                )
            }
            let installedSize = MediaStorage.fileSize(for: source.url)
            let exportedSize = MediaStorage.fileSize(for: temporary)
            guard installedSize > 0, installedSize == exportedSize else {
                try? await MediaStorage.installAtomicallyAsync(
                    from: backup,
                    to: source.url,
                    replacing: true
                )
                throw MediaStorageError.replaceVerificationFailed
            }
            return MediaExportOutcome(url: source.url, backupURL: backup)
        }
    }

    private static func newTakeName(
        source: ProjectAsset,
        extension pathExtension: String
    ) -> String {
        let stem = source.url.deletingPathExtension().lastPathComponent
        return "\(stem)-edit-\(MediaStorage.timestamp()).\(pathExtension)"
    }

    private static func fileType(for pathExtension: String) -> AVFileType {
        switch pathExtension {
        case "mp4", "m4v": .mp4
        default: .mov
        }
    }
}

private enum MediaAudioExporter {
    static func export(
        composition: sending AVComposition,
        outputURL: URL,
        progress: @escaping @Sendable @MainActor (Double) -> Void
    ) async throws {
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw MediaExportError.noAudioTrack
        }
        let format = await audioFormat(for: track)
        let duration = try await composition.load(.duration).seconds
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        guard reader.canAdd(output) else {
            throw MediaExportError.exportFailed(
                "The edited audio could not be read."
            )
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        guard writer.canAdd(input) else {
            throw MediaExportError.exportFailed(
                "The edited audio could not be written."
            )
        }
        let receiver = writer.inputReceiver(for: input)
        let provider = reader.outputProvider(for: output)
        do {
            try writer.start()
            writer.startSession(atSourceTime: .zero)
            try reader.start()
        } catch {
            writer.cancelWriting()
            throw error
        }

        do {
            while let sample = try await provider.next() {
                try Task.checkCancellation()
                try await receiver.append(sample)
                if duration > 0 {
                    let time = sample.presentationTimeStamp.seconds
                    await progress(min(max(time / duration, 0), 0.99))
                }
            }
        } catch {
            reader.cancelReading()
            receiver.finish()
            writer.cancelWriting()
            throw error
        }
        if reader.status == .failed {
            receiver.finish()
            writer.cancelWriting()
            throw reader.error ?? MediaExportError.exportFailed(
                "The audio reader failed."
            )
        }
        receiver.finish()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw writer.error ?? MediaExportError.exportFailed(
                "The audio writer did not complete."
            )
        }
        await progress(1)
    }

    private static func audioFormat(
        for track: AVAssetTrack
    ) async -> (sampleRate: Double, channelCount: Int) {
        guard let descriptions = try? await track.load(.formatDescriptions),
              let first = descriptions.first,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(
                  first
              )?.pointee,
              stream.mSampleRate.isFinite,
              stream.mSampleRate > 0 else {
            return (48_000, 2)
        }
        let channels = max(Int(stream.mChannelsPerFrame), 1)
        return (stream.mSampleRate, channels)
    }
}

@MainActor
private enum MediaVideoExporter {
    static func export(
        composition: AVComposition,
        outputURL: URL,
        fileType: AVFileType,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        // Passthrough keeps the source streams untouched. A container or
        // codec the file type cannot carry fails; the highest-quality preset
        // is the single re-encode fallback.
        for preset in [
            AVAssetExportPresetPassthrough,
            AVAssetExportPresetHighestQuality
        ] {
            guard let session = AVAssetExportSession(
                asset: composition,
                presetName: preset
            ) else {
                continue
            }
            session.shouldOptimizeForNetworkUse = false
            do {
                try await run(
                    session: session,
                    outputURL: outputURL,
                    fileType: fileType,
                    progress: progress
                )
                progress(1)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                MediaStorage.removeIfPresent(outputURL)
                if preset == AVAssetExportPresetHighestQuality {
                    throw MediaExportError.exportFailed(
                        error.localizedDescription
                    )
                }
            }
        }
        throw MediaExportError.unsupportedContainer(
            outputURL.pathExtension
        )
    }

    private static func run(
        session: AVAssetExportSession,
        outputURL: URL,
        fileType: AVFileType,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let exportTask = Task { @MainActor in
            try await session.export(to: outputURL, as: fileType)
        }
        let progressTask = Task { @MainActor in
            for await state in session.states(updateInterval: 0.1) {
                if case let .exporting(value) = state {
                    progress(
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
            throw error
        }
        progressTask.cancel()
    }
}
