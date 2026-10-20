import Foundation
import CryptoKit

public enum ProjectStore {
    public static func load(_ url: URL) throws -> EditorProject {
        let name = url.lastPathComponent, data: Data
        do { data = try Data(contentsOf: url) } catch { throw ProjectError.invalid("无法读取工程文件：\(name)。请确认文件存在且有读取权限") }
        var p: EditorProject
        // JSONDecoder's own messages are English and name internal types; report the field instead.
        do { p = try JSONDecoder().decode(EditorProject.self, from: data) }
        catch DecodingError.keyNotFound(let key, _) { throw ProjectError.invalid("工程文件缺少字段“\(key.stringValue)”：\(name)。文件可能损坏或不是本 App 的工程；可改用备份，或用“恢复自动保存”") }
        catch DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context) {
            throw ProjectError.invalid("工程文件字段“\(context.codingPath.map(\.stringValue).joined(separator: "."))”的值类型不对：\(name)。文件可能被手工改坏；可改用备份，或用“恢复自动保存”")
        }
        catch { throw ProjectError.invalid("工程文件不是有效的 JSON：\(name)。文件可能损坏、被截断或不是本 App 的工程；可改用备份，或用“恢复自动保存”") }
        try p.validate()
        p.schemaVersion=2 // In-memory upgrade only; opening never modifies the source file.
        return p
    }
    public static func encoded(_ p: EditorProject) throws -> Data {
        try p.validate()
        var current=p;current.schemaVersion=2
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(current)
    }
    public static func semanticHash(_ p: EditorProject, baseURL: URL) throws -> String {
        try p.validate()
        var normalized=p;normalized.schemaVersion=2
        normalized.assets = try p.assets.map { asset in
            // File stamps are a cache for opening, not project semantics.
            var a=asset; a.path=try p.assetURL(asset.id,baseURL:baseURL).path; a.byteSize=nil; a.modifiedAt=nil; return a
        }
        return SHA256.hash(data:try encoded(normalized)).map { String(format:"%02x",$0) }.joined()
    }
    /// Rebase references when saving elsewhere; never copies or overwrites source media.
    /// Media inside the destination folder is written relative, so a collected package stays
    /// movable after open/edit/save; media elsewhere is written as an absolute path.
    @discardableResult public static func save(_ p: EditorProject, from baseURL: URL, to url: URL) throws -> EditorProject {
        try p.validate()
        var rebased=p;rebased.schemaVersion=2
        let folder=url.deletingLastPathComponent().standardizedFileURL.path
        // Compare normalized paths: URL equality treats ".../pkg" and ".../pkg/" as different.
        let sameFolder=folder==baseURL.standardizedFileURL.path
        rebased.assets = try p.assets.map { asset in
            var a=asset
            if sameFolder && !asset.path.hasPrefix("/") { return a }
            let absolute=try p.assetURL(asset.id,baseURL:baseURL).standardizedFileURL.path
            a.path=absolute.hasPrefix(folder+"/") ? String(absolute.dropFirst(folder.count+1)) : absolute
            return a
        }
        try encoded(rebased).write(to:url,options:.atomic)
        return rebased
    }
}

extension EditorProject {
    public func validate() throws {
        func require(_ condition: Bool,_ message: String) throws { if !condition { throw ProjectError.invalid(message) } }
        try require(schemaVersion==1 || schemaVersion==2,"不支持工程版本 \(schemaVersion)，当前版本只读取工程1和2")
        try require(fps==30,"M1原型项目帧率固定30fps")
        try require((width==1920 && height==1080)||(width==1080 && height==1920),"M1原型支持1920×1080或1080×1920")
        try require(durationFrames>0 && durationFrames<=18000,"工程时长须在1帧至10分钟以内")
        try require(Set(assets.map(\.id)).count==assets.count,"素材ID重复")
        try require(Set(videoClips.map(\.id)).count==videoClips.count,"视频片段ID重复")
        try require(Set(audioClips.map(\.id)).count==audioClips.count,"音频片段ID重复")
        try require(Set(subtitles.map(\.id)).count==subtitles.count,"字幕ID重复")
        if let tracks=mutedAudioTracks { try require(Set(tracks).count==tracks.count && tracks.allSatisfy{(0...3).contains($0)},"静音轨道编号无效或重复") }
        if let tracks=hiddenVideoTracks { try require(Set(tracks).count==tracks.count && tracks.allSatisfy{(0...1).contains($0)},"隐藏轨道编号无效或重复") }
        let ids=Set(assets.map(\.id))
        for a in assets {
            try require(!a.path.isEmpty && !a.path.contains("://"),"仅支持本地文件：\(a.path)")
            if let fingerprint=a.fingerprint { try require(fingerprint.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,"素材指纹须为 SHA-256") }
        }
        for c in videoClips {
            try require(ids.contains(c.assetID),"视频引用不存在的素材 \(c.assetID)")
            try require((0...1).contains(c.track),"仅支持两条视频轨")
            try require(c.startFrame>=0 && c.startFrame<=durationFrames && c.sourceStartFrame>=0 && c.durationFrames>0 && c.durationFrames<=durationFrames-c.startFrame,"视频片段越界：\(c.id)")
            try require(c.sourceStartFrame<=Int.max-c.durationFrames,"视频素材入点溢出")
            try require(c.opacity.isFinite && (0...1).contains(c.opacity),"透明度须为0至1")
            try require([c.rect.x,c.rect.y,c.rect.width,c.rect.height].allSatisfy(\.isFinite) && c.rect.width>0 && c.rect.height>0,"画面矩形无效")
            try require(c.rotationDegrees%90==0,"原型旋转角度须为90度倍数")
        }
        for c in audioClips {
            try require(ids.contains(c.assetID),"音频引用不存在的素材 \(c.assetID)")
            try require((0...3).contains(c.track),"仅支持四条音频轨")
            try require(c.startFrame>=0 && c.startFrame<=durationFrames && c.sourceStartFrame>=0 && c.durationFrames>0 && c.durationFrames<=durationFrames-c.startFrame,"音频片段越界：\(c.id)")
            try require(c.sourceStartFrame<=Int.max-c.durationFrames,"音频素材入点溢出")
            try require(c.gain.isFinite && c.gain>=0 && c.gain<=4,"音量须为0至4")
            try require(c.fadeInFrames>=0 && c.fadeOutFrames>=0 && c.fadeOutFrames<=c.durationFrames && c.fadeInFrames<=c.durationFrames-c.fadeOutFrames,"淡入淡出范围无效")
        }
        // Link groups represent one original picture/audio pair, never arbitrary user grouping.
        let groups=Set(videoClips.compactMap(\.linkGroupID)+audioClips.compactMap(\.linkGroupID))
        for group in groups {
            try require(!group.isEmpty,"联动组 ID 不能为空")
            let videos=videoClips.filter{$0.linkGroupID==group},audios=audioClips.filter{$0.linkGroupID==group}
            try require(videos.count==1 && audios.count==1,"每个联动组必须恰有一个视频和一个原声音频")
            let v=videos[0],a=audios[0]
            try require(v.assetID==a.assetID && assets.first(where:{$0.id==v.assetID})?.kind == .video,"联动画面和原声必须引用同一个视频素材")
            try require(v.startFrame==a.startFrame && v.durationFrames==a.durationFrames && v.sourceStartFrame==a.sourceStartFrame,"联动画面和原声时间不一致")
        }
        func validateIntervals(_ rows: [(Int,Int,Int)],_ kind: String) throws {
            for track in Set(rows.map{$0.0}) {
                let sorted=rows.filter{$0.0==track}.sorted{$0.1<$1.1}
                for pair in zip(sorted,sorted.dropFirst()) { try require(pair.0.2<=pair.1.1,"\(kind)同轨片段重叠") }
            }
        }
        try validateIntervals(videoClips.map{($0.track,$0.startFrame,$0.startFrame+$0.durationFrames)},"视频")
        try validateIntervals(audioClips.map{($0.track,$0.startFrame,$0.startFrame+$0.durationFrames)},"音频")
        for c in subtitles {
            try require(c.startFrame>=0 && c.endFrame>c.startFrame && c.endFrame<=durationFrames,"字幕时间越界")
            if let y=c.positionY { try require(y.isFinite && (0.1...0.9).contains(y),"字幕位置须为0.1至0.9") }
            try require(c.fontSize.isFinite && c.fontSize>=12 && c.fontSize<=160,"字幕字号须为12至160")
            try require(c.text.split(separator:"\n",omittingEmptySubsequences:false).count<=2,"M1字幕最多两行")
            try require(c.colorHex.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil,"字幕颜色须为#RRGGBB")
        }
        try validateIntervals(subtitles.map{(0,$0.startFrame,$0.endFrame)},"字幕")
    }
}
