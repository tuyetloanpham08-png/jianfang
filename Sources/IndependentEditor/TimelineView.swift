import AppKit
import EditorCore

@MainActor final class TimelineView:NSView {
    var project=EditorProject(durationFrames:1),position:Double=0
    var selected:ClipSelection?
    var thumbnails=[String:[PreviewThumbnail]](),waveforms=[String:PreviewWaveform]()
    var onSelect:((ClipSelection?)->Void)?,onSeek:((Int)->Void)?,onMove:((ClipSelection,Int,Int)->Void)?,onTrim:((ClipSelection,Int,Int)->Void)?
    /// Track rows, top to bottom: V1, V2, A1–A4, 字幕. The fixed header column beside the
    /// scroll view lines up with these values, so they are shared.
    static let top:CGFloat=24,rowHeight:CGFloat=30,trackCount=7
    static var contentHeight:CGFloat{top+CGFloat(trackCount)*rowHeight+6}
    private let left:CGFloat=8,top=TimelineView.top,rowHeight=TimelineView.rowHeight
    private var downPoint=NSPoint.zero,dragChoice:ClipSelection?,dragMode=0,dragStart=0,dragDuration=0,dragTrack=0,dragDelta=0,dragRow=0,didDrag=false
    override var isFlipped:Bool{true}
    var scale:CGFloat{max(1,bounds.width-left-12)/CGFloat(max(1,project.durationFrames))}
    func interval(_ selection:ClipSelection)->(Int,Int,Int)?{
        switch selection{
        case .video(let id):return project.videoClips.first{$0.id==id}.map{($0.startFrame,$0.durationFrames,$0.track)}
        case .audio(let id):return project.audioClips.first{$0.id==id}.map{($0.startFrame,$0.durationFrames,$0.track+2)}
        case .subtitle(let id):return project.subtitles.first{$0.id==id}.map{($0.startFrame,$0.endFrame-$0.startFrame,6)}
        }
    }
    func rect(_ start:Int,_ duration:Int,_ track:Int)->NSRect{NSRect(x:left+CGFloat(start)*scale,y:top+CGFloat(track)*rowHeight+2,width:max(2,CGFloat(duration)*scale-2),height:rowHeight-4)}
    override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}
    override func draw(_ dirtyRect:NSRect){
        Palette.timeline.setFill();bounds.fill()
        let seconds=Double(project.durationFrames)/30;let tick=max(1,Int(ceil(seconds/Double(max(1,bounds.width/90)))))
        for sec in stride(from:0,through:Int(ceil(seconds)),by:tick){let x=left+CGFloat(sec*30)*scale;(String(format:"%02d:%02d",sec/60,sec%60) as NSString).draw(at:NSPoint(x:x+3,y:5),withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.regular),.foregroundColor:NSColor.secondaryLabelColor]);NSColor.separatorColor.setFill();NSRect(x:x,y:4,width:1,height:top-6).fill()}
        NSColor.separatorColor.setFill();NSRect(x:0,y:top-1,width:bounds.width,height:1).fill()
        for i in 0..<TimelineView.trackCount{Palette.lane.setFill();NSBezierPath(roundedRect:NSRect(x:left,y:top+CGFloat(i)*rowHeight+2,width:bounds.width-left-12,height:rowHeight-4),xRadius:5,yRadius:5).fill()}
        for c in project.videoClips{let choice=ClipSelection.video(c.id),r=rect(c.startFrame,c.durationFrames,c.track);let isImage=project.assets.first{$0.id==c.assetID}?.kind == .image
            drawClip(r,choice:choice,style:isImage ? Palette.imageClip:Palette.videoClip,title:assetName(c.assetID),disabled:(project.hiddenVideoTracks ?? []).contains(c.track),textInset:r.width>42 && thumbnails[c.assetID]?.isEmpty == false ? 40:8)
            if let thumbs=thumbnails[c.assetID],!thumbs.isEmpty,r.width>42{let target=c.sourceStartFrame+c.durationFrames/2;let thumb=thumbs.min{abs($0.frame-target)<abs($1.frame-target)}!;NSGraphicsContext.saveGraphicsState();NSBezierPath(roundedRect:r.insetBy(dx:2,dy:2),xRadius:3,yRadius:3).addClip();thumb.image.draw(in:NSRect(x:r.minX+2,y:r.minY+2,width:32,height:r.height-4),from:.zero,operation:.sourceOver,fraction:0.9,respectFlipped:true,hints:nil);NSGraphicsContext.restoreGraphicsState()}}
        for c in project.audioClips{let r=rect(c.startFrame,c.durationFrames,c.track+2);let style=Palette.audioClip;drawClip(r,choice:.audio(c.id),style:style,title:assetName(c.assetID),disabled:(project.mutedAudioTracks ?? []).contains(c.track),textInset:8)
            if let waveform=waveforms[c.assetID],!waveform.peaks.isEmpty,r.width>5{NSGraphicsContext.saveGraphicsState();NSBezierPath(rect:r.insetBy(dx:1,dy:1)).addClip();style.text.withAlphaComponent(0.35).setStroke();let path=NSBezierPath();for x in stride(from:0,through:Int(r.width),by:2){let sourceFrame=Double(c.sourceStartFrame)+Double(x)/Double(r.width)*Double(c.durationFrames);let bin=min(waveform.peaks.count-1,max(0,Int(sourceFrame/Double(max(1,waveform.durationFrames))*Double(waveform.peaks.count))));let height=CGFloat(min(1,Double(waveform.peaks[bin])*c.gain*3))*r.height*0.4;path.move(to:NSPoint(x:r.minX+CGFloat(x),y:r.midY-height));path.line(to:NSPoint(x:r.minX+CGFloat(x),y:r.midY+height))};path.stroke();NSGraphicsContext.restoreGraphicsState()}}
        for c in project.subtitles{drawClip(rect(c.startFrame,c.endFrame-c.startFrame,6),choice:.subtitle(c.id),style:Palette.subtitleClip,title:c.text.replacingOccurrences(of:"\n",with:" / "),disabled:false,textInset:8)}
        if didDrag{var start=dragStart,duration=dragDuration,track=dragTrack;if dragMode==0{start=max(0,dragStart+dragDelta);track=dragRow}else if dragMode==1{start=min(dragStart+dragDuration-1,max(dragStart,dragStart+dragDelta));duration=dragStart+dragDuration-start}else{duration=max(1,min(dragDuration,dragDuration+dragDelta))};NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke();let border=NSBezierPath(roundedRect:rect(start,duration,track),xRadius:5,yRadius:5);border.lineWidth=2;border.setLineDash([4,3],count:2,phase:0);border.stroke()}
        NSColor.systemRed.setFill();let x=left+CGFloat(position)*scale;NSRect(x:x-0.75,y:2,width:1.5,height:bounds.height-2).fill();NSBezierPath(ovalIn:NSRect(x:x-4,y:top-9,width:8,height:8)).fill()
    }
    func assetName(_ id:String)->String{project.assets.first{$0.id==id}.map{URL(fileURLWithPath:$0.path).lastPathComponent} ?? id}
    func drawClip(_ rect:NSRect,choice:ClipSelection,style:Palette.ClipStyle,title:String,disabled:Bool,textInset:CGFloat){
        let alpha:CGFloat=disabled ? 0.35:1,path=NSBezierPath(roundedRect:rect,xRadius:5,yRadius:5)
        style.fill.withAlphaComponent(alpha).setFill();path.fill()
        if selected==choice{NSColor.controlAccentColor.setStroke();let border=NSBezierPath(roundedRect:rect.insetBy(dx:1,dy:1),xRadius:4,yRadius:4);border.lineWidth=2;border.stroke()}else{style.border.withAlphaComponent(alpha).setStroke();let border=NSBezierPath(roundedRect:rect.insetBy(dx:0.5,dy:0.5),xRadius:5,yRadius:5);border.lineWidth=1;border.stroke()}
        if rect.width>textInset+24{let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(in:NSRect(x:rect.minX+textInset,y:rect.midY-7,width:rect.width-textInset-6,height:15),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:style.text.withAlphaComponent(disabled ? 0.6:1),.paragraphStyle:paragraph])}
    }
    func hit(_ point:NSPoint)->ClipSelection?{
        for c in project.videoClips where rect(c.startFrame,c.durationFrames,c.track).contains(point){return .video(c.id)}
        for c in project.audioClips where rect(c.startFrame,c.durationFrames,c.track+2).contains(point){return .audio(c.id)}
        for c in project.subtitles where rect(c.startFrame,c.endFrame-c.startFrame,6).contains(point){return .subtitle(c.id)}
        return nil
    }
    override func mouseDown(with event:NSEvent){let p=convert(event.locationInWindow,from:nil);downPoint=p;didDrag=false;dragChoice=hit(p);dragDelta=0
        if let selection=dragChoice,let info=interval(selection){selected=selection;dragStart=info.0;dragDuration=info.1;dragTrack=info.2;dragRow=info.2;let r=rect(info.0,info.1,info.2);dragMode=p.x-r.minX<7 ? 1:r.maxX-p.x<7 ? 2:0;onSelect?(selection)}else{onSelect?(nil)}
        onSeek?(max(0,Int(((p.x-left)/scale).rounded())));needsDisplay=true
    }
    override func mouseDragged(with event:NSEvent){guard let selection=dragChoice else{return};let p=convert(event.locationInWindow,from:nil);guard abs(p.x-downPoint.x)>2 || abs(p.y-downPoint.y)>4 else{return};didDrag=true;dragDelta=Int(((p.x-downPoint.x)/scale).rounded());let row=Int((p.y-top)/rowHeight)
        switch selection{case .video:dragRow=min(1,max(0,row));case .audio:dragRow=min(5,max(2,row));case .subtitle:dragRow=6};needsDisplay=true
    }
    override func mouseUp(with event:NSEvent){defer{dragChoice=nil;didDrag=false;needsDisplay=true};guard didDrag,let selection=dragChoice else{return}
        if dragMode==0{let track=dragRow<2 ? dragRow:dragRow<6 ? dragRow-2:0;onMove?(selection,max(0,dragStart+dragDelta),track)}else if dragMode==1{onTrim?(selection,min(dragStart+dragDuration-1,max(dragStart,dragStart+dragDelta)),dragStart+dragDuration)}else{onTrim?(selection,dragStart,dragStart+max(1,min(dragDuration,dragDuration+dragDelta)))}
    }
}
