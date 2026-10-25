import AVFoundation
import CoreVideo
import Darwin
import Foundation
import Synchronization
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

    func testCancellingPendingPermissionNeverStartsCapture() async {
        let gate = PermissionGate()
        let access = MicrophoneAccess(
            status: { .notDetermined },
            request: { await gate.wait() }
        )
        let engine = FakeRecordingEngine()
        let recorder = AudioRecorder(
            engine: engine,
            access: access,
            channelProbe: { 1 },
            inputAvailable: { true }
        )
        let url = temporaryFile(named: "cancelled-start.wav")
        let start = Task { try await recorder.start(to: url) }
        let waiting = await waitForGate(gate)
        XCTAssertTrue(waiting)
        XCTAssertTrue(recorder.isPreparing)

        recorder.cancel()
        await gate.resolve(true)
        do {
            try await start.value
            XCTFail("a cancelled start must not begin capture")
        } catch is CancellationError {
            XCTAssertFalse(engine.isRecording)
            XCTAssertFalse(recorder.isRecording)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStartingAgainWhilePreparingIsRejected() async {
        let gate = PermissionGate()
        let access = MicrophoneAccess(
            status: { .notDetermined },
            request: { await gate.wait() }
        )
        let engine = FakeRecordingEngine()
        let recorder = AudioRecorder(
            engine: engine,
            access: access,
            channelProbe: { 1 },
            inputAvailable: { true }
        )
        let start = Task {
            try await recorder.start(
                to: temporaryFile(named: "first-start.wav")
            )
        }
        let waiting = await waitForGate(gate)
        XCTAssertTrue(waiting)
        do {
            try await recorder.start(
                to: temporaryFile(named: "second-start.wav")
            )
            XCTFail("a second start must be rejected while preparing")
        } catch let error as AudioRecordingError {
            XCTAssertEqual(error, .alreadyStarting)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        recorder.cancel()
        await gate.resolve(false)
        _ = try? await start.value
        XCTAssertFalse(engine.isRecording)
    }

    func testLateCancelledStartCannotResetANewerStart() async {
        let gate = PermissionGate()
        let access = MicrophoneAccess(
            status: { .notDetermined },
            request: { await gate.wait() }
        )
        let engine = FakeRecordingEngine()
        let recorder = AudioRecorder(
            engine: engine,
            access: access,
            channelProbe: { 1 },
            inputAvailable: { true }
        )
        let first = Task {
            try await recorder.start(
                to: temporaryFile(named: "late-old.wav")
            )
        }
        let firstWaiting = await waitForGate(gate)
        XCTAssertTrue(firstWaiting)
        recorder.cancel()

        let second = Task {
            try await recorder.start(
                to: temporaryFile(named: "late-new.wav")
            )
        }
        let secondWaiting = await waitForGate(gate, count: 2)
        XCTAssertTrue(secondWaiting)
        XCTAssertTrue(recorder.isPreparing)

        await gate.resolveNext(true)
        _ = try? await first.value
        XCTAssertTrue(
            recorder.isPreparing,
            "the old continuation must not reset the newer start"
        )

        recorder.cancel()
        await gate.resolveNext(true)
        _ = try? await second.value
        XCTAssertFalse(engine.isRecording)
    }

    func testStopDetectsAFailedEngineBeforeTheNextTick() async throws {
        let engine = FakeRecordingEngine()
        let recorder = AudioRecorder(
            engine: engine,
            access: .granted,
            channelProbe: { 1 },
            inputAvailable: { true }
        )
        try await recorder.start(
            to: temporaryFile(named: "stop-after-failure.wav")
        )
        engine.isRecording = false
        engine.lastError = "The disk is full."

        XCTAssertNil(recorder.stop())
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.lastError, "The disk is full.")
    }

    func testStopRejectsATakeAfterAnEncodeErrorEvenWhileRecording() async throws {
        let engine = FakeRecordingEngine()
        let recorder = AudioRecorder(
            engine: engine,
            access: .granted,
            channelProbe: { 1 },
            inputAvailable: { true }
        )
        try await recorder.start(
            to: temporaryFile(named: "encode-error.wav")
        )
        // AVAudioRecorder can report an encode error while still claiming to
        // be recording; the file is already incomplete.
        engine.lastError = "The encoder failed."

        XCTAssertNil(recorder.stop())
        XCTAssertFalse(engine.isRecording)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.lastError, "The encoder failed.")
    }

    func testUnexpectedEngineStopFailsTheTake() async throws {
        let engine = FakeRecordingEngine()
        let recorder = AudioRecorder(
            engine: engine,
            access: .granted,
            channelProbe: { 1 },
            inputAvailable: { true }
        )
        try await recorder.start(
            to: temporaryFile(named: "engine-stop.wav")
        )
        engine.isRecording = false
        engine.lastError = "The disk is full."
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.lastError, "The disk is full.")
    }

    func testRevisionMatchingRejectsADifferentFileWithTheSameStamp() throws {
        let first = temporaryFile(named: "revision-a.wav")
        let second = temporaryFile(named: "revision-b.wav")
        try Data([1, 2, 3]).write(to: first)
        try Data([4, 5, 6]).write(to: second)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for url in [first, second] {
            try FileManager.default.setAttributes(
                [.modificationDate: stamp],
                ofItemAtPath: url.path
            )
        }
        let expected = try XCTUnwrap(MediaStorage.revision(for: first))
        XCTAssertFalse(MediaStorage.matches(expected, url: second))
    }

    func testAtomicReplacementCommitsOnlyTheExpectedRevision() async throws {
        let source = temporaryFile(named: "swap-source.wav")
        let staged = temporaryFile(named: "swap-staged.wav")
        let backupDirectory = try makeDirectory(named: "swap-backup")
        let backup = backupDirectory.appendingPathComponent("backup.wav")
        try Data("original".utf8).write(to: source)
        try Data("exported".utf8).write(to: staged)
        let expected = try await MediaStorage.fingerprint(for: source)

        try await MediaStorage.commitStagedReplacement(
            staged,
            to: source,
            expectedFingerprint: expected,
            expectedSize: 8,
            backupTo: backup
        )
        XCTAssertEqual(try Data(contentsOf: source), Data("exported".utf8))
        XCTAssertEqual(try Data(contentsOf: backup), Data("original".utf8))
    }

    func testAtomicReplacementRejectsAConcurrentWriterBeforeSwap() async throws {
        let source = temporaryFile(named: "swap-source-external.wav")
        let staged = temporaryFile(named: "swap-staged-external.wav")
        let backupDirectory = try makeDirectory(named: "swap-backup-external")
        let backup = backupDirectory.appendingPathComponent("backup.wav")
        try Data("original".utf8).write(to: source)
        try Data("exported".utf8).write(to: staged)
        let expected = try await MediaStorage.fingerprint(for: source)
        try Data("external".utf8).write(to: source)

        do {
            try await MediaStorage.commitStagedReplacement(
                staged,
                to: source,
                expectedFingerprint: expected,
                expectedSize: 8,
                backupTo: backup
            )
            XCTFail("a changed fingerprint must be rejected")
        } catch {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("external".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testAtomicReplacementPreservesTheOldSourceWhenValidationFails() async throws {
        let source = temporaryFile(named: "swap-source-invalid.wav")
        let staged = temporaryFile(named: "swap-staged-invalid.wav")
        let backupDirectory = try makeDirectory(named: "swap-backup-invalid")
        let backup = backupDirectory.appendingPathComponent("backup.wav")
        try Data("original".utf8).write(to: source)
        try Data("exported".utf8).write(to: staged)
        let expected = try await MediaStorage.fingerprint(for: source)

        do {
            try await MediaStorage.commitStagedReplacement(
                staged,
                to: source,
                expectedFingerprint: expected,
                expectedSize: 999,
                backupTo: backup
            )
            XCTFail("a destination that is not the staged export must be rejected")
        } catch {
            // Expected.
        }
        // The exchange happened, so the old source must survive at the backup
        // instead of being deleted by a rollback.
        XCTAssertEqual(try Data(contentsOf: backup), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("exported".utf8))
    }

    func testAtomicReplacementRestoresASaveThatLandsJustBeforeTheSwap() async throws {
        let source = temporaryFile(named: "swap-source-window.wav")
        let staged = temporaryFile(named: "swap-staged-window.wav")
        let backupDirectory = try makeDirectory(named: "swap-backup-window")
        let backup = backupDirectory.appendingPathComponent("backup.wav")
        try Data("original".utf8).write(to: source)
        try Data("exported".utf8).write(to: staged)
        let expected = try await MediaStorage.fingerprint(for: source)
        let swapCount = Atomic<Int>(0)

        do {
            try await MediaStorage.commitStagedReplacement(
                staged,
                to: source,
                expectedFingerprint: expected,
                expectedSize: 8,
                backupTo: backup,
                swapping: { first, second in
                    let count = swapCount.wrappingAdd(
                        1,
                        ordering: .relaxed
                    ).newValue
                    if count == 1 {
                        try? Data("external2".utf8).write(to: source)
                    }
                    return MediaStorage.swapFiles(first, second)
                }
            )
            XCTFail("a save in the commit window must be restored")
        } catch {
            // Expected.
        }
        XCTAssertEqual(swapCount.load(ordering: .relaxed), 2)
        XCTAssertEqual(try Data(contentsOf: source), Data("external2".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testFileSnapshotDetectsInPlaceWritesAndReplacements() throws {
        let first = temporaryFile(named: "snapshot-a.wav")
        let second = temporaryFile(named: "snapshot-b.wav")
        try Data("aaaa".utf8).write(to: first)
        let original = try XCTUnwrap(MediaStorage.snapshot(for: first))

        try Data("bbbb".utf8).write(to: first)
        let rewritten = try XCTUnwrap(MediaStorage.snapshot(for: first))
        XCTAssertFalse(rewritten.sameRevision(as: original))

        try Data("cccc".utf8).write(to: second)
        _ = try FileManager.default.replaceItemAt(first, withItemAt: second)
        let replaced = try XCTUnwrap(MediaStorage.snapshot(for: first))
        XCTAssertNotEqual(replaced.inode, rewritten.inode)
        XCTAssertFalse(replaced.sameRevision(as: rewritten))
    }

    func testClosingAnUnrelatedMediaTabKeepsTheExportOwner() {
        let workspace = MediaEditWorkspace()
        let first = workspace.document(
            for: makeAsset(
                url: temporaryFile(named: "owner-a.wav"),
                kind: .audio
            )
        )
        let second = workspace.document(
            for: makeAsset(
                url: temporaryFile(named: "owner-b.wav"),
                kind: .audio
            )
        )
        XCTAssertTrue(workspace.beginExport(first))

        workspace.close(url: second.asset.url)

        XCTAssertEqual(workspace.exportingDocumentID, first.id)
        workspace.close(url: first.asset.url)
        XCTAssertNil(workspace.exportingDocumentID)
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

    private func waitForGate(
        _ gate: PermissionGate,
        count: Int = 1
    ) async -> Bool {
        for _ in 0..<100 {
            if await gate.waitingCount >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await gate.waitingCount >= count
    }
}

@MainActor
private final class FakeRecordingEngine: AudioRecordingEngine {
    var isRecording = false
    var currentTime: TimeInterval = 0
    var averagePower: Float = -20
    var lastError: String?
    private(set) var startedAt: URL?
    private(set) var settings: AudioRecordingSettings?

    func start(to url: URL, settings: AudioRecordingSettings) throws {
        startedAt = url
        self.settings = settings
        lastError = nil
        isRecording = true
    }

    func stop() {
        isRecording = false
    }

    func cancel() {
        isRecording = false
    }
}

private actor PermissionGate {
    private var continuations: [CheckedContinuation<Bool, Never>] = []

    var waitingCount: Int { continuations.count }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resolve(_ value: Bool) {
        for continuation in continuations {
            continuation.resume(returning: value)
        }
        continuations.removeAll()
    }

    func resolveNext(_ value: Bool) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: value)
    }
}

private enum MediaTestError: Error {
    case videoWriter
}

@MainActor
final class MediaAcceptanceRegressionTests: XCTestCase {
    func testKeptAudioTailDropsTheEmptyVideoTrack() async throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "video-audio-tail",
                withExtension: "mov",
                subdirectory: "Fixtures"
            )
        )
        let state = MediaEditState(
            sourceDuration: 2,
            keepRanges: [MediaTimeRange(start: 1.2, duration: 0.8)]
        )
        let build = try await MediaCompositionBuilder.build(
            sourceURL: url,
            state: state
        )
        XCTAssertFalse(build.hasVideo)
        XCTAssertTrue(build.hasAudio)
        XCTAssertTrue(
            build.composition.tracks(withMediaType: .video).isEmpty
        )
        XCTAssertFalse(
            build.composition.tracks(withMediaType: .audio).isEmpty
        )
    }

    func testSetInAndOutAtTheMinimumBoundaryDoNotClearTheSelection() {
        let asset = ProjectAsset(
            id: "boundary.wav",
            url: URL(fileURLWithPath: "/tmp/boundary.wav"),
            name: "boundary.wav",
            relativePath: "boundary.wav",
            kind: .audio,
            size: 1,
            modified: nil,
            revision: AssetRevision(
                fileIdentifier: "boundary",
                size: 1,
                modified: nil
            )
        )
        let document = MediaEditDocument(asset: asset)
        document.prepare(sourceDuration: 10)
        XCTAssertTrue(document.setSelection(start: 5, end: 6))
        XCTAssertFalse(document.setSelectionEnd(atSourceTime: 0.5))
        XCTAssertEqual(document.selection?.start, 5)
        XCTAssertEqual(document.selection?.end, 6)

        XCTAssertTrue(document.setSelection(start: 1, end: 2))
        XCTAssertFalse(document.setSelectionStart(atSourceTime: 3))
        XCTAssertEqual(document.selection?.start, 1)
        XCTAssertEqual(document.selection?.end, 2)

        XCTAssertTrue(document.setSelection(start: 5, end: 6))
        XCTAssertTrue(document.setSelectionStart(atSourceTime: 5.98))
        let selection = try? XCTUnwrap(document.selection)
        XCTAssertNotNil(selection)
        XCTAssertEqual(
            selection?.duration ?? 0,
            MediaEditLimits.minimumSelectionDuration,
            accuracy: 0.0001
        )
    }

    func testRevisionReadsFreshAfterAnInPlaceOverwrite() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh-revision-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1, 2, 3]).write(to: url)
        let before = try XCTUnwrap(MediaStorage.revision(for: url))
        try Data([1, 2, 3, 4, 5]).write(to: url, options: .atomic)
        let after = try XCTUnwrap(MediaStorage.revision(for: url))
        XCTAssertFalse(MediaStorage.matches(before, revision: after))
    }

    func testReplaceCopiesPermissionsAndExtendedAttributes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "media-attributes-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let target = directory.appendingPathComponent("target.wav")
        try Data([1, 2, 3]).write(to: source)
        try Data([4, 5, 6]).write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: source.path
        )
        let name = "com.sonovo.test"
        let value = Array("tag-value".utf8)
        let setResult = value.withUnsafeBytes { bytes in
            setxattr(
                source.path,
                name,
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        XCTAssertEqual(setResult, 0)

        try MediaStorage.copyFileAttributes(from: source, to: target)
        let attrs = try FileManager.default.attributesOfItem(
            atPath: target.path
        )
        XCTAssertEqual(
            (attrs[.posixPermissions] as? NSNumber)?.intValue,
            0o640
        )
        var buffer = [UInt8](repeating: 0, count: 64)
        let read = buffer.withUnsafeMutableBytes { bytes in
            getxattr(
                target.path,
                name,
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        XCTAssertEqual(read, value.count)
        XCTAssertEqual(
            String(decoding: buffer.prefix(max(read, 0)), as: UTF8.self),
            "tag-value"
        )
    }

    func testExportCancellationIsCancellationNotFailure() async throws {
        let source = try XCTUnwrap(
            Bundle.module.url(
                forResource: "video-audio-tail",
                withExtension: "mov",
                subdirectory: "Fixtures"
            )
        )
        let exporter = MediaExportService()
        let asset = ProjectAsset(
            id: source.path,
            url: source,
            name: source.lastPathComponent,
            relativePath: source.lastPathComponent,
            kind: .video,
            size: 1,
            modified: nil,
            revision: try XCTUnwrap(MediaStorage.revision(for: source))
        )
        let state = MediaEditState(sourceDuration: 2)
        let task = Task {
            try await exporter.export(
                source: asset,
                state: state,
                destinationDirectory: FileManager.default.temporaryDirectory,
                projectName: "Cancel",
                mode: .newTake
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
        } catch is CancellationError {
            XCTAssertEqual(exporter.status, .idle)
        } catch {
            XCTFail("expected cancellation, got \(error)")
        }
    }
}
