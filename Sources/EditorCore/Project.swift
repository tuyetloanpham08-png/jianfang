import Foundation

public enum AssetKind: String, Codable, Sendable { case video, image, audio }
public struct MediaAsset: Codable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var kind: AssetKind
    /// SHA-256 of source bytes, recorded for safe relinking; absent in legacy schema 1 projects.
    public var fingerprint: String?
    /// File size and modification time (seconds since 2001) observed when `fingerprint` was last
    /// computed. Opening trusts an unchanged stamp instead of rereading the whole file; export
    /// and collection always recompute the full SHA-256. Absent in older projects.
    public var byteSize: Int64?
    public var modifiedAt: Double?
    public init(id: String, path: String, kind: AssetKind, fingerprint: String?=nil) { self.id=id; self.path=path; self.kind=kind; self.fingerprint=fingerprint }
}
/// Normalized top-left coordinates in the project canvas. Media is aspect-fitted inside this rectangle.
public struct FrameRect: Codable, Equatable, Sendable {
    public var x: Double = 0; public var y: Double = 0
    public var width: Double = 1; public var height: Double = 1
    public init(x: Double=0, y: Double=0, width: Double=1, height: Double=1) { self.x=x; self.y=y; self.width=width; self.height=height }
}
public struct VideoClip: Codable, Equatable, Sendable {
    public var id: String; public var assetID: String; public var track: Int
    public var startFrame: Int; public var sourceStartFrame: Int; public var durationFrames: Int
    public var rect: FrameRect; public var opacity: Double; public var rotationDegrees: Int
    public var linkGroupID: String?
    public init(id: String=UUID().uuidString, assetID: String, track: Int=0, startFrame: Int, sourceStartFrame: Int=0, durationFrames: Int, rect: FrameRect=FrameRect(), opacity: Double=1, rotationDegrees: Int=0, linkGroupID: String?=nil) {
        self.id=id; self.assetID=assetID; self.track=track; self.startFrame=startFrame; self.sourceStartFrame=sourceStartFrame; self.durationFrames=durationFrames; self.rect=rect; self.opacity=opacity; self.rotationDegrees=rotationDegrees; self.linkGroupID=linkGroupID
    }
}
public struct AudioClip: Codable, Equatable, Sendable {
    public var id: String; public var assetID: String; public var track: Int
    public var startFrame: Int; public var sourceStartFrame: Int; public var durationFrames: Int
    public var gain: Double; public var fadeInFrames: Int; public var fadeOutFrames: Int
    public var linkGroupID: String?
    public init(id: String=UUID().uuidString, assetID: String, track: Int=0, startFrame: Int, sourceStartFrame: Int=0, durationFrames: Int, gain: Double=1, fadeInFrames: Int=0, fadeOutFrames: Int=0, linkGroupID: String?=nil) {
        self.id=id; self.assetID=assetID; self.track=track; self.startFrame=startFrame; self.sourceStartFrame=sourceStartFrame; self.durationFrames=durationFrames; self.gain=gain; self.fadeInFrames=fadeInFrames; self.fadeOutFrames=fadeOutFrames; self.linkGroupID=linkGroupID
    }
}
public struct SubtitleCue: Codable, Equatable, Sendable {
    public var id: String; public var startFrame: Int; public var endFrame: Int; public var text: String
    public var fontSize: Double; public var colorHex: String
    /// Subtitle block center, normalized from the top. nil preserves legacy placement.
    public var positionY: Double?
    public init(id: String=UUID().uuidString, startFrame: Int, endFrame: Int, text: String, fontSize: Double=48, colorHex: String="#FFFFFF", positionY: Double?=nil) {
        self.id=id; self.startFrame=startFrame; self.endFrame=endFrame; self.text=text; self.fontSize=fontSize; self.colorHex=colorHex; self.positionY=positionY
    }
    /// Whitespace-only text. Not a project validation error, so older projects still open; the
    /// editor refuses to commit it, the renderer draws nothing for it and SRT export names it.
    public var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
public struct EditorProject: Codable, Equatable, Sendable {
    /// Version 2 prevents M1 readers from silently discarding editing and safety metadata.
    public var schemaVersion: Int = 2
    public var name: String; public var width: Int; public var height: Int; public var fps: Int; public var durationFrames: Int
    public var mutedAudioTracks: [Int]?
    public var hiddenVideoTracks: [Int]?
    public var assets: [MediaAsset]; public var videoClips: [VideoClip]; public var audioClips: [AudioClip]; public var subtitles: [SubtitleCue]
    public init(name: String="独立剪辑原型", width: Int=1920, height: Int=1080, fps: Int=30, durationFrames: Int=1800, assets: [MediaAsset]=[], videoClips: [VideoClip]=[], audioClips: [AudioClip]=[], subtitles: [SubtitleCue]=[], mutedAudioTracks: [Int]?=nil, hiddenVideoTracks: [Int]?=nil) {
        self.name=name; self.width=width; self.height=height; self.fps=fps; self.durationFrames=durationFrames; self.assets=assets; self.videoClips=videoClips; self.audioClips=audioClips; self.subtitles=subtitles; self.mutedAudioTracks=mutedAudioTracks; self.hiddenVideoTracks=hiddenVideoTracks
    }
    public func assetURL(_ id: String, baseURL: URL) throws -> URL {
        guard let asset=assets.first(where: {$0.id==id}) else { throw ProjectError.invalid("找不到素材：\(id)") }
        if asset.path.hasPrefix("/") { return URL(fileURLWithPath: asset.path) }
        return baseURL.appendingPathComponent(asset.path).standardizedFileURL
    }
    /// Assets used by clips whose files cannot be read now (unplugged drive, moved file). Edits of
    /// such a project are committed on project validation alone; preview waits and export stays strict.
    public func offlineAssetIDs(baseURL: URL) -> [String] {
        let used = Set(videoClips.map(\.assetID) + audioClips.map(\.assetID))
        return assets.filter { asset in
            used.contains(asset.id) && !((try? assetURL(asset.id, baseURL: baseURL)).map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false)
        }.map(\.id)
    }
}
public enum ProjectError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let s): return s } }
}
