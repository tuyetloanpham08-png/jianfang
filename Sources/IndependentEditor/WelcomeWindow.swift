import AppKit
import EditorCore
import MediaEngine

/// The app mark: a dark rounded square with orange in/out brackets.
final class AppMarkView:NSView {
    override func draw(_ dirtyRect:NSRect){AppMarkView.drawMark(in:bounds.insetBy(dx:2,dy:2))}
    /// Writes the macOS icon set (the mark on Apple's 824-in-1024 icon grid) for `iconutil -c icns`.
    static func writeIconSet(to folder:URL)throws{
        guard !FileManager.default.fileExists(atPath:folder.path) else{throw ProjectError.invalid("不覆盖已有图标目录：\(folder.path)")}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        for points in [16,32,128,256,512]{for scale in [1,2]{
            let pixels=points*scale
            guard let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) else{throw ProjectError.invalid("无法创建图标画布")}
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
            let unit=CGFloat(pixels)/1024;drawMark(in:NSRect(x:100*unit,y:100*unit,width:824*unit,height:824*unit))
            NSGraphicsContext.restoreGraphicsState()
            guard let png=rep.representation(using:.png,properties:[:]) else{throw ProjectError.invalid("无法编码图标 PNG")}
            try png.write(to:folder.appendingPathComponent("icon_\(points)x\(points)\(scale==2 ? "@2x":"").png"),options:.withoutOverwriting)
        }}
    }
    /// The mark itself: dark rounded square, orange in/out brackets and a centre dash, drawn into `r`.
    static func drawMark(in r:NSRect){
        NSColor(srgbRed:0.17,green:0.17,blue:0.18,alpha:1).setFill();NSBezierPath(roundedRect:r,xRadius:r.width*0.23,yRadius:r.width*0.23).fill()
        let s=r.width/48,path=NSBezierPath();path.lineWidth=3.2*s;path.lineCapStyle = .round;path.lineJoinStyle = .round
        func p(_ x:CGFloat,_ y:CGFloat)->NSPoint{NSPoint(x:r.minX+x*s,y:r.maxY-y*s)}
        path.move(to:p(16,9));path.line(to:p(9,9));path.line(to:p(9,39));path.line(to:p(16,39))
        path.move(to:p(32,9));path.line(to:p(39,9));path.line(to:p(39,39));path.line(to:p(32,39))
        path.move(to:p(20,24));path.line(to:p(28,24))
        NSColor(srgbRed:1,green:0.62,blue:0.04,alpha:1).setStroke();path.stroke()
    }
}

extension EditorController {
    /// Start window: new landscape/portrait, open, sample, and the unsaved-autosave notice.
    func showWelcome(){let w=makeWelcomeWindow();welcome=w;w.center();w.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    func makeWelcomeWindow()->NSWindow{
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:440),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
        w.titlebarAppearsTransparent=true;w.titleVisibility = .hidden;w.isMovableByWindowBackground=true;w.isReleasedWhenClosed=false;w.delegate=self;w.title="欢迎使用剪坊"
        w.standardWindowButton(.miniaturizeButton)?.isHidden=true;w.standardWindowButton(.zoomButton)?.isHidden=true
        let mark=AppMarkView();mark.widthAnchor.constraint(equalToConstant:88).isActive=true;mark.heightAnchor.constraint(equalToConstant:88).isActive=true
        let name=NSTextField(labelWithString:"剪坊");name.font = .systemFont(ofSize:28,weight:.bold)
        let version=secondaryLabel("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.1")",size:12)
        let actions=NSStackView(views:[
            welcomeAction("新建横版工程","1920×1080 · 30 fps","rectangle",#selector(welcomeNewLandscape)),
            welcomeAction("新建竖版工程","1080×1920 · 30 fps","rectangle.portrait",#selector(welcomeNewPortrait)),
            welcomeAction("打开工程…",nil,"folder",#selector(welcomeOpen)),
            welcomeAction("打开示例工程","60 秒示例","film",#selector(welcomeSample))]);actions.orientation = .vertical;actions.spacing=2
        for v in actions.arrangedSubviews{v.widthAnchor.constraint(equalTo:actions.widthAnchor).isActive=true}
        let left=NSStackView(views:[mark,name,version,actions]);left.orientation = .vertical;left.alignment = .centerX;left.spacing=6;left.setCustomSpacing(10,after:mark);left.setCustomSpacing(22,after:version);left.edgeInsets=NSEdgeInsets(top:44,left:40,bottom:24,right:40)
        actions.widthAnchor.constraint(equalTo:left.widthAnchor,constant:-80).isActive=true
        let heading=NSTextField(labelWithString:"开始之前");heading.font = .systemFont(ofSize:11,weight:.semibold);heading.textColor = .secondaryLabelColor
        let note=NSTextField(wrappingLabelWithString:"支持 1080p SDR H.264、PNG/JPEG、WAV/AAC 素材。工程 30 fps，最长 10 分钟。导入视频会自动附带原声。\n\n所有文件只在本机处理，不联网。");note.font = .systemFont(ofSize:12);note.textColor = .secondaryLabelColor
        var rightViews:[NSView]=[heading,note,spacer()]
        if RecoveryStore.needsPrompt(recoveryURL){let card=recoveryNotice();recoveryCard=card;rightViews.append(card)}
        let right=NSStackView(views:rightViews);right.orientation = .vertical;right.alignment = .leading;right.spacing=10;right.edgeInsets=NSEdgeInsets(top:44,left:16,bottom:16,right:16)
        for v in rightViews{v.widthAnchor.constraint(equalTo:right.widthAnchor,constant:-32).isActive=true}
        rightViews[2].setContentHuggingPriority(.defaultLow,for:.vertical)
        let rightPane=FillView(Palette.panel);right.translatesAutoresizingMaskIntoConstraints=false;rightPane.addSubview(right);rightPane.widthAnchor.constraint(equalToConstant:260).isActive=true
        NSLayoutConstraint.activate([right.leadingAnchor.constraint(equalTo:rightPane.leadingAnchor),right.trailingAnchor.constraint(equalTo:rightPane.trailingAnchor),right.topAnchor.constraint(equalTo:rightPane.topAnchor),right.bottomAnchor.constraint(equalTo:rightPane.bottomAnchor)])
        left.setContentHuggingPriority(.init(1),for:.horizontal)
        let content=row([left,separator(vertical:true),rightPane],spacing:0);content.alignment = .top;content.distribution = .fill
        for v in content.arrangedSubviews{v.heightAnchor.constraint(equalTo:content.heightAnchor).isActive=true}
        w.contentView=content;return w
    }
    func welcomeAction(_ title:String,_ detail:String?,_ image:String,_ action:Selector)->NSView{
        let b=NSButton(title:"",target:self,action:action);b.isBordered=false;b.setAccessibilityLabel(title)
        let icon=NSImageView(image:symbol(image,title));icon.contentTintColor = .controlAccentColor;icon.symbolConfiguration=NSImage.SymbolConfiguration(pointSize:18,weight:.regular);icon.widthAnchor.constraint(equalToConstant:28).isActive=true
        let titleLabel=NSTextField(labelWithString:title);titleLabel.font = .systemFont(ofSize:13,weight:.semibold)
        let text=NSStackView(views:[titleLabel]+(detail.map{[secondaryLabel($0)]} ?? []));text.orientation = .vertical;text.alignment = .leading;text.spacing=1
        let s=row([icon,text,spacer()],spacing:12);s.translatesAutoresizingMaskIntoConstraints=false;b.addSubview(s);b.heightAnchor.constraint(equalToConstant:44).isActive=true
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo:b.leadingAnchor,constant:12),s.trailingAnchor.constraint(equalTo:b.trailingAnchor,constant:-12),s.centerYAnchor.constraint(equalTo:b.centerYAnchor)])
        return b
    }
    func recoveryNotice()->NSView{
        let text=NSTextField(wrappingLabelWithString:"发现上次未保存的自动保存。");text.font = .systemFont(ofSize:12)
        let archive=button("存入历史",#selector(welcomeArchive)),restore=button("恢复",#selector(welcomeRecover));archive.controlSize = .small;restore.controlSize = .small;restore.bezelColor = .controlAccentColor;restore.keyEquivalent="\r"
        let buttons=row([spacer(),archive,restore],spacing:6)
        let s=NSStackView(views:[text,buttons]);s.orientation = .vertical;s.alignment = .leading;s.spacing=8;s.translatesAutoresizingMaskIntoConstraints=false;buttons.widthAnchor.constraint(equalTo:s.widthAnchor).isActive=true
        let card=FillView(Palette.card,cornerRadius:8,bordered:true);card.addSubview(s)
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo:card.leadingAnchor,constant:12),s.trailingAnchor.constraint(equalTo:card.trailingAnchor,constant:-12),s.topAnchor.constraint(equalTo:card.topAnchor,constant:10),s.bottomAnchor.constraint(equalTo:card.bottomAnchor,constant:-10)])
        return card
    }
    func enterMain(){welcome?.orderOut(nil);welcome=nil;recoveryCard=nil;window.center();window.makeKeyAndOrderFront(nil)}
    @objc func welcomeNewLandscape(){enterMain()}
    @objc func welcomeNewPortrait(){enterMain();newPortrait()}
    @objc func welcomeOpen(){let p=NSOpenPanel();p.allowedContentTypes=[.json];p.canChooseDirectories=false;guard p.runModal() == .OK,let u=p.url else{return};enterMain();load(u)}
    @objc func welcomeSample(){enterMain();openF1()}
    @objc func welcomeRecover(){enterMain();recoverProject()}
    @objc func welcomeArchive(){do{try RecoveryStore.archive(recoveryURL,into:recoveryHistoryURL);recoveryCard?.isHidden=true;statusLabel.stringValue="自动保存已存入恢复历史"}catch{showError(error)}}

    /// Diagnostic: renders the main window (with a project loaded) or the start window to a PNG
    /// in light or dark appearance, without showing anything on screen.
    func snapshot(project url:URL,to output:URL,dark:Bool,welcomeOnly:Bool)async throws{
        NSApp.setActivationPolicy(.accessory);buildWindow()
        let target:NSWindow
        if welcomeOnly{target=makeWelcomeWindow()}else{
            let (candidate,changed)=try AssetStore.verified(ProjectStore.load(url),baseURL:url.deletingLastPathComponent())
            project=candidate;changedAssets=Set(changed);baseURL=url.deletingLastPathComponent();projectURL=url;dirty=false;selected=nil;refreshFields()
            let built=try await TimelineEngine.compile(project:project,baseURL:baseURL);install(built,at:2);seek(60)
            if let first=project.videoClips.sorted(by:{$0.startFrame<$1.startFrame}).first{select(.video(first.id))}
            try await Task.sleep(nanoseconds:2_500_000_000)
            target=window
        }
        // JF_SNAPSHOT_HOLD=秒数：窗口真实显示这么久，便于用系统截图核对 cacheDisplay 画不出的玻璃/着色效果。
        let hold=Double(ProcessInfo.processInfo.environment["JF_SNAPSHOT_HOLD"] ?? "") ?? 0
        target.appearance=NSAppearance(named:dark ? .darkAqua:.aqua);target.alphaValue=hold>0 ? 1:0;target.orderFrontRegardless()
        try await Task.sleep(nanoseconds:500_000_000+UInt64(hold*1_000_000_000))
        let frame=target.contentView!.superview!;frame.layoutSubtreeIfNeeded();frame.display()
        guard let rep=frame.bitmapImageRepForCachingDisplay(in:frame.bounds) else{throw ProjectError.invalid("无法生成界面截图")}
        frame.cacheDisplay(in:frame.bounds,to:rep)
        guard let png=rep.representation(using:.png,properties:[:]) else{throw ProjectError.invalid("无法编码 PNG")}
        try png.write(to:output,options:.withoutOverwriting);target.orderOut(nil)
    }
}
