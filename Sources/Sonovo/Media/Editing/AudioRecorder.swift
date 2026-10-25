import AVFoundation
import Foundation
import Observation

enum MicrophonePermission: String, Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted

    var isDenied: Bool { self == .denied || self == .restricted }
}

struct MicrophoneAccess: Sendable {
    let status: @Sendable () -> MicrophonePermission
    let request: @Sendable () async -> Bool

    static let live = MicrophoneAccess(
        status: {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .authorized
            case .denied: .denied
            case .restricted: .restricted
            case .notDetermined: .notDetermined
            @unknown default: .denied
            }
        },
        request: {
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    )

    static let granted = MicrophoneAccess(
        status: { .authorized },
        request: { true }
    )

    static let denied = MicrophoneAccess(
        status: { .denied },
        request: { false }
    )
}

struct AudioRecordingSettings: Equatable, Sendable {
    /// Recording is a capture path, not a mix path: one channel stays mono,
    /// anything wider is captured as stereo. Per-channel routing is later.
    static let sampleRate: Double = 48_000
    static let bitDepth = 24

    let channelCount: Int

    init(channelCount: Int) {
        self.channelCount = min(max(channelCount, 1), 2)
    }

    var settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: Self.bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
}

enum AudioRecordingError: LocalizedError, Equatable {
    case permissionDenied
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Microphone access is denied. Enable it in System Settings › Privacy & Security › Microphone."
        case let .startFailed(message):
            message
        }
    }
}

@MainActor
protocol AudioRecordingEngine: AnyObject {
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    var averagePower: Float { get }
    func start(to url: URL, settings: AudioRecordingSettings) throws
    func stop()
    func cancel()
}

@MainActor
final class AVAudioRecorderEngine: AudioRecordingEngine {
    private var recorder: AVAudioRecorder?

    var isRecording: Bool { recorder?.isRecording == true }

    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }

    var averagePower: Float {
        recorder?.updateMeters()
        return recorder?.averagePower(forChannel: 0) ?? -160
    }

    func start(to url: URL, settings: AudioRecordingSettings) throws {
        let recorder = try AVAudioRecorder(
            url: url,
            settings: settings.settings
        )
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            throw AudioRecordingError.startFailed(
                "The microphone could not start recording."
            )
        }
        self.recorder = recorder
    }

    func stop() {
        recorder?.stop()
        recorder = nil
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
    }
}

enum AudioInputFormat {
    static var hasInputDevice: Bool {
        AVCaptureDevice.default(for: .audio) != nil
    }

    /// The input's real channel count, not a hardcoded mono assumption. The
    /// probe only reads the current format and does not start an engine.
    static func channelCount() -> Int {
        guard hasInputDevice else { return 1 }
        let engine = AVAudioEngine()
        let channels = Int(engine.inputNode.inputFormat(forBus: 0).channelCount)
        return channels > 0 ? min(channels, 2) : 1
    }
}

/// Owns one microphone capture. The engine writes to a temporary file; the
/// project installs that file only after recording stops. This type never
/// touches TCC in tests because the permission and channel probes are
/// injected.
@MainActor
@Observable
final class AudioRecorder {
    enum State: Equatable, Sendable {
        case idle
        case preparing
        case recording(URL)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var permission: MicrophonePermission
    private(set) var channelCount = 1
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Double = 0

    private let engine: any AudioRecordingEngine
    private let access: MicrophoneAccess
    private let channelProbe: @MainActor () -> Int
    private let inputAvailable: @MainActor () -> Bool
    private var ticker: Timer?

    init(
        engine: any AudioRecordingEngine = AVAudioRecorderEngine(),
        access: MicrophoneAccess = .live,
        channelProbe: @escaping @MainActor () -> Int = {
            AudioInputFormat.channelCount()
        },
        inputAvailable: @escaping @MainActor () -> Bool = {
            AudioInputFormat.hasInputDevice
        }
    ) {
        self.engine = engine
        self.access = access
        self.channelProbe = channelProbe
        self.inputAvailable = inputAvailable
        permission = access.status()
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var lastError: String? {
        if case let .failed(message) = state { return message }
        return nil
    }

    var settings: AudioRecordingSettings {
        AudioRecordingSettings(channelCount: channelCount)
    }

    func refreshPermission() {
        guard !isRecording else { return }
        permission = access.status()
        if permission == .authorized,
           case .failed = state {
            state = .idle
        }
    }

    func requestPermissionIfNeeded() async -> Bool {
        // The user may have changed the privacy setting while the app was in
        // the background. Re-read the real status before deciding.
        permission = access.status()
        if permission == .notDetermined {
            let granted = await access.request()
            permission = access.status()
            if permission == .notDetermined {
                permission = granted ? .authorized : .denied
            }
        }
        return permission == .authorized
    }

    func start(to url: URL) async throws {
        guard !isRecording else { return }
        state = .preparing
        guard await requestPermissionIfNeeded() else {
            state = .failed(AudioRecordingError.permissionDenied.localizedDescription)
            throw AudioRecordingError.permissionDenied
        }
        guard inputAvailable() else {
            let message = "No microphone input is connected."
            state = .failed(message)
            throw AudioRecordingError.startFailed(message)
        }
        do {
            let channels = channelProbe()
            channelCount = min(max(channels, 1), 2)
            try engine.start(
                to: url,
                settings: AudioRecordingSettings(channelCount: channelCount)
            )
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
        elapsed = 0
        level = 0
        state = .recording(url)
        startTicker()
    }

    /// Stops and returns the completed temporary file. The caller installs it
    /// into the project.
    @discardableResult
    func stop() -> URL? {
        guard case let .recording(url) = state else {
            stopTicker()
            return nil
        }
        elapsed = engine.currentTime
        level = 0
        engine.stop()
        stopTicker()
        state = .idle
        return url
    }

    func cancel() {
        engine.cancel()
        if case let .recording(url) = state {
            MediaStorage.removeIfPresent(url)
        }
        stopTicker()
        elapsed = 0
        level = 0
        state = .idle
    }

    func clearError() {
        if case .failed = state {
            state = .idle
        }
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 30.0, // token-exempt: meter refresh rate
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMeter()
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func refreshMeter() {
        guard isRecording else { return }
        elapsed = engine.currentTime
        level = AudioLevel.meterValue(fromDecibels: engine.averagePower)
    }
}

enum AudioLevel {
    static func meterValue(fromDecibels decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        let floor: Float = -60
        let clamped = min(max(decibels, floor), 0)
        let value = Double((clamped - floor) / -floor)
        return min(max(value, 0), 1)
    }
}
