import Foundation

public enum ClipSelection: Equatable, Sendable {
    case video(String), audio(String), subtitle(String)
}

/// Transactional, non-ripple timeline operations. Intervals are [startFrame,endFrame).
/// Validation happens both before and after a copy is edited; a failure cannot change its input.
public enum TimelineEdits {
    private static func targets(_ p: EditorProject, _ selection: ClipSelection) throws -> ([Int],[Int],Int?) {
        switch selection {
        case .video(let id):
            guard let index=p.videoClips.firstIndex(where:{$0.id==id}) else { throw ProjectError.invalid("未找到选中视频") }
            guard let group=p.videoClips[index].linkGroupID else { return ([index],[],nil) }
            return (p.videoClips.indices.filter{p.videoClips[$0].linkGroupID==group},p.audioClips.indices.filter{p.audioClips[$0].linkGroupID==group},nil)
        case .audio(let id):
            guard let index=p.audioClips.firstIndex(where:{$0.id==id}) else { throw ProjectError.invalid("未找到选中音频") }
            guard let group=p.audioClips[index].linkGroupID else { return ([],[index],nil) }
            return (p.videoClips.indices.filter{p.videoClips[$0].linkGroupID==group},p.audioClips.indices.filter{p.audioClips[$0].linkGroupID==group},nil)
        case .subtitle(let id):
            guard let index=p.subtitles.firstIndex(where:{$0.id==id}) else { throw ProjectError.invalid("未找到选中字幕") }
            return ([],[],index)
        }
    }
    private static func interval(_ p: EditorProject, _ targets: ([Int],[Int],Int?)) -> (Int,Int) {
        if let i=targets.0.first { let c=p.videoClips[i];return (c.startFrame,c.startFrame+c.durationFrames) }
        if let i=targets.1.first { let c=p.audioClips[i];return (c.startFrame,c.startFrame+c.durationFrames) }
        let c=p.subtitles[targets.2!];return (c.startFrame,c.endFrame)
    }
    public static func split(_ project: EditorProject, selection: ClipSelection, atFrame: Int) throws -> EditorProject {
        try project.validate();let t=try targets(project,selection);let (start,end)=interval(project,t)
        guard atFrame>start && atFrame<end else { throw ProjectError.invalid("分割点须在片段内部") }
        var p=project;p.schemaVersion=2;let leftLength=atFrame-start,rightLength=end-atFrame
        let leftGroup=UUID().uuidString,rightGroup=UUID().uuidString
        for i in t.0 {
            var right=p.videoClips[i];right.id=UUID().uuidString;right.startFrame=atFrame;right.sourceStartFrame+=leftLength;right.durationFrames=rightLength
            p.videoClips[i].durationFrames=leftLength
            if right.linkGroupID != nil { p.videoClips[i].linkGroupID=leftGroup;right.linkGroupID=rightGroup }
            p.videoClips.append(right)
        }
        for i in t.1 {
            let old=p.audioClips[i]
            // Splitting inside an existing fade cannot be represented exactly by the current gain model.
            guard leftLength>=old.fadeInFrames && rightLength>=old.fadeOutFrames else { throw ProjectError.invalid("分割点位于淡入淡出内；请先移除淡入淡出") }
            var right=old;right.id=UUID().uuidString;right.startFrame=atFrame;right.sourceStartFrame+=leftLength;right.durationFrames=rightLength;right.fadeInFrames=0
            p.audioClips[i].durationFrames=leftLength;p.audioClips[i].fadeOutFrames=0
            if right.linkGroupID != nil { p.audioClips[i].linkGroupID=leftGroup;right.linkGroupID=rightGroup }
            p.audioClips.append(right)
        }
        if let i=t.2 { var right=p.subtitles[i];right.id=UUID().uuidString;right.startFrame=atFrame;p.subtitles[i].endFrame=atFrame;p.subtitles.append(right) }
        try p.validate();return p
    }
    /// Move linked picture/audio together. A supplied track changes only the selected clip's track.
    public static func move(_ project: EditorProject, selection: ClipSelection, toFrame: Int, track: Int?=nil) throws -> EditorProject {
        try project.validate();let t=try targets(project,selection);let (start,end)=interval(project,t);let duration=end-start
        guard toFrame>=0 && toFrame<=project.durationFrames && duration<=project.durationFrames-toFrame else { throw ProjectError.invalid("移动后片段超出工程边界") }
        var p=project;p.schemaVersion=2
        for i in t.0 { p.videoClips[i].startFrame=toFrame }
        for i in t.1 { p.audioClips[i].startFrame=toFrame }
        if let i=t.2 { p.subtitles[i].startFrame=toFrame;p.subtitles[i].endFrame=toFrame+duration }
        if let track {
            switch selection {
            case .video(let id):p.videoClips[p.videoClips.firstIndex{$0.id==id}!].track=track
            case .audio(let id):p.audioClips[p.audioClips.firstIndex{$0.id==id}!].track=track
            case .subtitle:guard track==0 else { throw ProjectError.invalid("仅支持一条字幕轨") }
            }
        }
        try p.validate();return p
    }
    /// Trim inward without rippling other clips; linked media source entries advance together.
    /// Existing fades stay attached to the new clip boundaries and are clamped to its duration.
    public static func trim(_ project: EditorProject, selection: ClipSelection, startFrame: Int, endFrame: Int) throws -> EditorProject {
        try project.validate();let t=try targets(project,selection);let (start,end)=interval(project,t)
        guard startFrame>=start && endFrame<=end && endFrame>startFrame else { throw ProjectError.invalid("裁剪范围须位于原片段内部且至少保留一帧") }
        let offset=startFrame-start,duration=endFrame-startFrame;var p=project;p.schemaVersion=2
        for i in t.0 { p.videoClips[i].startFrame=startFrame;p.videoClips[i].sourceStartFrame+=offset;p.videoClips[i].durationFrames=duration }
        for i in t.1 {
            p.audioClips[i].startFrame=startFrame;p.audioClips[i].sourceStartFrame+=offset;p.audioClips[i].durationFrames=duration
            p.audioClips[i].fadeInFrames=min(p.audioClips[i].fadeInFrames,duration)
            p.audioClips[i].fadeOutFrames=min(p.audioClips[i].fadeOutFrames,duration-p.audioClips[i].fadeInFrames)
        }
        if let i=t.2 { p.subtitles[i].startFrame=startFrame;p.subtitles[i].endFrame=endFrame }
        try p.validate();return p
    }
    public static func delete(_ project: EditorProject, selection: ClipSelection) throws -> EditorProject {
        try project.validate();let t=try targets(project,selection);var p=project;p.schemaVersion=2
        for i in t.0.sorted(by:>) { p.videoClips.remove(at:i) }
        for i in t.1.sorted(by:>) { p.audioClips.remove(at:i) }
        if let i=t.2 { p.subtitles.remove(at:i) }
        try p.validate();return p
    }
}

public struct EditHistory: Sendable {
    private struct Entry: Sendable { let before:EditorProject;let after:EditorProject;let label:String }
    private var past:[Entry]=[],future:[Entry]=[]
    public let limit:Int
    public init(limit:Int=100) { self.limit=max(1,min(100,limit)) }
    public var canUndo:Bool { !past.isEmpty }
    public var canRedo:Bool { !future.isEmpty }
    public var undoLabel:String? { past.last?.label }
    public var redoLabel:String? { future.last?.label }
    public var undoCount:Int { past.count }
    public var redoCount:Int { future.count }
    public mutating func record(before:EditorProject,after:EditorProject,label:String) {
        guard before != after else { return }
        var normalizedBefore=before,normalizedAfter=after;normalizedBefore.schemaVersion=2;normalizedAfter.schemaVersion=2
        past.append(Entry(before:normalizedBefore,after:normalizedAfter,label:label));if past.count>limit { past.removeFirst(past.count-limit) };future.removeAll()
    }
    public mutating func undo()->EditorProject? { guard let entry=past.popLast() else { return nil };future.append(entry);return entry.before }
    public mutating func redo()->EditorProject? { guard let entry=future.popLast() else { return nil };past.append(entry);return entry.after }
    public mutating func reset() { past.removeAll();future.removeAll() }
}
