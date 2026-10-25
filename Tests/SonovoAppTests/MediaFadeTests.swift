@preconcurrency import AVFoundation
import XCTest
@testable import Sonovo

final class MediaFadePlannerTests: XCTestCase {
    func testFreshFullFileHasNoFades() {
        let plan = MediaAudioFadePlanner.plan(
            insertions: [
                MediaAudioInsertion(
                    trackID: 1,
                    sourceRange: MediaTimeRange(start: 0, duration: 10),
                    insertedStart: 0,
                    insertedDuration: 10,
                    isFirstInTrack: true,
                    isLastInTrack: true
                )
            ],
            sourceDuration: 10
        )
        XCTAssertFalse(plan.hasFades)
        XCTAssertTrue(plan.spans.isEmpty)
    }

    func testTrimCreatesHeadAndTailFades() {
        let plan = MediaAudioFadePlanner.plan(
            insertions: [
                MediaAudioInsertion(
                    trackID: 1,
                    sourceRange: MediaTimeRange(start: 0.5, duration: 1),
                    insertedStart: 0,
                    insertedDuration: 1,
                    isFirstInTrack: true,
                    isLastInTrack: true
                )
            ],
            sourceDuration: 2
        )
        XCTAssertEqual(plan.spans.count, 1)
        let span = plan.spans[0]
        XCTAssertEqual(span.fadeIn?.start ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(
            span.fadeIn?.duration ?? -1,
            MediaEditLimits.cutFadeDuration,
            accuracy: 0.0001
        )
        XCTAssertEqual(span.fadeOut?.start ?? -1, 0.97, accuracy: 0.0001)
    }

    func testInteriorCutGetsFadeOutThenFadeInAtTheSameCompositionTime() {
        let plan = MediaAudioFadePlanner.plan(
            insertions: [
                MediaAudioInsertion(
                    trackID: 1,
                    sourceRange: MediaTimeRange(start: 0, duration: 0.6),
                    insertedStart: 0,
                    insertedDuration: 0.6,
                    isFirstInTrack: true,
                    isLastInTrack: false
                ),
                MediaAudioInsertion(
                    trackID: 1,
                    sourceRange: MediaTimeRange(start: 1, duration: 0.6),
                    insertedStart: 0.6,
                    insertedDuration: 0.6,
                    isFirstInTrack: false,
                    isLastInTrack: true
                )
            ],
            sourceDuration: 10
        )
        XCTAssertEqual(plan.spans.count, 2)
        XCTAssertEqual(
            plan.spans[0].fadeOut?.end ?? -1,
            0.6,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            plan.spans[1].fadeIn?.start ?? -1,
            0.6,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            plan.spans[1].fadeOut?.start ?? -1,
            1.17,
            accuracy: 0.0001
        )
    }

    func testOffsetTrackFadesInAtItsInsertTime() {
        let plan = MediaAudioFadePlanner.plan(
            insertions: [
                MediaAudioInsertion(
                    trackID: 1,
                    sourceRange: MediaTimeRange(start: 0, duration: 1),
                    insertedStart: 0.5,
                    insertedDuration: 1,
                    isFirstInTrack: true,
                    isLastInTrack: true
                )
            ],
            sourceDuration: 10
        )
        XCTAssertEqual(plan.spans.count, 1)
        XCTAssertEqual(
            plan.spans[0].fadeIn?.start ?? -1,
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            plan.spans[0].fadeOut?.start ?? -1,
            1.47,
            accuracy: 0.0001
        )
    }

    func testShortSpanClampsFadesToHalf() {
        let plan = MediaAudioFadePlanner.plan(
            insertions: [
                MediaAudioInsertion(
                    trackID: 1,
                    sourceRange: MediaTimeRange(start: 1, duration: 0.02),
                    insertedStart: 0,
                    insertedDuration: 0.02,
                    isFirstInTrack: true,
                    isLastInTrack: true
                )
            ],
            sourceDuration: 10
        )
        XCTAssertEqual(plan.spans.count, 1)
        XCTAssertEqual(
            plan.spans[0].fadeIn?.duration ?? -1,
            0.01,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            plan.spans[0].fadeOut?.duration ?? -1,
            0.01,
            accuracy: 0.0001
        )
    }
}

@MainActor
final class MediaCompositionFadeTests: XCTestCase {
    private var temporaryItems: [URL] = []

    override func tearDown() {
        for url in temporaryItems {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryItems = []
        super.tearDown()
    }

    func testCutBuildReturnsAMixAndFullBuildDoesNot() async throws {
        let source = try makeTone(duration: 2)
        let full = try await MediaCompositionBuilder.build(
            sourceURL: source,
            state: MediaEditState(sourceDuration: 2)
        )
        XCTAssertFalse(full.fadePlan.hasFades)
        XCTAssertNil(full.audioMix)

        let cut = try await MediaCompositionBuilder.build(
            sourceURL: source,
            state: MediaEditState(
                sourceDuration: 2,
                keepRanges: [
                    MediaTimeRange(start: 0, duration: 0.6),
                    MediaTimeRange(start: 1, duration: 0.6)
                ]
            )
        )
        XCTAssertTrue(cut.fadePlan.hasFades)
        XCTAssertNotNil(cut.audioMix)
        XCTAssertEqual(cut.audioMix?.inputParameters.count, 1)
    }

    func testExportedWAVHasAFadeAtTheCut() async throws {
        let source = try makeTone(duration: 2)
        let state = MediaEditState(
            sourceDuration: 2,
            keepRanges: [
                MediaTimeRange(start: 0, duration: 0.6),
                MediaTimeRange(start: 1, duration: 0.6)
            ]
        )
        let mixedBuild = try await MediaCompositionBuilder.build(
            sourceURL: source,
            state: state
        )
        let mixed = try temporaryOutput(extension: "wav")
        let dry = try temporaryOutput(extension: "wav")
        try await MediaAudioExporter.export(
            composition: mixedBuild.composition,
            audioMix: mixedBuild.audioMix,
            outputURL: mixed
        ) { _ in }
        let dryBuild = try await MediaCompositionBuilder.build(
            sourceURL: source,
            state: state
        )
        try await MediaAudioExporter.export(
            composition: dryBuild.composition,
            audioMix: nil,
            outputURL: dry
        ) { _ in }

        let mixedSamples = try await readSamples(from: mixed)
        let drySamples = try await readSamples(from: dry)
        let join = Int(0.6 * 44_100)
        let window = 44
        let mixedPeak = peak(mixedSamples, around: join, radius: window)
        let dryPeak = peak(drySamples, around: join, radius: window)
        XCTAssertLessThan(mixedPeak, 0.02)
        XCTAssertLessThan(mixedPeak, dryPeak * 0.2)
    }

    func testNewTakeAndReplacePreserveFades() async throws {
        let source = try makeTone(duration: 2)
        let revision = try XCTUnwrap(
            MediaStorage.revision(for: source)
        )
        let asset = ProjectAsset(
            id: source.path,
            url: source,
            name: source.lastPathComponent,
            relativePath: source.lastPathComponent,
            kind: .audio,
            size: revision.size,
            modified: revision.modified,
            revision: revision
        )
        let state = MediaEditState(
            sourceDuration: 2,
            keepRanges: [
                MediaTimeRange(start: 0, duration: 0.6),
                MediaTimeRange(start: 1, duration: 0.6)
            ]
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fade-destination-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        temporaryItems.append(destination)
        let projectName = "MediaFadeTests-\(UUID().uuidString)"
        let service = MediaExportService()

        let take = try await service.export(
            source: asset,
            state: state,
            destinationDirectory: destination,
            projectName: projectName,
            mode: .newTake
        )
        let join = Int(0.6 * 44_100)
        let takeSamples = try await readSamples(from: take.url)
        XCTAssertLessThan(
            peak(takeSamples, around: join, radius: 44),
            0.02
        )

        let replaced = try await service.export(
            source: asset,
            state: state,
            destinationDirectory: destination,
            projectName: projectName,
            mode: .replaceOriginal
        )
        let backup = try XCTUnwrap(replaced.backupURL)
        temporaryItems.append(backup.deletingLastPathComponent())
        let replacedSamples = try await readSamples(from: source)
        XCTAssertLessThan(
            peak(replacedSamples, around: join, radius: 44),
            0.02
        )
        let backupAsset = AVURLAsset(url: backup)
        let backupDuration = try await backupAsset.load(.duration).seconds
        XCTAssertEqual(backupDuration, 2, accuracy: 0.03)
    }

    func testVideoFadeMuxPreservesTheVideoCodecAndFadesAudio() async throws {
        let source = try await makeVideoWithAudio(duration: 2)
        let state = MediaEditState(
            sourceDuration: 2,
            keepRanges: [
                MediaTimeRange(start: 0, duration: 0.6),
                MediaTimeRange(start: 1, duration: 0.6)
            ]
        )
        let build = try await MediaCompositionBuilder.build(
            sourceURL: source,
            state: state
        )
        XCTAssertTrue(build.fadePlan.hasFades)
        let composition = build.composition
        let audioMix = build.audioMix
        let output = try temporaryOutput(extension: "mov")
        try await MediaVideoExporter.export(
            composition: composition,
            audioMix: audioMix,
            outputURL: output,
            fileType: .mov
        ) { _ in }

        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        let descriptions = try await videoTracks[0].load(
            .formatDescriptions
        )
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(
            CMFormatDescriptionGetMediaSubType(description),
            kCMVideoCodecType_H264
        )

        let samples = try await readSamples(from: output)
        let join = Int(0.6 * 44_100)
        XCTAssertLessThan(peak(samples, around: join, radius: 44), 0.02)
    }

    func testMP4FadeMuxUsesTheAACPath() async throws {
        let source = try await makeVideoWithAudio(duration: 2)
        let build = try await MediaCompositionBuilder.build(
            sourceURL: source,
            state: MediaEditState(
                sourceDuration: 2,
                keepRanges: [
                    MediaTimeRange(start: 0, duration: 0.6),
                    MediaTimeRange(start: 1, duration: 0.6)
                ]
            )
        )
        let output = try temporaryOutput(extension: "mp4")
        try await MediaVideoExporter.export(
            composition: build.composition,
            audioMix: build.audioMix,
            outputURL: output,
            fileType: .mp4
        ) { _ in }

        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        let samples = try await readSamples(from: output)
        XCTAssertFalse(samples.isEmpty)
        let join = Int(0.6 * 44_100)
        // AAC smears the ramp slightly; the exact join still has to be well
        // below the unfaded 0.4 amplitude.
        XCTAssertLessThan(peak(samples, around: join, radius: 44), 0.08)
    }

    func testVideoFadeMuxPreservesDelayedAudioOffset() async throws {
        let videoURL = try await makeVideoOnly(duration: 2)
        let audioURL = try makeTone(duration: 2)
        let composition = AVMutableComposition()

        let videoAsset = AVURLAsset(url: videoURL)
        let videoTracks = try await videoAsset.loadTracks(
            withMediaType: .video
        )
        let videoSource = try XCTUnwrap(videoTracks.first)
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MediaTestFixtureError.writer
        }
        try videoTrack.insertTimeRange(
            try await videoSource.load(.timeRange),
            of: videoSource,
            at: .zero
        )
        videoTrack.preferredTransform = try await videoSource.load(
            .preferredTransform
        )

        let audioAsset = AVURLAsset(url: audioURL)
        let audioTracks = try await audioAsset.loadTracks(
            withMediaType: .audio
        )
        let audioSource = try XCTUnwrap(audioTracks.first)
        guard let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MediaTestFixtureError.writer
        }
        try audioTrack.insertTimeRange(
            try await audioSource.load(.timeRange),
            of: audioSource,
            at: CMTime(seconds: 0.4, preferredTimescale: 600)
        )
        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        parameters.setVolumeRamp(
            fromStartVolume: 0,
            toEndVolume: 1,
            timeRange: CMTimeRange(
                start: CMTime(seconds: 0.4, preferredTimescale: 600),
                duration: CMTime(seconds: 0.03, preferredTimescale: 600)
            )
        )
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [parameters]

        let output = try temporaryOutput(extension: "mov")
        try await MediaVideoExporter.export(
            composition: composition,
            audioMix: audioMix,
            outputURL: output,
            fileType: .mov
        ) { _ in }

        let asset = AVURLAsset(url: output)
        let writtenAudioTracks = try await asset.loadTracks(
            withMediaType: .audio
        )
        let writtenAudio = try XCTUnwrap(writtenAudioTracks.first)
        let trackStart = try await writtenAudio.load(.timeRange)
            .start.seconds
        let samples = try await readSamples(from: output)
        let firstLoud = samples.firstIndex { abs($0) > 0.005 } ?? -1
        XCTAssertGreaterThanOrEqual(firstLoud, 0)
        let absoluteOnset = trackStart
            + Double(firstLoud) / 44_100
        XCTAssertEqual(
            absoluteOnset,
            0.4,
            accuracy: 0.08,
            "the fade mux must keep delayed audio at its composition offset"
        )
    }

    func testMP4FadeMuxKeepsAudioOnset() async throws {
        let videoURL = try await makeVideoOnly(duration: 2)
        let audioURL = try makeBurstTone(duration: 2, start: 0.8)
        let composition = AVMutableComposition()

        let videoAsset = AVURLAsset(url: videoURL)
        let videoTracks = try await videoAsset.loadTracks(
            withMediaType: .video
        )
        let videoSource = try XCTUnwrap(videoTracks.first)
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MediaTestFixtureError.writer
        }
        try videoTrack.insertTimeRange(
            try await videoSource.load(.timeRange),
            of: videoSource,
            at: .zero
        )

        let audioAsset = AVURLAsset(url: audioURL)
        let audioTracks = try await audioAsset.loadTracks(
            withMediaType: .audio
        )
        let audioSource = try XCTUnwrap(audioTracks.first)
        guard let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MediaTestFixtureError.writer
        }
        try audioTrack.insertTimeRange(
            try await audioSource.load(.timeRange),
            of: audioSource,
            at: .zero
        )
        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        parameters.setVolume(1, at: .zero)
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [parameters]

        let mov = try temporaryOutput(extension: "mov")
        let mp4 = try temporaryOutput(extension: "mp4")
        try await MediaVideoExporter.export(
            composition: composition,
            audioMix: audioMix,
            outputURL: mov,
            fileType: .mov
        ) { _ in }
        try await MediaVideoExporter.export(
            composition: composition,
            audioMix: audioMix,
            outputURL: mp4,
            fileType: .mp4
        ) { _ in }

        let movOnset = try await audioOnset(of: mov)
        let mp4Onset = try await audioOnset(of: mp4)
        XCTAssertEqual(movOnset, 0.8, accuracy: 0.04)
        XCTAssertEqual(
            mp4Onset,
            movOnset,
            accuracy: 0.015,
            "AAC encoder priming must not move MP4 audio against the picture"
        )
    }

    func testVideoFadeMuxMixesEveryAudioTrack() async throws {
        let videoURL = try await makeVideoOnly(duration: 2)
        let audioURL = try makeTone(duration: 2)
        let composition = AVMutableComposition()

        let videoAsset = AVURLAsset(url: videoURL)
        let videoTracks = try await videoAsset.loadTracks(
            withMediaType: .video
        )
        let videoSource = try XCTUnwrap(videoTracks.first)
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MediaTestFixtureError.writer
        }
        try videoTrack.insertTimeRange(
            try await videoSource.load(.timeRange),
            of: videoSource,
            at: .zero
        )

        let audioAsset = AVURLAsset(url: audioURL)
        let audioTracks = try await audioAsset.loadTracks(
            withMediaType: .audio
        )
        let audioSource = try XCTUnwrap(audioTracks.first)
        let audioRange = try await audioSource.load(.timeRange)
        guard let firstAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let secondAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MediaTestFixtureError.writer
        }
        try firstAudio.insertTimeRange(
            audioRange,
            of: audioSource,
            at: .zero
        )
        try secondAudio.insertTimeRange(
            audioRange,
            of: audioSource,
            at: .zero
        )

        let muted = AVMutableAudioMixInputParameters(track: firstAudio)
        muted.setVolume(0, at: .zero)
        let audible = AVMutableAudioMixInputParameters(track: secondAudio)
        audible.setVolume(1, at: .zero)
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [muted, audible]

        let output = try temporaryOutput(extension: "mov")
        try await MediaVideoExporter.export(
            composition: composition,
            audioMix: audioMix,
            outputURL: output,
            fileType: .mov
        ) { _ in }

        let samples = try await readSamples(from: output)
        XCTAssertGreaterThan(
            peak(samples, around: 44_100, radius: 4_410),
            0.2,
            "a second audio track must not be silently dropped"
        )
    }

    func testVideoWithAudioProducesAWaveformAndAPreviewMix() async throws {
        let source = try await makeVideoWithAudio(duration: 2)
        let data = try await WaveformExtractor.extract(url: source)
        XCTAssertGreaterThan(data.peaks.count, 0)
        XCTAssertTrue(
            data.bucketFrameCounts.contains { $0 > 0 }
        )

        let build = try await MediaCompositionBuilder.build(
            sourceURL: source,
            state: MediaEditState(
                sourceDuration: 2,
                keepRanges: [
                    MediaTimeRange(start: 0, duration: 0.6),
                    MediaTimeRange(start: 1, duration: 0.6)
                ]
            )
        )
        XCTAssertTrue(build.hasVideo)
        XCTAssertTrue(build.hasAudio)
        XCTAssertNotNil(build.audioMix)
        XCTAssertTrue(build.fadePlan.hasFades)

        let model = MediaPlaybackModel()
        model.load(
            asset: build.composition,
            sourceURL: source,
            fileSize: 0,
            audioMix: build.audioMix
        )
        let ready = await waitUntil { model.state == .ready }
        XCTAssertTrue(ready, "state was \(model.state)")
        XCTAssertNotNil(model.previewAudioMix)
        model.unload()
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

    private func peak(
        _ samples: [Float],
        around index: Int,
        radius: Int
    ) -> Float {
        guard !samples.isEmpty else { return 0 }
        let lower = max(index - radius, 0)
        let upper = min(index + radius, samples.count - 1)
        guard lower <= upper else { return 0 }
        return samples[lower...upper].map(abs).max() ?? 0
    }

    private func audioOnset(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let trackStart = try await track.load(.timeRange).start.seconds
        let samples = try await readSamples(from: url)
        let firstLoud = samples.firstIndex { abs($0) > 0.005 } ?? -1
        guard firstLoud >= 0 else { return .infinity }
        return trackStart + Double(firstLoud) / 44_100
    }

    private func readSamples(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(
            withMediaType: .audio
        ).first else {
            return []
        }
        let reader = try AVAssetReader(asset: asset)
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
            throw MediaTestFixtureError.writer
        }
        let provider = reader.outputProvider(for: output)
        try reader.start()
        var samples: [Float] = []
        while let sample = try await provider.next() {
            sample.withUnsafeSampleBuffer { buffer in
                var bufferList = AudioBufferList()
                var block: CMBlockBuffer?
                let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                    buffer,
                    bufferListSizeNeededOut: nil,
                    bufferListOut: &bufferList,
                    bufferListSize: MemoryLayout<AudioBufferList>.size,
                    blockBufferAllocator: nil,
                    blockBufferMemoryAllocator: nil,
                    flags: 0,
                    blockBufferOut: &block
                )
                guard status == noErr,
                      let data = bufferList.mBuffers.mData else {
                    return
                }
                let count = Int(bufferList.mBuffers.mDataByteSize)
                    / MemoryLayout<Float>.size
                let pointer = data.assumingMemoryBound(to: Float.self)
                samples.append(
                    contentsOf: UnsafeBufferPointer(
                        start: pointer,
                        count: count
                    )
                )
                withExtendedLifetime(block) {}
            }
        }
        return samples
    }

    private func makeVideoWithAudio(duration: Double) async throws -> URL {
        let video = try await makeVideoOnly(duration: duration)
        let audio = try makeTone(duration: duration)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        guard let videoSource = try await videoAsset.loadTracks(
            withMediaType: .video
        ).first else {
            throw MediaTestFixtureError.writer
        }
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MediaTestFixtureError.writer
        }
        try videoTrack.insertTimeRange(
            try await videoSource.load(.timeRange),
            of: videoSource,
            at: .zero
        )
        videoTrack.preferredTransform = try await videoSource.load(
            .preferredTransform
        )

        let audioAsset = AVURLAsset(url: audio)
        guard let audioSource = try await audioAsset.loadTracks(
            withMediaType: .audio
        ).first else {
            throw MediaTestFixtureError.writer
        }
        guard let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MediaTestFixtureError.writer
        }
        try audioTrack.insertTimeRange(
            try await audioSource.load(.timeRange),
            of: audioSource,
            at: .zero
        )

        let output = try temporaryOutput(extension: "mov")
        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw MediaTestFixtureError.writer
        }
        try await session.export(to: output, as: .mov)
        return output
    }

    private func makeVideoOnly(duration: Double) async throws -> URL {
        let url = try temporaryOutput(extension: "mov")
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
            throw MediaTestFixtureError.writer
        }
        writer.startSession(atSourceTime: .zero)
        let frameRate: Int32 = 30
        for index in 0..<Int(duration * Double(frameRate)) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw MediaTestFixtureError.writer
            }
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pool,
                &pixelBuffer
            ) == kCVReturnSuccess,
                  let pixelBuffer else {
                throw MediaTestFixtureError.writer
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(
                    base,
                    0x40,
                    CVPixelBufferGetBytesPerRow(pixelBuffer) * height
                )
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(
                    value: Int64(index),
                    timescale: frameRate
                )
            ) else {
                throw MediaTestFixtureError.writer
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw writer.error ?? MediaTestFixtureError.writer
        }
        return url
    }

    private func temporaryOutput(extension pathExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fade-\(UUID().uuidString).\(pathExtension)"
            )
        temporaryItems.append(url)
        return url
    }

    private enum MediaTestFixtureError: Error {
        case writer
    }

    private func makeBurstTone(
        duration: Double,
        start: Double
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fade-\(UUID().uuidString).wav")
        temporaryItems.append(url)
        let sampleRate = 44_100.0
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
            )
        )
        let frames = AVAudioFrameCount(duration * sampleRate)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData?[0])
        let burstStart = Int(max(start, 0) * sampleRate)
        for index in 0..<Int(frames) {
            data[index] = index >= burstStart
                ? 0.4 * sin(
                    2 * .pi * 997 * Float(index) / Float(sampleRate)
                )
                : 0
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings
        )
        try file.write(from: buffer)
        return url
    }

    private func makeTone(duration: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fade-\(UUID().uuidString).wav")
        temporaryItems.append(url)
        let sampleRate = 44_100.0
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
            )
        )
        let frames = AVAudioFrameCount(duration * sampleRate)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            data[index] = 0.4 * sin(
                2 * .pi * 997 * Float(index) / Float(sampleRate)
            )
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings
        )
        try file.write(from: buffer)
        return url
    }
}
