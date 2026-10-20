import Foundation

/// Where newly imported media lands. Lengths come from each probed track's own
/// time range (integer frame math), never from the container's longest track.
public enum ImportPlacement {
    public static let maximumFrames = 18000

    private static func v1End(_ p: EditorProject) -> Int {
        p.videoClips.filter { $0.track == 0 }.map { $0.startFrame + $0.durationFrames }.max() ?? 0
    }
    private static func freeAudioTrack(_ p: EditorProject, order: [Int], start: Int, frames: Int) -> Int? {
        order.first { t in !p.audioClips.contains { $0.track == t && $0.startFrame < start + frames && start < $0.startFrame + $0.durationFrames } }
    }
    private static func requireLength(_ frames: Int) throws {
        guard frames > 0 else { throw ProjectError.invalid("素材不足一帧") }
        guard frames <= maximumFrames else { throw ProjectError.invalid("单个素材须在10分钟以内") }
    }

    /// Appends a video to the end of V1. When the original audio is usable, picture
    /// and audio are linked over the overlap of both tracks; `note` reports a cut
    /// longer than one frame.
    public static func appendVideo(_ project: EditorProject, assetID: String, path: String, fingerprint: String?,
                                   video: Range<Int>, audio: Range<Int>?) throws -> (project: EditorProject, note: String?) {
        guard let linked = FrameMath.linkedRange(video: video, audio: audio) else { throw ProjectError.invalid("画面与原声没有重叠的时间段") }
        try requireLength(linked.durationFrames)
        var p = project; p.schemaVersion = 2
        let start = v1End(p), frames = linked.durationFrames
        p.assets.append(MediaAsset(id: assetID, path: path, kind: .video, fingerprint: fingerprint))
        let group = audio == nil ? nil : UUID().uuidString
        p.videoClips.append(VideoClip(assetID: assetID, startFrame: start, sourceStartFrame: linked.sourceStartFrame, durationFrames: frames, linkGroupID: group))
        if audio != nil {
            guard let track = freeAudioTrack(p, order: [0, 1, 2, 3], start: start, frames: frames) else { throw ProjectError.invalid("视频原声没有空闲音轨，请移动现有音频后再导入") }
            p.audioClips.append(AudioClip(assetID: assetID, track: track, startFrame: start, sourceStartFrame: linked.sourceStartFrame, durationFrames: frames, linkGroupID: group))
        }
        p.durationFrames = max(p.durationFrames, start + frames)
        try p.validate()
        var note: String?
        if let audio, linked.mismatchFrames > 1 {
            let audioShorter = audio.count < video.count
            note = "\(audioShorter ? "原声比画面短" : "画面比原声短") \(linked.mismatchFrames) 帧，已按较短者截齐"
        }
        return (p, note)
    }

    /// Independent audio at the playhead; music prefers A2–A4, then A1.
    public static func appendAudio(_ project: EditorProject, assetID: String, path: String, fingerprint: String?,
                                   audio: Range<Int>, at start: Int) throws -> EditorProject {
        let frames = audio.count
        try requireLength(frames)
        var p = project; p.schemaVersion = 2
        guard let track = freeAudioTrack(p, order: [1, 2, 3, 0], start: start, frames: frames) else { throw ProjectError.invalid("播放头之后没有空闲音轨，请移动现有片段") }
        p.assets.append(MediaAsset(id: assetID, path: path, kind: .audio, fingerprint: fingerprint))
        p.audioClips.append(AudioClip(assetID: assetID, track: track, startFrame: start, sourceStartFrame: audio.lowerBound, durationFrames: frames, gain: 0.5))
        p.durationFrames = max(p.durationFrames, start + frames)
        try p.validate()
        return p
    }

    /// Still images default to five seconds at the end of V1.
    public static func appendImage(_ project: EditorProject, assetID: String, path: String, fingerprint: String?, frames: Int = 150) throws -> EditorProject {
        var p = project; p.schemaVersion = 2
        let start = v1End(p)
        p.assets.append(MediaAsset(id: assetID, path: path, kind: .image, fingerprint: fingerprint))
        p.videoClips.append(VideoClip(assetID: assetID, startFrame: start, durationFrames: frames))
        p.durationFrames = max(p.durationFrames, start + frames)
        try p.validate()
        return p
    }
}
