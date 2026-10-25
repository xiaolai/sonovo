import AVFoundation
import AudioToolbox
import Foundation

enum TimelineAudioPeakError: LocalizedError {
    case readerUnavailable

    var errorDescription: String? {
        "The mixed timeline audio could not be read for peak measurement."
    }
}

enum TimelineAudioPeak {
    /// The floor keeps log10 finite for silence; it is a measurement
    /// convention, not a limiter.
    private static let floor: Float = 1e-5

    static func decibels(_ peak: Float) -> Float {
        20 * log10(max(peak, floor))
    }

    /// Decodes the composition with the same audio mix used by preview and
    /// export. The maximum absolute sample is the peak; no limiter is applied.
    static func measure(
        asset: AVAsset,
        audioMix: AVAudioMix?
    ) async throws -> Float {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: audioTracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.audioMix = audioMix
        let provider = reader.outputProvider(for: output)
        try reader.start()

        var peak: Float = 0
        while let ready = try await provider.next() {
            try Task.checkCancellation()
            ready.withUnsafeSampleBuffer { sample in
                guard let block = CMSampleBufferGetDataBuffer(sample) else {
                    return
                }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                let status = CMBlockBufferGetDataPointer(
                    block,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &pointer
                )
                guard status == kCMBlockBufferNoErr, let pointer else {
                    return
                }
                let count = length / MemoryLayout<Float>.size
                pointer.withMemoryRebound(
                    to: Float.self,
                    capacity: count
                ) { samples in
                    for index in 0..<count {
                        peak = max(peak, abs(samples[index]))
                    }
                }
            }
        }
        return peak
    }
}
