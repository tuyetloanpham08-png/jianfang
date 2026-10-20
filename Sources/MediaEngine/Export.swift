import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import EditorCore

/// Measured on the mixed 48 kHz 16-bit PCM before AAC encoding.
public struct ExportReport: Sendable {
    /// Interleaved samples at ±full scale: the mix was hard-clipped there.
    public let fullScaleSamples: Int
    public let peakSample: Int
    public var peakDBFS: Double { peakSample == 0 ? -.infinity : 20 * log10(Double(peakSample) / 32768) }
    /// Chinese warning for the UI/CLI, nil when nothing reached full scale.
    public var clippingWarning: String? {
        guard fullScaleSamples > 0 else { return nil }
        return "混音有 \(fullScaleSamples) 个采样达到满幅（约 \(String(format: "%.2f", Double(fullScaleSamples) / 96000)) 秒），这些位置已削波。请降低重叠片段或音轨的音量后，重新导出到新文件"
    }
}

extension TimelineEngine {
    /// Export uses the very same AVVideoComposition and AVAudioMix as preview.
    /// Writes a sibling temporary file and publishes only a completed result.
    @discardableResult
    public static func export(_ compiled: CompiledTimeline, to url: URL, progress: @escaping (Double) -> Void) async throws -> ExportReport {
        do { return try await writeExport(compiled, to: url, progress: progress) }
        catch { throw MediaEngineError.describing(error, "导出失败：\(url.lastPathComponent)。未完成的文件已清理，已有成片没有改动；请检查磁盘空间和目标文件夹的写入权限后重试") }
    }

    private static func writeExport(_ compiled: CompiledTimeline, to url: URL, progress: @escaping (Double) -> Void) async throws -> ExportReport {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw MediaEngineError.invalid("导出目标已存在，请选择新文件名") }
        let directory = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { throw MediaEngineError.invalid("导出目录不存在") }
        // Partial output lives in a system temporary area on the same volume, not beside the user's files.
        let staging = AssetStore.stagingDirectory(near: directory)
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        let temporary = staging?.appendingPathComponent("\(UUID().uuidString).partial.mp4")
            ?? directory.appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).\(UUID().uuidString).partial.mp4")
        let reader = try AVAssetReader(asset: compiled.composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: compiled.duration)
        let videoTracks = try await compiled.composition.loadTracks(withMediaType: .video)
        let audioTracks = try await compiled.composition.loadTracks(withMediaType: .audio)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.videoComposition = compiled.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw MediaEngineError.render("无法创建导出视频读取器") }
        reader.add(videoOutput)
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        audioOutput.audioMix = compiled.audioMix
        audioOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(audioOutput) else { throw MediaEngineError.render("无法创建导出混音读取器") }
        reader.add(audioOutput)
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        // moov before mdat ("faststart"): players can start without reading to the end of the file.
        writer.shouldOptimizeForNetworkUse = true
        let size = compiled.videoComposition.renderSize
        let fps = Int((1 / CMTimeGetSeconds(compiled.videoComposition.frameDuration)).rounded())
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: false
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.mediaTimeScale = Int32(fps * 1000)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000
        ])
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw MediaEngineError.render("系统不支持要求的 H.264/AAC 编码设置") }
        writer.add(videoInput); writer.add(audioInput)
        do {
            guard writer.startWriting() else { throw writer.error ?? MediaEngineError.render("导出编码器启动失败") }
            writer.startSession(atSourceTime: .zero)
            guard reader.startReading() else { throw reader.error ?? MediaEngineError.render("时间线读取失败") }
            progress(0)
            let pump = ExportMediaPump(reader: reader, writer: writer,
                                       videoOutput: videoOutput, audioOutput: audioOutput,
                                       videoInput: videoInput, audioInput: audioInput,
                                       duration: compiled.duration, progress: progress)
            try await pump.run()
            guard reader.status == .completed else { throw reader.error ?? MediaEngineError.render("时间线读取未完成") }
            writer.endSession(atSourceTime: compiled.duration)
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? MediaEngineError.render("导出文件未完整写入") }
            // moveItem does not overwrite a destination created during export.
            try FileManager.default.moveItem(at: temporary, to: url)
            progress(1)
            return ExportReport(fullScaleSamples: pump.fullScaleSamples, peakSample: pump.peakSample)
        } catch {
            reader.cancelReading()
            if writer.status != .completed { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public static func frame(_ compiled: CompiledTimeline, atFrame: Int, fps: Int, to url: URL) async throws {
        let requested = CMTime(value: Int64(atFrame), timescale: Int32(fps))
        guard fps > 0, atFrame >= 0, CMTimeCompare(requested, compiled.duration) < 0 else { throw MediaEngineError.invalid("抽帧位置超出工程") }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw MediaEngineError.invalid("抽帧目标已存在") }
        let generator = AVAssetImageGenerator(asset: compiled.composition)
        generator.videoComposition = compiled.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: requested)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw MediaEngineError.render("无法创建 PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MediaEngineError.render("PNG 编码失败") }
        try (data as Data).write(to: url, options: .withoutOverwriting)
    }
}

/// Reader outputs must be drained independently: compressed video frames and
/// mixed PCM buffers cover different time spans. A one-video/one-audio loop can
/// get one output minutes ahead, then block while the other is unable to drain.
private final class ExportMediaPump: @unchecked Sendable {
    private enum Stream: Hashable { case video, audio }
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderOutput
    private let audioOutput: AVAssetReaderOutput
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let duration: Double
    private let progress: (Double) -> Void
    private let videoQueue = DispatchQueue(label: "IndependentEditor.export.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "IndependentEditor.export.audio", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "IndependentEditor.export.control", qos: .userInitiated)
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var failure: Error?
    private var finished: Set<Stream> = []
    private var lastActivity = DispatchTime.now().uptimeNanoseconds
    private var lastVideoProgress = 0.0 // Accessed only on videoQueue.
    /// Mixed 16-bit samples at ±full scale, i.e. clipped by the mix; written on audioQueue, read after run().
    private(set) var fullScaleSamples = 0
    private(set) var peakSample = 0

    private func measure(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let length = CMBlockBufferGetDataLength(block)
        let count = length / 2
        guard count > 0 else { return }
        var values = [Int16](repeating: 0, count: count)
        guard values.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 2, destination: $0.baseAddress!) }) == kCMBlockBufferNoErr else { return }
        for value in values {
            let magnitude = value == .min ? 32768 : Int(abs(value))
            if magnitude >= 32767 { fullScaleSamples += 1 }
            if magnitude > peakSample { peakSample = magnitude }
        }
    }

    init(reader: AVAssetReader, writer: AVAssetWriter,
         videoOutput: AVAssetReaderOutput, audioOutput: AVAssetReaderOutput,
         videoInput: AVAssetWriterInput, audioInput: AVAssetWriterInput,
         duration: CMTime, progress: @escaping (Double) -> Void) {
        self.reader = reader; self.writer = writer
        self.videoOutput = videoOutput; self.audioOutput = audioOutput
        self.videoInput = videoInput; self.audioInput = audioInput
        self.duration = CMTimeGetSeconds(duration); self.progress = progress
        group.enter(); group.enter()
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let timer = DispatchSource.makeTimerSource(queue: controlQueue)
                timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
                timer.setEventHandler { [weak self] in self?.checkStatus() }
                timer.resume()
                group.notify(queue: controlQueue) { [self] in
                    timer.cancel()
                    lock.lock(); let error = failure; lock.unlock()
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
                // Cancellation waits for registration to finish, then finishes both
                // serial queues before resuming the caller (writeExport cancels the reader).
                lock.lock()
                if failure == nil {
                    videoInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in self?.drain(.video) }
                    audioInput.requestMediaDataWhenReady(on: audioQueue) { [weak self] in self?.drain(.audio) }
                    lock.unlock()
                } else {
                    lock.unlock()
                    videoQueue.async { [self] in finish(.video) }
                    audioQueue.async { [self] in finish(.audio) }
                }
            }
        } onCancel: {
            self.fail(CancellationError())
        }
    }

    private func drain(_ stream: Stream) {
        let input = stream == .video ? videoInput : audioInput
        let output = stream == .video ? videoOutput : audioOutput
        lock.lock(); let alreadyFinished = finished.contains(stream); lock.unlock()
        guard !alreadyFinished else { return }
        while input.isReadyForMoreMediaData {
            lock.lock(); let error = failure; lock.unlock()
            if error != nil { finish(stream); return }
            do {
                if writer.status == .failed { throw writer.error ?? MediaEngineError.render("导出编码失败") }
                if reader.status == .failed { throw reader.error ?? MediaEngineError.render("导出解码或合成失败") }
                let ended: Bool = try autoreleasepool {
                    guard let sample = output.copyNextSampleBuffer() else {
                        if reader.status == .failed { throw reader.error ?? MediaEngineError.render("媒体读取失败") }
                        if reader.status == .cancelled { throw CancellationError() }
                        return true
                    }
                    lock.lock(); let stopped = failure != nil; lock.unlock()
                    if stopped { return true }
                    if stream == .audio { measure(sample) }
                    guard input.append(sample) else { throw writer.error ?? MediaEngineError.render("导出媒体写入失败") }
                    lock.lock(); lastActivity = DispatchTime.now().uptimeNanoseconds; lock.unlock()
                    if stream == .video {
                        let value = min(0.99, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) / duration)
                        if value - lastVideoProgress >= 0.01 { progress(value); lastVideoProgress = value }
                    }
                    return false
                }
                if ended { finish(stream); return }
            } catch {
                fail(error)
                finish(stream)
                return
            }
        }
    }

    /// Must run on the corresponding input's serial queue. It executes at most
    /// once and cannot race an append on that same input.
    private func finish(_ stream: Stream) {
        lock.lock()
        let isNew = finished.insert(stream).inserted
        lock.unlock()
        guard isNew else { return }
        let input = stream == .video ? videoInput : audioInput
        if writer.status == .writing { input.markAsFinished() }
        group.leave()
    }

    /// Stops both drains at their next buffer. The reader is cancelled by writeExport only
    /// after run() returns, when both input queues are quiescent: cancelReading() racing an
    /// in-flight copyNextSampleBuffer() is the teardown race that crashed Core 0.2.0's timeline
    /// preview. Only a 60-second stall, where a drain may be
    /// stuck inside copyNextSampleBuffer() and nothing else can end it, cancels the reader here.
    private func fail(_ error: Error, cancelStuckReader: Bool = false) {
        lock.lock()
        guard failure == nil else { lock.unlock(); return }
        failure = error
        lock.unlock()
        controlQueue.async { [self] in
            // Do not cancel the writer until both input queues are quiescent;
            // its cancellation must not race an in-flight append/markAsFinished.
            if cancelStuckReader { reader.cancelReading() }
            videoQueue.async { [self] in finish(.video) }
            audioQueue.async { [self] in finish(.audio) }
        }
    }

    private func checkStatus() {
        if writer.status == .failed { fail(writer.error ?? MediaEngineError.render("导出编码失败")); return }
        if reader.status == .failed { fail(reader.error ?? MediaEngineError.render("媒体读取失败")); return }
        lock.lock(); let last = lastActivity; let done = finished.count == 2; lock.unlock()
        if !done, DispatchTime.now().uptimeNanoseconds - last > 60_000_000_000 {
            fail(MediaEngineError.render("媒体导出连续 60 秒无进展，已停止并清理未完成文件"), cancelStuckReader: true)
        }
    }
}
