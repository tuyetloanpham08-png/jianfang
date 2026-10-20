import Foundation
import AppKit
import AVFoundation
import CoreImage
import QuartzCore
import EditorCore
import MediaEngine

@main struct Program {
    @MainActor static func main() async {
        let args=Array(CommandLine.arguments.dropFirst())
        if args.isEmpty {
            let app=NSApplication.shared
            let controller=EditorController()
            controller.show()
            withExtendedLifetime(controller) { app.run() }
            return
        }
        do {
            if args.first=="app-icon"{
                // Build step: app-icon 输出.iconset (then iconutil -c icns), see scripts/build_release_app.sh.
                guard args.count==2 else{throw ProjectError.invalid("app-icon 需要输出 .iconset 目录")}
                try AppMarkView.writeIconSet(to:URL(fileURLWithPath:args[1]).standardizedFileURL);print("APP_ICONSET \(args[1])");return
            }
            // Same per-build folder the app uses (JF_SUPPORT_DIR overrides), so the CLI shares its export journal.
            let journal=RecoveryStore.supportFolder(bundleID:Bundle.main.bundleIdentifier,environment:ProcessInfo.processInfo.environment,home:URL(fileURLWithPath:NSHomeDirectory())).appendingPathComponent("export-journal",isDirectory:true)
            if args.first=="sweep-exports"{
                // What the app does at launch: remove partial exports left by crashed or killed runs.
                let report=ExportJournal.sweep(journal);let carriers=TimelineEngine.sweepStaleCarrierFolders()
                for u in report.removed{print("REMOVED \(u.path)")}
                print("SWEPT removed=\(report.removed.count) bytes=\(report.bytes) kept=\(report.kept) carrier_folders=\(carriers)");return
            }
            guard args.count>=2 else {throw ProjectError.invalid("用法: IndependentEditor validate|export|frame|roundtrip|preview-probe 工程.json [输出路径/帧号]")}
            let url=URL(fileURLWithPath:args[1]).standardizedFileURL
            let project=try ProjectStore.load(url), base=url.deletingLastPathComponent()
            switch args[0] {
            case "ui-snapshot":
                // Diagnostic: ui-snapshot 工程.json 输出.png light|dark [welcome]
                guard args.count>=4,["light","dark"].contains(args[3]) else{throw ProjectError.invalid("ui-snapshot 需要输出 PNG 路径和 light 或 dark")}
                let destination=URL(fileURLWithPath:args[2]).standardizedFileURL
                guard !FileManager.default.fileExists(atPath:destination.path) else{throw ProjectError.invalid("不覆盖已有截图")}
                _=NSApplication.shared;let controller=EditorController()
                try await controller.snapshot(project:url,to:destination,dark:args[3]=="dark",welcomeOnly:args.count>4 && args[4]=="welcome")
                print("UI_SNAPSHOT \(destination.path)")
            case "validate":
                let compiled=try await TimelineEngine.compile(project:project,baseURL:base)
                print("VALID \(project.name) duration=\(compiled.duration.seconds)s hash=\(try ProjectStore.semanticHash(project,baseURL:base))")
            case "roundtrip":
                guard args.count==3 else{throw ProjectError.invalid("roundtrip 需要输出 JSON 路径")}
                let destination=URL(fileURLWithPath:args[2]).standardizedFileURL
                guard !FileManager.default.fileExists(atPath:destination.path) else{throw ProjectError.invalid("不覆盖已有工程")}
                let before=try ProjectStore.semanticHash(project,baseURL:base)
                _=try ProjectStore.save(project,from:base,to:destination)
                let reopened=try ProjectStore.load(destination)
                let after=try ProjectStore.semanticHash(reopened,baseURL:destination.deletingLastPathComponent())
                guard before==after else{throw ProjectError.invalid("保存重开语义不一致")}
                print("ROUNDTRIP PASS \(before)")
            case "export":
                guard args.count==3 else{throw ProjectError.invalid("export 需要输出 MP4 路径")}
                let start=Date();let verified=try await Task.detached{try AssetStore.fingerprinted(project,baseURL:base)}.value;let compiled=try await TimelineEngine.compile(project:verified,baseURL:base)
                print("COMPILED seconds=\(Date().timeIntervalSince(start))");fflush(stdout)
                let meter=ProgressMeter()
                let report=try await TimelineEngine.export(compiled,to:URL(fileURLWithPath:args[2]),journal:journal) {p in meter.update(p)}
                print("EXPORTED elapsed_seconds=\(Date().timeIntervalSince(start)) output=\(args[2])")
                print(String(format:"AUDIO_MIX peak_dbfs=%.2f full_scale_samples=%d",report.peakDBFS,report.fullScaleSamples))
                if let warning=report.clippingWarning{print("WARNING: \(warning)")}
            case "open-timing":
                // The identity check the GUI runs when opening: which assets had to be fully rehashed.
                let start=Date();let result=try AssetStore.verify(project,baseURL:base)
                print(String(format:"OPEN seconds=%.3f assets=%d hashed=%d changed=%d",Date().timeIntervalSince(start),project.assets.count,result.hashed.count,result.changed.count))
            case "compile-timing":
                // Same-process repeated compiles: shows the cost an edit pays, with the CFR scan cache.
                let runs=args.count>2 ? max(1,Int(args[2]) ?? 3):3
                for run in 1...runs {
                    let start=Date();_=try await TimelineEngine.compile(project:project,baseURL:base)
                    let counts=TimelineEngine.cfrScanCounts
                    print(String(format:"COMPILE %d seconds=%.3f cfr_scans=%d cache_hits=%d",run,Date().timeIntervalSince(start),counts.scans,counts.hits));fflush(stdout)
                }
            case "frame":
                guard args.count==4,let frame=Int(args[2]),frame>=0,frame<project.durationFrames else{throw ProjectError.invalid("frame 需要有效帧号和 PNG 路径")}
                let compiled=try await TimelineEngine.compile(project:project,baseURL:base)
                try await TimelineEngine.frame(compiled,atFrame:frame,fps:project.fps,to:URL(fileURLWithPath:args[3]))
                print("FRAME \(frame) \(args[3])")
            case "preview-probe":
                guard args.count>=3 else{throw ProjectError.invalid("preview-probe 需要报告路径，可选播放秒数；0 只测 50 次定位")}
                let reportFolder=URL(fileURLWithPath:args[2]).standardizedFileURL.deletingLastPathComponent()
                for target in [URL(fileURLWithPath:args[2]).standardizedFileURL,reportFolder.appendingPathComponent("delivered-frames.csv"),reportFolder.appendingPathComponent("preview-frames")] where FileManager.default.fileExists(atPath:target.path){throw ProjectError.invalid("不覆盖已有证据，请换新的报告目录：\(target.path)")}
                _=NSApplication.shared
                let compiled=try await TimelineEngine.compile(project:project,baseURL:base)
                let seconds=args.count>3 ? Double(args[3]) ?? compiled.duration.seconds:compiled.duration.seconds
                let selectedFrames:[Int]? = args.count>4 ? try JSONDecoder().decode([Int].self,from:Data(contentsOf:URL(fileURLWithPath:args[4]))):nil
                if let selectedFrames,selectedFrames.count<30 || selectedFrames.count>50 || selectedFrames.contains(where:{$0<0 || $0>=project.durationFrames}){throw ProjectError.invalid("预览帧列表须有30至50个有效项目帧号")}
                try await PreviewProbe.run(compiled:compiled,project:project,seconds:seconds,reportURL:URL(fileURLWithPath:args[2]),selectedFrames:selectedFrames)
            default: throw ProjectError.invalid("未知命令：\(args[0])")
            }
        } catch {fputs("ERROR: \(error.localizedDescription)\n",stderr);exit(1)}
    }
}
final class ProgressMeter: @unchecked Sendable {
    let lock=NSLock();var bucket = -1
    func update(_ progress:Double){lock.lock();defer{lock.unlock()};let next=Int(progress*20);if next>bucket{bucket=next;print("PROGRESS \(min(100,next*5))%");fflush(stdout)}}
}

@MainActor enum PreviewProbe {
    static func run(compiled:CompiledTimeline,project:EditorProject,seconds:Double,reportURL:URL,selectedFrames:[Int]?=nil) async throws {
        let item=AVPlayerItem(asset:compiled.composition);item.videoComposition=compiled.videoComposition;item.audioMix=compiled.audioMix
        let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        item.add(output)
        let player=AVPlayer(playerItem:item);player.isMuted=true;player.actionAtItemEnd = .pause
        let readyStart=CACurrentMediaTime()
        while item.status == .unknown && CACurrentMediaTime()-readyStart<30 {try await Task.sleep(nanoseconds:5_000_000)}
        guard item.status == .readyToPlay else{throw item.error ?? ProjectError.invalid("预览未就绪")}
        var frames=Set<Int>(),gaps=[Double](),lastWall:Double?,firstWall:Double?,lastProgress = -1
        var deliveredRows=["frame,media_seconds,host_monotonic_seconds"]
        let targetDuration=min(max(0,seconds),compiled.duration.seconds)
        if targetDuration>0 {
            player.play()
            let deadline=CACurrentMediaTime()+targetDuration+20
            while CACurrentMediaTime()<deadline {
                let host=CACurrentMediaTime(),time=output.itemTime(forHostTime:host)
                if output.hasNewPixelBuffer(forItemTime:time) {
                    var display=CMTime.invalid
                    if let _=output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&display),display.isValid {
                        let frame=Int((display.seconds*Double(project.fps)).rounded())
                        if frame>=0,frame<project.durationFrames,frames.insert(frame).inserted {
                            deliveredRows.append("\(frame),\(display.seconds),\(host)")
                            if let lastWall{gaps.append(host-lastWall)}
                            lastWall=host;if firstWall==nil{firstWall=host}
                        }
                    }
                }
                let current=player.currentTime().seconds
                let progress=Int(current/30)
                if progress>lastProgress{lastProgress=progress;print("PREVIEW \(Int(current)) / \(Int(targetDuration))s frames=\(frames.count)");fflush(stdout)}
                if current>=targetDuration-0.001 {break}
                if item.status == .failed{throw item.error ?? ProjectError.invalid("播放失败")}
                try await Task.sleep(nanoseconds:3_000_000)
            }
            player.pause()
        }
        let endedTime=player.currentTime().seconds
        var seeks=[[String:Any]]()
        let shots=reportURL.deletingLastPathComponent().appendingPathComponent("preview-frames")
        try FileManager.default.createDirectory(at:shots,withIntermediateDirectories:false)
        let context=CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.linearSRGB)!])
        for index in 0..<50 {
            let keyFrames=selectedFrames ?? [0,14,15,30,74,75,89,90,119,120,149,150,239,240,269,270,359,360,389,390,479,480,719,720,749,750,839,840,project.durationFrames/2,project.durationFrames-1].filter{$0<project.durationFrames}
            let frame=index<keyFrames.count ? keyFrames[index]:(index*7919+17)%project.durationFrames
            let target=CMTime(value:Int64(frame),timescale:Int32(project.fps)),start=CACurrentMediaTime()
            let finished=await withCheckedContinuation { (continuation:CheckedContinuation<Bool,Never>) in player.seek(to:target,toleranceBefore:.zero,toleranceAfter:.zero){continuation.resume(returning:$0)} }
            var buffer:CVPixelBuffer?,actual=CMTime.invalid
            while CACurrentMediaTime()-start<5 {
                if output.hasNewPixelBuffer(forItemTime:target),let pixel=output.copyPixelBuffer(forItemTime:target,itemTimeForDisplay:&actual),actual.isValid,Int((actual.seconds*30).rounded())==frame{buffer=pixel;break}
                try await Task.sleep(nanoseconds:2_000_000)
            }
            let ms=(CACurrentMediaTime()-start)*1000
            seeks.append(["target_frame":frame,"actual_frame":actual.isValid ? Int((actual.seconds*30).rounded()):-1,"milliseconds":ms,"seek_completed":finished,"frame_received":buffer != nil])
            if index<30,let buffer {
                let ci=CIImage(cvPixelBuffer:buffer)
                try context.writePNGRepresentation(of:ci,to:shots.appendingPathComponent("frame-\(frame).png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            }
        }
        let latencies=seeks.compactMap{$0["milliseconds"] as? Double}.sorted()
        let expected=Int((targetDuration*30).rounded()),missing=max(0,expected-frames.filter{$0<expected}.count)
        let report:[String:Any]=[
            "project":project.name,"method":"AVPlayer + AVPlayerItemVideoOutput; muted audio; display buffer polling 3ms; 50 exact seeks wait for delivered frame",
            "duration_requested_seconds":targetDuration,"playback_end_seconds":endedTime,
            "expected_frames":expected,"received_distinct_frames":frames.count,"missing_frames":missing,
            "missing_frame_ratio":expected>0 ? Double(missing)/Double(expected):0,
            "maximum_delivery_gap_ms":(gaps.max() ?? 0)*1000,
            "delivery_wall_seconds":(lastWall ?? 0)-(firstWall ?? 0),
            "seek_p95_ms":latencies[Int(ceil(Double(latencies.count)*0.95))-1],"seeks":seeks,
            "startup_excluded":true,"physical_display_refresh_measured":false,"ui_input_latency_measured":false
        ]
        try Data(deliveredRows.joined(separator:"\n").utf8).write(to:reportURL.deletingLastPathComponent().appendingPathComponent("delivered-frames.csv"),options:.withoutOverwriting)
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:reportURL,options:.withoutOverwriting)
        print("PREVIEW_REPORT \(reportURL.path) dropped=\(missing)/\(expected) max_gap_ms=\((gaps.max() ?? 0)*1000) seek_p95_ms=\(latencies[47])")
        player.replaceCurrentItem(with:nil)
    }
}
