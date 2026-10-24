import AVFoundation
import Foundation
import Observation
import SonovoCore

/// Owns the AVPlayer used by the subtitle preview.
///
/// The player is main-actor bound; only asset metadata loading runs off-main.
/// The time observer ticks at 30 Hz so the cue overlay and scrubber follow
/// playback without driving the whole workspace at display refresh.
@MainActor
@Observable
final class SubtitleMediaPlayer {
    private(set) var url: URL?
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var isReady = false
    private(set) var hasVideo = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored
    let player = AVPlayer()

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var preferenceObserver: NSObjectProtocol?
    private var openGeneration: UInt64 = 0
    /// Invalidates a replay's play call when the user pauses, seeks, or
    /// closes before the rewind seek completes.
    private var playGeneration: UInt64 = 0

    init() {
        applyAudioDevice()
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyAudioDevice()
            }
        }
    }

    isolated deinit {
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
        }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    /// The subtitle preview uses its own AVPlayer; it must route to the
    /// same output device as the main player.
    private func applyAudioDevice() {
        let uid = Preferences.audioDeviceUID
        guard player.audioOutputDeviceUniqueID != uid else { return }
        player.audioOutputDeviceUniqueID = uid
    }

    var currentMilliseconds: Int {
        NumericConversion.milliseconds(currentTime)
    }

    var durationMilliseconds: Int {
        NumericConversion.milliseconds(duration)
    }

    // MARK: - Opening

    func open(url: URL) async {
        if self.url == url, isReady {
            return
        }
        close()
        openGeneration += 1
        let generation = openGeneration
        self.url = url
        isLoading = true
        errorMessage = nil

        let metadata = await Task.detached(
            priority: .userInitiated
        ) { () -> Result<MediaMetadata, Error> in
            do {
                let asset = AVURLAsset(url: url)
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration)
                let videoTracks = try await asset.loadTracks(
                    withMediaType: .video
                )
                let audioTracks = try await asset.loadTracks(
                    withMediaType: .audio
                )
                return .success(
                    MediaMetadata(
                        isPlayable: playable,
                        duration: duration.seconds,
                        hasVideo: !videoTracks.isEmpty,
                        hasAudio: !audioTracks.isEmpty
                    )
                )
            } catch {
                return .failure(error)
            }
        }.value

        guard generation == openGeneration else { return }

        switch metadata {
        case let .success(metadata):
            guard metadata.isPlayable else {
                fail("This file cannot be played.")
                return
            }
            guard metadata.duration.isFinite, metadata.duration > 0 else {
                fail("This file has no playable duration.")
                return
            }
            guard metadata.hasVideo || metadata.hasAudio else {
                fail("This file has no audio or video tracks.")
                return
            }
            let item = AVPlayerItem(asset: AVURLAsset(url: url))
            player.replaceCurrentItem(with: item)
            duration = metadata.duration
            hasVideo = metadata.hasVideo
            // Readiness follows the item's actual status, not the asset
            // metadata. A track that parses but cannot be played must not
            // enable the transport.
            isLoading = true
            installObservers(item: item)
        case let .failure(error):
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        isReady = false
        isLoading = false
        hasVideo = false
        duration = 0
    }

    private func installObservers(item: AVPlayerItem) {
        removeObservers()
        statusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem else {
                    return
                }
                switch item.status {
                case .readyToPlay:
                    self.isReady = true
                    self.isLoading = false
                case .failed:
                    self.errorMessage = item.error?.localizedDescription
                        ?? "The file could not be played."
                    self.isReady = false
                    self.isPlaying = false
                    self.isLoading = false
                default:
                    break
                }
            }
        }
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.handleTick(time)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleEnd()
            }
        }
    }

    private func removeObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
    }

    // MARK: - Transport

    func play() {
        guard isReady else { return }
        if currentTime >= duration - 0.05 {
            replayFromStart()
            return
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        playGeneration &+= 1
        player.pause()
        isPlaying = false
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: TimeInterval) {
        guard isReady else { return }
        let target = min(max(0, seconds), duration)
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func seek(toMilliseconds milliseconds: Int) {
        seek(to: TimeInterval(milliseconds) / 1000)
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func close() {
        openGeneration += 1
        playGeneration &+= 1
        removeObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        url = nil
        duration = 0
        currentTime = 0
        isPlaying = false
        isReady = false
        hasVideo = false
        isLoading = false
        errorMessage = nil
    }

    // MARK: - Observer callbacks

    private func handleTick(_ time: CMTime) {
        let seconds = time.seconds
        if seconds.isFinite, seconds >= 0 {
            currentTime = min(seconds, duration)
        }
        isPlaying = player.timeControlStatus == .playing
        if let itemError = player.currentItem?.error {
            errorMessage = itemError.localizedDescription
            isReady = false
            isPlaying = false
            isLoading = false
        }
    }

    private func handleEnd() {
        isPlaying = false
        currentTime = duration
    }

    /// Restarts a finished item. Playback cannot resume from the end, and
    /// calling play() synchronously after seek can be ignored while the seek
    /// is still in flight, so play starts in the seek completion.
    private func replayFromStart() {
        playGeneration &+= 1
        let generation = playGeneration
        currentTime = 0
        player.seek(
            to: .zero,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor in
                guard let self, finished,
                      generation == self.playGeneration,
                      self.isReady,
                      self.player.currentItem != nil else {
                    return
                }
                self.player.play()
                self.isPlaying = true
            }
        }
    }
}

private struct MediaMetadata: Sendable {
    let isPlayable: Bool
    let duration: TimeInterval
    let hasVideo: Bool
    let hasAudio: Bool
}
