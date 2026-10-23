import AVFoundation
import CoreMedia
import Foundation
import Observation
import SonovoCore

/// Fixed-resolution peak analysis. The view width does not change the data;
/// the waveform is downsampled for drawing. Peak, sample count, and sum of
/// squares are retained so RMS is possible without a second pass.
struct WaveformData: Sendable, Equatable {
    let peaks: [Float]
    let sumSquares: [Float]
    /// The number of source frames that actually landed in each bucket. The
    /// final bucket is usually partial; RMS must divide by its real count,
    /// not by a full bucket.
    let bucketFrameCounts: [Int]
    let bucketFrames: Int
    let totalFrames: Int
    let sampleRate: Double
    let channelCount: Int
    let bucketsPerSecond: Int
    let duration: Double

    func rms(at index: Int) -> Float? {
        guard index >= 0,
              index < sumSquares.count,
              index < bucketFrameCounts.count,
              bucketFrameCounts[index] > 0 else {
            return nil
        }
        return sqrt(sumSquares[index] / Float(bucketFrameCounts[index]))
    }
}

@MainActor
@Observable
final class WaveformModel {
    enum State: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var data: WaveformData?
    private(set) var state: State = .idle

    private let cache: WaveformCache
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(cache: WaveformCache = .shared) {
        self.cache = cache
    }

    func load(url: URL, revision: AssetRevision) {
        task?.cancel()
        generation &+= 1
        let generation = generation
        if let cached = cache.data(for: url, revision: revision) {
            data = cached
            state = .ready
            return
        }
        data = nil
        state = .loading
        task = Task { @MainActor [weak self] in
            do {
                let result = try await WaveformExtractor.extract(url: url)
                guard !Task.isCancelled,
                      let self,
                      generation == self.generation else {
                    return
                }
                self.cache.store(result, for: url, revision: revision)
                self.data = result
                self.state = .ready
            } catch is CancellationError {
                // A newer source replaced this one.
            } catch {
                guard let self, generation == self.generation else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation &+= 1
    }
}

@MainActor
final class WaveformCache {
    static let shared = WaveformCache()

    private struct Key: Hashable {
        let path: String
        let revision: String
        let bucketsPerSecond: Int
        let channelLayout: String
    }

    private static let channelLayout = "mono-downmix"

    private var storage: [Key: WaveformData] = [:]
    private var order: [Key] = []
    private var byteCount = 0
    private let byteBudget: Int

    init(byteBudget: Int = 64 * 1024 * 1024) {
        self.byteBudget = byteBudget
    }

    var cachedByteCount: Int { byteCount }

    func data(for url: URL, revision: AssetRevision) -> WaveformData? {
        let key = key(
            for: url,
            revision: revision,
            bucketsPerSecond: WaveformExtractor.bucketsPerSecond
        )
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    func contains(url: URL, revision: AssetRevision) -> Bool {
        storage[key(
            for: url,
            revision: revision,
            bucketsPerSecond: WaveformExtractor.bucketsPerSecond
        )] != nil
    }

    func store(
        _ data: WaveformData,
        for url: URL,
        revision: AssetRevision
    ) {
        let key = key(
            for: url,
            revision: revision,
            bucketsPerSecond: data.bucketsPerSecond
        )
        if let existing = storage[key] {
            byteCount -= cost(existing)
        }
        storage[key] = data
        byteCount += cost(data)
        order.removeAll { $0 == key }
        order.append(key)
        evictIfNeeded()
    }

    private func key(
        for url: URL,
        revision: AssetRevision,
        bucketsPerSecond: Int
    ) -> Key {
        Key(
            path: url.path,
            revision: revision.token,
            bucketsPerSecond: bucketsPerSecond,
            channelLayout: Self.channelLayout
        )
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while byteCount > byteBudget, let oldest = order.first {
            order.removeFirst()
            if let value = storage.removeValue(forKey: oldest) {
                byteCount -= cost(value)
            }
        }
    }

    private func cost(_ data: WaveformData) -> Int {
        (data.peaks.count + data.sumSquares.count)
            * MemoryLayout<Float>.size
            + data.bucketFrameCounts.count * MemoryLayout<Int>.size
    }
}

enum WaveformExtractor {
    static let bucketsPerSecond = 200
    /// Four hours at 200 buckets/s is about 2.9M buckets across three
    /// arrays. Longer audio gets a named failure instead of an unbounded
    /// allocation.
    static let maximumAnalyzedSeconds: Double = 4 * 60 * 60

    static func extract(url: URL) async throws -> WaveformData {
        let task = Task.detached(priority: .userInitiated) {
            try extractSync(url: url)
        }
        // Cancelling the caller must cancel the detached decode too; its
        // per-sample check otherwise never observes the cancellation.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func extractSync(url: URL) throws -> WaveformData {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw WaveformError.noAudioTrack
        }
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0 else {
            throw WaveformError.invalidDuration
        }
        guard duration <= WaveformExtractor.maximumAnalyzedSeconds else {
            throw WaveformError.tooLong
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
            throw WaveformError.cannotRead
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? WaveformError.cannotRead
        }
        defer { reader.cancelReading() }

        var accumulator = BucketAccumulator(duration: duration)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            accumulator.consume(sample)
        }

        if reader.status == .failed {
            throw reader.error ?? WaveformError.cannotRead
        }
        return try accumulator.finish()
    }

    /// Peak and sum-of-squares accumulation for one asset. Kept separate from
    /// the reader loop so placement, allocation, and trimming each stay
    /// readable on their own.
    private struct BucketAccumulator {
        let duration: Double
        private var peaks: [Float] = []
        private var sums: [Float] = []
        private var counts: [Int] = []
        private var bucketFrames = 1
        private var sampleRate: Double = 44_100
        private var channelCount = 1
        private var totalFrames = 0
        private var bufferFailures = 0

        init(duration: Double) {
            self.duration = duration
        }

        mutating func consume(_ sample: CMSampleBuffer) {
            guard let format = CMSampleBufferGetFormatDescription(sample),
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(
                    format
                  )?.pointee else {
                return
            }
            let rate = stream.mSampleRate > 0
                ? stream.mSampleRate
                : sampleRate
            guard rate.isFinite, rate > 0 else {
                bufferFailures += 1
                return
            }
            let channels = max(Int(stream.mChannelsPerFrame), 1)
            guard let rawFramesPerBucket = NumericConversion.int(
                rate / Double(WaveformExtractor.bucketsPerSecond)
            ) else {
                bufferFailures += 1
                return
            }
            let framesPerBucket = max(rawFramesPerBucket, 1)
            allocateIfNeeded(
                rate: rate,
                channels: channels,
                framesPerBucket: framesPerBucket
            )

            guard let frameCount = withFloatSamples(
                in: sample,
                channels: channels,
                { pointer, frames in
                    accumulate(
                        samples: pointer,
                        frameCount: frames,
                        channels: channels,
                        framesPerBucket: framesPerBucket,
                        sample: sample
                    )
                }
            ) else {
                bufferFailures += 1
                return
            }
            totalFrames += frameCount
        }

        func finish() throws -> WaveformData {
            guard bufferFailures == 0 else {
                throw WaveformError.cannotRead
            }
            guard totalFrames > 0, !peaks.isEmpty else {
                throw WaveformError.emptyAudio
            }
            // The allocation carries two guard buckets so a partial final
            // frame cannot index past the end. They are not part of the
            // timeline: MediaWaveformView stretches every bucket across the
            // asset duration, so leaving them shifts every visible event.
            let rawBuckets = ceil(
                duration * sampleRate / Double(bucketFrames)
            )
            guard rawBuckets.isFinite,
                  let bucketCount = NumericConversion.int(rawBuckets)
            else {
                throw WaveformError.cannotRead
            }
            let timelineBuckets = min(
                max(1, bucketCount),
                peaks.count
            )
            return WaveformData(
                peaks: Array(peaks.prefix(timelineBuckets)),
                sumSquares: Array(sums.prefix(timelineBuckets)),
                bucketFrameCounts: Array(counts.prefix(timelineBuckets)),
                bucketFrames: bucketFrames,
                totalFrames: totalFrames,
                sampleRate: sampleRate,
                channelCount: channelCount,
                bucketsPerSecond: WaveformExtractor.bucketsPerSecond,
                duration: duration
            )
        }

        private mutating func allocateIfNeeded(
            rate: Double,
            channels: Int,
            framesPerBucket: Int
        ) {
            guard peaks.isEmpty else { return }
            sampleRate = rate
            channelCount = channels
            bucketFrames = framesPerBucket
            // Allocate from the same rounded frames-per-bucket used for
            // indexing, not from a nominal 200 buckets per second. The two
            // disagree at rates such as 22.05 kHz, and the smaller allocation
            // silently dropped the trailing audio.
            let rawCount = ceil(
                duration * rate / Double(framesPerBucket)
            ) + 2
            guard rawCount.isFinite,
                  let count = NumericConversion.int(rawCount),
                  count > 0 else {
                bufferFailures += 1
                return
            }
            peaks = Array(repeating: 0, count: count)
            sums = Array(repeating: 0, count: count)
            counts = Array(repeating: 0, count: count)
        }

        /// Borrows the sample's float PCM for the duration of `body` and
        /// returns the frame count. The retained block buffer stays alive
        /// here until the body has consumed the pointer; returning the
        /// pointer alone would let ARC release the owner first.
        private func withFloatSamples(
            in sample: CMSampleBuffer,
            channels: Int,
            _ body: (UnsafePointer<Float>, Int) -> Void
        ) -> Int? {
            var bufferList = AudioBufferList()
            var block: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample,
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
                return nil
            }
            let frameCount = Int(bufferList.mBuffers.mDataByteSize)
                / (MemoryLayout<Float>.size * channels)
            body(data.assumingMemoryBound(to: Float.self), frameCount)
            withExtendedLifetime(block) {}
            return frameCount
        }

        private mutating func accumulate(
            samples: UnsafePointer<Float>,
            frameCount: Int,
            channels: Int,
            framesPerBucket: Int,
            sample: CMSampleBuffer
        ) {
            // Place the buffer on the asset timeline. A track with an
            // initial offset or a gap must not have its waveform shifted
            // by the cumulative decoded sample count.
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            let timelineOffset: Int
            if presentation.isNumeric,
               presentation.seconds.isFinite,
               let offset = NumericConversion.int(
                   presentation.seconds * sampleRate
               ) {
                timelineOffset = offset
            } else {
                timelineOffset = totalFrames
            }
            for frame in 0..<frameCount {
                let (absolute, overflow) = timelineOffset
                    .addingReportingOverflow(frame)
                // A negative timestamp places samples before the asset
                // timeline; indexing with it would crash. An overflowing
                // sample is equally outside the timeline.
                guard !overflow, absolute >= 0 else { continue }
                let bucket = absolute / framesPerBucket
                guard bucket < peaks.count else { break }
                var framePeak: Float = 0
                var frameSquare: Float = 0
                for channel in 0..<channels {
                    let value = samples[frame * channels + channel]
                    framePeak = max(framePeak, abs(value))
                    frameSquare += value * value
                }
                peaks[bucket] = max(peaks[bucket], framePeak)
                sums[bucket] += frameSquare / Float(channels)
                counts[bucket] += 1
            }
        }
    }
}

enum WaveformError: LocalizedError {
    case noAudioTrack
    case invalidDuration
    case cannotRead
    case emptyAudio
    case tooLong

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: "This file has no audio track."
        case .invalidDuration: "This file has no usable duration."
        case .cannotRead: "The audio track could not be read."
        case .emptyAudio: "The audio track contained no samples."
        case .tooLong:
            "This audio is longer than four hours; the waveform is not drawn."
        }
    }
}
