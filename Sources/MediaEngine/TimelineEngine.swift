import AVFoundation
import CoreImage
import ImageIO
import Foundation
import EditorCore

public struct CompiledTimeline: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix
    public let duration: CMTime
}
public enum MediaEngineError: Error, LocalizedError {
    case invalid(String)
    case render(String)
    public var errorDescription: String? {
        switch self { case .invalid(let s), .render(let s): return s }
    }
    /// Raw system errors (often English, e.g. "Cannot Open") are replaced at the engine boundary by
    /// a Chinese message naming the file and the next step; only the system code is kept for support.
    /// Our own errors and cancellation pass through unchanged.
    public static func describing(_ error: Error, _ message: String) -> Error {
        if error is MediaEngineError || error is ProjectError || error is CancellationError { return error }
        let ns = error as NSError
        return MediaEngineError.render("\(message)（系统代码 \(ns.domain) \(ns.code)）")
    }
}

public enum TimelineEngine {
    public static func compile(project: EditorProject, baseURL: URL) async throws -> CompiledTimeline {
        try project.validate()
        let composition = AVMutableComposition()
        let duration = CMTime(value: Int64(project.durationFrames), timescale: Int32(project.fps))
        let canvas = CGRect(x: 0, y: 0, width: project.width, height: project.height)
        let assets = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
        var loadedAssets: [String: AVURLAsset] = [:]
        var sourceVideos: [String: AVAssetTrack] = [:]
        var sourceAudios: [String: AVAssetTrack] = [:]
        var stills: [String: CIImage] = [:]
        var orientations: [String: CGAffineTransform] = [:]
        var names: [String: String] = [:]
        var sampleOffsets: [String: CMTime] = [:]
        let usedIDs = Set(project.videoClips.map(\.assetID) + project.audioClips.map(\.assetID))
        for id in usedIDs {
            try Task.checkCancellation()
            guard let model = assets[id] else { throw MediaEngineError.invalid("素材不存在：\(id)") }
            let url = try project.assetURL(id, baseURL: baseURL)
            names[id] = url.lastPathComponent
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw MediaEngineError.invalid("无法读取素材：\(url.lastPathComponent)") }
            if model.kind == .image {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else {
                    throw MediaEngineError.invalid("图片解码失败：\(url.lastPathComponent)")
                }
                // An embedded ICC profile (Display P3, Adobe RGB, sRGB…) is honoured and Core Image
                // converts it to the working space; untagged RGB is explicitly read as sRGB.
                // CMYK/Lab/indexed-without-expansion are rejected instead of being guessed.
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                guard let space = image.colorSpace, [.rgb, .monochrome].contains(space.model) else {
                    throw MediaEngineError.invalid("图片色彩空间不支持（只接受 RGB/灰度；CMYK 等请先转换为 sRGB）：\(url.lastPathComponent)")
                }
                let tagged = properties?[kCGImagePropertyProfileName] != nil
                var still = tagged || space.model == .monochrome ? CIImage(cgImage: image) : CIImage(cgImage: image, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
                if let orientation = properties?[kCGImagePropertyOrientation] as? Int32 {
                    still = still.oriented(forExifOrientation: orientation)
                }
                stills[id] = still
                continue
            }
            let asset = AVURLAsset(url: url)
            loadedAssets[id] = asset
            let unreadable = "无法打开素材，文件可能损坏或不是支持的音视频格式：\(url.lastPathComponent)。请换用完好的文件，或生成符合项目说明支持范围的兼容副本"
            if project.videoClips.contains(where: { $0.assetID == id }) {
                let loaded: AVAssetTrack?
                do { loaded = try await asset.loadTracks(withMediaType: .video).first } catch { throw MediaEngineError.describing(error, unreadable) }
                guard let track = loaded else { throw MediaEngineError.invalid("素材不包含视频：\(url.lastPathComponent)") }
                let issues: [String]
                do { issues = try await videoProblems(track, asset: asset) } catch { throw MediaEngineError.describing(error, unreadable) }
                guard issues.isEmpty else { throw MediaEngineError.invalid(unsupportedMessage(issues, name: url.lastPathComponent)) }
                sourceVideos[id] = track
                let timescale = try await track.load(.naturalTimeScale)
                let sourceFPS = Int(Double(try await track.load(.nominalFrameRate)).rounded())
                sampleOffsets[id] = CMTime(value: FrameMath.roundedTimestampGuardTicks(timescale: timescale, fps: sourceFPS), timescale: timescale)
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let extent = CGRect(origin: .zero, size: size).applying(transform)
                // AVFoundation's transform is top-left based; Core Image is bottom-left.
                orientations[id] = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
                    .concatenating(transform)
                    .concatenating(CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                    .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: extent.height))
            }
            if project.audioClips.contains(where: { $0.assetID == id }) {
                let loaded: AVAssetTrack?
                do { loaded = try await asset.loadTracks(withMediaType: .audio).first } catch { throw MediaEngineError.describing(error, unreadable) }
                guard let track = loaded else { throw MediaEngineError.invalid("素材不包含音频：\(url.lastPathComponent)") }
                let issues: [String]
                do { issues = try await audioProblems(track) } catch { throw MediaEngineError.describing(error, unreadable) }
                guard issues.isEmpty else { throw MediaEngineError.invalid(unsupportedMessage(issues, name: url.lastPathComponent)) }
                sourceAudios[id] = track
            }
        }

        let carrierURL = try await CarrierCache.shared.url()
        let carrierAsset = AVURLAsset(url: carrierURL)
        guard let carrierSource = try await carrierAsset.loadTracks(withMediaType: .video).first,
              let carrier = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaEngineError.render("无法创建内部时间线")
        }
        let silenceAsset = AVURLAsset(url: try await CarrierCache.shared.silenceURL())
        guard let silenceSource = try await silenceAsset.loadTracks(withMediaType: .audio).first,
              let silentTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaEngineError.render("无法创建静音音床")
        }
        let oneSecond = CMTime(value: 1, timescale: 1)
        var cursor = CMTime.zero
        while CMTimeCompare(cursor, duration) < 0 {
            let segmentDuration = CMTimeMinimum(oneSecond, CMTimeSubtract(duration, cursor))
            try carrier.insertTimeRange(CMTimeRange(start: .zero, duration: segmentDuration), of: carrierSource, at: cursor)
            try silentTrack.insertTimeRange(CMTimeRange(start: .zero, duration: segmentDuration), of: silenceSource, at: cursor)
            cursor = CMTimeAdd(cursor, segmentDuration)
        }
        var videoTracks: [Int: AVMutableCompositionTrack] = [:]
        for index in 0..<2 where project.videoClips.contains(where: { $0.track == index && assets[$0.assetID]?.kind == .video }) {
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MediaEngineError.render("无法创建视频轨") }
            videoTracks[index] = track
        }
        var layers: [RenderLayer] = []
        for clip in project.videoClips.filter({ !(project.hiddenVideoTracks ?? []).contains($0.track) }).sorted(by: { $0.track == $1.track ? $0.startFrame < $1.startFrame : $0.track < $1.track }) {
            let start = time(clip.startFrame, fps: project.fps)
            let range = CMTimeRange(start: time(clip.sourceStartFrame, fps: project.fps), duration: time(clip.durationFrames, fps: project.fps))
            if let still = stills[clip.assetID] {
                layers.append(RenderLayer(clip: clip, sourceTrackID: nil, image: still, preferredTransform: .identity))
            } else {
                guard let source = sourceVideos[clip.assetID], let target = videoTracks[clip.track] else { throw MediaEngineError.invalid("视频素材和轨道不匹配") }
                let available = try await checkSourceRange(range, track: source, name: names[clip.assetID] ?? clip.assetID)
                // Rounded-timebase sources are sampled one tick late (see FrameMath); the tail
                // is clamped to the track end and lies after the clip's last frame instant.
                var sampled = CMTimeRange(start: CMTimeAdd(range.start, sampleOffsets[clip.assetID] ?? .zero), duration: range.duration)
                if CMTimeCompare(CMTimeRangeGetEnd(sampled), CMTimeRangeGetEnd(available)) > 0 { sampled.duration = CMTimeSubtract(CMTimeRangeGetEnd(available), sampled.start) }
                try target.insertTimeRange(sampled, of: source, at: start)
                layers.append(RenderLayer(clip: clip, sourceTrackID: target.trackID, image: nil, preferredTransform: orientations[clip.assetID] ?? .identity))
            }
        }
        let mix = AVMutableAudioMix()
        let silenceParameters = AVMutableAudioMixInputParameters(track: silentTrack)
        silenceParameters.setVolume(0, at: .zero)
        var mixParameters: [AVAudioMixInputParameters] = [silenceParameters]
        for index in 0..<4 {
            let clips = project.audioClips.filter { $0.track == index && !(project.mutedAudioTracks ?? []).contains(index) }.sorted { $0.startFrame < $1.startFrame }
            guard !clips.isEmpty else { continue }
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MediaEngineError.render("无法创建音轨") }
            let parameters = AVMutableAudioMixInputParameters(track: target)
            for clip in clips {
                guard let source = sourceAudios[clip.assetID] else { throw MediaEngineError.invalid("音频素材和轨道不匹配") }
                let start = time(clip.startFrame, fps: project.fps)
                let end = time(clip.startFrame + clip.durationFrames, fps: project.fps)
                let range = CMTimeRange(start: time(clip.sourceStartFrame, fps: project.fps), duration: time(clip.durationFrames, fps: project.fps))
                try await checkSourceRange(range, track: source, name: names[clip.assetID] ?? clip.assetID)
                try target.insertTimeRange(range, of: source, at: start)
                // Define every occupied interval explicitly. setVolume(0, at:end)
                // can turn the final segment into an unintended interpolation on
                // AVAudioMix; gaps already contain no source samples and need no
                // closing volume event.
                let holdStart = CMTimeAdd(start, time(clip.fadeInFrames, fps: project.fps))
                let holdEnd = CMTimeSubtract(end, time(clip.fadeOutFrames, fps: project.fps))
                if clip.fadeInFrames > 0 {
                    parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: Float(clip.gain), timeRange: CMTimeRange(start: start, duration: time(clip.fadeInFrames, fps: project.fps)))
                }
                if CMTimeCompare(holdEnd, holdStart) > 0 {
                    parameters.setVolumeRamp(fromStartVolume: Float(clip.gain), toEndVolume: Float(clip.gain),
                                             timeRange: CMTimeRange(start: holdStart, end: holdEnd))
                }
                if clip.fadeOutFrames > 0 {
                    parameters.setVolumeRamp(fromStartVolume: Float(clip.gain), toEndVolume: 0,
                                             timeRange: CMTimeRange(start: holdEnd, end: end))
                }
            }
            mixParameters.append(parameters)
        }
        mix.inputParameters = mixParameters
        // A blank cue would burn an empty translucent box; it is drawn as nothing.
        let subtitles = try project.subtitles.filter { !$0.isBlank }.map { cue in
            RenderSubtitle(startFrame: cue.startFrame, endFrame: cue.endFrame, image: try SubtitleRasterizer.image(cue, canvas: canvas.size))
        }
        let instruction = TimelineInstruction(duration: duration, canvas: canvas, fps: project.fps,
                                              tracks: [carrier.trackID] + videoTracks.values.map(\.trackID), layers: layers, subtitles: subtitles)
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = TimelineCompositor.self
        video.renderSize = canvas.size
        video.frameDuration = time(1, fps: project.fps)
        video.instructions = [instruction]
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return CompiledTimeline(composition: composition, videoComposition: video, audioMix: mix, duration: duration)
    }

    private static func time(_ frames: Int, fps: Int) -> CMTime { CMTime(value: Int64(frames), timescale: Int32(fps)) }
    @discardableResult private static func checkSourceRange(_ range: CMTimeRange, track: AVAssetTrack, name: String) async throws -> CMTimeRange {
        let available = try await track.load(.timeRange)
        guard CMTimeCompare(range.start, available.start) >= 0,
              CMTimeCompare(CMTimeRangeGetEnd(range), CMTimeRangeGetEnd(available)) <= 0 else {
            throw MediaEngineError.invalid("素材入点或长度超出源文件：\(name)")
        }
        return available
    }
}
