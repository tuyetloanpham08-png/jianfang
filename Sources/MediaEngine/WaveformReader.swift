import AVFoundation
import Foundation
import Synchronization
import EditorCore

/// Timeline waveform peaks for one source's first audio track.
///
/// The blocking AVAssetReader loop runs on one private serial queue, and cancellation only
/// raises a flag that the loop checks between buffers: the reader is created, started,
/// drained and cancelled on that queue alone. Core 0.2.0 called `cancelReading()` from a
/// task-cancellation handler, so a refresh on the main thread tore the reader down while a
/// cooperative-pool thread was inside `copyNextSampleBuffer()` and crashed (EXC_BAD_ACCESS in
/// FigSimpleMutexUnlock). Doing the blocking read on the cooperative pool also let a burst of
/// refreshes park every pool thread in `copyNextSampleBuffer()` and stall the process.
public enum WaveformReader {
    static let queue = DispatchQueue(label: "IndependentEditor.waveform", qos: .utility)
    private final class Flag: Sendable { let cancelled = Atomic<Bool>(false) }

    /// Peak absolute sample per bin across `duration` seconds, or nil when the source has no
    /// audio track or reading did not complete. Throws CancellationError when cancelled.
    public static func peaks(url: URL, duration: Double, bins: Int) async throws -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        try Task.checkCancellation()
        let flag = Flag()
        nonisolated(unsafe) let track = audio
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try read(asset: asset, track: track, duration: duration, bins: bins, flag: flag) })
                }
            }
        }, onCancel: { flag.cancelled.store(true, ordering: .relaxed) })
    }

    private static func read(asset: AVURLAsset, track: AVAssetTrack, duration: Double, bins: Int, flag: Flag) throws -> [Float]? {
        func checkCancelled() throws { if flag.cancelled.load(ordering: .relaxed) { throw CancellationError() } }
        try checkCancelled()
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else { throw ProjectError.invalid("波形音轨不支持读取") }
        reader.add(output)
        var peaks = Array(repeating: Float(0), count: max(1, bins))
        guard reader.startReading() else { throw reader.error ?? ProjectError.invalid("波形读取失败") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let began = ProcessInfo.processInfo.systemUptime
        var sampleBuffers = 0, totalBytes = 0
        let maximumBytes = 8000 * 601 * MemoryLayout<Float>.size
        while let sample = output.copyNextSampleBuffer() {
            try checkCancelled(); sampleBuffers += 1
            guard sampleBuffers <= 100_000, ProcessInfo.processInfo.systemUptime - began <= 30 else { throw ProjectError.invalid("波形读取超出后台预算") }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes > 0 else { continue }
            guard bytes % MemoryLayout<Float>.size == 0, bytes <= 4 * 1024 * 1024, totalBytes <= maximumBytes - bytes else { throw ProjectError.invalid("波形PCM缓冲区无效或超出预算") }
            totalBytes += bytes
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard start.isFinite else { continue }
            var values = Array(repeating: Float(0), count: bytes / MemoryLayout<Float>.size)
            let copied = values.withUnsafeMutableBytes { buffer -> Bool in
                guard let destination = buffer.baseAddress else { return false }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: destination) == kCMBlockBufferNoErr
            }
            guard copied else { throw ProjectError.invalid("波形PCM缓冲区读取失败") }
            for (i, value) in values.enumerated() where value.isFinite {
                let time = start + Double(i) / 8000
                guard time.isFinite else { continue }
                let fraction = min(1, max(0, time / duration))
                let bin = min(peaks.count - 1, Int(fraction * Double(peaks.count)))
                peaks[bin] = max(peaks[bin], abs(value))
            }
        }
        try checkCancelled()
        return reader.status == .completed ? peaks : nil
    }
}
