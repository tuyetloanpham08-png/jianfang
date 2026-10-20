import AVFoundation
import Foundation
import EditorCore

/// Import-time probe: every unsupported property is collected at once (not only
/// the first), and track lengths are measured per track with integer CMTime math.
public struct MediaInspection: Sendable {
    public let name: String
    public let hasVideo: Bool
    public let hasAudio: Bool
    public let videoIssues: [String]
    public let audioIssues: [String]
    /// Half-open project-frame ranges fully covered by each source track.
    public let videoFrames: Range<Int>?
    public let audioFrames: Range<Int>?
    /// Full Chinese rejection for the picture (or for an audio-only file), nil when importable.
    public var rejection: String? {
        let issues = hasVideo ? videoIssues : audioIssues
        return issues.isEmpty ? nil : TimelineEngine.unsupportedMessage(issues, name: name)
    }
    /// The picture can still be imported without its original audio when only the audio is unsupported.
    public var audioOnlyProblem: String? {
        hasVideo && hasAudio && !audioIssues.isEmpty ? "原声不符合规格（" + audioIssues.joined(separator: "；") + "），已只导入画面、未关联原声" : nil
    }
}

/// Remembers sources whose full compressed-timestamp CFR scan already passed, keyed by
/// path + size + modification date, so every edit no longer rereads each whole video file.
/// A changed file gets a new key and is scanned again; failures are never cached.
final class CFRScanCache: @unchecked Sendable {
    static let shared = CFRScanCache()
    private let lock = NSLock()
    private var passed = Set<String>()
    private(set) var hits = 0, scans = 0
    static func key(_ asset: AVAsset) -> String? {
        guard let url = (asset as? AVURLAsset)?.url, url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else { return nil }
        return "\(url.standardizedFileURL.path)|\(size)|\(date.timeIntervalSinceReferenceDate)"
    }
    func contains(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; if passed.contains(key) { hits += 1; return true }; scans += 1; return false }
    func insert(_ key: String) { lock.lock(); passed.insert(key); lock.unlock() }
    var counts: (hits: Int, scans: Int) { lock.lock(); defer { lock.unlock() }; return (hits, scans) }
}

extension TimelineEngine {
    /// Diagnostics for tests and logs: CFR scans skipped thanks to the cache, and scans performed.
    public static var cfrScanCounts: (hits: Int, scans: Int) { CFRScanCache.shared.counts }
    static let compatibleCopyHint = "处理办法：先生成兼容副本（H.264 High 8bit 4:2:0、不高于1080p、30fps 恒定帧率、BT.709 limited，音频 AAC 48kHz 双声道）再导入，支持范围见项目说明；原文件不会被修改，副本按新素材登记"

    static func unsupportedMessage(_ issues: [String], name: String) -> String {
        // HDR needs tone mapping, which neither the app nor the compatible-copy script performs.
        let hdr = issues.contains { $0.hasPrefix("HDR") } ? "HDR 素材须先在调色软件中转换为 SDR BT.709，兼容副本脚本不做色调映射；" : ""
        return "素材不符合首版输入规格：\(name)。不符项：" + issues.joined(separator: "；") + "。" + hdr + compatibleCopyHint
    }

    public static func inspect(_ url: URL, fps: Int = 30) async throws -> MediaInspection {
        let name = url.lastPathComponent
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw MediaEngineError.invalid("无法读取素材：\(name)") }
        let asset = AVURLAsset(url: url)
        let videos: [AVAssetTrack], audios: [AVAssetTrack]
        do {
            videos = try await asset.loadTracks(withMediaType: .video)
            audios = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw MediaEngineError.invalid("无法打开素材，文件可能损坏或不是支持的音视频格式：\(name)")
        }
        guard !videos.isEmpty || !audios.isEmpty else { throw MediaEngineError.invalid("文件没有可用音视频轨：\(name)") }
        var videoIssues: [String] = [], audioIssues: [String] = []
        var videoFrames: Range<Int>?, audioFrames: Range<Int>?
        if let track = videos.first {
            videoIssues = try await videoProblems(track, asset: asset)
            videoFrames = try await frames(of: track, fps: fps)
            if videoFrames == nil { videoIssues.append("视频轨不足一帧或时长无效") }
        }
        if let track = audios.first {
            audioIssues = try await audioProblems(track)
            audioFrames = try await frames(of: track, fps: fps)
            if audioFrames == nil { audioIssues.append("音频轨不足一帧或时长无效") }
        }
        return MediaInspection(name: name, hasVideo: !videos.isEmpty, hasAudio: !audios.isEmpty,
                               videoIssues: videoIssues, audioIssues: audioIssues,
                               videoFrames: videoFrames, audioFrames: audioFrames)
    }

    static func frames(of track: AVAssetTrack, fps: Int) async throws -> Range<Int>? {
        let range = try await track.load(.timeRange)
        let end = CMTimeRangeGetEnd(range)
        guard range.start.isNumeric, end.isNumeric, range.start.timescale > 0, end.timescale > 0 else { return nil }
        return FrameMath.usableFrames(start: (range.start.value, range.start.timescale), end: (end.value, end.timescale), fps: fps)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
        let text = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? String(code) : text
    }

    /// All picture-format problems. The compressed-timestamp CFR scan reads the
    /// whole track, so it runs only when every cheaper check already passed.
    static func videoProblems(_ track: AVAssetTrack, asset: AVAsset) async throws -> [String] {
        var issues: [String] = []
        let descriptions = try await track.load(.formatDescriptions)
        var isH264 = !descriptions.isEmpty
        for description in descriptions {
            let codec = CMFormatDescriptionGetMediaSubType(description)
            let extensions = (CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? NSDictionary()
            let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Data] ?? [:]
            if codec != kCMVideoCodecType_H264 {
                isH264 = false
                let label = [kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha, 0x6865_7631 /* hev1 */].contains(codec) ? "HEVC/H.265" : fourCC(codec)
                if !issues.contains(where: { $0.hasPrefix("编码") }) { issues.append("编码为 \(label)（需 H.264）") }
            }
            var deep = false
            if let bits = extensions[kCMFormatDescriptionExtension_BitsPerComponent] as? Int, bits > 8 { deep = true }
            if let hvcC = atoms["hvcC"], hvcC.count > 1, hvcC[1] & 0x1f == 2 { deep = true }
            if codec == kCMVideoCodecType_H264, let avc = atoms["avcC"], avc.count > 2, ![66, 77, 88, 100].contains(Int(avc[1])) {
                issues.append("H.264 档次为 \(Int(avc[1]))（需 8bit 4:2:0 的 Baseline/Main/High）")
            } else if deep, !issues.contains(where: { $0.hasPrefix("位深") }) {
                issues.append("位深高于 8bit（需 8bit 4:2:0）")
            }
            let transfer = extensions[kCVImageBufferTransferFunctionKey] as? String
            let hdr = transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
            if hdr {
                if !issues.contains(where: { $0.hasPrefix("HDR") }) { issues.append("HDR（PQ/HLG）视频（需 SDR BT.709）") }
                continue
            }
            if codec == kCMVideoCodecType_H264 {
                let colorTags = atoms["avcC"].flatMap { try? AVCColorTags.read(from: $0) } ?? []
                if colorTags.isEmpty || !colorTags.allSatisfy({ $0.primaries == 1 && $0.transfer == 1 && $0.matrix == 1 && !$0.fullRange }) {
                    issues.append("SPS 色彩标签缺失或不是 BT.709 limited-range")
                }
            }
            if (extensions[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool) == true, !issues.contains(where: { $0.contains("full-range") }) {
                issues.append("full-range 视频（需 limited-range）")
            }
            // Container metadata, when exposed, must not contradict BT.709.
            let containerTags: [(CFString, CFString)] = [
                (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
                (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            ]
            if !containerTags.allSatisfy({ key, expected in (extensions[key] as? String).map { $0 == expected as String } ?? true }),
               !issues.contains(where: { $0.hasPrefix("容器") }) {
                issues.append("容器色彩标签与 BT.709 不一致")
            }
        }
        if descriptions.isEmpty { issues.append("无法识别视频编码") }
        let size = try await track.load(.naturalSize)
        if max(size.width, size.height) > 1920 || min(size.width, size.height) > 1080 {
            issues.append("分辨率 \(Int(size.width))×\(Int(size.height))（需不高于 1920×1080 或 1080×1920）")
        }
        let rate = Double(try await track.load(.nominalFrameRate))
        let fps = [24.0, 25, 30].first(where: { abs($0 - rate) < 0.001 })
        if fps == nil { issues.append("帧率 \(String(format: "%.3f", rate).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression))fps（需 24/25/30fps 恒定帧率）") }
        if issues.isEmpty, isH264, let fps {
            let key = CFRScanCache.key(asset)
            if let key, CFRScanCache.shared.contains(key) { return issues }
            if let vfr = try await variableFrameRateProblem(track, asset: asset, fps: fps) { issues.append(vfr) }
            else if let key { CFRScanCache.shared.insert(key) }
        }
        return issues
    }

    static func audioProblems(_ track: AVAssetTrack) async throws -> [String] {
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first, let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return ["无法识别音频格式"]
        }
        var issues: [String] = []
        if ![kAudioFormatLinearPCM, kAudioFormatMPEG4AAC].contains(basic.mFormatID) { issues.append("音频编码 \(fourCC(basic.mFormatID))（需 PCM 或 AAC-LC）") }
        if ![44100.0, 48000.0].contains(basic.mSampleRate) { issues.append("采样率 \(Int(basic.mSampleRate))Hz（需 44.1/48kHz）") }
        if !(1...2).contains(basic.mChannelsPerFrame) { issues.append("\(basic.mChannelsPerFrame) 声道（需单/双声道）") }
        return issues
    }

    /// Inspect compressed sample timestamps (no decode), rather than trusting
    /// nominalFrameRate, to reject variable-frame-rate assets explicitly.
    static func variableFrameRateProblem(_ track: AVAssetTrack, asset: AVAsset, fps: Double) async throws -> String? {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MediaEngineError.invalid("无法读取视频时间信息") }
        var timestamps: [Double] = [], timescale: Int32 = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // AVAssetReader emits zero-sample edit-list/discontinuity markers;
            // their duplicate timestamp is not a variable-rate video frame.
            let count = CMSampleBufferGetNumSamples(sample)
            for index in 0..<count {
                var info = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &info) == noErr else {
                    throw MediaEngineError.invalid("无法读取源视频帧时间")
                }
                timestamps.append(CMTimeGetSeconds(info.presentationTimeStamp))
                timescale = max(timescale, info.presentationTimeStamp.timescale)
            }
        }
        guard reader.status == .completed else { throw reader.error ?? MediaEngineError.invalid("视频时间信息读取失败") }
        guard !timestamps.isEmpty, timescale > 0 else { return "视频没有有效帧" }
        timestamps.sort()
        return FrameMath.isConstantFrameRate(timestamps, fps: fps, tick: 1 / Double(timescale)) ? nil : "可变帧率 VFR（需恒定帧率）"
    }
}
