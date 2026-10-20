import Foundation
import CoreGraphics
import ImageIO
import AVFoundation
import EditorCore
import MediaEngine
import Synchronization

extension EditorProject {
    /// Same project with only the fingerprints copied over (no stamps), for semantic-hash comparison.
    func withFingerprints(from other:EditorProject)->EditorProject {
        var p=self;for i in p.assets.indices{p.assets[i].fingerprint=other.assets.first{$0.id==p.assets[i].id}?.fingerprint};return p
    }
}

@main struct CoreChecks {
    struct Failure:Error,CustomStringConvertible {let message:String;var description:String{message}}
    static func expect(_ condition:Bool,_ message:String)throws {if !condition{throw Failure(message:message)}}
    static func expectValue<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(message:message)};return value}
    static func rejects(_ body:()throws->Void)throws {var rejected=false;do{try body()}catch{rejected=true};try expect(rejected,"Expected validation failure")}
    static func project()->EditorProject {EditorProject(assets:[MediaAsset(id:"v",path:"media/v.mp4",kind:.video)],videoClips:[VideoClip(id:"c",assetID:"v",startFrame:0,durationFrames:30)])}
    /// Project root, for the sample projects and self-contained synthetic regression inputs.
    static let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func media(_ relative:String)throws->URL{let u=root.appendingPathComponent(relative);try expect(FileManager.default.fileExists(atPath:u.path),"缺少测试素材 \(relative)；请先运行 python3 scripts/generate_fixtures.py 和 python3 scripts/make_step7_fixtures.py");return u}
    static func main()async throws {
        var passed=0
        func check(_ name:String,_ block:()throws->Void)throws{try block();passed+=1;print("PASS \(name)")}
        func checkAsync(_ name:String,_ block:()async throws->Void)async throws{try await block();passed+=1;print("PASS \(name)")}
        try check("atomic save/reopen rebases references and preserves canonical semantics"){
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let original=root.appendingPathComponent("original"),moved=root.appendingPathComponent("moved")
            try FileManager.default.createDirectory(at:original,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:moved,withIntermediateDirectories:true)
            defer{try? FileManager.default.removeItem(at:root)}
            let p=project(),u=moved.appendingPathComponent("project.json")
            _=try ProjectStore.save(p,from:original,to:u)
            let read=try ProjectStore.load(u)
            try expect(p.assetURL("v",baseURL:original)==read.assetURL("v",baseURL:moved),"Reference changed")
            try expect(ProjectStore.semanticHash(p,baseURL:original)==ProjectStore.semanticHash(read,baseURL:moved),"Semantics changed")
        }
        try check("adjacent half-open intervals accepted; overlap rejected"){
            var p=project();p.videoClips.append(VideoClip(id:"b",assetID:"v",startFrame:30,durationFrames:30));try p.validate()
            p.videoClips[1].startFrame=29;try rejects{try p.validate()}
        }
        try check("unsupported schema rejected"){var p=project();p.schemaVersion=99;try rejects{try p.validate()}}
        try check("subtitle conflict and out-of-bounds rejected"){
            var p=project();p.subtitles=[SubtitleCue(startFrame:0,endFrame:31,text:"你好"),SubtitleCue(startFrame:30,endFrame:60,text:"world")];try rejects{try p.validate()}
            p.subtitles=[SubtitleCue(startFrame:1799,endFrame:1801,text:"结束")];try rejects{try p.validate()}
        }
        try check("remote source and excess track rejected"){
            var p=project();p.assets[0].path="https://example.com/v.mp4";try rejects{try p.validate()}
            p=project();p.videoClips[0].track=2;try rejects{try p.validate()}
        }
        try check("invalid save does not replace an existing valid project"){
            let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
            defer{try? FileManager.default.removeItem(at:url)}
            let base=url.deletingLastPathComponent();_=try ProjectStore.save(project(),from:base,to:url);let before=try Data(contentsOf:url)
            var invalid=project();invalid.durationFrames = -1;try rejects{_=try ProjectStore.save(invalid,from:base,to:url)}
            try expect(Data(contentsOf:url)==before,"Existing file changed")
        }
        try check("corrupt extreme frame values reject without integer overflow"){
            var p=project();p.videoClips[0].startFrame=Int.max;p.videoClips[0].durationFrames=Int.max;try rejects{try p.validate()}
            p=project();p.audioClips=[AudioClip(assetID:"v",startFrame:0,durationFrames:30,fadeInFrames:Int.max,fadeOutFrames:Int.max)];try rejects{try p.validate()}
        }
        try check("100 edits undo and redo restore every complete snapshot; branch drops redo"){
            var history=EditHistory(),p=project();var states=[p]
            for n in 1...100 { let before=p;p.name="Edit \(n)";history.record(before:before,after:p,label:"rename");states.append(p) }
            try expect(history.undoCount==100,"History did not retain 100 edits")
            for n in stride(from:99,through:0,by:-1) { try expect(history.undo()==states[n],"Undo mismatch at \(n)") }
            try expect(history.undo()==nil && !history.canUndo,"Undo exceeded beginning")
            for n in 1...100 { try expect(history.redo()==states[n],"Redo mismatch at \(n)") }
            try expect(history.redo()==nil && !history.canRedo,"Redo exceeded end")
            p=history.undo()!;var branch=p;branch.name="branch";history.record(before:p,after:branch,label:"branch")
            try expect(!history.canRedo,"New edit kept stale future")
            for n in 0..<20 { var next=branch;next.name="extra\(n)";history.record(before:branch,after:next,label:"extra");branch=next }
            try expect(history.undoCount==100,"History cap not enforced")
        }
        try check("linked picture and original audio split trim move delete together"){
            var p=project();p.videoClips[0].durationFrames=120;p.videoClips[0].sourceStartFrame=9;p.videoClips[0].linkGroupID="source"
            p.audioClips=[AudioClip(id:"sound",assetID:"v",startFrame:0,sourceStartFrame:9,durationFrames:120,linkGroupID:"source")]
            p=try TimelineEdits.split(p,selection:.video("c"),atFrame:60)
            try expect(p.videoClips.count==2 && p.audioClips.count==2,"Linked split missed media")
            try expect(p.videoClips[0].linkGroupID==p.audioClips[0].linkGroupID && p.videoClips[1].linkGroupID==p.audioClips[1].linkGroupID && p.videoClips[0].linkGroupID != p.videoClips[1].linkGroupID,"Split groups not independent")
            try expect(p.videoClips[1].sourceStartFrame==69 && p.audioClips[1].sourceStartFrame==69,"Split changed source entry")
            p=try TimelineEdits.trim(p,selection:.audio("sound"),startFrame:10,endFrame:50)
            try expect(p.videoClips[0].sourceStartFrame==19 && p.audioClips[0].sourceStartFrame==19 && p.videoClips[0].durationFrames==40,"Linked trim mismatch")
            p=try TimelineEdits.move(p,selection:.audio("sound"),toFrame:200,track:2)
            try expect(p.videoClips[0].startFrame==200 && p.audioClips[0].startFrame==200 && p.audioClips[0].track==2,"Linked move mismatch")
            p=try TimelineEdits.delete(p,selection:.video("c"))
            try expect(p.videoClips.count==1 && p.audioClips.count==1 && p.videoClips[0].startFrame==60,"Linked delete removed wrong split half")
        }
        try check("atomic edits reject conflict boundary overflow and stale selection without changing input"){
            var p=project();p.videoClips.append(VideoClip(id:"other",assetID:"v",startFrame:60,durationFrames:30))
            let original=p
            try rejects{_=try TimelineEdits.move(p,selection:.video("c"),toFrame:50)}
            try rejects{_=try TimelineEdits.move(p,selection:.video("c"),toFrame:Int.max)}
            try rejects{_=try TimelineEdits.trim(p,selection:.video("c"),startFrame:-1,endFrame:10)}
            try rejects{_=try TimelineEdits.split(p,selection:.video("c"),atFrame:0)}
            try rejects{_=try TimelineEdits.delete(p,selection:.audio("missing"))}
            try expect(p==original,"Rejected transaction changed original")
            p.videoClips[0].sourceStartFrame=Int.max;try rejects{try p.validate()}
        }
        try check("fade split preserves outer ramps and rejects unrepresentable split"){
            var p=project();p.audioClips=[AudioClip(id:"a",assetID:"v",startFrame:0,durationFrames:60,fadeInFrames:10,fadeOutFrames:10)]
            let split=try TimelineEdits.split(p,selection:.audio("a"),atFrame:30)
            try expect(split.audioClips[0].fadeInFrames==10 && split.audioClips[0].fadeOutFrames==0 && split.audioClips[1].fadeInFrames==0 && split.audioClips[1].fadeOutFrames==10,"Split altered ramps")
            try rejects{_=try TimelineEdits.split(p,selection:.audio("a"),atFrame:5)}
        }
        try check("legacy schema 1 decodes absent new optional fields and new empty project validates"){
            var legacy=project();legacy.schemaVersion=1
            let data=try JSONEncoder().encode(legacy);let loaded=try JSONDecoder().decode(EditorProject.self,from:data)
            try expect(loaded.videoClips[0].linkGroupID==nil && loaded.assets[0].fingerprint==nil && loaded.mutedAudioTracks==nil,"Legacy fields incompatible")
            try EditorProject(durationFrames:1).validate()
            var p=project();p.mutedAudioTracks=[0,0];try rejects{try p.validate()};p.mutedAudioTracks=[4];try rejects{try p.validate()}
            p.mutedAudioTracks=[1];p.hiddenVideoTracks=[1];p.subtitles=[SubtitleCue(startFrame:0,endFrame:30,text:"位置",positionY:0.4)];try p.validate()
            try expect(try JSONDecoder().decode(EditorProject.self,from:ProjectStore.encoded(p))==p,"Optional controls did not persist")
        }
        try check("UTF8 SRT exact frame roundtrip and nearest-frame quantization"){
            let cues=[SubtitleCue(startFrame:1,endFrame:29,text:"第一行\nsecond line"),SubtitleCue(startFrame:30,endFrame:61,text:"末句")]
            let text=try SRTCodec.encode(cues);let decoded=try SRTCodec.parse(Data(text.utf8))
            try expect(decoded.map(\.startFrame)==cues.map(\.startFrame) && decoded.map(\.endFrame)==cues.map(\.endFrame) && decoded.map(\.text)==cues.map(\.text),"SRT frame/text roundtrip changed")
            let q=try SRTCodec.parse("\u{feff}1\r\n00:00:00,016 --> 00:00:00,050\r\n测试\r\n")
            try expect(q[0].startFrame==0 && q[0].endFrame==2,"Nearest-frame tie quantization wrong")
        }
        try check("SRT malformed overlap third line invalid UTF8 and atomic append rejected"){
            try rejects{_=try SRTCodec.parse(Data([0xff,0xfe]))}
            for bad in ["", " \n \n", "1\n00:00:00,000 --> 00:00:01,000\na\nb\nc", "1\n00:00:00,000 --> 00:00:01,000\na\n\n2\n00:00:00,900 --> 00:00:02,000\nb", "1\n00:00:00,001 --> 00:00:00,002\na", "1\n00:99:00,000 --> 00:99:01,000\na"] { try rejects{_=try SRTCodec.parse(bad)} }
            var p=project();p.subtitles=[SubtitleCue(startFrame:0,endFrame:30,text:"existing")];let old=p
            try rejects{_=try SRTCodec.importing("1\n00:00:00,500 --> 00:00:01,500\nconflict",into:p,replacing:false)}
            try expect(p==old,"Failed SRT import changed project")
        }
        try check("immediate recovery resolves absolute sources and corrupt primary falls back to readable backup"){
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer{try? FileManager.default.removeItem(at:root)}
            let url=root.appendingPathComponent("recovery.json"),projectURL=root.appendingPathComponent("old/project.json")
            var p=project();try RecoveryStore.write(p,baseURL:root,projectURL:projectURL,to:url)
            let first=try RecoveryStore.read(url)
            try expect(first.project.assets[0].path==root.appendingPathComponent("media/v.mp4").path && first.projectURL==projectURL,"Recovery lost location")
            p.name="second";try RecoveryStore.write(p,baseURL:root,projectURL:projectURL,to:url)
            try expect(RecoveryStore.read(url).project.name=="second","Latest immediate recovery not visible")
            try Data("truncated".utf8).write(to:url)
            try expect(RecoveryStore.read(url).project.name==first.project.name,"Corrupt primary did not use backup")
            p.name="third";try RecoveryStore.write(p,baseURL:root,projectURL:projectURL,to:url)
            try Data("corrupt again".utf8).write(to:url)
            try expect(RecoveryStore.read(url).project.name==first.project.name,"Bad primary overwrote good backup")
            var invalid=p;invalid.durationFrames=0;try rejects{try RecoveryStore.write(invalid,baseURL:root,projectURL:projectURL,to:url)}
            try expect(RecoveryStore.read(url).project.name==first.project.name,"Rejected recovery write destroyed backup")
            try RecoveryStore.clear(url);try expect(!FileManager.default.fileExists(atPath:url.path),"Recovery clear failed")
        }
        try check("fingerprint relink accepts identical bytes and refuses same-name substitution or untracked legacy"){
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer{try? FileManager.default.removeItem(at:root)}
            let original=root.appendingPathComponent("original.bin"),moved=root.appendingPathComponent("moved.bin"),wrong=root.appendingPathComponent("same-name.bin")
            try Data("source".utf8).write(to:original);try Data("source".utf8).write(to:moved);try Data("wrong".utf8).write(to:wrong)
            var p=project();p.assets[0].path=original.path
            try rejects{_=try AssetStore.relink(p,baseURL:root,assetID:"v",to:moved)}
            p=try AssetStore.fingerprinted(p,baseURL:root);let sourceHash=p.assets[0].fingerprint!
            try FileManager.default.removeItem(at:original)
            let relinked=try AssetStore.relink(p,baseURL:root,assetID:"v",to:moved)
            try expect(relinked.assets[0].path==moved.path && relinked.assets[0].fingerprint==sourceHash,"Exact-byte relink failed")
            try rejects{_=try AssetStore.relink(p,baseURL:root,assetID:"v",to:wrong)}
        }
        try check("collected project reopens relative sources and destination/source failure leaves originals intact"){
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer{try? FileManager.default.removeItem(at:root)}
            let source=root.appendingPathComponent("source.bin");let bytes=Data("immutable original".utf8);try bytes.write(to:source)
            var p=project();p.assets[0].path=source.path
            let destination=root.appendingPathComponent("portable")
            let collected=try AssetStore.collect(p,baseURL:root,to:destination)
            let reopened=try ProjectStore.load(destination.appendingPathComponent("project.json"))
            try expect(collected==reopened && reopened.assets[0].path.hasPrefix("media/"),"Collected references not portable")
            try expect(try Data(contentsOf:reopened.assetURL("v",baseURL:destination))==bytes,"Collected source changed")
            try rejects{_=try AssetStore.collect(p,baseURL:root,to:destination)}
            try expect(Data(contentsOf:source)==bytes,"Collect replaced original")
            p.assets[0].path=root.appendingPathComponent("missing").path;let failed=root.appendingPathComponent("failed")
            try rejects{_=try AssetStore.collect(p,baseURL:root,to:failed)}
            try expect(!FileManager.default.fileExists(atPath:failed.path),"Failed collection published partial directory")
        }
        try check("schema 1 opens without disk writes and all editing persistence upgrades to schema 2"){
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer{try? FileManager.default.removeItem(at:root)}
            var legacy=project();legacy.schemaVersion=1;let original=try JSONEncoder().encode(legacy),url=root.appendingPathComponent("legacy.json")
            try original.write(to:url);let upgraded=try ProjectStore.load(url)
            try expect(upgraded.schemaVersion==2 && Data(contentsOf:url)==original,"Load modified legacy source or did not upgrade")
            try expect(ProjectStore.semanticHash(legacy,baseURL:root)==ProjectStore.semanticHash(upgraded,baseURL:root),"Version-only upgrade changed semantic hash")
            let written=try ProjectStore.save(legacy,from:root,to:root.appendingPathComponent("new.json"))
            try expect(written.schemaVersion==2,"Save did not upgrade")
            let encoded=try JSONDecoder().decode(EditorProject.self,from:ProjectStore.encoded(legacy));try expect(encoded.schemaVersion==2,"Serialized old schema")
            let moved=try TimelineEdits.move(legacy,selection:.video("c"),toFrame:30);try expect(moved.schemaVersion==2,"Edit did not upgrade")
            try RecoveryStore.write(legacy,baseURL:root,projectURL:url,to:root.appendingPathComponent("recovery"))
            try expect(RecoveryStore.read(root.appendingPathComponent("recovery")).project.schemaVersion==2,"Recovery did not upgrade")
        }
        try check("malformed original audio link groups reject unrelated or incomplete members"){
            var pair=project();pair.videoClips[0].linkGroupID="pair";pair.audioClips=[AudioClip(id:"sound",assetID:"v",startFrame:0,durationFrames:30,linkGroupID:"pair")];try pair.validate()
            var p=pair;p.audioClips=[];try rejects{try p.validate()}
            p=pair;p.videoClips.append(VideoClip(assetID:"v",track:1,startFrame:0,durationFrames:30,linkGroupID:"pair"));try rejects{try p.validate()}
            p=pair;p.assets.append(MediaAsset(id:"music",path:"music.wav",kind:.audio));p.audioClips[0].assetID="music";try rejects{try p.validate()}
            p=pair;p.assets[0].kind = .audio;try rejects{try p.validate()}
            p=pair;p.audioClips[0].sourceStartFrame=1;try rejects{try p.validate()}
            p=pair;p.audioClips[0].durationFrames=29;try rejects{try p.validate()}
        }
        // ---- 步骤7 修复回归 ----
        try await checkAsync("S7-01 HEVC 1440p60 lists codec, resolution and frame rate at once; compatible copy passes"){
            let raw=try await TimelineEngine.inspect(media("Tests/Fixtures/media/hevc-1440p60.mp4"))
            try expect(raw.videoIssues.count==3 && raw.videoIssues[0].contains("HEVC") && raw.videoIssues.contains{$0.contains("2560×1440")} && raw.videoIssues.contains{$0.contains("60fps")},"Diagnostics incomplete: \(raw.videoIssues)")
            try expect(raw.audioIssues.isEmpty,"AAC 48k stereo wrongly rejected: \(raw.audioIssues)")
            let copy=try await TimelineEngine.inspect(media("Tests/Fixtures/media/hevc-1440p60-compatible-v2.mp4"))
            try expect(copy.videoIssues.isEmpty && copy.audioIssues.isEmpty && copy.videoFrames==0..<120,"Compatible copy rejected: \(copy.videoIssues) \(copy.audioIssues) \(String(describing:copy.videoFrames))")
            let fixture=try await TimelineEngine.inspect(media("fixtures/media/source01.mp4"))
            try expect(fixture.videoIssues.isEmpty && fixture.videoFrames==0..<600,"Frozen fixture regressed: \(fixture.videoIssues)")
        }
        try check("S7-02 linked import uses the overlap of picture and original audio and reports cuts over one frame"){
            let empty=EditorProject(durationFrames:1)
            var placed=try ImportPlacement.appendVideo(empty,assetID:"a",path:"/x/a.mp4",fingerprint:nil,video:0..<120,audio:0..<119)
            try expect(placed.project.videoClips[0].durationFrames==119 && placed.project.audioClips[0].durationFrames==119 && placed.note==nil,"One-frame shorter audio not trimmed silently")
            placed=try ImportPlacement.appendVideo(empty,assetID:"a",path:"/x/a.mp4",fingerprint:nil,video:0..<120,audio:0..<100)
            try expect(placed.project.videoClips[0].durationFrames==100 && placed.note=="原声比画面短 20 帧，已按较短者截齐","Short audio note wrong: \(String(describing:placed.note))")
            placed=try ImportPlacement.appendVideo(empty,assetID:"a",path:"/x/a.mp4",fingerprint:nil,video:2..<120,audio:0..<130)
            try expect(placed.project.videoClips[0].sourceStartFrame==2 && placed.project.audioClips[0].sourceStartFrame==2 && placed.project.videoClips[0].durationFrames==118 && placed.note=="画面比原声短 12 帧，已按较短者截齐","Overlap with late video start wrong")
            placed=try ImportPlacement.appendVideo(placed.project,assetID:"b",path:"/x/b.mp4",fingerprint:nil,video:0..<30,audio:nil)
            try expect(placed.project.videoClips[1].startFrame==118 && placed.project.videoClips[1].linkGroupID==nil && placed.project.audioClips.count==1,"Picture-only import wrong")
            try rejects{_=try ImportPlacement.appendVideo(empty,assetID:"c",path:"/x/c.mp4",fingerprint:nil,video:0..<18001,audio:nil)}
        }
        try await checkAsync("S7-02 real AV length mismatch imports and compiles; old longest-track length fails naming the file"){
            let folder=try media("Tests/Fixtures/media/av-audio-short-v2.mp4").deletingLastPathComponent()
            for (file,expectedVideo,expectedAudio,oldFrames) in [("av-audio-short-v2.mp4",0..<120,0..<119,120),("av-audio-long-v2.mp4",0..<120,0..<120,120),("av-audio-long-100ms-v2.mp4",0..<120,0..<123,123)]{
                let url=try media("Tests/Fixtures/media/"+file),info=try await TimelineEngine.inspect(url)
                try expect(info.videoFrames==expectedVideo && info.audioFrames==expectedAudio,"\(file) track frames \(String(describing:info.videoFrames)) \(String(describing:info.audioFrames))")
                let placed=try ImportPlacement.appendVideo(EditorProject(durationFrames:1),assetID:"m",path:url.path,fingerprint:nil,video:info.videoFrames!,audio:info.audioFrames)
                _=try await TimelineEngine.compile(project:placed.project,baseURL:folder)
                // The pre-fix importer used the container's longest track for both clips.
                var old=placed.project;old.durationFrames=oldFrames;old.videoClips[0].durationFrames=oldFrames;old.audioClips[0].durationFrames=oldFrames
                if oldFrames>min(expectedVideo.count,expectedAudio.count){
                    var failed=false
                    do{_=try await TimelineEngine.compile(project:old,baseURL:folder)}catch{failed=error.localizedDescription.contains(file)}
                    try expect(failed,"\(file): old length should fail and name the file")
                }
            }
        }
        try check("S7-03 collected package stays relative through save, open-edit-save and relocation"){
            let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:root,withIntermediateDirectories:true)
            defer{try? fm.removeItem(at:root)}
            let source=root.appendingPathComponent("source.bin"),bytes=Data("package media".utf8);try bytes.write(to:source)
            var p=project();p.assets[0].path=source.path
            // NSSavePanel returns the package folder without a trailing slash; the saved file's parent has one.
            let package=URL(fileURLWithPath:root.appendingPathComponent("pkg").path),projectURL=package.appendingPathComponent("project.json")
            try expect(package.standardizedFileURL != projectURL.deletingLastPathComponent().standardizedFileURL,"Root cause no longer reproduces: URL equality now ignores trailing slash")
            let collected=try AssetStore.collect(p,baseURL:root,to:package)
            var saved=try ProjectStore.save(collected,from:package,to:projectURL)
            try expect(saved.assets[0].path.hasPrefix("media/"),"Save right after collect wrote \(saved.assets[0].path)")
            // GUI open keeps references as loaded; edit; save in place.
            let opened=try ProjectStore.load(projectURL),edited=try TimelineEdits.move(opened,selection:.video("c"),toFrame:10)
            saved=try ProjectStore.save(edited,from:projectURL.deletingLastPathComponent(),to:projectURL)
            try expect(saved.assets[0].path.hasPrefix("media/") && ProjectStore.load(projectURL).assets[0].path.hasPrefix("media/"),"Open-edit-save rewrote to absolute")
            // A recovered snapshot carries absolute paths inside the package; saving back makes them relative.
            var recovered=edited;recovered.assets[0].path=try edited.assetURL("v",baseURL:package).path
            saved=try ProjectStore.save(recovered,from:root,to:package.appendingPathComponent("recovered.json"))
            try expect(saved.assets[0].path.hasPrefix("media/"),"Absolute media inside package not made relative")
            // Media outside the destination stays absolute when saving elsewhere.
            let elsewhere=root.appendingPathComponent("other");try fm.createDirectory(at:elsewhere,withIntermediateDirectories:true)
            saved=try ProjectStore.save(edited,from:package,to:elsewhere.appendingPathComponent("p.json"))
            try expect(saved.assets[0].path.hasPrefix("/") && saved.assets[0].path.hasSuffix(collected.assets[0].path),"Save-as outside package lost the reference")
            // Move the whole package and reopen.
            let moved=root.appendingPathComponent("moved-package");try fm.moveItem(at:package,to:moved)
            let reopened=try ProjectStore.load(moved.appendingPathComponent("project.json"))
            try expect(try Data(contentsOf:reopened.assetURL("v",baseURL:moved))==bytes && reopened.videoClips[0].startFrame==10,"Relocated package lost media or edit")
        }
        try check("S7-04 changed or missing media no longer blocks opening; export-time check still refuses and names the file"){
            let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:root,withIntermediateDirectories:true)
            defer{try? fm.removeItem(at:root)}
            let music=root.appendingPathComponent("配乐.wav"),clip=root.appendingPathComponent("clip.mp4")
            try Data("original music".utf8).write(to:music);try Data("clip".utf8).write(to:clip)
            var p=project();p.assets[0].path=clip.path;p.assets.append(MediaAsset(id:"m",path:music.path,kind:.audio))
            p.audioClips=[AudioClip(assetID:"m",track:1,startFrame:0,durationFrames:30)]
            p=try AssetStore.fingerprinted(p,baseURL:root);let recorded=p.assets[1].fingerprint
            try Data("re-exported music".utf8).write(to:music)
            let opened=try AssetStore.verified(p,baseURL:root)
            try expect(opened.changed==["m"] && opened.project.assets[1].fingerprint==recorded,"Changed asset not reported or fingerprint overwritten")
            var failure="";do{_=try AssetStore.fingerprinted(p,baseURL:root)}catch{failure=error.localizedDescription}
            try expect(failure.contains("配乐.wav"),"Export check message lacks file name: \(failure)")
            // Relinking to an untouched copy of the original clears the problem.
            let backup=root.appendingPathComponent("backup.wav");try Data("original music".utf8).write(to:backup)
            let relinked=try AssetStore.relink(opened.project,baseURL:root,assetID:"m",to:backup)
            try expect(try AssetStore.verified(relinked,baseURL:root).changed.isEmpty,"Relink did not clear changed state")
            // A missing file is skipped (left for relinking); a legacy asset gains a fingerprint.
            try fm.removeItem(at:clip);var legacy=p;legacy.assets[1].fingerprint=nil;legacy.assets[1].path=backup.path
            let partial=try AssetStore.verified(legacy,baseURL:root)
            try expect(partial.changed.isEmpty && partial.project.assets[1].fingerprint==recorded,"Missing file blocked verification or legacy fingerprint not filled")
        }
        try check("S7-05 CFR test tolerates millisecond timebases but rejects jitter, dropped frames and drift"){
            let ms30=(0..<300).map{Double(Int((Double($0)*1000/30).rounded()))/1000},ms24=(0..<240).map{Double(Int((Double($0)*1000/24).rounded()))/1000}
            try expect(FrameMath.isConstantFrameRate(ms30,fps:30,tick:0.001) && FrameMath.isConstantFrameRate(ms24,fps:24,tick:0.001),"Millisecond-timebase CFR misjudged as VFR")
            let exact=(0..<300).map{Double($0*512)/15360}
            try expect(FrameMath.isConstantFrameRate(exact,fps:30,tick:1.0/15360),"Exact CFR rejected")
            // The pre-fix rule (every step within 0.1 ms) rejects the millisecond 30 fps file.
            try expect(zip(ms30,ms30.dropFirst()).contains{abs($1-$0-1.0/30)>0.0001},"Old-rule reproduction lost")
            var dropped=exact;dropped.remove(at:150);try expect(!FrameMath.isConstantFrameRate(dropped,fps:30,tick:1.0/15360),"Dropped frame accepted")
            let jitter=exact.enumerated().map{$0.offset%2==1 ? $0.element+0.0133:$0.element};try expect(!FrameMath.isConstantFrameRate(jitter,fps:30,tick:1.0/15360),"Jitter accepted")
            let drift=(0..<300).map{Double($0)*(1.0/30+0.0009)};try expect(!FrameMath.isConstantFrameRate(drift,fps:30,tick:0.001),"Slow drift hidden inside step tolerance")
            // Late-sampling guard only for rounded timebases; frozen fixtures (15360/30, 12288/24, 12800/25) keep zero.
            try expect(FrameMath.roundedTimestampGuardTicks(timescale:1000,fps:30)==1 && FrameMath.roundedTimestampGuardTicks(timescale:1000,fps:24)==1,"Rounded timebase not guarded")
            try expect([(15360,30),(12288,24),(12800,25),(90000,30),(1000,25)].allSatisfy{FrameMath.roundedTimestampGuardTicks(timescale:Int32($0.0),fps:$0.1)==0},"Exact timebase changed")
        }
        try await checkAsync("S7-05 real 1/1000-timebase 30 and 24 fps CFR files pass; jittered file is rejected"){
            for file in ["cfr30-tb1000.mp4","cfr24-tb1000.mp4"]{
                let info=try await TimelineEngine.inspect(media("Tests/Fixtures/media/"+file))
                try expect(info.videoIssues.isEmpty,"\(file) rejected: \(info.videoIssues)")
            }
            let vfr=try await TimelineEngine.inspect(media("Tests/Fixtures/media/vfr-jitter30-v3.mp4"))
            print("  vfr-jitter30-v3 issues: \(vfr.videoIssues)")
            try expect(!vfr.videoIssues.isEmpty,"Jittered file accepted")
        }
        try await checkAsync("S7-06 repeated compile reuses the CFR scan; a modified file is scanned again"){
            let f1=try media("fixtures/F1.json"),p=try ProjectStore.load(f1),base=f1.deletingLastPathComponent()
            let sources=Set(p.videoClips.map(\.assetID)).filter{id in p.assets.first{$0.id==id}?.kind == .video}.count
            let before=TimelineEngine.cfrScanCounts,t0=Date()
            _=try await TimelineEngine.compile(project:p,baseURL:base);let first=Date().timeIntervalSince(t0),mid=TimelineEngine.cfrScanCounts,t1=Date()
            _=try await TimelineEngine.compile(project:p,baseURL:base);let second=Date().timeIntervalSince(t1),after=TimelineEngine.cfrScanCounts
            try expect(after.hits-mid.hits==sources && after.scans==mid.scans,"Second compile rescanned: \(mid) -> \(after)")
            print(String(format:"  F1 compile: first %.3fs (scans +%d, hits +%d), second %.3fs (scans +0, hits +%d)",first,mid.scans-before.scans,mid.hits-before.hits,second,after.hits-mid.hits))
            let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:root,withIntermediateDirectories:true)
            defer{try? fm.removeItem(at:root)}
            let copy=root.appendingPathComponent("clip.mp4");try fm.copyItem(at:media("Tests/Fixtures/media/cfr30-tb1000.mp4"),to:copy)
            let one=EditorProject(durationFrames:30,assets:[MediaAsset(id:"v",path:copy.path,kind:.video)],videoClips:[VideoClip(id:"c",assetID:"v",startFrame:0,durationFrames:30)])
            _=try await TimelineEngine.compile(project:one,baseURL:root);let s1=TimelineEngine.cfrScanCounts.scans
            try fm.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-3600)],ofItemAtPath:copy.path)
            _=try await TimelineEngine.compile(project:one,baseURL:root)
            try expect(TimelineEngine.cfrScanCounts.scans==s1+1,"Modified file reused stale scan")
        }
        try check("S7-07 SRT problems are all listed with block and line numbers; conflicts with existing cues are named"){
            let bad="1\n00:00:00,000 --> 00:00:01,000\n好\n\n2\n00:00:01,000 --> 00:00:02,000\n\n3\n00:00:0x,000 --> 00:00:03,000\n坏时间\n\n4\n00:00:04,000 --> 00:00:05,000\n甲\n\n5\n00:00:04,500 --> 00:00:06,000\n乙\n"
            var message="";do{_=try SRTCodec.parse(bad)}catch{message=error.localizedDescription}
            try expect(message.hasPrefix("SRT 有 3 处问题"),"Problem count wrong: \(message)")
            try expect(message.contains("第2条（第5行）：没有字幕文字") && message.contains("第3条（第8行）：SRT时间格式无效") && message.contains("序号 4（第12行，00:00:04,000–00:00:05,000）与序号 5（第16行，00:00:04,500–00:00:06,000）时间重叠"),"Locations missing: \(message)")
            var p=project();p.subtitles=[SubtitleCue(startFrame:0,endFrame:30,text:"已有\n第二行")];let old=p
            message="";do{_=try SRTCodec.importing("1\n00:00:00,500 --> 00:00:01,500\n新\n\n2\n00:00:01,500 --> 00:00:02,000\n不冲突",into:p,replacing:false)}catch{message=error.localizedDescription}
            try expect(message.hasPrefix("SRT 与已有字幕有 1 处时间冲突") && message.contains("序号 1（第1行，00:00:00,500–00:00:01,500）与已有字幕「已有 第二行」（00:00:00,000–00:00:01,000）重叠"),"Conflict not named: \(message)")
            try expect(p==old,"Rejected SRT import changed project")
            let ok=try SRTCodec.importing("1\n00:00:01,000 --> 00:00:01,500\n不冲突",into:p,replacing:false)
            try expect(ok.subtitles.count==2,"Valid append rejected")
            // Frozen SRT inputs still parse to the same cue counts as their projects.
            for (srt,json) in [("fixtures/F1.srt","fixtures/F1.json"),("fixtures/F2.srt","fixtures/F2.json"),("fixtures/F1-portrait.srt","fixtures/F1-portrait.json")]{
                let cues=try SRTCodec.parse(Data(contentsOf:media(srt))),expected=try ProjectStore.load(media(json)).subtitles
                try expect(cues.map(\.startFrame)==expected.sorted{$0.startFrame<$1.startFrame}.map(\.startFrame) && cues.count==expected.count,"\(srt) changed")
            }
            // A portable handwritten three-cue input exercises parsing without private GUI records.
            let sample="1\n00:00:00,000 --> 00:00:01,000\n开场\n\n2\n00:00:02,000 --> 00:00:03,000\n中段\n\n3\n00:00:04,000 --> 00:00:05,000\n结尾\n"
            let sampleCues=try SRTCodec.parse(Data(sample.utf8))
            try expect(sampleCues.map(\.startFrame)==[0,60,120] && sampleCues.map(\.endFrame)==[30,90,150] && sampleCues.map(\.text)==["开场","中段","结尾"],"Three-cue sample changed")
        }
        try check("S7-08 large subtitle boxes near the top or bottom edge are moved inside the canvas"){
            // Audit example: landscape, two-line 160 px box ≈ 490 px, center Y 0.1 / 0.9.
            let top=SubtitleLayout.originY(canvasHeight:1080,boxHeight:490,positionY:0.1),bottom=SubtitleLayout.originY(canvasHeight:1080,boxHeight:490,positionY:0.9)
            try expect(top==590 && top+490<=1080,"Top box still clipped: origin \(top)")
            try expect(bottom==0,"Bottom box still clipped: origin \(bottom)")
            // Unclipped placements are unchanged: legacy default and a mid-screen box.
            try expect(SubtitleLayout.originY(canvasHeight:1080,boxHeight:150,positionY:nil)==floor(1080*0.07),"Legacy default moved")
            try expect(SubtitleLayout.originY(canvasHeight:1920,boxHeight:150,positionY:0.4)==floor(1920*0.6-75),"Mid-screen box moved")
        }
        try await checkAsync("S7-09 embedded Display P3 profile is honoured, sRGB-tagged image unchanged, CMYK is rejected"){
            let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:root,withIntermediateDirectories:true)
            defer{try? fm.removeItem(at:root)}
            func write(_ name:String,_ space:CGColorSpace,_ components:[CGFloat],_ type:String)throws->URL{
                let url=root.appendingPathComponent(name)
                let ctx=CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:space.model == .cmyk ? CGImageAlphaInfo.none.rawValue:CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.setFillColor(CGColor(colorSpace:space,components:components+[1])!);ctx.fill(CGRect(x:0,y:0,width:64,height:64))
                let dest=CGImageDestinationCreateWithURL(url as CFURL,type as CFString,1,nil)!;CGImageDestinationAddImage(dest,ctx.makeImage()!,nil);try expect(CGImageDestinationFinalize(dest),"write \(name)");return url
            }
            func rendered(_ image:URL)async throws->[Int]{
                let p=EditorProject(durationFrames:30,assets:[MediaAsset(id:"i",path:image.path,kind:.image)],videoClips:[VideoClip(id:"c",assetID:"i",startFrame:0,durationFrames:30)])
                let out=root.appendingPathComponent(UUID().uuidString+".png")
                try await TimelineEngine.frame(try await TimelineEngine.compile(project:p,baseURL:root),atFrame:0,fps:30,to:out)
                let cg=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(out as CFURL,nil)!,0,nil)!
                let srgb=CGColorSpace(name:CGColorSpace.sRGB)!,ctx=CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:srgb,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
                let bytes=ctx.data!.assumingMemoryBound(to:UInt8.self),i=(cg.height/2*cg.width+cg.width/2)*4
                return [Int(bytes[i]),Int(bytes[i+1]),Int(bytes[i+2])]
            }
            let rgb:[CGFloat]=[0.8,0.3,0.2]
            let p3=try write("p3.png",CGColorSpace(name:CGColorSpace.displayP3)!,rgb,"public.png")
            let srgb=try write("srgb.png",CGColorSpace(name:CGColorSpace.sRGB)!,rgb,"public.png")
            // Independent oracle: P3 (204,77,51) → linear → P3-to-sRGB matrix → sRGB ≈ (221,64,37); the same numbers read as sRGB stay (204,77,51).
            let a=try await rendered(p3),b=try await rendered(srgb)
            print("  rendered P3 \(a) vs sRGB-tagged \(b); oracle P3≈[221,64,37], sRGB=[204,77,51]")
            try expect(zip(a,[221,64,37]).allSatisfy{abs($0-$1)<=12} && zip(b,[204,77,51]).allSatisfy{abs($0-$1)<=12},"Colour outside 12/255 tolerance")
            try expect(abs(a[0]-b[0])>=8 && abs(a[1]-b[1])>=6,"Embedded P3 profile ignored")
            let cmyk=try write("cmyk.jpg",CGColorSpaceCreateDeviceCMYK(),[0,0.5,0.5,0],"public.jpeg")
            var message="";do{_=try await rendered(cmyk)}catch{message=error.localizedDescription}
            try expect(message.contains("CMYK") && message.contains("cmyk.jpg"),"CMYK not rejected clearly: \(message)")
        }
        try check("S7-11 only unsaved recovery snapshots prompt; start-blank archives a copy and stops re-prompting"){
            let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:dir,withIntermediateDirectories:true)
            defer{try? fm.removeItem(at:dir)}
            let url=dir.appendingPathComponent("recovery.json"),history=dir.appendingPathComponent("history")
            try expect(!RecoveryStore.needsPrompt(url),"Missing recovery prompted")
            // After open/new/manual save the snapshot is written with unsaved=false: a clean relaunch does not prompt.
            var p=project();try RecoveryStore.write(p,baseURL:dir,projectURL:nil,to:url,unsaved:false)
            try expect(!RecoveryStore.needsPrompt(url),"Saved snapshot prompted on relaunch")
            p.name="edited";try RecoveryStore.write(p,baseURL:dir,projectURL:nil,to:url,unsaved:true)
            try expect(RecoveryStore.needsPrompt(url),"Unsaved edit did not prompt")
            // An explicit legacy shape omits unsaved; no historical user project is needed.
            let legacy=dir.appendingPathComponent("legacy.json")
            var legacyProject=project();legacyProject.schemaVersion=1;legacyProject.assets[0].path="/synthetic-media/clip.mp4"
            let legacyObject:[String:Any]=["version":1,"project":try JSONSerialization.jsonObject(with:JSONEncoder().encode(legacyProject)),"savedAt":0]
            try JSONSerialization.data(withJSONObject:legacyObject).write(to:legacy,options:.withoutOverwriting)
            let legacySnapshot=try RecoveryStore.read(legacy)
            try expect(legacySnapshot.unsaved==nil && legacySnapshot.project.schemaVersion==2 && RecoveryStore.needsPrompt(legacy),"Legacy snapshot not treated as unsaved")
            // Unreadable primary without backup still prompts, so the user is told rather than silently ignored.
            let corrupt=dir.appendingPathComponent("corrupt.json");try Data("x".utf8).write(to:corrupt);try expect(RecoveryStore.needsPrompt(corrupt),"Corrupt recovery hidden")
            // "Start blank": both files are copied byte-for-byte into history, then the prompt does not come back.
            let primary=try Data(contentsOf:url),backup=try Data(contentsOf:url.appendingPathExtension("backup"))
            let copies=try RecoveryStore.archive(url,into:history)
            try expect(copies.count==2 && Set(try copies.map{try Data(contentsOf:$0)})==Set([primary,backup]),"Archive lost snapshot bytes")
            try expect(!RecoveryStore.needsPrompt(url) && !fm.fileExists(atPath:url.path),"Archived snapshot still prompts")
            try expect(try RecoveryStore.read(copies.first{$0.lastPathComponent.hasSuffix("recovery.json")}!).project.name=="edited","Archived copy unreadable")
        }
        try await checkAsync("S7-12 a compliant picture imports alone when only its original audio is unsupported (96 kHz PCM)"){
            let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:dir,withIntermediateDirectories:true)
            defer{try? fm.removeItem(at:dir)}
            // Test input built here without FFmpeg: the compliant H.264 track of a step7 fixture copied
            // unchanged (passthrough) plus 4 s of 96 kHz stereo 16-bit PCM, which the spec does not accept.
            let wav=dir.appendingPathComponent("tone-96k.wav"),frames:AVAudioFrameCount=384_000
            do{
                let format=AVAudioFormat(standardFormatWithSampleRate:96000,channels:2)!,buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:frames)!;buffer.frameLength=frames
                for c in 0..<2{let s=buffer.floatChannelData![c];for i in 0..<Int(frames){s[i]=0.1*sin(Float(i)*2 * .pi*1000/96000)}}
                let file=try AVAudioFile(forWriting:wav,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:96000,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false])
                try file.write(from:buffer)
            }
            let source=try media("Tests/Fixtures/media/av-audio-short-v2.mp4"),mov=dir.appendingPathComponent("picture-ok-audio-96k.mov")
            let videoAsset=AVURLAsset(url:source),audioAsset=AVURLAsset(url:wav)
            let video=try await videoAsset.loadTracks(withMediaType:.video)[0],audio=try await audioAsset.loadTracks(withMediaType:.audio)[0]
            let pcm:[String:Any]=[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:96000,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false,AVLinearPCMIsNonInterleaved:false]
            let videoReader=try AVAssetReader(asset:videoAsset),videoOut=AVAssetReaderTrackOutput(track:video,outputSettings:nil);videoReader.add(videoOut)
            let audioReader=try AVAssetReader(asset:audioAsset),audioOut=AVAssetReaderTrackOutput(track:audio,outputSettings:pcm);audioReader.add(audioOut)
            let writer=try AVAssetWriter(outputURL:mov,fileType:.mov)
            let videoIn=AVAssetWriterInput(mediaType:.video,outputSettings:nil,sourceFormatHint:try await video.load(.formatDescriptions).first),audioIn=AVAssetWriterInput(mediaType:.audio,outputSettings:pcm)
            writer.add(videoIn);writer.add(audioIn)
            try expect(videoReader.startReading() && audioReader.startReading() && writer.startWriting(),"test media writer failed to start");writer.startSession(atSourceTime:.zero)
            var pending:[(AVAssetReaderTrackOutput,AVAssetWriterInput)]=[(videoOut,videoIn),(audioOut,audioIn)]
            while !pending.isEmpty{
                var moved=false
                pending=pending.filter{output,input in guard input.isReadyForMoreMediaData else{return true};moved=true
                    if let sample=output.copyNextSampleBuffer(){return input.append(sample)};input.markAsFinished();return false}
                if !moved{try await Task.sleep(nanoseconds:1_000_000)}
            }
            await writer.finishWriting();try expect(writer.status == .completed,"test media writer failed: \(writer.error?.localizedDescription ?? "")")
            let info=try await TimelineEngine.inspect(mov)
            print("  probe: rejection=\(info.rejection ?? "nil")；audioOnlyProblem=\(info.audioOnlyProblem ?? "nil")")
            try expect(info.hasVideo && info.hasAudio && info.rejection==nil && info.audioOnlyProblem?.contains("96000Hz")==true,"Picture rejected or audio problem not named")
            // Import as the UI does: no original-audio link when only the audio is unsupported.
            let placed=try ImportPlacement.appendVideo(EditorProject(durationFrames:1),assetID:"m",path:mov.path,fingerprint:nil,video:info.videoFrames!,audio:info.audioOnlyProblem==nil ? info.audioFrames:nil)
            try expect(placed.project.videoClips.count==1 && placed.project.videoClips[0].linkGroupID==nil && placed.project.audioClips.isEmpty && placed.project.videoClips[0].durationFrames==120,"Picture-only import wrong")
            _=try await TimelineEngine.compile(project:placed.project,baseURL:dir)
            // Before the fix the original audio was always linked; that project still fails, naming the reason.
            let linked=try ImportPlacement.appendVideo(EditorProject(durationFrames:1),assetID:"m",path:mov.path,fingerprint:nil,video:info.videoFrames!,audio:info.audioFrames)
            var message="";do{_=try await TimelineEngine.compile(project:linked.project,baseURL:dir)}catch{message=error.localizedDescription}
            print("  linked (pre-fix behaviour) compile: \(message)")
            try expect(message.contains("96000Hz") && message.contains(mov.lastPathComponent),"Linked unsupported audio not rejected clearly")
        }
        try check("S7-13 whole-frame durations convert exactly with integer math; the old float formula lost a frame"){
            // Every whole-frame length 1…18000 in timebases that hold 1/30 s exactly.
            var lines:[String]=[]
            for timescale:Int32 in [600,15360,30000,44100,48000,90000]{
                var oldLost=0
                for n in 1...18000{
                    let value=Int64(n)*Int64(timescale)/30
                    try expect(FrameMath.floorFrames(value:value,timescale:timescale,fps:30)==n,"Integer conversion wrong: \(n) frames at 1/\(timescale)")
                    if Int((CMTime(value:value,timescale:timescale).seconds*30).rounded(.down)) != n{oldLost+=1}
                }
                lines.append("1/\(timescale): old formula lost 1 frame for \(oldLost)/18000")
            }
            print("  "+lines.joined(separator:"; "))
            try expect(lines.allSatisfy{$0.contains("for 404/18000")},"Old-formula baseline differs from the audit (404 per timebase)")
            // Audit example: 123 frames = 4.1 s at 1/600.
            try expect(Int((CMTime(value:2460,timescale:600).seconds*30).rounded(.down))==122 && FrameMath.floorFrames(value:2460,timescale:600,fps:30)==123,"4.1 s example")
        }
        try await checkAsync("S7-14 an offline asset is detected so edits and undo commit on validation; export-time checks stay strict"){
            let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:dir,withIntermediateDirectories:true)
            defer{try? fm.removeItem(at:dir)}
            try fm.copyItem(at:media("Tests/Fixtures/media/av-audio-short-v2.mp4"),to:dir.appendingPathComponent("online.mp4"))
            var p=EditorProject(durationFrames:240,assets:[MediaAsset(id:"on",path:"online.mp4",kind:.video),MediaAsset(id:"off",path:"unplugged/gone.mp4",kind:.video),MediaAsset(id:"unused",path:"also-gone.mp4",kind:.video)],
                                videoClips:[VideoClip(id:"a",assetID:"on",startFrame:0,durationFrames:60),VideoClip(id:"b",assetID:"off",startFrame:60,durationFrames:60)])
            try expect(p.offlineAssetIDs(baseURL:dir)==["off"],"Offline detection wrong: \(p.offlineAssetIDs(baseURL:dir))")
            // Before: every edit had to compile first, and compile refuses the unreadable file.
            var message="";do{_=try await TimelineEngine.compile(project:p,baseURL:dir)}catch{message=error.localizedDescription}
            try expect(message.contains("gone.mp4"),"Offline compile did not name the file: \(message)")
            // After: the edit itself only needs project validation; history undo/redo is pure.
            var history=EditHistory(limit:100);let before=p
            p=try TimelineEdits.move(p,selection:.video("a"),toFrame:120);try p.validate();history.record(before:before,after:p,label:"move")
            try expect(history.undo()==before && history.redo()==p,"Undo/redo with offline media failed")
            // Export still refuses until the file is relinked or its clips are deleted.
            try rejects{_=try AssetStore.fingerprinted(p,baseURL:dir)}
            p=try TimelineEdits.delete(p,selection:.video("b"))
            try expect(p.offlineAssetIDs(baseURL:dir).isEmpty,"Deleted clip still offline")
            _=try await TimelineEngine.compile(project:p,baseURL:dir)
        }
        try await checkAsync("S7-15 corrupt media, broken project JSON and system I/O errors surface as Chinese messages with the file name"){
            func chinese(_ s:String)->Bool{s.unicodeScalars.contains{(0x4E00...0x9FFF).contains($0.value)}}
            let raw=["Cannot Open","could not be completed","couldn’t be","couldn't be","DecodingError","dataCorrupted"]
            func clean(_ s:String,_ name:String)throws{try expect(chinese(s) && s.contains(name) && !raw.contains{s.contains($0)},"Not a clean Chinese message naming \(name): \(s)")}
            // Frozen corrupt-media probe (formerly "ERROR: Cannot Open").
            let probe=try media("fixtures/reject-corrupt.json");var message=""
            do{_=try await TimelineEngine.compile(project:ProjectStore.load(probe),baseURL:probe.deletingLastPathComponent())}catch{message=error.localizedDescription}
            print("  reject-corrupt: \(message)")
            let corruptName=try ProjectStore.load(probe).assets.map{URL(fileURLWithPath:$0.path).lastPathComponent}.first{message.contains($0)} ?? "?"
            try clean(message,corruptName)
            let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:dir,withIntermediateDirectories:true)
            defer{try? fm.removeItem(at:dir)}
            let full=try ProjectStore.encoded(project())
            let cases:[(String,Data?)]=[("truncated.json",full.prefix(full.count/2)),("missing-field.json",Data(#"{"schemaVersion":2,"name":"x"}"#.utf8)),("wrong-type.json",Data(String(decoding:full,as:UTF8.self).replacingOccurrences(of:#""fps" : 30"#,with:#""fps" : "thirty""#).utf8)),("absent.json",nil)]
            for (name,data) in cases{
                let url=dir.appendingPathComponent(name);if let data{try data.write(to:url)}
                var text="";do{_=try ProjectStore.load(url)}catch{text=error.localizedDescription}
                print("  \(name): \(text)");try clean(text,name)
            }
            var text="";do{_=try AssetStore.fingerprint(dir.appendingPathComponent("gone.mp4"))}catch{text=error.localizedDescription};try clean(text,"gone.mp4")
            // Engine boundary mapping keeps only the system code, and leaves our own errors and cancellation alone.
            let mapped=MediaEngineError.describing(NSError(domain:AVFoundationErrorDomain,code:-11800,userInfo:[NSLocalizedDescriptionKey:"The operation could not be completed"]),"导出失败：a.mp4").localizedDescription
            try clean(mapped,"a.mp4");try expect(mapped.contains("-11800"),"System code dropped")
            try expect(MediaEngineError.describing(CancellationError(),"x") is CancellationError && MediaEngineError.describing(MediaEngineError.invalid("原文"),"x").localizedDescription=="原文","Own errors were rewrapped")
        }
        try await checkAsync("S7-16 export and collect stage partial files in a system temporary area on the same volume, never beside user files"){
            let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString),out=dir.appendingPathComponent("exports"),pkgParent=dir.appendingPathComponent("packages")
            for d in [out,pkgParent]{try fm.createDirectory(at:d,withIntermediateDirectories:true)}
            defer{try? fm.removeItem(at:dir)}
            try fm.copyItem(at:media("Tests/Fixtures/media/av-audio-short-v2.mp4"),to:dir.appendingPathComponent("clip.mp4"))
            let area=try expectValue(AssetStore.stagingDirectory(near:out),"no staging area")
            let volume={(u:URL) in try u.resourceValues(forKeys:[.volumeIdentifierKey]).volumeIdentifier as? NSObject}
            try expect(try volume(area)==volume(out) && !area.path.hasPrefix(out.path) && !area.path.hasPrefix(dir.path),"Staging area not separate on same volume: \(area.path)")
            try? fm.removeItem(at:area)
            let p=EditorProject(durationFrames:30,assets:[MediaAsset(id:"v",path:"clip.mp4",kind:.video)],videoClips:[VideoClip(assetID:"v",startFrame:0,durationFrames:30)])
            let target=out.appendingPathComponent("short.mp4");let seen=NSMutableSet()
            try await TimelineEngine.export(try await TimelineEngine.compile(project:p,baseURL:dir),to:target){_ in for n in (try? fm.contentsOfDirectory(atPath:out.path)) ?? []{seen.add(n)}}
            print("  names seen in the export folder during export: \(seen.allObjects)")
            try expect(seen.allObjects.allSatisfy{($0 as! String)=="short.mp4"} && (try fm.contentsOfDirectory(atPath:out.path))==["short.mp4"],"Partial file appeared beside the export")
            _=try AssetStore.collect(p,baseURL:dir,to:pkgParent.appendingPathComponent("pkg"))
            try expect((try fm.contentsOfDirectory(atPath:pkgParent.path))==["pkg"],"Collect left staging beside the package")
        }
        try await checkAsync("S7-17 exports put moov before mdat and report mix samples clipped at full scale"){
            /// Top-level MP4 box types in file order, read by walking box headers.
            func boxes(_ url:URL)throws->[String]{
                let h=try FileHandle(forReadingFrom:url);defer{try? h.close()}
                let end=try h.seekToEnd();var offset:UInt64=0,types:[String]=[]
                while offset+8<=end{
                    try h.seek(toOffset:offset);let head=try h.read(upToCount:16) ?? Data()
                    guard head.count>=8 else{break}
                    var size=head.prefix(4).reduce(UInt64(0)){$0<<8|UInt64($1)}
                    types.append(String(decoding:head[4..<8],as:UTF8.self))
                    if size==1,head.count>=16{size=head[8..<16].reduce(UInt64(0)){$0<<8|UInt64($1)}}else if size==0{size=end-offset}
                    guard size>=8 else{break};offset+=size
                }
                return types
            }
            let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:dir,withIntermediateDirectories:true)
            defer{try? fm.removeItem(at:dir)}
            // Handwritten box headers validate the ordering reader independently of the exporter.
            // This is only a parser fixture, not a playable MP4 or a historical export.
            var headers=Data()
            for type in ["ftyp","mdat","moov"]{headers.append(contentsOf:[0,0,0,8]);headers.append(contentsOf:type.utf8)}
            let headerFixture=dir.appendingPathComponent("box-order.bin");try headers.write(to:headerFixture,options:.withoutOverwriting)
            try expect(try boxes(headerFixture)==["ftyp","mdat","moov"],"Box-order reader changed")
            try fm.copyItem(at:media("Tests/Fixtures/media/av-audio-short-v2.mp4"),to:dir.appendingPathComponent("clip.mp4"))
            func export(_ gains:[Double],_ name:String)async throws->(ExportReport,[String]){
                let p=EditorProject(durationFrames:60,assets:[MediaAsset(id:"v",path:"clip.mp4",kind:.video)],videoClips:[VideoClip(assetID:"v",startFrame:0,durationFrames:60)],
                                    audioClips:gains.enumerated().map{AudioClip(assetID:"v",track:$0.offset,startFrame:0,durationFrames:60,gain:$0.element)})
                let out=dir.appendingPathComponent(name);let report=try await TimelineEngine.export(try await TimelineEngine.compile(project:p,baseURL:dir),to:out){_ in}
                return (report,try boxes(out))
            }
            let (quiet,layout)=try await export([0.5],"quiet.mp4"),(loud,_)=try await export([4,4,4,4],"loud.mp4")
            print("  post-fix boxes: \(layout); quiet peak \(String(format:"%.2f",quiet.peakDBFS)) dBFS, full-scale \(quiet.fullScaleSamples); four tracks ×4 peak \(String(format:"%.2f",loud.peakDBFS)) dBFS, full-scale \(loud.fullScaleSamples)")
            try expect(layout.firstIndex(of:"moov")! < layout.firstIndex(of:"mdat")!,"moov still after mdat")
            try expect(quiet.fullScaleSamples==0 && quiet.clippingWarning==nil && quiet.peakDBFS < -6,"Quiet mix reported as clipped")
            try expect(loud.fullScaleSamples>1000 && loud.clippingWarning?.contains("削波")==true,"Clipped mix not reported")
        }
        try await checkAsync("S7-18 a blank subtitle draws nothing, still opens, and SRT export names the cue"){
            let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:dir,withIntermediateDirectories:true)
            defer{try? fm.removeItem(at:dir)}
            func pixels(_ p:EditorProject,_ frame:Int)async throws->Data{
                let out=dir.appendingPathComponent(UUID().uuidString+".png")
                try await TimelineEngine.frame(try await TimelineEngine.compile(project:p,baseURL:dir),atFrame:frame,fps:30,to:out)
                let cg=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(out as CFURL,nil)!,0,nil)!
                return cg.dataProvider!.data! as Data
            }
            let blank=SubtitleCue(startFrame:0,endFrame:30,text:" \n "),real=SubtitleCue(startFrame:30,endFrame:60,text:"有字")
            let p=EditorProject(durationFrames:60,subtitles:[real,blank]);try p.validate()   // older projects with a blank cue still open
            try expect(blank.isBlank && !real.isBlank,"isBlank wrong")
            let empty=EditorProject(durationFrames:60)
            let withBlank=try await pixels(p,10),without=try await pixels(empty,10),withText=try await pixels(p,40)
            try expect(withBlank==without,"Blank cue still burned a box")
            try expect(withText != without,"Sanity: real cue not drawn")
            var message="";do{_=try SRTCodec.encode(p.subtitles)}catch{message=error.localizedDescription}
            print("  SRT export: \(message)")
            try expect(message.contains("第1条") && message.contains("00:00:00,000") && message.contains("文字为空"),"SRT export error does not locate the cue")
        }
        try check("S7-19 SRT variants: dot milliseconds, one-digit hours, coordinates and style tags; UTF-16/GBK named"){
            let srt="1\n0:00:01.000 --> 0:00:02.500  X1:100 X2:500 Y1:10 Y2:60\n<i>斜体</i> 与 {\\an8}顶部\n\n2\n00:00:03,000 --> 00:00:04,000\n{\\an8}\n第二条 a < b\n"
            let cues=try SRTCodec.parse(srt)
            try expect(cues.map(\.startFrame)==[30,90] && cues.map(\.endFrame)==[75,120],"Variant timing wrong: \(cues.map{($0.startFrame,$0.endFrame)})")
            try expect(cues.map(\.text)==["斜体 与 顶部","第二条 a < b"],"Tags not stripped or literal < damaged: \(cues.map(\.text))")
            let notes=SRTCodec.compatibilityNotes(srt);print("  notes: \(notes)")
            try expect(notes.count==2 && notes[0].contains("1 处") && notes[1].contains("4 个"),"Compatibility notes wrong")
            try expect(SRTCodec.compatibilityNotes("1\n00:00:00,000 --> 00:00:01,000\n普通\n").isEmpty,"Plain SRT produced notes")
            // Still rejected: two-digit milliseconds, a tags-only cue, three text lines after stripping.
            for bad in ["1\n00:00:01,00 --> 00:00:02,000\na","1\n00:00:01,000 --> 00:00:02,000\n<i></i>","1\n00:00:01,000 --> 00:00:02,000\na\n<b>b</b>\nc"]{try rejects{_=try SRTCodec.parse(bad)}}
            let body="1\n00:00:00,000 --> 00:00:01,000\n中文字幕\n"
            func message(_ data:Data)->String{do{_=try SRTCodec.parse(data);return ""}catch{return error.localizedDescription}}
            let utf16=message(Data([0xff,0xfe])+body.data(using:.utf16LittleEndian)!),gbk=message(body.data(using:String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))!),junk=message(Data([0x31,0x0a,0xc3,0x28]))
            print("  UTF-16: \(utf16)\n  GBK: \(gbk)\n  invalid: \(junk)")
            try expect(utf16.contains("UTF-16") && gbk.contains("GBK") && junk.contains("不是有效的 UTF-8"),"Encoding not named")
            try expect(try SRTCodec.parse(Data(("\u{feff}"+body).utf8)).first?.text=="中文字幕","UTF-8 BOM regressed")
        }
        try await checkAsync("S7-20 cancelling during the export fingerprint stage stops hashing promptly"){
            let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:dir,withIntermediateDirectories:true)
            defer{try? fm.removeItem(at:dir)}
            // 512 MB sparse file: real bytes to hash, almost no disk use.
            let big=dir.appendingPathComponent("big.mov");fm.createFile(atPath:big.path,contents:nil)
            let h=try FileHandle(forWritingTo:big);try h.truncate(atOffset:512*1_048_576);try h.close()
            let p=EditorProject(durationFrames:30,assets:[MediaAsset(id:"b",path:"big.mov",kind:.video)])
            func timed(_ body:@escaping @Sendable ()async throws->Void)async->(Double,String){
                let start=Date(),task=Task{try await body()}
                try? await Task.sleep(nanoseconds:30_000_000);task.cancel()
                let outcome:String;do{try await task.value;outcome="completed"}catch is CancellationError{outcome="cancelled"}catch{outcome="error: \(error.localizedDescription)"}
                return (Date().timeIntervalSince(start),outcome)
            }
            // Old pattern in exportVideo: a plain detached task ignores the caller's cancellation.
            let old=await timed{_=try await Task.detached{try AssetStore.fingerprinted(p,baseURL:dir)}.value}
            let new=await timed{_=try await AssetStore.fingerprintedInBackground(p,baseURL:dir)}
            print(String(format:"  old pattern: %.3fs (%@); new: %.3fs (%@)",old.0,old.1,new.0,new.1))
            try expect(old.1=="completed","Baseline unexpectedly honoured cancellation")
            try expect(new.1=="cancelled" && new.0<old.0/2 && new.0<0.5,"Fingerprint stage did not stop on cancel")
        }
        try check("S7-04/S7-06 opening skips rehashing files whose size and modification time match the stamp; export stays strict"){
            let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:dir,withIntermediateDirectories:true)
            defer{try? fm.removeItem(at:dir)}
            let big=dir.appendingPathComponent("big.mov");fm.createFile(atPath:big.path,contents:nil)
            let h=try FileHandle(forWritingTo:big);try h.truncate(atOffset:1024*1_048_576);try h.close()   // 1 GB sparse
            try fm.copyItem(at:media("Tests/Fixtures/media/av-audio-short-v2.mp4"),to:dir.appendingPathComponent("clip.mp4"))
            let legacy=EditorProject(durationFrames:30,assets:[MediaAsset(id:"big",path:"big.mov",kind:.video),MediaAsset(id:"clip",path:"clip.mp4",kind:.video)])
            func timed<T>(_ body:()throws->T)rethrows->(T,Double){let s=Date();let r=try body();return (r,Date().timeIntervalSince(s))}
            // First open of a project without stamps (all pre-step7 projects): every file is read in full.
            let (first,t1)=try timed{try AssetStore.verify(legacy,baseURL:dir)}
            try expect(Set(first.hashed)==["big","clip"] && first.changed.isEmpty && first.project.assets.allSatisfy{$0.byteSize != nil && $0.modifiedAt != nil},"First open did not hash and stamp")
            // Save and reopen: stamps persist, nothing is reread.
            let url=dir.appendingPathComponent("p.json");_=try ProjectStore.save(first.project,from:dir,to:url)
            let (second,t2)=try timed{try AssetStore.verify(ProjectStore.load(url),baseURL:dir)}
            print(String(format:"  open 1 GB + clip: unstamped %.3fs (hashed %d); stamped reopen %.4fs (hashed %d)",t1,first.hashed.count,t2,second.hashed.count))
            try expect(second.hashed.isEmpty && second.changed.isEmpty && t2<t1/10,"Stamped reopen still rehashed")
            try expect(try ProjectStore.semanticHash(first.project,baseURL:dir)==ProjectStore.semanticHash(legacy.withFingerprints(from:first.project),baseURL:dir),"Stamps leaked into semantic hash")
            // A real edit changes the modification time: the file is rehashed and reported as changed.
            let w=try FileHandle(forWritingTo:big);try w.seek(toOffset:4096);try w.write(contentsOf:Data([1,2,3]));try w.close()
            let third=try AssetStore.verify(ProjectStore.load(url),baseURL:dir)
            try expect(third.hashed==["big"] && third.changed==["big"],"Modified file not detected on open")
            // Known limit: same size and a restored modification time hide the change at open,
            // but the strict export/collect check rereads every byte and still refuses.
            try fm.setAttributes([.modificationDate:Date(timeIntervalSinceReferenceDate:first.project.assets[0].modifiedAt!)],ofItemAtPath:big.path)
            let disguised=try AssetStore.verify(ProjectStore.load(url),baseURL:dir)
            try expect(disguised.hashed.isEmpty,"Expected the documented stamp limitation")
            try rejects{_=try AssetStore.fingerprinted(ProjectStore.load(url),baseURL:dir)}
        }
        try await checkAsync("waveform reads survive a refresh storm with cancellation (Core 0.2.0 preview crash)"){
            // Same shape as MediaPreviewCache.refresh during rapid edits: each refresh cancels the
            // previous task mid-read. Core 0.2.0 crashed (cancelReading from the cancelling thread)
            // or stalled (every cooperative thread parked in copyNextSampleBuffer).
            var urls=[URL]()
            for json in ["fixtures/F1.json","fixtures/F2.json"]{
                let file=try media(json),p=try ProjectStore.load(file)
                for a in p.assets where a.kind != .image{urls.append(try p.assetURL(a.id,baseURL:file.deletingLastPathComponent()))}
            }
            let iterations=Int(ProcessInfo.processInfo.environment["CORECHECKS_WAVEFORM_STRESS"] ?? "") ?? 120
            final class Done:Sendable{let value=Atomic<Bool>(false)}
            let done=Done()
            DispatchQueue.global().asyncAfter(deadline:.now()+120){
                if !done.value.load(ordering:.relaxed){print("FAIL waveform refresh storm did not finish in 120 s (reader deadlock)");exit(1)}
            }
            var task:Task<Void,Never>?
            for _ in 0..<iterations{
                task?.cancel()
                task=Task.detached{for u in urls{guard !Task.isCancelled else{return};_=try? await WaveformReader.peaks(url:u,duration:20,bins:400)}}
                try await Task.sleep(nanoseconds:UInt64.random(in:0...20_000_000))
            }
            task?.cancel();await task?.value
            let tone=try media("fixtures/media/tone01.wav")
            let peaks=try expectValue(try await WaveformReader.peaks(url:tone,duration:20,bins:400),"Uncancelled waveform read did not complete")
            done.value.store(true,ordering:.relaxed)
            try expect(peaks.count==400 && (peaks.max() ?? 0)>0.05,"Waveform peaks empty after storm")
            let cancelled=Task{try await WaveformReader.peaks(url:tone,duration:20,bins:400)};cancelled.cancel()
            var threw=false;do{_=try await cancelled.value}catch is CancellationError{threw=true}
            try expect(threw,"Cancelled waveform read did not throw CancellationError")
            print("  \(iterations) cancelled refreshes over \(urls.count) F1/F2 sources")
        }
        try await checkAsync("export cancelled at random points stops cleanly, leaves no file, never crashes"){
            // Cancelling an export must not tear the AVAssetReader down while a drain queue is
            // inside copyNextSampleBuffer (same race class as the Core 0.2.0 preview crash).
            let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? fm.removeItem(at:dir)}
            let f1=try media("fixtures/F1.json"),compiled=try await TimelineEngine.compile(project:ProjectStore.load(f1),baseURL:f1.deletingLastPathComponent())
            let iterations=Int(ProcessInfo.processInfo.environment["CORECHECKS_EXPORT_CANCEL_STRESS"] ?? "") ?? 8
            var cancelled=0,completed=0,slowest=0.0
            for i in 0..<iterations{
                let target=dir.appendingPathComponent("cancel-\(i).mp4")
                // Cancel only once the drain queues are reading (first video progress), then at a
                // random point within the next 80 ms, so the cancel lands mid-copyNextSampleBuffer.
                final class Started:Sendable{let value=Atomic<Bool>(false)}
                let started=Started()
                let task=Task.detached{try await TimelineEngine.export(compiled,to:target){p in if p>0{started.value.store(true,ordering:.relaxed)}}}
                while !started.value.load(ordering:.relaxed){try await Task.sleep(nanoseconds:1_000_000)}
                try await Task.sleep(nanoseconds:UInt64.random(in:0...80_000_000));task.cancel()
                let cancelAt=ProcessInfo.processInfo.systemUptime;defer{slowest=max(slowest,ProcessInfo.processInfo.systemUptime-cancelAt)}
                do{_=try await task.value;completed+=1;try? fm.removeItem(at:target)}
                catch is CancellationError{cancelled+=1;try expect(!fm.fileExists(atPath:target.path),"Cancelled export left \(target.lastPathComponent)")}
            }
            try expect((try fm.contentsOfDirectory(atPath:dir.path)).isEmpty,"Cancelled exports left files: \(try fm.contentsOfDirectory(atPath:dir.path))")
            print(String(format:"  %d exports of F1 cancelled 0–80 ms into reading: %d cancelled, %d completed; slowest cancel %.3fs",iterations,cancelled,completed,slowest))
            try expect(slowest<5,"Export cancellation took \(slowest) s")
        }
        try check("release test and unbundled builds keep independent autosave folders"){
            // Bundle-specific recovery prevents a test build from writing another app's autosave.
            let home=URL(fileURLWithPath:"/test-home"),support="/test-home/Library/Application Support/"
            func folder(_ id:String?,_ env:[String:String]=[:])->String{RecoveryStore.supportFolder(bundleID:id,environment:env,home:home).path}
            try expect(folder(RecoveryStore.coreBundleID)==support+"io.github.jianfang.editor","Release recovery folder is not isolated")
            try expect(folder("io.github.jianfang.uicheck")==support+"io.github.jianfang.uicheck","Test build shares another folder")
            try expect(folder("io.github.jianfang.test")==support+"io.github.jianfang.test","Test build shares release folder")
            for unbundled in [nil,"","../escape","a/b"]{try expect(folder(unbundled)==support+"Jianfang-Dev","Unbundled or unsafe ID not isolated: \(String(describing:unbundled))")}
            try expect(folder(RecoveryStore.coreBundleID,["JF_SUPPORT_DIR":"/tmp/jf-check"])=="/tmp/jf-check","Override ignored")
            try expect(folder(RecoveryStore.coreBundleID,["JF_SUPPORT_DIR":"relative"])==support+"io.github.jianfang.editor","Relative override accepted")
        }
        /// A process ID nothing is using right now, standing in for a crashed export.
        func deadPID()throws->Int32{try expectValue((Int32(90_000)...Int32(99_990)).first{!ExportJournal.processIsRunning($0)},"No free process ID")}
        try check("owned crashed exports and writer-only remnants are swept; active and legacy records stay"){
            let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString),journal=root.appendingPathComponent("export-journal")
            try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
            let dead=try deadPID(),me=ProcessInfo.processInfo.processIdentifier
            let crashed=try ExportJournal.prepare(near:root,journal:journal,pid:dead,useSystemStaging:false)
            try Data(count:1000).write(to:crashed.temporary)
            try Data(count:500).write(to:URL(fileURLWithPath:crashed.temporary.path+".sb-1"))
            let writerOnly=try ExportJournal.prepare(near:root,journal:journal,pid:dead,useSystemStaging:false)
            try Data(count:2300).write(to:URL(fileURLWithPath:writerOnly.temporary.path+".sb-1"))
            let running=try ExportJournal.prepare(near:root,journal:journal,pid:me,useSystemStaging:false)
            try Data(count:100).write(to:running.temporary)
            let legacy=root.appendingPathComponent(".legacy.partial.mp4");try Data(count:700).write(to:legacy)
            let old:[String:Any] = ["pid":dead,"staging":legacy.absoluteString,"started":0]
            try JSONSerialization.data(withJSONObject:old).write(to:journal.appendingPathComponent("legacy.json"))
            try Data("not json".utf8).write(to:journal.appendingPathComponent("broken.json"))
            let report=ExportJournal.sweep(journal)
            try expect(!fm.fileExists(atPath:crashed.entry.staging.path) && !fm.fileExists(atPath:writerOnly.entry.staging.path),"Owned remnants survived, including the writer-only remnant")
            try expect(report.bytes==3800,"Only successfully removed payload bytes should be reported: \(report.bytes)")
            try expect(fm.fileExists(atPath:running.temporary.path) && fm.fileExists(atPath:legacy.path),"Active or legacy files were touched")
            try expect(report.kept==3 && (try fm.contentsOfDirectory(atPath:journal.path)).count==3,"Active, legacy and malformed records must be retained")
        }
        try check("system replacement staging is cleaned without read-opening its shared parent"){
            let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString),journal=root.appendingPathComponent("export-journal")
            try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
            let work=try ExportJournal.prepare(near:root,journal:journal)
            try Data(count:128).write(to:work.temporary)
            let report=ExportJournal.finish(work)
            try expect(report.kept==0 && report.bytes==128 && !fm.fileExists(atPath:work.entry.staging.path) && !fm.fileExists(atPath:work.journalFile!.path),"System replacement staging was not cleaned: \(work.entry.staging.path)")
        }
        try check("only valid task-specific AppleDouble sidecars are removed"){
            let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString),journal=root.appendingPathComponent("export-journal")
            try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
            let work=try ExportJournal.prepare(near:root,journal:journal,useSystemStaging:false)
            try Data(count:128).write(to:work.temporary)
            let sidecar=work.entry.staging.appendingPathComponent("._"+work.temporary.lastPathComponent)
            try Data("unrelated user data".utf8).write(to:sidecar)
            try expect(ExportJournal.finish(work).kept==1 && fm.fileExists(atPath:sidecar.path),"Invalid sidecar was treated as disposable metadata")
            let valid=Data([0x00,0x05,0x16,0x07,0x00,0x02,0x00,0x00])+Data(count:18)
            try valid.write(to:sidecar)
            try valid.write(to:work.entry.staging.appendingPathComponent("._.jianfang-work-owner.json"))
            let unknown=work.entry.staging.appendingPathComponent("._unrelated.mp4");try valid.write(to:unknown)
            try expect(ExportJournal.finish(work).kept==1 && fm.fileExists(atPath:unknown.path),"Unrelated valid metadata was removed")
            try fm.removeItem(at:unknown)
            try expect(ExportJournal.finish(work).kept==0 && !fm.fileExists(atPath:work.entry.staging.path),"Valid owned metadata prevented cleanup")
        }
        try check("failed cleanup retains its journal and reports no space freed"){
            let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString),journal=root.appendingPathComponent("export-journal")
            try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
            let work=try ExportJournal.prepare(near:root,journal:journal,pid:try deadPID(),useSystemStaging:false)
            try Data(count:1234).write(to:work.temporary)
            // Unknown content forces a conservative refusal even when run by a privileged test user.
            let keep=work.entry.staging.appendingPathComponent("keep-user-file.txt");try Data("keep".utf8).write(to:keep)
            let refused=ExportJournal.finish(work)
            try expect(refused.kept==1 && refused.bytes==0 && refused.removed.isEmpty,"Refused cleanup claimed success")
            try expect(fm.fileExists(atPath:work.journalFile!.path) && fm.fileExists(atPath:work.temporary.path) && fm.fileExists(atPath:keep.path),"Refused cleanup discarded data or its journal")
            try fm.removeItem(at:keep)
            if getuid() != 0 {
                try fm.setAttributes([.posixPermissions:0o500],ofItemAtPath:work.entry.staging.path)
                let failed=ExportJournal.finish(work)
                try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:work.entry.staging.path)
                try expect(failed.kept==1 && failed.bytes==0 && failed.removed.isEmpty && fm.fileExists(atPath:work.journalFile!.path),"A failed unlink lost its journal or claimed freed bytes")
            }
            let retry=ExportJournal.finish(work)
            try expect(retry.kept==0 && retry.bytes==1234 && !fm.fileExists(atPath:work.journalFile!.path),"Cleanup could not retry after the obstruction was removed")
        }
        try check("unavailable staging parent retains the journal until the same location returns"){
            let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString),journal=root.appendingPathComponent("export-journal"),out=root.appendingPathComponent("out"),parked=root.appendingPathComponent("temporarily-away")
            try fm.createDirectory(at:out,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
            let work=try ExportJournal.prepare(near:out,journal:journal,pid:try deadPID(),useSystemStaging:false)
            try Data(count:32).write(to:work.temporary);try fm.moveItem(at:out,to:parked)
            let missing=ExportJournal.finish(work)
            try expect(missing.kept==1 && fm.fileExists(atPath:work.journalFile!.path),"Unavailable volume/directory lost its cleanup record")
            try fm.moveItem(at:parked,to:out)
            let returned=ExportJournal.sweep(journal)
            try expect(returned.kept==0 && returned.bytes==32 && !fm.fileExists(atPath:work.journalFile!.path),"Cleanup failed after the recorded directory returned")
        }
        try check("cleanup rejects symbolic links in the parent path and payloads"){
            let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString),journal=root.appendingPathComponent("export-journal"),out=root.appendingPathComponent("out"),moved=root.appendingPathComponent("moved")
            try fm.createDirectory(at:out,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
            let work=try ExportJournal.prepare(near:out,journal:journal,pid:try deadPID(),useSystemStaging:false)
            try Data(count:64).write(to:work.temporary);try fm.moveItem(at:out,to:moved);try fm.createSymbolicLink(at:out,withDestinationURL:moved)
            let linked=ExportJournal.sweep(journal)
            try expect(linked.kept==1 && linked.removed.isEmpty && fm.fileExists(atPath:work.temporary.path),"Cleanup followed a replaced parent symlink")
            try fm.removeItem(at:out);try fm.moveItem(at:moved,to:out)
            let victim=root.appendingPathComponent("user-video.mp4");try Data(count:80).write(to:victim)
            let sibling=URL(fileURLWithPath:work.temporary.path+".sb-link");try fm.createSymbolicLink(at:sibling,withDestinationURL:victim)
            let payload=ExportJournal.sweep(journal)
            try expect(payload.kept==1 && payload.bytes==0 && fm.fileExists(atPath:victim.path) && fm.fileExists(atPath:work.temporary.path),"Cleanup accepted a payload symlink")
            try fm.removeItem(at:sibling);_=ExportJournal.finish(work)
        }
        try check("a copied marker does not authorize deleting a replacement directory"){
            let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString),journal=root.appendingPathComponent("export-journal")
            try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
            let work=try ExportJournal.prepare(near:root,journal:journal,pid:try deadPID(),useSystemStaging:false)
            let original=root.appendingPathComponent("original");try fm.moveItem(at:work.entry.staging,to:original)
            try fm.createDirectory(at:work.entry.staging,withIntermediateDirectories:false)
            try fm.copyItem(at:original.appendingPathComponent(".jianfang-work-owner.json"),to:work.entry.staging.appendingPathComponent(".jianfang-work-owner.json"))
            try Data(count:512).write(to:work.temporary)
            let report=ExportJournal.sweep(journal)
            try expect(report.kept==1 && report.bytes==0 && fm.fileExists(atPath:work.temporary.path),"Copied marker bypassed directory identity validation")
        }
        try check("a mismatched recorded volume cannot authorize cleanup"){
            let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString),journal=root.appendingPathComponent("export-journal")
            try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
            let work=try ExportJournal.prepare(near:root,journal:journal,pid:try deadPID(),useSystemStaging:false)
            try Data(count:128).write(to:work.temporary)
            var json=try JSONSerialization.jsonObject(with:Data(contentsOf:work.journalFile!)) as! [String:Any]
            var parent=json["parentIdentity"] as! [String:Any];parent["volumeUUID"]=UUID().uuidString;json["parentIdentity"]=parent
            let changed=try JSONSerialization.data(withJSONObject:json)
            try changed.write(to:work.journalFile!);try changed.write(to:work.entry.staging.appendingPathComponent(".jianfang-work-owner.json"))
            let report=ExportJournal.sweep(journal)
            try expect(report.kept==1 && report.bytes==0 && fm.fileExists(atPath:work.temporary.path),"Volume identity mismatch was ignored")
        }
        try check("only marked carrier folders of ended processes are removed; legacy and active folders stay"){
            let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
            let dead=try deadPID(),me=ProcessInfo.processInfo.processIdentifier
            let ended=try ExportJournal.createCarrierFolder(in:root,pid:dead),active=try ExportJournal.createCarrierFolder(in:root,pid:me)
            try Data(count:64).write(to:ended.appendingPathComponent("carrier-\(UUID().uuidString).mp4"))
            let legacy=root.appendingPathComponent("IndependentEditor-\(dead)");try fm.createDirectory(at:legacy,withIntermediateDirectories:false)
            let report=TimelineEngine.sweepStaleCarrierFolders(in:root)
            try expect(report==1 && !fm.fileExists(atPath:ended.path),"Marked ended carrier was not cleaned")
            try expect(fm.fileExists(atPath:active.path) && fm.fileExists(atPath:legacy.path),"Active or unmarked carrier was removed")
            // Enumerating a root through a symlink must work, but a symlink posing as a child
            // carrier folder must never authorize deleting its otherwise valid destination.
            let alias=root.appendingPathComponent("root-alias");try fm.createSymbolicLink(at:alias,withDestinationURL:root)
            let aliased=try ExportJournal.createCarrierFolder(in:alias,pid:dead)
            try expect(TimelineEngine.sweepStaleCarrierFolders(in:alias)==1 && !fm.fileExists(atPath:aliased.path),"Canonical root aliases prevented owned carrier cleanup")
            let outside=root.appendingPathComponent("outside");try fm.createDirectory(at:outside,withIntermediateDirectories:false)
            let protected=try ExportJournal.createCarrierFolder(in:outside,pid:dead)
            let childLink=root.appendingPathComponent("IndependentEditor-linked");try fm.createSymbolicLink(at:childLink,withDestinationURL:protected)
            try expect(TimelineEngine.sweepStaleCarrierFolders(in:root)==0 && fm.fileExists(atPath:protected.path),"A child symlink authorized cleanup outside the enumerated root")
        }
        try await checkAsync("a 10-minute export cancelled halfway leaves no file, no staging and no journal entry"){
            let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString),journal=dir.appendingPathComponent("export-journal")
            try fm.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? fm.removeItem(at:dir)}
            let f2=try media("fixtures/F2.json"),compiled=try await TimelineEngine.compile(project:ProjectStore.load(f2),baseURL:f2.deletingLastPathComponent())
            final class Percent:Sendable{let value=Atomic<Int>(0);let finished=Atomic<Bool>(false)}
            let percent=Percent(),target=dir.appendingPathComponent("F2.mp4"),began=Date()
            let task=Task.detached{defer{percent.finished.store(true,ordering:.releasing)};return try await TimelineEngine.export(compiled,to:target,journal:journal){p in percent.value.store(Int(p*100),ordering:.relaxed)}}
            while percent.value.load(ordering:.relaxed)<50 && !percent.finished.load(ordering:.acquiring) && Date().timeIntervalSince(began)<300{try await Task.sleep(nanoseconds:50_000_000)}
            guard percent.value.load(ordering:.relaxed)>=50 else{
                if percent.finished.load(ordering:.acquiring){_=try await task.value;throw ProjectError.invalid("Long export ended before the requested cancellation point")}
                let reached=percent.value.load(ordering:.relaxed);task.cancel();_=try? await task.value
                throw ProjectError.invalid("Long export reached only \(reached) percent within five minutes")
            }
            let entries=try fm.contentsOfDirectory(at:journal,includingPropertiesForKeys:nil)
            try expect(entries.count==1,"Running export not recorded in the journal")
            let staging=try JSONDecoder().decode(ExportJournal.Entry.self,from:Data(contentsOf:entries[0])).staging
            try expect(fm.fileExists(atPath:staging.path),"Journal points at a staging area that does not exist")
            let reached=Date().timeIntervalSince(began);task.cancel();let cancelAt=Date()
            var cancelled=false;do{_=try await task.value}catch is CancellationError{cancelled=true}
            let took=Date().timeIntervalSince(cancelAt)
            try expect(cancelled,"Halfway cancel did not end as a cancellation")
            try expect(!fm.fileExists(atPath:target.path) && !fm.fileExists(atPath:staging.path),"Cancelled long export left a file or its staging area")
            try expect((try fm.contentsOfDirectory(atPath:journal.path)).isEmpty,"Journal entry left after a clean cancel")
            try expect(took<5,"Halfway cancel took \(took) s")
            print(String(format:"  F2 (10 min) reached 50%% after %.1fs; cancel finished in %.3fs",reached,took))
        }
        print("CORE CHECKS: \(passed) PASS, 0 FAIL")
    }
}
