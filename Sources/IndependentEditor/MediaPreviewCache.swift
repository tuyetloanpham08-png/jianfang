import AppKit
import AVFoundation
import EditorCore
import MediaEngine

struct PreviewThumbnail: @unchecked Sendable {let frame:Int;let image:NSImage}
struct PreviewWaveform: Sendable {let durationFrames:Int;let peaks:[Float]}
struct PreviewVisual: @unchecked Sendable {let thumbnails:[PreviewThumbnail];let waveform:PreviewWaveform?}

@MainActor final class MediaPreviewCache {
    var stored=[String:PreviewVisual](),task:Task<Void,Never>?
    func refresh(project:EditorProject,baseURL:URL,completion:@escaping([String:[PreviewThumbnail]],[String:PreviewWaveform])->Void){
        task?.cancel();let assets=project.assets
        task=Task{var thumbs=[String:[PreviewThumbnail]](),waves=[String:PreviewWaveform]()
            for asset in assets{
                guard !Task.isCancelled else{return}
                guard let url=try? project.assetURL(asset.id,baseURL:baseURL),FileManager.default.isReadableFile(atPath:url.path) else{continue}
                let attrs=try? FileManager.default.attributesOfItem(atPath:url.path)
                let key=url.path+"|"+String(describing:attrs?[.modificationDate])+"|"+String(describing:attrs?[.size])
                let result:PreviewVisual
                if let found=stored[key]{result=found}else{
                    let worker=Task.detached(priority:.utility){await Self.generate(url,kind:asset.kind)}
                    // Detached tasks do not inherit cancellation from this refresh task.
                    result=await withTaskCancellationHandler(operation:{await worker.value},onCancel:{worker.cancel()})
                    guard !Task.isCancelled else{return}
                    if stored.count>50{stored.removeAll()};stored[key]=result
                }
                guard !Task.isCancelled else{return}
                thumbs[asset.id]=result.thumbnails;if let wave=result.waveform{waves[asset.id]=wave};completion(thumbs,waves)
            }
        }
    }
    nonisolated private static func frameIndex(_ seconds:Double)->Int?{
        let rounded=(seconds*30).rounded()
        guard rounded.isFinite,rounded>=0,rounded<Double(Int.max) else{return nil}
        return Int(rounded)
    }
    nonisolated static func generate(_ url:URL,kind:AssetKind) async->PreviewVisual{
        let empty=PreviewVisual(thumbnails:[],waveform:nil)
        guard !Task.isCancelled else{return empty}
        if kind == .image{
            if let image=NSImage(contentsOf:url),!Task.isCancelled{return PreviewVisual(thumbnails:[PreviewThumbnail(frame:0,image:image)],waveform:nil)}
            return empty
        }
        let asset=AVURLAsset(url:url);var thumbs=[PreviewThumbnail]()
        let duration=(try? await asset.load(.duration).seconds) ?? 0
        guard !Task.isCancelled,duration.isFinite,duration>0,let durationFrames=frameIndex(duration) else{return empty}
        if let videos=try? await asset.loadTracks(withMediaType:.video),!videos.isEmpty,!Task.isCancelled{
            let generator=AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:160,height:90)
            for sec in [0.0,duration/2,max(0,duration-0.2)]{
                guard !Task.isCancelled else{return empty}
                let generated=await withTaskCancellationHandler(operation:{try? await generator.image(at:CMTime(seconds:sec,preferredTimescale:600))},onCancel:{generator.cancelAllCGImageGeneration()})
                if let (image,_)=generated,let frame=frameIndex(sec),!Task.isCancelled{thumbs.append(PreviewThumbnail(frame:frame,image:NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height))))}
            }
        }
        guard !Task.isCancelled else{return empty}
        // Waveforms are optional UI aids. Never decode hours of an imported source for a
        // ten-minute editor, or publish a truncated waveform as if it described the whole source.
        guard duration<=600 else{return PreviewVisual(thumbnails:thumbs,waveform:nil)}
        // Read on MediaEngine's serial waveform queue: never cancelReading() from this task's
        // cancellation handler while another thread is inside copyNextSampleBuffer (Core 0.2.0 crash).
        let peaks=try? await WaveformReader.peaks(url:url,duration:duration,bins:max(60,min(6000,Int(duration*20))))
        let waveform=peaks.flatMap{$0}.map{PreviewWaveform(durationFrames:durationFrames,peaks:$0)}
        return Task.isCancelled ? empty:PreviewVisual(thumbnails:thumbs,waveform:waveform)
    }
}
