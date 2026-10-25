@preconcurrency import AVFoundation
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
    case multipleAudioTracks
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .busy:
            "Another export is already running."
        case let .unsupportedContainer(extensionName):
            "This file’s .\(extensionName) container cannot be replaced safely by this edit."
        case let .exportFailed(message):
            message
        case .noAudioTrack:
            "The edited file has no audio track."
        case .multipleAudioTracks:
            "This file has more than one audio track. Audio-only export of multiple tracks is not supported yet."
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
        // A same-size/same-mtime in-place write cannot be distinguished from
        // metadata. Destructive replacement therefore takes a content
        // fingerprint before doing any asynchronous work and verifies the
        // bytes swapped out at commit time.
        let expectedFingerprint = mode == .replaceOriginal
            ? try await MediaStorage.fingerprint(for: source.url)
            : nil
        let build = try await MediaCompositionBuilder.build(
            sourceURL: source.url,
            state: state
        )
        let composition = build.composition
        try Task.checkCancellation()

        let hasVideo = build.hasVideo
        if !hasVideo, build.audioTrackCount > 1 {
            throw MediaExportError.multipleAudioTracks
        }
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
                audioMix: build.audioMix,
                outputURL: temporary,
                fileType: fileType
            ) { [weak self] value in
                self?.status = .exporting(progress: value)
            }
        } else {
            try await MediaAudioExporter.export(
                composition: composition,
                audioMix: build.audioMix,
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
            // Stage the output next to the source first. The expensive copy
            // happens before the swap, then only the fast atomic exchange
            // remains after the final revision checks.
            let staged = try await MediaStorage.stageAtomicallyAsync(
                from: temporary,
                to: source.url
            )
            var commitAttempted = false
            defer {
                if !commitAttempted {
                    MediaStorage.removeIfPresent(staged)
                }
            }
            guard MediaStorage.matches(source.revision, url: source.url) else {
                throw MediaStorageError.sourceChanged(source.name)
            }
            let backupDirectory = try MediaStorage.backupDirectory(
                projectName: projectName
            )
            let backupName = "\(MediaStorage.timestamp())-\(source.name)"
            let backup = MediaStorage.uniqueURL(
                in: backupDirectory,
                preferredName: backupName
            )
            try Task.checkCancellation()
            guard let expectedFingerprint else {
                throw MediaStorageError.sourceChanged(source.name)
            }
            commitAttempted = true
            do {
                // The swap moves the exact pre-replacement bytes to `staged`.
                // They become the backup only after the fingerprint and size
                // checks pass, so a concurrent writer is never lost.
                try await MediaStorage.commitStagedReplacement(
                    staged,
                    to: source.url,
                    expectedFingerprint: expectedFingerprint,
                    expectedSize: MediaStorage.fileSize(for: temporary),
                    backupTo: backup
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MediaExportError.exportFailed(
                    error.localizedDescription
                )
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

enum MediaAudioExporter {
    static func export(
        composition: sending AVComposition,
        audioMix: sending AVAudioMix?,
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
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output: AVAssetReaderOutput
        if let audioMix {
            let mixOutput = AVAssetReaderAudioMixOutput(
                audioTracks: [track],
                audioSettings: outputSettings
            )
            mixOutput.audioMix = audioMix
            output = mixOutput
        } else {
            output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: outputSettings
            )
        }
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

    static func audioFormat(
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

private enum MediaAudioRenderer {
    /// Renders the edited composition's audio with the same mix used for
    /// preview. The video mux then carries this AAC track through passthrough,
    /// so the video stream is never re-encoded just to apply a cut fade.
    static func exportAAC(
        composition: sending AVComposition,
        audioMix: sending AVAudioMix,
        outputURL: URL,
        progress: @escaping @Sendable @MainActor (Double) -> Void
    ) async throws {
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw MediaExportError.noAudioTrack
        }
        let format = await MediaAudioExporter.audioFormat(for: track)
        guard format.channelCount <= 2 else {
            throw MediaExportError.exportFailed(
                "Multichannel video audio is not supported yet."
            )
        }
        let duration = try await composition.load(.duration).seconds
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.audioMix = audioMix
        guard reader.canAdd(output) else {
            throw MediaExportError.exportFailed(
                "The edited audio could not be read."
            )
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 192_000
            ]
        )
        guard writer.canAdd(input) else {
            throw MediaExportError.exportFailed(
                "The faded audio could not be written."
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
                "The audio mix reader failed."
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
                "The faded audio writer did not complete."
            )
        }
        await progress(1)
    }
}

/// Confines one non-Sendable export session to the two tasks that drive it.
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

enum MediaVideoExporter {
    static func export(
        composition: sending AVComposition,
        audioMix: sending AVAudioMix?,
        outputURL: URL,
        fileType: AVFileType,
        progress: @escaping @Sendable @MainActor (Double) -> Void
    ) async throws {
        if let audioMix {
            try await exportWithFades(
                composition: composition,
                audioMix: audioMix,
                outputURL: outputURL,
                fileType: fileType,
                progress: progress
            )
            return
        }
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
                await progress(1)
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

    /// Video with a cut fade: render the mixed audio once, then pass the
    /// original compressed video samples through untouched. Attaching an
    /// audioMix to a passthrough export would silently drop it; forcing
    /// HighestQuality would re-encode the entire video and lose its codec.
    private static func exportWithFades(
        composition: sending AVComposition,
        audioMix: sending AVAudioMix,
        outputURL: URL,
        fileType: AVFileType,
        progress: @escaping @Sendable @MainActor (Double) -> Void
    ) async throws {
        let mux = AVMutableComposition()
        let videoTracks = try await composition.loadTracks(
            withMediaType: .video
        )
        guard !videoTracks.isEmpty else {
            throw MediaExportError.missingOutput
        }
        for track in videoTracks {
            let timeRange = try await track.load(.timeRange)
            guard let muxTrack = mux.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw MediaExportError.exportFailed(
                    "The video track could not be copied."
                )
            }
            try muxTrack.insertTimeRange(
                timeRange,
                of: track,
                at: .zero
            )
            muxTrack.preferredTransform = try await track.load(
                .preferredTransform
            )
        }

        // MOV can carry the lossless 24-bit PCM the audio exporter already
        // writes; MP4/M4V require AAC. Keeping MOV lossless also avoids an
        // encoder-delay alignment risk at the cut.
        let audioExtension = fileType == .mov ? "wav" : "m4a"
        let audioURL = try MediaStorage.makeTemporaryURL(
            pathExtension: audioExtension
        )
        defer { MediaStorage.removeIfPresent(audioURL) }
        if fileType == .mov {
            try await MediaAudioExporter.export(
                composition: composition,
                audioMix: audioMix,
                outputURL: audioURL
            ) { value in
                progress(value * 0.5)
            }
        } else {
            try await MediaAudioRenderer.exportAAC(
                composition: composition,
                audioMix: audioMix,
                outputURL: audioURL
            ) { value in
                progress(value * 0.5)
            }
        }

        let audioAsset = AVURLAsset(url: audioURL)
        let audioTracks = try await audioAsset.loadTracks(
            withMediaType: .audio
        )
        guard let sourceAudio = audioTracks.first else {
            throw MediaExportError.noAudioTrack
        }
        let audioRange = try await sourceAudio.load(.timeRange)
        guard let muxAudio = mux.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MediaExportError.exportFailed(
                "The faded audio track could not be added."
            )
        }
        try muxAudio.insertTimeRange(
            audioRange,
            of: sourceAudio,
            at: .zero
        )

        guard let session = AVAssetExportSession(
            asset: mux,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw MediaExportError.unsupportedContainer(
                outputURL.pathExtension
            )
        }
        session.shouldOptimizeForNetworkUse = false
        do {
            try await run(
                session: session,
                outputURL: outputURL,
                fileType: fileType,
                progress: { value in
                    progress(0.5 + value * 0.5)
                }
            )
            await progress(1)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            MediaStorage.removeIfPresent(outputURL)
            throw MediaExportError.exportFailed(error.localizedDescription)
        }
    }

    private static func run(
        session: AVAssetExportSession,
        outputURL: URL,
        fileType: AVFileType,
        progress: @escaping @Sendable @MainActor (Double) -> Void
    ) async throws {
        // AVAssetExportSession is not Sendable, but both tasks below use the
        // same single export operation; the box confines it to them.
        let box = ExportSessionBox(session)
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
            throw error
        }
        progressTask.cancel()
    }
}
