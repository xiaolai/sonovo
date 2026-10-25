import AVFoundation
import CoreVideo
import Foundation
import XCTest
@testable import Sonovo

@MainActor
final class MediaEditingTests: XCTestCase {
    private var temporaryItems: [URL] = []
    private var backupDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryItems {
            try? FileManager.default.removeItem(at: url)
        }
        for url in backupDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryItems = []
        backupDirectories = []
        super.tearDown()
    }

    // MARK: - Edit algebra

    func testTrimDeleteAndResetCloseTheGap() {
        var state = MediaEditState(sourceDuration: 10)
        XCTAssertEqual(state.keepRanges.count, 1)
        _ = state.setSelection(start: 2, end: 4)
        XCTAssertTrue(state.trimToSelection())
        XCTAssertEqual(state.keepRanges, [
            MediaTimeRange(start: 2, duration: 2)
        ])
        XCTAssertEqual(state.editedDuration, 2, accuracy: 0.0001)
        XCTAssertTrue(state.reset())
        XCTAssertEqual(state.keepRanges, [
            MediaTimeRange(start: 0, duration: 10)
        ])

        _ = state.setSelection(start: 3, end: 5)
        XCTAssertTrue(state.deleteSelection())
        XCTAssertEqual(state.keepRanges, [
            MediaTimeRange(start: 0, duration: 3),
            MediaTimeRange(start: 5, duration: 5)
        ])
        XCTAssertEqual(state.editedDuration, 8, accuracy: 0.0001)
        XCTAssertEqual(state.removedRanges, [
            MediaTimeRange(start: 3, duration: 2)
        ])
    }

    func testSourceAndEditedTimeRoundTripAcrossACut() {
        var state = MediaEditState(sourceDuration: 10)
        _ = state.setSelection(start: 4, end: 6)
        XCTAssertTrue(state.deleteSelection())

        XCTAssertEqual(state.sourceTime(forEditedTime: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(state.sourceTime(forEditedTime: 4), 6, accuracy: 0.0001)
        XCTAssertEqual(state.sourceTime(forEditedTime: 6), 8, accuracy: 0.0001)
        XCTAssertEqual(
            state.editedTime(forSourceTime: 4),
            4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            state.editedTime(forSourceTime: 5),
            4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            state.editedTime(forSourceTime: 8),
            6,
            accuracy: 0.0001
        )
    }

    func testDeletingEverythingLeavesAnExplicitEmptyState() {
        var state = MediaEditState(sourceDuration: 3)
        _ = state.setSelection(start: 0, end: 3)
        XCTAssertTrue(state.deleteSelection())
        XCTAssertTrue(state.keepRanges.isEmpty)
        XCTAssertTrue(state.hasEdits)
        XCTAssertEqual(state.editedDuration, 0)
        XCTAssertTrue(state.reset())
        XCTAssertFalse(state.hasEdits)
    }

    // MARK: - Undo and stale sources

    func testUndoRedoAndHistoryBound() {
        let asset = makeAsset(
            url: temporaryFile(named: "undo.wav"),
            kind: .audio
        )
        let document = MediaEditDocument(asset: asset)
        document.prepare(sourceDuration: 100)

        document.setSelection(start: 1, end: 2)
        XCTAssertTrue(document.trimToSelection())
        XCTAssertTrue(document.canUndo)
        XCTAssertTrue(document.undo())
        XCTAssertEqual(
            document.editState?.keepRanges,
            [MediaTimeRange(start: 0, duration: 100)]
        )
        XCTAssertTrue(document.redo())
        XCTAssertEqual(
            document.editState?.keepRanges,
            [MediaTimeRange(start: 1, duration: 1)]
        )
        XCTAssertFalse(document.canRedo)

        document.reset()
        for index in 0..<30 {
            let start = Double(index) + 0.1
            document.setSelection(start: start, end: start + 0.2)
            XCTAssertTrue(document.deleteSelection())
        }
        var undoCount = 0
        while document.undo() {
            undoCount += 1
        }
        XCTAssertLessThanOrEqual(undoCount, 20)
    }

    func testExternalRevisionMarksTheSessionStale() {
        let url = temporaryFile(named: "stale.wav")
        try? Data("source".utf8).write(to: url)
        let asset = makeAsset(url: url, kind: .audio)
        let document = MediaEditDocument(asset: asset)
        document.prepare(sourceDuration: 4)

        let changed = ProjectAsset(
            id: asset.id,
            url: asset.url,
            name: asset.name,
            relativePath: asset.relativePath,
            kind: asset.kind,
            size: asset.size + 1,
            modified: Date().addingTimeInterval(1),
            revision: AssetRevision(
                fileIdentifier: nil,
                size: asset.size + 1,
                modified: Date().addingTimeInterval(1)
            )
        )
        document.observe(asset: changed)

        XCTAssertTrue(document.isStale)
        document.setSelection(start: 1, end: 2)
        XCTAssertFalse(document.trimToSelection())
        document.reload(sourceDuration: 4)
        XCTAssertFalse(document.isStale)
        XCTAssertEqual(
            document.editState?.keepRanges,
            [MediaTimeRange(start: 0, duration: 4)]
        )
    }

    // MARK: - Composition and export

    func testAudioCompositionKeepsTheTrimmedDurationAndChannels() async throws {
        let source = try makeTone(duration: 1, channels: 2)
        let asset = makeAsset(url: source, kind: .audio)
        var state = MediaEditState(sourceDuration: 1)
        _ = state.setSelection(start: 0.2, end: 0.6)
        XCTAssertTrue(state.trimToSelection())

        let build = try await MediaCompositionBuilder.build(
            sourceURL: source,
            state: state
        )
        XCTAssertFalse(build.hasVideo)
        XCTAssertTrue(build.hasAudio)
        XCTAssertEqual(build.duration, 0.4, accuracy: 0.02)
        XCTAssertEqual(build.audioChannelCount, 2)
    }

    func testCompositionPreviewLoadsInTheMediaPlayer() async throws {
        let source = try makeTone(duration: 1, channels: 1)
        var state = MediaEditState(sourceDuration: 1)
        state.setSelection(start: 0.2, end: 0.5)
        XCTAssertTrue(state.trimToSelection())
        let build = try await MediaCompositionBuilder.build(
            sourceURL: source,
            state: state
        )

        let playback = MediaPlaybackModel()
        playback.load(
            asset: build.composition,
            sourceURL: source,
            fileSize: MediaStorage.fileSize(for: source)
        )
        let ready = await waitUntil { playback.state == .ready }
        XCTAssertTrue(ready, "state was \(playback.state)")
        XCTAssertEqual(playback.duration, 0.3, accuracy: 0.03)
        XCTAssertTrue(playback.hasAudio)
        playback.unload()
    }

    func testAudioExportNewTakeWritesPlayableWAV() async throws {
        let source = try makeTone(duration: 1, channels: 2)
        let asset = makeAsset(url: source, kind: .audio)
        var state = MediaEditState(sourceDuration: 1)
        _ = state.setSelection(start: 0.25, end: 0.75)
        XCTAssertTrue(state.trimToSelection())

        let destination = try makeDirectory(named: "export-destination")
        let service = MediaExportService()
        let outcome = try await service.export(
            source: asset,
            state: state,
            destinationDirectory: destination,
            projectName: "MediaEditingTests-\(UUID().uuidString)",
            mode: .newTake
        )

        XCTAssertEqual(outcome.url.pathExtension, "wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.url.path))
        let exported = AVURLAsset(url: outcome.url)
        let duration = try await exported.load(.duration).seconds
        XCTAssertEqual(duration, 0.5, accuracy: 0.03)
        let tracks = try await exported.loadTracks(withMediaType: .audio)
        XCTAssertFalse(tracks.isEmpty)
        let firstTrack = try XCTUnwrap(tracks.first)
        let descriptions = try await firstTrack.load(.formatDescriptions)
        let stream = try XCTUnwrap(
            CMAudioFormatDescriptionGetStreamBasicDescription(
                try XCTUnwrap(descriptions.first)
            )?.pointee
        )
        XCTAssertEqual(stream.mChannelsPerFrame, 2)
    }

    func testReplaceOriginalCreatesBackupAndKeepsTheEdit() async throws {
        let source = try makeTone(duration: 1, channels: 1)
        let asset = makeAsset(url: source, kind: .audio)
        var state = MediaEditState(sourceDuration: 1)
        _ = state.setSelection(start: 0.2, end: 0.8)
        XCTAssertTrue(state.trimToSelection())

        let destination = try makeDirectory(named: "replace-destination")
        let projectName = "MediaEditingTests-\(UUID().uuidString)"
        let service = MediaExportService()
        let outcome = try await service.export(
            source: asset,
            state: state,
            destinationDirectory: destination,
            projectName: projectName,
            mode: .replaceOriginal
        )
        if let backup = outcome.backupURL {
            backupDirectories.append(backup.deletingLastPathComponent())
        }

        let backup = try XCTUnwrap(outcome.backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let replaced = AVURLAsset(url: source)
        let replacedDuration = try await replaced.load(.duration).seconds
        XCTAssertEqual(replacedDuration, 0.6, accuracy: 0.03)
        let backupAsset = AVURLAsset(url: backup)
        let backupDuration = try await backupAsset.load(.duration).seconds
        XCTAssertEqual(backupDuration, 1, accuracy: 0.03)
    }

    func testVideoTrimExportsVideoStreams() async throws {
        let source = try await makeVideo(duration: 1)
        let asset = makeAsset(url: source, kind: .video)
        var state = MediaEditState(sourceDuration: 1)
        _ = state.setSelection(start: 0.2, end: 0.8)
        XCTAssertTrue(state.trimToSelection())

        let destination = try makeDirectory(named: "video-destination")
        let service = MediaExportService()
        let outcome = try await service.export(
            source: asset,
            state: state,
            destinationDirectory: destination,
            projectName: "MediaEditingTests-\(UUID().uuidString)",
            mode: .newTake
        )

        XCTAssertEqual(outcome.url.pathExtension, "mov")
        let exported = AVURLAsset(url: outcome.url)
        let duration = try await exported.load(.duration).seconds
        XCTAssertEqual(duration, 0.6, accuracy: 0.08)
        let tracks = try await exported.loadTracks(withMediaType: .video)
        XCTAssertFalse(tracks.isEmpty)
    }

    // MARK: - Recording

    func testRecorderPreservesTheProbedStereoChannelCount() async throws {
        let engine = FakeRecordingEngine()
        let recorder = AudioRecorder(
            engine: engine,
            access: .granted,
            channelProbe: { 2 },
            inputAvailable: { true }
        )
        let url = temporaryFile(named: "recording.wav")
        try await recorder.start(to: url)

        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(recorder.channelCount, 2)
        XCTAssertEqual(engine.settings?.channelCount, 2)
        XCTAssertEqual(engine.settings?.settings[AVNumberOfChannelsKey] as? Int, 2)
        XCTAssertEqual(engine.startedAt, url)

        let stopped = recorder.stop()
        XCTAssertEqual(stopped, url)
        XCTAssertFalse(recorder.isRecording)
    }

    func testDeniedMicrophoneIsActionableAndDoesNotRecord() async {
        let engine = FakeRecordingEngine()
        let recorder = AudioRecorder(
            engine: engine,
            access: .denied,
            channelProbe: { 1 },
            inputAvailable: { true }
        )
        do {
            try await recorder.start(
                to: temporaryFile(named: "denied.wav")
            )
            XCTFail("recording should not start without permission")
        } catch {
            XCTAssertEqual(recorder.permission, .denied)
            XCTAssertFalse(engine.isRecording)
            XCTAssertTrue(recorder.lastError?.contains("Microphone") == true)
        }
    }

    func testMissingInputIsReportedBeforeStartingTheEngine() async {
        let engine = FakeRecordingEngine()
        let recorder = AudioRecorder(
            engine: engine,
            access: .granted,
            channelProbe: { 1 },
            inputAvailable: { false }
        )
        do {
            try await recorder.start(
                to: temporaryFile(named: "no-input.wav")
            )
            XCTFail("recording should not start without an input device")
        } catch {
            XCTAssertFalse(engine.isRecording)
            XCTAssertTrue(
                recorder.lastError?.contains("No microphone input") == true
            )
        }
    }

    func testRecordingSettingsClampToMonoOrStereo() {
        XCTAssertEqual(AudioRecordingSettings(channelCount: 0).channelCount, 1)
        XCTAssertEqual(AudioRecordingSettings(channelCount: 1).channelCount, 1)
        XCTAssertEqual(AudioRecordingSettings(channelCount: 2).channelCount, 2)
        XCTAssertEqual(AudioRecordingSettings(channelCount: 8).channelCount, 2)
        XCTAssertEqual(
            AudioLevel.meterValue(fromDecibels: -160),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioLevel.meterValue(fromDecibels: 0),
            1,
            accuracy: 0.0001
        )
    }

    // MARK: - Sample registry

    func testAudioMetadataReflectsTheFileNotAProductionRow() throws {
        let source = try makeTone(duration: 0.75, channels: 2)
        let audio = try XCTUnwrap(MediaAudioMetadata.describe(url: source))
        XCTAssertEqual(audio.duration, 0.75, accuracy: 0.02)
        XCTAssertEqual(audio.sampleRate, 44_100, accuracy: 1)
        XCTAssertEqual(audio.channelCount, 2)
        XCTAssertEqual(audio.durationText, "00:00.8")
        XCTAssertEqual(audio.detail, "00:00.8 · 44.1 kHz · Stereo")
    }

    func testSampleRegistryExcludesBundledTakesAndHiddenFiles() throws {
        let directory = try makeDirectory(named: "sample-registry")
        try Data([0, 1]).write(
            to: directory.appendingPathComponent("Recording-1.wav")
        )
        try Data([0, 1]).write(
            to: directory.appendingPathComponent("vo-take-03.wav")
        )
        try Data([0, 1]).write(
            to: directory.appendingPathComponent(".partial.wav")
        )
        let registry = SampleMediaRegistry(directory: directory)

        XCTAssertEqual(registry.recordings.map(\.name), ["Recording-1.wav"])
        XCTAssertNotNil(registry.asset(id: "recording-Recording-1.wav"))
        XCTAssertEqual(
            registry.productionStage()?.title,
            "Recordings"
        )
    }

    func testSampleRegistryReadsTheRealRecordingDuration() throws {
        let directory = try makeDirectory(named: "sample-audio")
        let source = try makeTone(duration: 0.75, channels: 1)
        let target = directory.appendingPathComponent("Recording-tone.wav")
        try FileManager.default.copyItem(at: source, to: target)
        let registry = SampleMediaRegistry(directory: directory)
        let stage = try XCTUnwrap(registry.productionStage())
        let detail = try XCTUnwrap(stage.assets.first?.detail)
        XCTAssertTrue(detail.hasPrefix("00:00.8 · 44.1 kHz · Mono"))
    }

    func testSampleProjectAddsARecordingsStageAndOpensRegisteredTakes() throws {
        let source = try makeDirectory(named: "sample-source")
        let destination = try makeDirectory(named: "sample-destination")
        let name = "Recording-20261025-101010.wav"
        try Data([0, 1]).write(
            to: destination.appendingPathComponent(name)
        )
        let project = Project.demo(
            production: .sample,
            markdown: MarkdownWorkspace(readsDemoEnvironment: false),
            subtitles: SubtitleWorkspace(readsDemoEnvironment: false),
            models: Model3DWorkspace(opensDemoModel: false),
            terminalSessions: TerminalSessionsStore(),
            sampleDocuments: SampleProjectDocuments(
                sourceDirectory: source,
                destinationDirectory: destination
            )
        )

        let stage = try XCTUnwrap(
            project.sampleStages.first { $0.id == "recordings" }
        )
        XCTAssertEqual(stage.title, "Recordings")
        XCTAssertEqual(stage.assets.map(\.name), [name])
        XCTAssertEqual(stage.assets.first?.id, "recording-\(name)")
        XCTAssertNotNil(
            project.sampleMediaAsset(for: "recording-\(name)")
        )

        project.openAsset(id: "recording-\(name)")
        XCTAssertEqual(project.selectedTab?.title, name)
        XCTAssertEqual(project.selectedTab?.kind, .audio)
    }

    // MARK: - Fixtures

    private func makeTone(
        duration: Double,
        channels: AVAudioChannelCount
    ) throws -> URL {
        let url = temporaryFile(named: "tone-\(UUID().uuidString).wav")
        let sampleRate = 44_100.0
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: channels
            )
        )
        let frames = AVAudioFrameCount(duration * sampleRate)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = try XCTUnwrap(buffer.floatChannelData?[channel])
            for index in 0..<Int(frames) {
                data[index] = 0.4 * sin(
                    2 * .pi * 440 * Float(index) / Float(sampleRate)
                )
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings
        )
        try file.write(from: buffer)
        return url
    }

    private func makeVideo(duration: Double) async throws -> URL {
        let url = temporaryFile(named: "video-\(UUID().uuidString).mov")
        let width = 160
        let height = 120
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw MediaTestError.videoWriter
        }
        writer.startSession(atSourceTime: .zero)
        let frameRate: Int32 = 30
        let frameCount = Int(duration * Double(frameRate))
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pool,
                &pixelBuffer
            ) == kCVReturnSuccess,
                  let pixelBuffer else {
                throw MediaTestError.videoWriter
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let length = CVPixelBufferGetBytesPerRow(pixelBuffer)
                    * height
                memset(base, 0x40, length)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let time = CMTime(
                value: Int64(index),
                timescale: frameRate
            )
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw MediaTestError.videoWriter
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw writer.error ?? MediaTestError.videoWriter
        }
        return url
    }

    private func makeAsset(url: URL, kind: AssetKind) -> ProjectAsset {
        let revision = MediaStorage.revision(for: url)
            ?? AssetRevision(fileIdentifier: nil, size: 0, modified: nil)
        return ProjectAsset(
            id: url.path,
            url: url,
            name: url.lastPathComponent,
            relativePath: url.lastPathComponent,
            kind: kind,
            size: revision.size,
            modified: revision.modified,
            revision: revision
        )
    }

    private func temporaryFile(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaEditing-\(UUID().uuidString)-\(name)")
        temporaryItems.append(url)
        return url
    }

    private func makeDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MediaEditing-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        temporaryItems.append(url)
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

@MainActor
private final class FakeRecordingEngine: AudioRecordingEngine {
    var isRecording = false
    var currentTime: TimeInterval = 0
    var averagePower: Float = -20
    private(set) var startedAt: URL?
    private(set) var settings: AudioRecordingSettings?

    func start(to url: URL, settings: AudioRecordingSettings) throws {
        startedAt = url
        self.settings = settings
        isRecording = true
    }

    func stop() {
        isRecording = false
    }

    func cancel() {
        isRecording = false
    }
}

private enum MediaTestError: Error {
    case videoWriter
}
