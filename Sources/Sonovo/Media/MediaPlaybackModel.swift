import AVFoundation
import CoreMedia
import Foundation
import Observation

/// One local media file. The model owns the player, readiness, metadata, and
/// timecode; the view owns layout. Failures surface at the item-status level,
/// so a file that parses but cannot play is not reported as ready.
@MainActor
@Observable
final class MediaPlaybackModel {
    enum State: Equatable, Sendable {
        case idle
        case loading
        case ready
        case unsupported(String)
        case failed(String)
    }

    let player = AVPlayer()

    private(set) var state: State = .idle
    private(set) var url: URL?
    private(set) var duration: Double = 0
    private(set) var elapsed: Double = 0
    private(set) var isPlaying = false
    private(set) var hasVideo = false
    private(set) var hasAudio = false
    private(set) var videoSize: CGSize = .zero
    private(set) var nominalFrameRate: Double = 0
    /// Exact frame duration from the video track, when it declares one.
    private(set) var frameDurationSeconds: Double?
    /// The track's exact rational frame duration. Seeking with this CMTime
    /// keeps 90000/1001 boundaries representable.
    private(set) var frameDuration: CMTime?
    private(set) var isVariableFrameRate = false
    /// True only when the entire video track's presentation timing was read
    /// and found constant. Frame stepping is disabled otherwise.
    private(set) var isFrameRateVerified = false
    private(set) var timecode = MediaTimecode()
    private(set) var videoCodec: String?
    private(set) var audioSummary: String?
    private(set) var fileSize: Int64 = 0

    var volume: Float = 1 {
        didSet { player.volume = volume }
    }

    var isMuted = false {
        didSet { player.isMuted = isMuted }
    }

    var isLooping = false
    private(set) var auditionRange: ClosedRange<Double>?
    var isAuditioning: Bool { auditionRange != nil }

    private var timeObserver: Any?
    private var auditionObserver: Any?
    private var auditionGeneration: UInt64 = 0
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var errorLogObserver: NSObjectProtocol?
    private var loadGeneration: UInt64 = 0
    private var seekGeneration: UInt64 = 0
    private var pendingSeekGeneration: UInt64?
    private var lastRequestedSeekTarget: Double?
    /// Incremented whenever playback is explicitly stopped. A loop restart
    /// captures it before its rewind seek so a pause during that await wins.
    private var playIntent: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    /// 600 cannot represent a 30000/1001 frame boundary. This timescale
    /// resolves frame durations to under a microsecond.
    nonisolated static let seekTimescale: CMTimeScale = 600_000

    private var preferenceObserver: NSObjectProtocol?

    init() {
        player.actionAtItemEnd = .pause
        applyPreferences()
        installTimeObserver()
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyPreferences()
            }
        }
        controlObservation = player.observe(
            \.timeControlStatus,
            options: [.new]
        ) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in
                self?.isPlaying = playing
            }
        }
    }

    /// Routes audio to the output device chosen in Settings. A missing or
    /// unknown device falls back to the system default (nil).
    private func applyPreferences() {
        let uid = Preferences.audioDeviceUID
        guard player.audioOutputDeviceUniqueID != uid else { return }
        player.audioOutputDeviceUniqueID = uid
    }

    isolated deinit {
        loadTask?.cancel()
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
        }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let auditionObserver {
            player.removeTimeObserver(auditionObserver)
        }
        controlObservation?.invalidate()
        removeItemObservers()
    }

    func load(url: URL) {        // Reset before validating. A rejected URL must not leave the
        // previous item playing behind the failure state, and an earlier
        // load must not be able to overwrite it.
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        seekGeneration &+= 1
        reset()
        guard url.isFileURL else {
            state = .failed("Only local files can be opened.")
            return
        }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey])
            .fileSize).map(Int64.init) ?? 0
        startLoad(
            asset: AVURLAsset(url: url),
            displayURL: url,
            timingURL: url,
            fileSize: fileSize,
            generation: generation
        )
    }

    /// Plays an edited composition while keeping the source file's identity
    /// and metadata. Frame stepping is not claimed for the composition: its
    /// frame timing has not been measured.
    /// Exposed for tests and diagnostics: the preview item must carry the
    /// same cut-fade mix the exporter uses.
    var previewAudioMix: AVAudioMix? {
        player.currentItem?.audioMix
    }

    func load(
        asset: AVAsset,
        sourceURL: URL,
        fileSize: Int64,
        audioMix: AVAudioMix? = nil,
        videoComposition: AVVideoComposition? = nil,
        resumeAt: Double? = nil
    ) {
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        seekGeneration &+= 1
        reset()
        startLoad(
            asset: asset,
            displayURL: sourceURL,
            timingURL: nil,
            fileSize: fileSize,
            audioMix: audioMix,
            videoComposition: videoComposition,
            resumeAt: resumeAt,
            generation: generation
        )
    }

    private func startLoad(
        asset: AVAsset,
        displayURL: URL,
        timingURL: URL?,
        fileSize: Int64,
        audioMix: AVAudioMix? = nil,
        videoComposition: AVVideoComposition? = nil,
        resumeAt: Double? = nil,
        generation: UInt64
    ) {
        url = displayURL
        self.fileSize = fileSize
        state = .loading
        loadTask = Task { @MainActor [weak self] in
            await self?.loadAsset(
                asset: asset,
                timingURL: timingURL,
                audioMix: audioMix,
                videoComposition: videoComposition,
                resumeAt: resumeAt,
                generation: generation
            )
        }
    }

    private struct VideoMetadata {
        let size: CGSize
        let rate: Double
        let frameDuration: CMTime?
        let variable: Bool
        let verified: Bool
        let codec: String?
    }

    private enum MetadataResult {
        case success(AssetMetadata)
        case unsupported(String)
    }

    private struct AssetMetadata {
        let duration: Double
        let hasVideo: Bool
        let hasAudio: Bool
        let video: VideoMetadata?
        let audioSummary: String?
        let source: [MediaTimecode.SourceSegment]
    }

    private func loadAsset(
        asset: AVAsset,
        timingURL: URL?,
        audioMix: AVAudioMix?,
        videoComposition: AVVideoComposition?,
        resumeAt: Double?,
        generation: UInt64
    ) async {
        let metadata = await readMetadata(
            asset: asset,
            timingURL: timingURL
        )

        // Every await above can be outrun by a newer load.
        guard !Task.isCancelled, generation == loadGeneration else {
            return
        }
        switch metadata {
        case .unsupported(let message):
            state = .unsupported(message)
        case .success(let value):
            apply(value)
            let item = AVPlayerItem(asset: asset)
            item.audioMix = audioMix
            item.videoComposition = videoComposition
            observe(item: item, generation: generation)
            player.replaceCurrentItem(with: item)
            if let resumeAt, resumeAt > 0, resumeAt.isFinite {
                _ = await player.seek(
                    to: CMTime(
                        seconds: resumeAt,
                        preferredTimescale: Self.seekTimescale
                    ),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
        }
    }

    /// Reads every metadata value before the caller touches model state, so
    /// a stale load cannot apply half a snapshot. Failures carry the
    /// user-facing message that belongs to the specific validation.
    private func readMetadata(
        asset: AVAsset,
        timingURL: URL?
    ) async -> MetadataResult {
        do {
            let playable = try await asset.load(.isPlayable)
            let assetDuration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)

            guard playable,
                  assetDuration.isNumeric,
                  assetDuration.seconds.isFinite,
                  assetDuration.seconds > 0 else {
                return .unsupported(
                    "This format needs a proxy or an external player."
                )
            }
            let videoTrack = tracks.first { $0.mediaType == .video }
            let audioTrack = tracks.first { $0.mediaType == .audio }
            guard videoTrack != nil || audioTrack != nil else {
                return .unsupported(
                    "This file has no audio or video tracks."
                )
            }

            var videoInfo: VideoMetadata?
            if let videoTrack {
                let size = try await videoTrack.load(.naturalSize)
                let rate = Double(
                    try await videoTrack.load(.nominalFrameRate)
                )
                let minFrameDuration = try? await videoTrack.load(
                    .minFrameDuration
                )
                let timing: (variable: Bool, verified: Bool)
                if let timingURL {
                    timing = await Self.frameTiming(
                        url: timingURL,
                        trackID: videoTrack.trackID,
                        nominalRate: rate,
                        minFrameDuration: minFrameDuration
                    )
                } else {
                    // A composition's frame timing is not the source file's
                    // sample timing; frame stepping stays unavailable rather
                    // than making an unverified claim.
                    timing = (false, false)
                }
                let codec = await Self.codecName(for: videoTrack)
                let exactDuration = minFrameDuration.flatMap { duration in
                    duration.isNumeric
                        && duration.seconds.isFinite
                        && duration.seconds > 0
                        ? duration
                        : nil
                }
                videoInfo = VideoMetadata(
                    size: size,
                    rate: rate,
                    frameDuration: exactDuration,
                    variable: timing.variable,
                    verified: timing.verified,
                    codec: codec
                )
            }
            var audioInfo: String?
            if let audioTrack {
                audioInfo = await Self.audioDescription(for: audioTrack)
            }
            let source: [MediaTimecode.SourceSegment]
            if let timingURL {
                source = await Self.readTimecode(
                    url: timingURL,
                    trackID: tracks.first(where: {
                        $0.mediaType == .timecode
                    })?.trackID
                )
            } else {
                source = []
            }
            return .success(
                AssetMetadata(
                    duration: assetDuration.seconds,
                    hasVideo: videoTrack != nil,
                    hasAudio: audioTrack != nil,
                    video: videoInfo,
                    audioSummary: audioInfo,
                    source: source
                )
            )
        } catch {
            return .unsupported(
                "This format needs a proxy or an external player."
            )
        }
    }

    private func apply(_ metadata: AssetMetadata) {
        duration = metadata.duration
        hasVideo = metadata.hasVideo
        hasAudio = metadata.hasAudio
        if let video = metadata.video {
            videoSize = video.size
            nominalFrameRate = video.rate
            frameDuration = video.frameDuration
            frameDurationSeconds = video.frameDuration?.seconds
            isVariableFrameRate = video.variable
            isFrameRateVerified = video.verified
            videoCodec = video.codec
        }
        audioSummary = metadata.audioSummary
        timecode = MediaTimecode(
            elapsed: 0,
            nominalFrameRate: nominalFrameRate,
            frameDurationSeconds: frameDurationSeconds,
            sourceSegments: metadata.source,
            isVariableFrameRate: isVariableFrameRate,
            // With no video track there is no video timing to verify; the
            // audio timeline is exact. A video track must be measured.
            isTimingVerified: metadata.video?.verified ?? true
        )
    }

    /// Stops loading and releases the item when the viewer disappears. The
    /// generation bump discards any metadata still in flight.
    func unload() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration &+= 1
        seekGeneration &+= 1
        reset()
    }

    // MARK: - Transport

    func play() {
        guard state == .ready else { return }
        player.play()
    }

    func pause() {
        stopAudition()
        playIntent &+= 1
        player.pause()
    }

    /// Loops the edited span between the selection bounds. The boundary time
    /// observer fires at the selection end; a periodic 30 Hz observer would
    /// overshoot by up to a frame and is not used here.
    func startAudition(range: ClosedRange<Double>) {
        guard state == .ready,
              range.lowerBound.isFinite,
              range.upperBound.isFinite,
              range.lowerBound >= 0,
              range.upperBound - range.lowerBound
                > MediaEditLimits.minimumSelectionDuration,
              duration > 0 else {
            return
        }
        stopAudition()
        // Ordinary playback may still be running when the audition starts;
        // pause it explicitly so the exact seek does not leave a blip of the
        // old position before the loop begins.
        player.pause()
        playIntent &+= 1
        auditionGeneration &+= 1
        let generation = auditionGeneration
        let start = min(max(range.lowerBound, 0), duration)
        let end = min(max(range.upperBound, start), duration)
        guard end - start > MediaEditLimits.minimumSelectionDuration else {
            return
        }
        auditionRange = start ... end
        let boundary = CMTime(
            seconds: end,
            preferredTimescale: Self.seekTimescale
        )
        auditionObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: boundary)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.auditionGeneration,
                      self.auditionRange != nil else {
                    return
                }
                await self.loopAudition(generation: generation)
            }
        }
        player.seek(
            to: CMTime(
                seconds: start,
                preferredTimescale: Self.seekTimescale
            ),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.auditionGeneration,
                      self.auditionRange != nil else {
                    return
                }
                self.player.play()
            }
        }
    }

    func stopAudition() {
        let wasAuditioning = auditionRange != nil || auditionObserver != nil
        auditionGeneration &+= 1
        auditionRange = nil
        if let auditionObserver {
            player.removeTimeObserver(auditionObserver)
            self.auditionObserver = nil
        }
        // Seeking and selection changes call this unconditionally. Only an
        // actual audition owns a pause; a no-op here must not turn a normal
        // seek into a stop.
        if wasAuditioning {
            player.pause()
        }
    }

    private func loopAudition(generation: UInt64) async {
        guard generation == auditionGeneration,
              let range = auditionRange else {
            return
        }
        player.pause()
        await withCheckedContinuation { continuation in
            player.seek(
                to: CMTime(
                    seconds: range.lowerBound,
                    preferredTimescale: Self.seekTimescale
                ),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                continuation.resume()
            }
        }
        guard generation == auditionGeneration,
              auditionRange != nil else {
            return
        }
        player.play()
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to seconds: Double) async {
        stopAudition()
        let clamped = min(max(seconds, 0), max(duration, 0))
        await seek(
            to: CMTime(
                seconds: clamped,
                preferredTimescale: Self.seekTimescale
            ),
            seconds: clamped
        )
    }

    /// The single seek path. An exact CMTime is passed through unchanged so
    /// a frame boundary is not re-rounded to the general-purpose timescale.
    private func seek(to time: CMTime, seconds clamped: Double) async {
        // A seek before the item is ready has no player to act on; moving
        // the readout would claim a position that was never applied.
        guard state == .ready else { return }
        seekGeneration &+= 1
        let generation = seekGeneration
        lastRequestedSeekTarget = clamped
        // While a seek is in flight the player's periodic time is either the
        // old position or a sample taken before the seek completed. Applying
        // it would move the playhead backwards after a newer seek finished.
        pendingSeekGeneration = generation
        await withCheckedContinuation { continuation in
            player.seek(
                to: time,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                continuation.resume()
            }
        }
        guard generation == seekGeneration else { return }
        // An interrupted seek leaves the player wherever it actually is;
        // reporting the requested position would be a lie. The player's
        // current time is the truth in both the completed and failed cases.
        var actual = player.currentTime().seconds
        if !actual.isFinite || abs(actual - clamped) > 0.05 {
            // Overlapping seeks can report completion out of order: an older
            // completion may have landed after this generation was issued,
            // leaving the player at the stale target. One corrective seek
            // makes the newest request authoritative.
            await withCheckedContinuation { continuation in
                player.seek(
                    to: time,
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                ) { _ in
                    continuation.resume()
                }
            }
            guard generation == seekGeneration else { return }
            actual = player.currentTime().seconds
        }
        // Keep the pending marker and the requested target until both seeks
        // finish. Clearing them earlier lets a frame-step or skip issued
        // during the correction read stale `elapsed`, and lets periodic
        // time updates move the playhead before the seek lands.
        pendingSeekGeneration = nil
        lastRequestedSeekTarget = nil
        let position = actual.isFinite ? actual : clamped
        elapsed = min(max(position, 0), max(duration, 0))
        timecode.elapsed = elapsed
    }

    func stepFrames(_ delta: Int) {
        guard state == .ready else { return }
        // Frame stepping is an exact-frame claim; it requires the whole
        // track's timing to have been measured as constant.
        guard isFrameRateVerified else { return }
        let fallbackStep = nominalFrameRate > 0 ? 1 / nominalFrameRate : 0
        guard frameDuration != nil || fallbackStep > 0 else { return }
        pause()
        // Use the newest requested target, not `elapsed`: several quick
        // presses must accumulate rather than all aiming at the same frame.
        let base = lastRequestedSeekTarget ?? elapsed
        let targetSeconds: Double
        let targetTime: CMTime
        if let frameDuration, let frameDurationSeconds {
            let baseFrame = Int64(
                (base / frameDurationSeconds + 0.000_001).rounded(.down)
            )
            let targetFrame = max(0, baseFrame + Int64(delta))
            targetTime = CMTimeMultiply(
                frameDuration,
                multiplier: Int32(clamping: targetFrame)
            )
            targetSeconds = targetTime.seconds
        } else {
            targetSeconds = base + Double(delta) * fallbackStep
            targetTime = CMTime(
                seconds: targetSeconds,
                preferredTimescale: Self.seekTimescale
            )
        }
        let bounded = min(max(targetSeconds, 0), max(duration, 0))
        let boundedTime = bounded == targetSeconds
            ? targetTime
            : CMTime(
                seconds: bounded,
                preferredTimescale: Self.seekTimescale
            )
        // Record the target synchronously. Two quick commands otherwise both
        // read the same base before either queued seek task starts.
        lastRequestedSeekTarget = bounded
        let generation = loadGeneration
        Task { @MainActor [weak self] in
            // A queued command must not seek the item that replaced the one
            // it was issued against.
            guard let self, self.loadGeneration == generation else { return }
            await self.seek(to: boundedTime, seconds: bounded)
        }
    }

    func skip(by seconds: Double) {
        guard state == .ready else { return }
        let base = lastRequestedSeekTarget ?? elapsed
        let target = min(max(base + seconds, 0), max(duration, 0))
        lastRequestedSeekTarget = target
        let generation = loadGeneration
        Task { @MainActor [weak self] in
            guard let self, self.loadGeneration == generation else { return }
            await self.seek(to: target)
        }
    }

    // MARK: - Item observation

    private func observe(item: AVPlayerItem, generation: UInt64) {
        statusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            let status = item.status
            let error = item.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, generation == self.loadGeneration else {
                    return
                }
                switch status {
                case .readyToPlay:
                    self.state = .ready
                case .failed:
                    self.state = .failed(
                        error ?? "The file could not be played."
                    )
                default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == self.loadGeneration else {
                    return
                }
                if self.auditionRange != nil {
                    self.isPlaying = false
                    // A boundary observer at the exact item end is not
                    // guaranteed to fire before the item stops. The end
                    // notification is the reliable loop trigger for a
                    // selection that ends at the duration.
                    let auditionGeneration = self.auditionGeneration
                    await self.loopAudition(
                        generation: auditionGeneration
                    )
                    return
                }
                self.isPlaying = false
                if self.isLooping {
                    let intent = self.playIntent
                    await self.seek(to: 0)
                    // The seek can span a newer load or a pause. Neither may
                    // be overridden by an old item's end callback.
                    guard generation == self.loadGeneration,
                          intent == self.playIntent else { return }
                    self.play()
                } else {
                    self.elapsed = self.duration
                    self.timecode.elapsed = self.duration
                }
            }
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[
                AVPlayerItemFailedToPlayToEndTimeErrorKey
            ] as? Error)?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, generation == self.loadGeneration else {
                    return
                }
                self.state = .failed(
                    message ?? "Playback failed before the end."
                )
            }
        }

        errorLogObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.loadGeneration,
                      let error = item.error else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func removeItemObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        if let errorLogObserver {
            NotificationCenter.default.removeObserver(errorLogObserver)
        }
        endObserver = nil
        failureObserver = nil
        errorLogObserver = nil
    }

    private func reset() {
        stopAudition()
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeItemObservers()
        state = .idle
        duration = 0
        elapsed = 0
        pendingSeekGeneration = nil
        lastRequestedSeekTarget = nil
        isPlaying = false
        hasVideo = false
        hasAudio = false
        videoSize = .zero
        nominalFrameRate = 0
        frameDurationSeconds = nil
        frameDuration = nil
        isVariableFrameRate = false
        isFrameRateVerified = false
        timecode = MediaTimecode()
        videoCodec = nil
        audioSummary = nil
        url = nil
        fileSize = 0
    }

    private func installTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            MainActor.assumeIsolated {
                guard let self,
                      self.state == .ready,
                      self.pendingSeekGeneration == nil else {
                    return
                }
                self.elapsed = min(max(seconds, 0), max(self.duration, 0))
                self.timecode.elapsed = self.elapsed
            }
        }
    }

    // MARK: - Metadata

    /// A positive nominal frame rate is not proof of constant timing. Read a
    /// bounded run of decoded samples and measure the presentation deltas; a
    /// track that cannot be measured is treated as variable rather than
    /// claiming exact frame positions we do not have.
    /// A constant-rate track's shortest frame interval equals the nominal
    /// interval. A shorter minimum means at least one frame runs faster than
    /// the average, which is enough to stop claiming exact frame positions.
    nonisolated private static func minFrameDurationIndicatesVariable(
        _ duration: CMTime?,
        nominalRate: Double
    ) -> Bool {
        guard nominalRate > 0,
              let duration,
              duration.isNumeric,
              duration.seconds > 0 else {
            return false
        }
        let nominal = 1 / nominalRate
        return abs(duration.seconds - nominal) > nominal * 0.1
    }

    /// Reads the whole video track's presentation timestamps (compressed
    /// samples; no decode) up to a 60,000-frame cap. `verified` is true only
    /// when every sample was seen and the intervals were constant within 1%.
    /// A longer or unreadable track is not verified, so frame stepping is
    /// disabled rather than claiming exact frames we did not measure.
    /// Internal so the provider migration can be exercised with fixtures.
    nonisolated static func frameTiming(
        url: URL,
        trackID: CMPersistentTrackID,
        nominalRate: Double,
        minFrameDuration: CMTime?,
        // Test seams. Production call sites pass nil, which reads samples
        // from the reader's own provider and runs no per-sample hook.
        nextSample: (@Sendable () async throws
            -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent>?)? = nil,
        onSample: (@Sendable () -> Void)? = nil
    ) async -> (variable: Bool, verified: Bool) {
        guard nominalRate > 0 else { return (true, false) }
        if minFrameDurationIndicatesVariable(
            minFrameDuration,
            nominalRate: nominalRate
        ) {
            return (true, false)
        }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks),
              let track = tracks.first(where: { $0.trackID == trackID }),
              let reader = try? AVAssetReader(asset: asset) else {
            return (true, false)
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        guard reader.canAdd(output) else { return (true, false) }
        let provider = reader.outputProvider(for: output)
        do {
            try reader.start()
        } catch {
            return (true, false)
        }
        defer { reader.cancelReading() }

        let nominalDelta = 1 / nominalRate
        let cap = 60_000
        var timestamps: [Double] = []
        var sampleCount = 0
        do {
            while true {
                let sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>?
                if let nextSample {
                    sample = try await nextSample()
                } else {
                    sample = try await provider.next()
                }
                guard let sample else { break }
                // A marker-only buffer carries no picture and its timestamp
                // is not a frame boundary; counting it distorts the interval
                // test.
                guard sample.sampleCount > 0 else {
                    continue
                }
                let timestamp = sample.presentationTimeStamp
                if timestamp.isNumeric,
                   timestamp.seconds.isFinite {
                    timestamps.append(timestamp.seconds)
                }
                sampleCount += 1
                onSample?()
                if Task.isCancelled { return (true, false) }
                if sampleCount >= cap { break }
            }
        } catch {
            return (true, false)
        }
        // Decode order is not presentation order: a B-frame stream yields
        // timestamps out of order. Sort before measuring intervals, and skip
        // zero-length marker buffers.
        timestamps.sort()
        var variable = false
        if timestamps.count > 1 {
            for index in 1..<timestamps.count {
                let delta = timestamps[index] - timestamps[index - 1]
                if delta > 0,
                   abs(delta - nominalDelta) > nominalDelta * 0.01 {
                    variable = true
                    break
                }
            }
        }
        // Variability and verification are exclusive: a track that showed
        // any non-nominal interval is not exact, even if every sample was
        // read.
        let verified = reader.status == .completed
            && sampleCount < cap
            && sampleCount > 1
            && !variable
        return (variable, verified)
    }

    private static func codecName(for track: AVAssetTrack) async -> String? {
        guard let descriptions = try? await track.load(.formatDescriptions),
              let first = descriptions.first else {
            return nil
        }
        let description = first
        return fourCC(CMFormatDescriptionGetMediaSubType(description))
    }

    private static func audioDescription(
        for track: AVAssetTrack
    ) async -> String? {
        guard let descriptions = try? await track.load(.formatDescriptions),
              let first = descriptions.first else {
            return nil
        }
        let description = first
        guard let stream = CMAudioFormatDescriptionGetStreamBasicDescription(
            description
        )?.pointee else {
            return "Audio"
        }
        let channels = Int(stream.mChannelsPerFrame)
        let kilohertz = stream.mSampleRate / 1000
        let rateText = kilohertz.rounded() == kilohertz
            ? String(format: "%.0f kHz", kilohertz)
            : String(format: "%.1f kHz", kilohertz)
        let channelText = channels == 1 ? "Mono" : "\(channels) ch"
        return "\(rateText) · \(channelText)"
    }

    /// The timecode track can contain one sample per frame. Scanning it on
    /// the main actor would freeze the interface on a dense track, so the
    /// scan runs in a detached task and checks cancellation per sample.
    nonisolated private static func readTimecode(
        url: URL,
        trackID: CMPersistentTrackID?
    ) async -> [MediaTimecode.SourceSegment] {
        guard let trackID else { return [] }
        let task = Task.detached(priority: .userInitiated) {
            await scanTimecode(url: url, trackID: trackID)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Internal so the provider migration can be exercised with fixtures.
    nonisolated static func scanTimecode(
        url: URL,
        trackID: CMPersistentTrackID,
        // Test seams. Production call sites pass nil, which reads samples
        // from the reader's own provider and runs no per-sample hook.
        nextSample: (@Sendable () async throws
            -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent>?)? = nil,
        onSample: (@Sendable () -> Void)? = nil
    ) async -> [MediaTimecode.SourceSegment] {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(
            withMediaType: .timecode
        ),
        let track = tracks.first(where: { $0.trackID == trackID }) else {
            return []
        }
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return [] }
        let provider = reader.outputProvider(for: output)
        do {
            try reader.start()
        } catch {
            return []
        }
        defer {
            reader.cancelReading()
        }

        var segments: [MediaTimecode.SourceSegment] = []
        do {
            // The first tmcd sample can be an empty marker; the frame number
            // is in the next sample. Skip anything without a format and a
            // full sample.
            while true {
                let sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>?
                if let nextSample {
                    sample = try await nextSample()
                } else {
                    sample = try await provider.next()
                }
                guard let sample else { break }
                if Task.isCancelled { return [] }
                let segment = sample.withUnsafeSampleBuffer { buffer in
                    Self.timecodeSegment(from: buffer)
                }
                guard let segment else { continue }
                // Keep one segment per run of contiguous timecode. A track
                // with a sample per frame would otherwise store a segment per
                // frame while carrying no new information.
                if let previous = segments.last,
                   Self.isContiguous(previous, followedBy: segment) {
                    if let duration = segment.duration {
                        let end = segment.time + duration
                        segments[segments.count - 1] =
                            MediaTimecode.SourceSegment(
                                time: previous.time,
                                startFrame: previous.startFrame,
                                frameRate: previous.frameRate,
                                frameQuanta: previous.frameQuanta,
                                isDropFrame: previous.isDropFrame,
                                duration: max(
                                    previous.duration ?? 0,
                                    end - previous.time
                                )
                            )
                    }
                } else {
                    segments.append(segment)
                }
                onSample?()
                if Task.isCancelled { return [] }
                // A pathological file with a discontinuity at every sample
                // is too irregular to label honestly; suppress source
                // timecode rather than publish a truncated track.
                if segments.count > 100_000 { return [] }
            }
        } catch {
            return []
        }
        segments.sort { $0.time < $1.time }
        return segments
    }

    /// Parses one timecode sample. The format subtype decides the sample
    /// width; the buffer length is not authoritative because a 32-bit sample
    /// may be padded, and a counter sample is not a frame number at all.
    nonisolated private static func timecodeSegment(
        from sample: CMSampleBuffer
    ) -> MediaTimecode.SourceSegment? {
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample)
        else {
            return nil
        }
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        let width: Int
        switch subtype {
        case kCMTimeCodeFormatType_TimeCode64:
            width = 8
        case kCMTimeCodeFormatType_TimeCode32:
            width = 4
        default:
            // Counter32/Counter64 samples count ticks, not frames; a
            // frame-number label would be wrong.
            return nil
        }
        guard let frame = timecodeFrameNumber(in: block, width: width) else {
            return nil
        }
        let dropFrame = (
            CMTimeCodeFormatDescriptionGetTimeCodeFlags(format)
                & kCMTimeCodeFlag_DropFrame
        ) != 0
        let frameDuration = CMTimeCodeFormatDescriptionGetFrameDuration(
            format
        )
        let frameRate = frameDuration.isNumeric
            && frameDuration.seconds > 0
            ? 1 / frameDuration.seconds
            : nil
        let quanta = Int(
            CMTimeCodeFormatDescriptionGetFrameQuanta(format)
        )
        let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
        guard presentation.isNumeric,
              presentation.seconds.isFinite else {
            return nil
        }
        let sampleDuration = CMSampleBufferGetDuration(sample)
        let duration = sampleDuration.isNumeric
            && sampleDuration.seconds.isFinite
            && sampleDuration.seconds > 0
            ? sampleDuration.seconds
            : nil
        return MediaTimecode.SourceSegment(
            time: presentation.seconds,
            startFrame: frame,
            frameRate: frameRate,
            frameQuanta: quanta > 0 ? quanta : nil,
            isDropFrame: dropFrame,
            duration: duration
        )
    }

    /// Copies exactly the sample's frame-number bytes out of the block
    /// buffer. `CMBlockBufferGetDataPointer` returns a pointer whose declared
    /// length is only the first contiguous block; a sample split across
    /// blocks would be read out of bounds if its total length were used.
    nonisolated static func timecodeFrameNumber(
        in block: CMBlockBuffer,
        width: Int
    ) -> Int64? {
        guard width == 4 || width == 8,
              CMBlockBufferGetDataLength(block) >= width else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: width)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: width,
                destination: base
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        // Time-code samples are signed two's-complement frame numbers.
        if width == 8 {
            var value: UInt64 = 0
            for byte in bytes {
                value = (value << 8) | UInt64(byte)
            }
            return Int64(bitPattern: value)
        }
        var value: UInt32 = 0
        for byte in bytes {
            value = (value << 8) | UInt32(byte)
        }
        return Int64(Int32(bitPattern: value))
    }

    /// True when `next` is the expected continuation of `previous`, so no
    /// new segment is needed.
    nonisolated static func isContiguous(
        _ previous: MediaTimecode.SourceSegment,
        followedBy next: MediaTimecode.SourceSegment
    ) -> Bool {
        guard previous.frameRate == next.frameRate,
              previous.frameQuanta == next.frameQuanta,
              previous.isDropFrame == next.isDropFrame,
              let rate = previous.frameRate ?? next.frameRate,
              rate.isFinite, rate > 0 else {
            return false
        }
        if let duration = previous.duration,
           duration.isFinite,
           duration > 0,
           next.time > previous.time + duration + 0.000_001 {
            return false
        }
        let deltaTime = next.time - previous.time
        guard deltaTime.isFinite, deltaTime >= 0 else { return false }
        let rawDelta = (deltaTime * rate).rounded()
        guard rawDelta.isFinite,
              let deltaFrames = Int64(exactly: rawDelta) else {
            return false
        }
        let (expected, overflow) = previous.startFrame
            .addingReportingOverflow(deltaFrames)
        guard !overflow else { return false }
        return expected == next.startFrame
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }
}
