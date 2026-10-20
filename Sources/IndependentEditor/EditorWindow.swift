import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import EditorCore
import MediaEngine

/// One row of the sidebar source list.
enum SourceRow {case header(String),asset(Int),subtitle(String)}

/// Document view for the inspector scroll view: flipped so content starts at the top.
final class FlippedView:NSView {override var isFlipped:Bool{true}}

extension NSToolbarItem.Identifier {
    static let jfSidebar=Self("jf.sidebar"),jfImport=Self("jf.import"),jfSubtitle=Self("jf.subtitle"),jfSplit=Self("jf.split"),jfExport=Self("jf.export"),jfInspector=Self("jf.inspector")
}

@MainActor final class EditorController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSApplicationDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    var window:NSWindow!
    var welcome:NSWindow?,recoveryCard:NSView?
    var project=EditorProject(name:"未命名工程",durationFrames:1)
    var baseURL=URL(fileURLWithPath:NSHomeDirectory()),projectURL:URL?
    var history=EditHistory(limit:100)
    var selected:ClipSelection?
    var selections=[ClipSelection]()
    var compiled:CompiledTimeline?
    let player=AVPlayer(),playerView=AVPlayerView(),timeline=TimelineView()
    let sourceTable=NSTableView(),searchField=NSSearchField(),clipPicker=NSPopUpButton(),trackPicker=NSPopUpButton(),rotationPicker=NSPopUpButton()
    let statusLabel=NSTextField(labelWithString:"新建工程，导入素材开始剪辑。"),timeLabel=NSTextField(labelWithString:"00:00:00:00"),formatLabel=NSTextField(labelWithString:"")
    let saveLabel=NSTextField(labelWithString:"尚未修改"),selectionLabel=NSTextField(wrappingLabelWithString:"点击时间线片段进行编辑")
    let scrubber=NSSlider(value:0,minValue:0,maxValue:1,target:nil,action:nil),zoom=NSSlider(value:1,minValue:1,maxValue:12,target:nil,action:nil)
    let progress=NSProgressIndicator(),cancelExportButton=NSButton(),playButton=NSButton(),timelineScroll=NSScrollView(),inspectorScroll=NSScrollView(),subtitleText=NSTextView()
    let inspectorTabs=NSSegmentedControl(labels:["画面","声音","字幕","时间"],trackingMode:.selectOne,target:nil,action:nil)
    let sidebar=NSVisualEffectView(),inspector=FillView(Palette.panel)
    var inspectorPanes=[NSView](),exportItem:NSToolbarItem?,videoAspect:NSLayoutConstraint?
    var fields=[String:NSTextField](),trackChecks=[NSButton](),sourceRows=[SourceRow]()
    var observer:Any?,rateObservation:NSKeyValueObservation?,buildTask:Task<Void,Never>?,exportTask:Task<Void,Never>?
    var dirty=false,busy=false,buildGeneration=0,exportGeneration=0
    var exporting=false{didSet{updateExportControls()}}
    /// Per-build folder: test builds never touch the released app's autosave (see RecoveryStore.supportFolder).
    let recoveryURL=RecoveryStore.supportFolder(bundleID:Bundle.main.bundleIdentifier,environment:ProcessInfo.processInfo.environment,home:URL(fileURLWithPath:NSHomeDirectory())).appendingPathComponent("recovery.json")
    var cache=MediaPreviewCache()
    /// Asset IDs whose bytes no longer match the recorded fingerprint; marked in the sidebar, export refuses them.
    var changedAssets=Set<String>()

    func show(){
        NSApp.setActivationPolicy(.regular);NSApp.delegate=self
        buildWindow();buildMenu();showWelcome()
    }
    /// Builds the main window (not yet shown). Follows the system light/dark appearance.
    func buildWindow(){
        window=NSWindow(contentRect:NSRect(x:60,y:60,width:1440,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.minSize=NSSize(width:1180,height:820);window.delegate=self;window.isReleasedWhenClosed=false;window.toolbarStyle = .unified
        let toolbar=NSToolbar(identifier:"JianfangMain");toolbar.delegate=self;toolbar.displayMode = .iconOnly;toolbar.allowsUserCustomization=false;window.toolbar=toolbar
        let content=NSView();window.contentView=content
        let viewer=makeViewer();viewer.setContentHuggingPriority(.init(1),for:.horizontal);viewer.setContentCompressionResistancePriority(.init(1),for:.horizontal)
        let top=row([makeSidebar(),separator(vertical:true),viewer,separator(vertical:true),makeInspector()],spacing:0);top.alignment = .top;top.distribution = .fill
        for v in top.arrangedSubviews{v.heightAnchor.constraint(equalTo:top.heightAnchor).isActive=true}
        let main=NSStackView(views:[top,separator(vertical:false),makeTimelineArea(),separator(vertical:false),makeStatusBar()]);main.orientation = .vertical;main.spacing=0;main.translatesAutoresizingMaskIntoConstraints=false
        for v in main.arrangedSubviews{v.widthAnchor.constraint(equalTo:main.widthAnchor).isActive=true}
        top.setContentHuggingPriority(.defaultLow,for:.vertical);top.heightAnchor.constraint(greaterThanOrEqualToConstant:360).isActive=true
        content.addSubview(main)
        NSLayoutConstraint.activate([main.leadingAnchor.constraint(equalTo:content.leadingAnchor),main.trailingAnchor.constraint(equalTo:content.trailingAnchor),main.topAnchor.constraint(equalTo:content.topAnchor),main.bottomAnchor.constraint(equalTo:content.bottomAnchor)])
        timeline.onSelect={ [weak self] choice in self?.select(choice) }
        timeline.onSeek={ [weak self] frame in self?.seek(frame) }
        timeline.onMove={ [weak self] choice,frame,track in self?.move(choice,frame:frame,track:track) }
        timeline.onTrim={ [weak self] choice,start,end in self?.trim(choice,start:start,end:end) }
        observer=player.addPeriodicTimeObserver(forInterval:CMTime(value:1,timescale:30),queue:.main){[weak self] t in Task{@MainActor in guard let self else{return};let seconds=t.seconds;guard seconds.isFinite else{return};self.scrubber.doubleValue=seconds;self.timeline.position=seconds*30;self.timeline.needsDisplay=true;self.updateTimeLabel(Int((seconds*30).rounded()))}}
        rateObservation=player.observe(\.rate,options:[.new]){[weak self] player,_ in let playing=player.rate != 0;Task{@MainActor in self?.playButton.image=self?.symbol(playing ? "pause.fill":"play.fill",playing ? "暂停":"播放")}}
        refreshFields();compilePreview()
    }
    func row(_ views:[NSView],spacing:CGFloat=7)->NSStackView{let s=NSStackView(views:views);s.orientation = .horizontal;s.spacing=spacing;return s}
    func spacer()->NSView{let v=NSView();v.setContentHuggingPriority(.defaultLow,for:.horizontal);return v}
    func separator(vertical:Bool)->NSView{let b=NSBox();b.boxType = .separator;if vertical{b.widthAnchor.constraint(equalToConstant:1).isActive=true}else{b.heightAnchor.constraint(equalToConstant:1).isActive=true};return b}
    func symbol(_ name:String,_ label:String)->NSImage{NSImage(systemSymbolName:name,accessibilityDescription:label) ?? NSImage()}
    func button(_ title:String,_ action:Selector)->NSButton{let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;return b}
    /// Borderless icon (+ optional text) button for bars inside the window.
    func plainButton(_ title:String?,_ image:String,_ label:String,_ action:Selector)->NSButton{
        let b=title.map{NSButton(title:$0,image:symbol(image,label),target:self,action:action)} ?? NSButton(image:symbol(image,label),target:self,action:action)
        b.isBordered=false;b.imagePosition=title == nil ? .imageOnly:.imageLeading;b.controlSize = .small;b.font = .systemFont(ofSize:12);b.contentTintColor = .secondaryLabelColor;b.toolTip=label;b.setAccessibilityLabel(label);return b
    }
    func secondaryLabel(_ text:String,size:CGFloat=11)->NSTextField{let l=NSTextField(labelWithString:text);l.font = .systemFont(ofSize:size);l.textColor = .secondaryLabelColor;return l}

    // MARK: Sidebar
    func makeSidebar()->NSView{
        sidebar.material = .sidebar;sidebar.blendingMode = .behindWindow;sidebar.state = .followsWindowActiveState
        sidebar.widthAnchor.constraint(equalToConstant:232).isActive=true
        searchField.placeholderString="搜索素材";searchField.sendsSearchStringImmediately=true;searchField.delegate=self;searchField.target=self;searchField.action=#selector(filterSources)
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("source"));sourceTable.addTableColumn(column);sourceTable.headerView=nil;sourceTable.style = .sourceList;sourceTable.rowSizeStyle = .default;sourceTable.backgroundColor = .clear;sourceTable.dataSource=self;sourceTable.delegate=self;sourceTable.setAccessibilityLabel("素材与字幕")
        let menu=NSMenu();menu.addItem(withTitle:"重连所选素材…",action:#selector(relinkAsset),keyEquivalent:"").target=self;sourceTable.menu=menu
        let scroll=NSScrollView();scroll.documentView=sourceTable;scroll.hasVerticalScroller=true;scroll.drawsBackground=false;scroll.borderType = .noBorder
        let importButton=plainButton(nil,"plus","导入素材",#selector(importMedia));importButton.toolTip="导入素材：支持 1080p SDR H.264、PNG/JPEG、WAV/AAC；导入视频自动附带原声"
        let footer=row([importButton,plainButton(nil,"link","重连所选素材",#selector(relinkAsset)),spacer()],spacing:4)
        let stack=NSStackView(views:[searchField,scroll,footer]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=6;stack.edgeInsets=NSEdgeInsets(top:10,left:8,bottom:6,right:8);stack.translatesAutoresizingMaskIntoConstraints=false
        for v in stack.arrangedSubviews{v.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-16).isActive=true}
        scroll.setContentHuggingPriority(.defaultLow,for:.vertical)
        sidebar.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor),stack.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor),stack.topAnchor.constraint(equalTo:sidebar.topAnchor),stack.bottomAnchor.constraint(equalTo:sidebar.bottomAnchor)])
        return sidebar
    }
    @objc func filterSources(){reloadSources()}
    func assetFileName(_ index:Int)->String{URL(fileURLWithPath:project.assets[index].path).lastPathComponent}
    func reloadSources(){
        let query=searchField.stringValue.trimmingCharacters(in:.whitespaces).lowercased()
        let assets=project.assets.indices.filter{query.isEmpty || assetFileName($0).lowercased().contains(query)}
        let subtitles=project.subtitles.sorted{$0.startFrame<$1.startFrame}.filter{query.isEmpty || $0.text.lowercased().contains(query)}
        var rows=[SourceRow]()
        if query.isEmpty || !assets.isEmpty{rows.append(.header("素材"));rows+=assets.map{.asset($0)}}
        if !subtitles.isEmpty{rows.append(.header("字幕"));rows+=subtitles.map{.subtitle($0.id)}}
        sourceRows=rows;sourceTable.reloadData()
    }
    var selectedAssetIndex:Int?{let r=sourceTable.selectedRow;guard sourceRows.indices.contains(r),case .asset(let i)=sourceRows[r] else{return nil};return i}
    func numberOfRows(in tableView:NSTableView)->Int{sourceRows.count}
    func tableView(_ tableView:NSTableView,isGroupRow row:Int)->Bool{if case .header=sourceRows[row]{return true};return false}
    func tableView(_ tableView:NSTableView,shouldSelectRow row:Int)->Bool{!self.tableView(tableView,isGroupRow:row)}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView?{
        switch sourceRows[row]{
        case .header(let title):let cell=NSTableCellView();let l=NSTextField(labelWithString:title);l.font = .systemFont(ofSize:11,weight:.semibold);l.textColor = .secondaryLabelColor;l.translatesAutoresizingMaskIntoConstraints=false;cell.addSubview(l);cell.textField=l
            NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:4),l.centerYAnchor.constraint(equalTo:cell.centerYAnchor)]);return cell
        case .asset(let i):
            let a=project.assets[i],u=try? project.assetURL(a.id,baseURL:baseURL);let missing = u.map{!FileManager.default.isReadableFile(atPath:$0.path)} ?? true,changed=changedAssets.contains(a.id)
            let icon=missing || changed ? "exclamationmark.triangle.fill":a.kind == .video ? "film":a.kind == .audio ? "waveform":"photo"
            return sourceCell(icon:icon,tint:missing || changed ? .systemOrange:nil,title:assetFileName(i),detail:missing ? "离线":changed ? "已变化":"",detailColor:.systemOrange,tip:missing ? "找不到文件：可用“重连所选素材”指向原文件":changed ? "文件内容与工程记录的指纹不一致：请重连原文件或删除相关片段":nil)
        case .subtitle(let id):
            let c=project.subtitles.first{$0.id==id};let start=(c?.startFrame ?? 0)/30
            return sourceCell(icon:"text.bubble",tint:nil,title:c?.text.components(separatedBy:"\n").first ?? "",detail:String(format:"%02d:%02d",start/60,start%60),detailColor:.secondaryLabelColor,tip:c?.text)
        }
    }
    func sourceCell(icon:String,tint:NSColor?,title:String,detail:String,detailColor:NSColor,tip:String?)->NSView{
        let cell=NSTableCellView(),image=NSImageView(image:symbol(icon,title)),text=NSTextField(labelWithString:title),trailing=NSTextField(labelWithString:detail)
        image.contentTintColor=tint;text.lineBreakMode = .byTruncatingMiddle;text.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        trailing.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular);trailing.textColor=detailColor;trailing.setContentHuggingPriority(.required,for:.horizontal)
        cell.imageView=image;cell.textField=text;cell.toolTip=tip
        let s=row([image,text,trailing],spacing:6);s.translatesAutoresizingMaskIntoConstraints=false;cell.addSubview(s);image.widthAnchor.constraint(equalToConstant:18).isActive=true
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:2),s.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),s.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification:Notification){let r=sourceTable.selectedRow;guard sourceRows.indices.contains(r),case .subtitle(let id)=sourceRows[r] else{return};select(.subtitle(id))}

    // MARK: Viewer
    func makeViewer()->NSView{
        let area=FillView(Palette.viewer)
        playerView.player=player;playerView.controlsStyle = .none;playerView.videoGravity = .resizeAspect;playerView.translatesAutoresizingMaskIntoConstraints=false;area.addSubview(playerView)
        let fillWidth=playerView.widthAnchor.constraint(equalTo:area.widthAnchor,constant:-48),fillHeight=playerView.heightAnchor.constraint(equalTo:area.heightAnchor,constant:-28);fillWidth.priority = .init(200);fillHeight.priority = .init(200)
        NSLayoutConstraint.activate([playerView.centerXAnchor.constraint(equalTo:area.centerXAnchor),playerView.centerYAnchor.constraint(equalTo:area.centerYAnchor),playerView.widthAnchor.constraint(lessThanOrEqualTo:area.widthAnchor,constant:-48),playerView.heightAnchor.constraint(lessThanOrEqualTo:area.heightAnchor,constant:-28),fillWidth,fillHeight])
        scrubber.target=self;scrubber.action=#selector(scrub);scrubber.isContinuous=true;scrubber.controlSize = .small;scrubber.setAccessibilityLabel("播放位置秒")
        timeLabel.font = .monospacedDigitSystemFont(ofSize:13,weight:.regular);formatLabel.font = .systemFont(ofSize:12);formatLabel.textColor = .secondaryLabelColor;formatLabel.alignment = .right
        playButton.image=symbol("play.fill","播放");playButton.isBordered=false;playButton.target=self;playButton.action=#selector(togglePlayback);playButton.setAccessibilityLabel("播放或暂停");playButton.symbolConfiguration=NSImage.SymbolConfiguration(pointSize:17,weight:.regular)
        let back=plainButton(nil,"backward.frame.fill","上一帧",#selector(stepBack)),forward=plainButton(nil,"forward.frame.fill","下一帧",#selector(stepForward));back.contentTintColor = .labelColor;forward.contentTintColor = .labelColor;playButton.contentTintColor = .labelColor
        let controls=row([back,playButton,forward],spacing:14)
        let bar=NSStackView(views:[timeLabel,controls,formatLabel]);bar.orientation = .horizontal;bar.distribution = .equalCentering
        timeLabel.widthAnchor.constraint(equalToConstant:210).isActive=true;formatLabel.widthAnchor.constraint(equalToConstant:210).isActive=true
        let transport=NSStackView(views:[scrubber,bar]);transport.orientation = .vertical;transport.spacing=4;transport.edgeInsets=NSEdgeInsets(top:6,left:18,bottom:8,right:18)
        for v in transport.arrangedSubviews{v.widthAnchor.constraint(equalTo:transport.widthAnchor,constant:-36).isActive=true}
        let column=NSStackView(views:[area,transport]);column.orientation = .vertical;column.spacing=0
        for v in column.arrangedSubviews{v.widthAnchor.constraint(equalTo:column.widthAnchor).isActive=true}
        area.setContentHuggingPriority(.defaultLow,for:.vertical);transport.setContentHuggingPriority(.required,for:.vertical)
        let background=FillView(Palette.viewer);column.translatesAutoresizingMaskIntoConstraints=false;background.addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo:background.leadingAnchor),column.trailingAnchor.constraint(equalTo:background.trailingAnchor),column.topAnchor.constraint(equalTo:background.topAnchor),column.bottomAnchor.constraint(equalTo:background.bottomAnchor)])
        return background
    }
    /// Keeps the player frame at the project's aspect ratio (landscape or portrait).
    func setVideoAspect(){let ratio=CGFloat(project.width)/CGFloat(max(1,project.height));if let videoAspect,abs(videoAspect.multiplier-ratio)<0.0001{return};videoAspect?.isActive=false;videoAspect=playerView.widthAnchor.constraint(equalTo:playerView.heightAnchor,multiplier:ratio);videoAspect?.isActive=true}
    func timecode(_ frame:Int)->String{let f=max(0,frame);return String(format:"%02d:%02d:%02d:%02d",f/108000,f/1800%60,f/30%60,f%30)}
    func updateTimeLabel(_ frame:Int){timeLabel.stringValue="\(timecode(frame)) / \(timecode(project.durationFrames))"}

    // MARK: Inspector
    func makeInspector()->NSView{
        inspector.widthAnchor.constraint(equalToConstant:284).isActive=true
        clipPicker.isBordered=false;clipPicker.font = .systemFont(ofSize:13,weight:.semibold);clipPicker.target=self;clipPicker.action=#selector(pickClip);clipPicker.setAccessibilityLabel("当前片段");clipPicker.heightAnchor.constraint(greaterThanOrEqualToConstant:20).isActive=true // keeps its height when empty
        selectionLabel.font = .systemFont(ofSize:11);selectionLabel.textColor = .secondaryLabelColor;selectionLabel.preferredMaxLayoutWidth=250
        inspectorTabs.segmentDistribution = .fillEqually;inspectorTabs.target=self;inspectorTabs.action=#selector(switchInspectorTab);inspectorTabs.selectedSegment=0
        func field(_ key:String,_ label:String,_ value:String="0",width:CGFloat=120)->NSTextField{
            let f=NSTextField(string:value);f.widthAnchor.constraint(equalToConstant:width).isActive=true;f.setAccessibilityLabel(label);f.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular);f.alignment = .right;f.controlSize = .small;f.target=self;f.action=#selector(applyInspector);(f.cell as? NSTextFieldCell)?.sendsActionOnEndEditing=false;fields[key]=f;return f
        }
        func pair(_ caption:String,_ f:NSTextField)->NSView{row([secondaryLabel(caption),f],spacing:4)}
        func card(_ title:String,_ rows:[[NSView]])->NSView{
            let grid=NSGridView(views:rows.map{[$0[0]]+[$0.count>1 ? row(Array($0.dropFirst()),spacing:8):NSGridCell.emptyContentView]});grid.rowSpacing=8;grid.columnSpacing=10;grid.column(at:0).xPlacement = .trailing;grid.rowAlignment = .firstBaseline;grid.translatesAutoresizingMaskIntoConstraints=false
            let box=FillView(Palette.card,cornerRadius:8,bordered:true);box.addSubview(grid)
            NSLayoutConstraint.activate([grid.leadingAnchor.constraint(equalTo:box.leadingAnchor,constant:10),grid.trailingAnchor.constraint(lessThanOrEqualTo:box.trailingAnchor,constant:-10),grid.topAnchor.constraint(equalTo:box.topAnchor,constant:10),grid.bottomAnchor.constraint(equalTo:box.bottomAnchor,constant:-10)])
            let header=NSTextField(labelWithString:title);header.font = .systemFont(ofSize:11,weight:.semibold);header.textColor = .secondaryLabelColor
            let s=NSStackView(views:[header,box]);s.orientation = .vertical;s.alignment = .leading;s.spacing=5;box.widthAnchor.constraint(equalTo:s.widthAnchor).isActive=true;return s
        }
        func label(_ text:String)->NSTextField{NSTextField(labelWithString:text)}
        rotationPicker.controlSize = .small;rotationPicker.setAccessibilityLabel("顺时针旋转度");trackPicker.controlSize = .small;trackPicker.setAccessibilityLabel("目标轨道")
        let picture=pane([card("变换",[[label("位置"),pair("X",field("x","位置X比例",width:64)),pair("Y",field("y","位置Y比例",width:64))],[label("大小"),pair("宽",field("width","画面宽度比例","1",width:64)),pair("高",field("height","画面高度比例","1",width:64))],[label("旋转"),rotationPicker]]),card("合成",[[label("不透明度"),field("opacity","不透明度","1")]])])
        let sound=pane([card("音量与淡入淡出",[[label("音量"),field("gain","片段音量","1")],[label("淡入（秒）"),field("fadeIn","淡入秒")],[label("淡出（秒）"),field("fadeOut","淡出秒")]])])
        subtitleText.font = .systemFont(ofSize:13);subtitleText.isRichText=false;subtitleText.isHorizontallyResizable=false;subtitleText.isVerticallyResizable=true;subtitleText.textContainer?.widthTracksTextView=true;subtitleText.setAccessibilityLabel("字幕文字")
        let textScroll=NSScrollView();textScroll.documentView=subtitleText;textScroll.hasVerticalScroller=true;textScroll.borderType = .bezelBorder;textScroll.heightAnchor.constraint(equalToConstant:72).isActive=true;textScroll.widthAnchor.constraint(equalToConstant:228).isActive=true
        let words=pane([card("文字（最多两行）",[[textScroll]]),card("样式",[[label("字号"),field("font","字幕字号","48")],[label("颜色"),field("color","字幕颜色","#FFFFFF")],[label("中心 Y"),field("position","字幕中心Y","0.85")]])])
        let time=pane([card("时间",[[label("开始（秒）"),field("start","项目开始秒")],[label("素材入点（秒）"),field("source","素材入点秒")],[label("时长（秒）"),field("duration","片段长度秒")],[label("轨道"),trackPicker]])])
        inspectorPanes=[picture,sound,words,time]
        let apply=button("应用修改",#selector(applyInspector));apply.toolTip="也可以在任一输入框按回车应用"
        let stack=NSStackView(views:[clipPicker,selectionLabel,inspectorTabs]+inspectorPanes+[apply]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10;stack.setCustomSpacing(2,after:clipPicker);stack.setCustomSpacing(12,after:inspectorTabs);stack.edgeInsets=NSEdgeInsets(top:12,left:14,bottom:14,right:14);stack.translatesAutoresizingMaskIntoConstraints=false
        for v in [clipPicker,inspectorTabs]+inspectorPanes{v.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-28).isActive=true}
        let document=FlippedView();document.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:document.leadingAnchor),stack.trailingAnchor.constraint(equalTo:document.trailingAnchor),stack.topAnchor.constraint(equalTo:document.topAnchor),stack.bottomAnchor.constraint(equalTo:document.bottomAnchor)])
        inspectorScroll.documentView=document;inspectorScroll.hasVerticalScroller=true;inspectorScroll.drawsBackground=false;document.translatesAutoresizingMaskIntoConstraints=false
        document.widthAnchor.constraint(equalTo:inspectorScroll.contentView.widthAnchor).isActive=true;document.topAnchor.constraint(equalTo:inspectorScroll.contentView.topAnchor).isActive=true
        inspectorScroll.translatesAutoresizingMaskIntoConstraints=false;inspector.addSubview(inspectorScroll)
        NSLayoutConstraint.activate([inspectorScroll.leadingAnchor.constraint(equalTo:inspector.leadingAnchor),inspectorScroll.trailingAnchor.constraint(equalTo:inspector.trailingAnchor),inspectorScroll.topAnchor.constraint(equalTo:inspector.topAnchor),inspectorScroll.bottomAnchor.constraint(equalTo:inspector.bottomAnchor)])
        switchInspectorTab();return inspector
    }
    func pane(_ cards:[NSView])->NSView{let s=NSStackView(views:cards);s.orientation = .vertical;s.alignment = .leading;s.spacing=14;for c in cards{c.widthAnchor.constraint(equalTo:s.widthAnchor).isActive=true};return s}
    @objc func switchInspectorTab(){for (i,p) in inspectorPanes.enumerated(){p.isHidden = i != inspectorTabs.selectedSegment}}

    // MARK: Timeline area and status bar
    func makeTimelineArea()->NSView{
        zoom.target=self;zoom.action=#selector(changeZoom);zoom.controlSize = .small;zoom.widthAnchor.constraint(equalToConstant:120).isActive=true;zoom.setAccessibilityLabel("时间线缩放")
        let minus=NSImageView(image:symbol("minus.magnifyingglass","缩小")),plus=NSImageView(image:symbol("plus.magnifyingglass","放大"));minus.contentTintColor = .secondaryLabelColor;plus.contentTintColor = .secondaryLabelColor
        let tools=row([plainButton("分割","scissors","在播放头分割",#selector(splitClip)),plainButton("删除","trash","删除片段",#selector(deleteClip)),plainButton("收尾到内容","arrow.right.to.line","收尾到内容",#selector(fitDuration)),spacer(),minus,zoom,plus],spacing:12);tools.edgeInsets=NSEdgeInsets(top:0,left:12,bottom:0,right:14)
        let bar=FillView(Palette.panel);tools.translatesAutoresizingMaskIntoConstraints=false;bar.addSubview(tools);bar.heightAnchor.constraint(equalToConstant:34).isActive=true
        NSLayoutConstraint.activate([tools.leadingAnchor.constraint(equalTo:bar.leadingAnchor),tools.trailingAnchor.constraint(equalTo:bar.trailingAnchor),tools.centerYAnchor.constraint(equalTo:bar.centerYAnchor)])
        // Fixed track headers beside the horizontally scrolling timeline; rows match TimelineView.
        let headers=NSStackView();headers.orientation = .vertical;headers.alignment = .leading;headers.spacing=0;headers.edgeInsets=NSEdgeInsets(top:TimelineView.top,left:10,bottom:0,right:0)
        let names=["V1","V2","A1","A2","A3","A4","字幕"]
        for i in 0..<TimelineView.trackCount{
            let control:NSView
            if i<6{let video=i<2;let b=NSButton(image:symbol(video ? "eye.slash":"speaker.slash",video ? "隐藏 \(names[i])":"静音 \(names[i])"),target:self,action:#selector(toggleTrack(_:)));b.setButtonType(.toggle);b.alternateImage=symbol(video ? "eye":"speaker.wave.2",video ? "显示 \(names[i])":"启用 \(names[i])");b.isBordered=false;b.tag=i;b.state = .on;b.contentTintColor = .secondaryLabelColor;b.toolTip=video ? "显示或隐藏 \(names[i])":"启用或静音 \(names[i])";b.setAccessibilityLabel(video ? "显示\(names[i])":"启用\(names[i])");trackChecks.append(b);control=b}
            else{let image=NSImageView(image:symbol("captions.bubble","字幕"));image.contentTintColor = .secondaryLabelColor;control=image}
            control.widthAnchor.constraint(equalToConstant:22).isActive=true
            let r=row([control,NSTextField(labelWithString:names[i])],spacing:6);r.heightAnchor.constraint(equalToConstant:TimelineView.rowHeight).isActive=true;headers.addArrangedSubview(r)
        }
        let headerColumn=FillView(Palette.timeline);headers.translatesAutoresizingMaskIntoConstraints=false;headerColumn.addSubview(headers);headerColumn.widthAnchor.constraint(equalToConstant:92).isActive=true
        NSLayoutConstraint.activate([headers.leadingAnchor.constraint(equalTo:headerColumn.leadingAnchor),headers.topAnchor.constraint(equalTo:headerColumn.topAnchor)])
        timelineScroll.hasHorizontalScroller=true;timelineScroll.hasVerticalScroller=false;timelineScroll.borderType = .noBorder;timelineScroll.drawsBackground=false;timelineScroll.documentView=timeline
        timelineScroll.contentView.postsFrameChangedNotifications=true;NotificationCenter.default.addObserver(self,selector:#selector(changeZoom),name:NSView.frameDidChangeNotification,object:timelineScroll.contentView)
        timeline.frame=NSRect(x:0,y:0,width:1300,height:TimelineView.contentHeight);timeline.toolTip="拖动片段移动；拖左右边缘向内裁剪；同轨冲突时取消本次操作"
        let lower=row([headerColumn,timelineScroll],spacing:0);lower.alignment = .top;lower.distribution = .fill;timelineScroll.setContentHuggingPriority(.init(1),for:.horizontal)
        for v in lower.arrangedSubviews{v.heightAnchor.constraint(equalTo:lower.heightAnchor).isActive=true}
        lower.heightAnchor.constraint(equalToConstant:TimelineView.contentHeight+14).isActive=true
        let area=FillView(Palette.timeline);let stack=NSStackView(views:[bar,separator(vertical:false),lower]);stack.orientation = .vertical;stack.spacing=0;stack.translatesAutoresizingMaskIntoConstraints=false
        for v in stack.arrangedSubviews{v.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
        area.addSubview(stack);NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:area.leadingAnchor),stack.trailingAnchor.constraint(equalTo:area.trailingAnchor),stack.topAnchor.constraint(equalTo:area.topAnchor),stack.bottomAnchor.constraint(equalTo:area.bottomAnchor)])
        return area
    }
    func makeStatusBar()->NSView{
        for l in [saveLabel,statusLabel]{l.font = .systemFont(ofSize:11);l.textColor = .secondaryLabelColor}
        statusLabel.lineBreakMode = .byTruncatingTail;statusLabel.maximumNumberOfLines=1;statusLabel.allowsExpansionToolTips=true;statusLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        progress.isIndeterminate=false;progress.minValue=0;progress.maxValue=100;progress.style = .bar;progress.controlSize = .small;progress.widthAnchor.constraint(equalToConstant:140).isActive=true
        cancelExportButton.image=symbol("xmark.circle.fill","取消导出");cancelExportButton.isBordered=false;cancelExportButton.target=self;cancelExportButton.action=#selector(cancelExport);cancelExportButton.contentTintColor = .secondaryLabelColor;cancelExportButton.toolTip="取消导出"
        let s=row([saveLabel,statusLabel,spacer(),progress,cancelExportButton,secondaryLabel("本地运行，不联网")],spacing:12);s.edgeInsets=NSEdgeInsets(top:0,left:12,bottom:0,right:12)
        let bar=FillView(Palette.panel);s.translatesAutoresizingMaskIntoConstraints=false;bar.addSubview(s);bar.heightAnchor.constraint(equalToConstant:26).isActive=true
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo:bar.leadingAnchor),s.trailingAnchor.constraint(equalTo:bar.trailingAnchor),s.centerYAnchor.constraint(equalTo:bar.centerYAnchor)])
        updateExportControls();return bar
    }
    func updateExportControls(){progress.isHidden = !exporting;cancelExportButton.isHidden = !exporting;exportItem?.isEnabled = !exporting}

    // MARK: Toolbar
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier]{[.jfSidebar,.flexibleSpace,.jfImport,.jfSubtitle,.jfSplit,.space,.jfExport,.jfInspector]}
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier]{toolbarDefaultItemIdentifiers(toolbar)}
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag:Bool)->NSToolbarItem?{
        func item(_ image:String,_ label:String,_ action:Selector)->NSToolbarItem{let i=NSToolbarItem(itemIdentifier:id);i.image=symbol(image,label);i.label=label;i.toolTip=label;i.target=self;i.action=action;i.isBordered=true;return i}
        switch id{
        case .jfSidebar:return item("sidebar.left","侧栏",#selector(toggleSidebar))
        case .jfImport:return item("plus","导入素材",#selector(importMedia))
        case .jfSubtitle:return item("captions.bubble","添加字幕",#selector(addSubtitle))
        case .jfSplit:return item("scissors","分割",#selector(splitClip))
        case .jfInspector:return item("sidebar.right","检查器",#selector(toggleInspector))
        case .jfExport:let i=item("square.and.arrow.up","导出",#selector(exportVideo));i.title="导出";i.style = .prominent;i.autovalidates=false;i.toolTip="导出 MP4（不覆盖已有文件）";exportItem=i;updateExportControls();return i
        default:return nil
        }
    }
    @objc func toggleSidebar(){sidebar.isHidden.toggle()}
    @objc func toggleInspector(){inspector.isHidden.toggle()}

    // MARK: Menu bar
    func buildMenu(){
        let menu=NSMenu()
        func submenu(_ title:String)->NSMenu{let item=NSMenuItem(title:title,action:nil,keyEquivalent:"");let m=NSMenu(title:title);item.submenu=m;menu.addItem(item);return m}
        func add(_ m:NSMenu,_ title:String,_ action:Selector,_ key:String="",_ modifiers:NSEvent.ModifierFlags=[.command],target:AnyObject?=nil){let i=m.addItem(withTitle:title,action:action,keyEquivalent:key);i.keyEquivalentModifierMask=modifiers;i.target=target}
        let app=submenu("剪坊")
        add(app,"关于剪坊",#selector(NSApplication.orderFrontStandardAboutPanel(_:)),target:NSApp);app.addItem(.separator())
        add(app,"隐藏剪坊",#selector(NSApplication.hide(_:)),"h",target:NSApp);add(app,"隐藏其他",#selector(NSApplication.hideOtherApplications(_:)),"h",[.command,.option],target:NSApp);add(app,"全部显示",#selector(NSApplication.unhideAllApplications(_:)),target:NSApp);app.addItem(.separator())
        add(app,"退出剪坊",#selector(NSApplication.terminate(_:)),"q")
        let file=submenu("文件")
        add(file,"新建横版工程",#selector(newLandscape),"n",target:self);add(file,"新建竖版工程",#selector(newPortrait),"n",[.command,.shift],target:self);add(file,"打开工程…",#selector(openProject),"o",target:self)
        let samples=NSMenu(title:"示例工程");add(samples,"60 秒示例",#selector(openF1),target:self);add(samples,"10 分钟基准",#selector(openF2),target:self);let samplesItem=file.addItem(withTitle:"示例工程",action:nil,keyEquivalent:"");samplesItem.submenu=samples;file.addItem(.separator())
        add(file,"保存",#selector(saveAction),"s",target:self);add(file,"另存为…",#selector(saveAs),"s",[.command,.shift],target:self);add(file,"收集工程…",#selector(collectProject),target:self);file.addItem(.separator())
        add(file,"导入素材…",#selector(importMedia),"i",target:self);add(file,"重连所选素材…",#selector(relinkAsset),target:self);add(file,"导入 SRT…",#selector(importSRT),target:self);add(file,"导出 SRT…",#selector(exportSRT),target:self);file.addItem(.separator())
        add(file,"导出 MP4…",#selector(exportVideo),"e",target:self);add(file,"取消导出",#selector(cancelExport),".",target:self);file.addItem(.separator())
        add(file,"恢复自动保存",#selector(recoverProject),target:self);add(file,"打开恢复历史",#selector(openRecoveryHistory),target:self)
        let edit=submenu("编辑")
        add(edit,"撤销剪辑",#selector(undoEdit),"z",target:self);add(edit,"重做剪辑",#selector(redoEdit),"z",[.command,.shift],target:self);edit.addItem(.separator())
        add(edit,"剪切",#selector(NSText.cut(_:)),"x");add(edit,"复制",#selector(NSText.copy(_:)),"c");add(edit,"粘贴",#selector(NSText.paste(_:)),"v");add(edit,"全选",#selector(NSText.selectAll(_:)),"a");edit.addItem(.separator())
        add(edit,"在播放头分割",#selector(splitClip),"b",target:self);add(edit,"删除片段",#selector(deleteClip),"\u{8}",target:self);add(edit,"添加字幕",#selector(addSubtitle),"t",[.command,.option],target:self);add(edit,"收尾到内容",#selector(fitDuration),target:self)
        let view=submenu("显示")
        add(view,"显示或隐藏侧栏",#selector(toggleSidebar),"s",[.command,.control],target:self);add(view,"显示或隐藏检查器",#selector(toggleInspector),"i",[.command,.option],target:self);view.addItem(.separator());add(view,"播放 / 暂停",#selector(togglePlayback),target:self)
        let windows=submenu("窗口");add(windows,"最小化",#selector(NSWindow.performMiniaturize(_:)),"m");add(windows,"缩放",#selector(NSWindow.performZoom(_:)));NSApp.windowsMenu=windows
        NSApp.mainMenu=menu
    }

    // MARK: Model → views
    func refreshFields(){
        window?.title=project.name;window?.subtitle=dirty ? "剪坊 · 已编辑":"剪坊";window?.isDocumentEdited=dirty
        formatLabel.stringValue="\(project.width)×\(project.height) · 30 fps";setVideoAspect()
        reloadSources();timeline.project=project;timeline.selected=selected;scrubber.maxValue=Double(project.durationFrames)/30;updateTimeLabel(Int((scrubber.doubleValue*30).rounded()))
        selections=[];clipPicker.removeAllItems()
        let videos=project.videoClips.sorted{($0.track,$0.startFrame)<($1.track,$1.startFrame)}
        for c in videos{selections.append(.video(c.id));clipPicker.addItem(withTitle:String(format:"V%d · %.2fs · %@",c.track+1,Double(c.startFrame)/30,assetName(c.assetID)))}
        for c in project.audioClips.sorted(by:{($0.track,$0.startFrame)<($1.track,$1.startFrame)}){selections.append(.audio(c.id));clipPicker.addItem(withTitle:String(format:"A%d · %.2fs · %@",c.track+1,Double(c.startFrame)/30,assetName(c.assetID)))}
        for c in project.subtitles.sorted(by:{$0.startFrame<$1.startFrame}){selections.append(.subtitle(c.id));clipPicker.addItem(withTitle:String(format:"字幕 · %.2fs · %@",Double(c.startFrame)/30,String(c.text.prefix(16))))}
        if selections.isEmpty{clipPicker.addItem(withTitle:"未选择片段")}
        if let selected,let i=selections.firstIndex(of:selected){clipPicker.selectItem(at:i)}else{selected=selections.first;clipPicker.selectItem(at:0)}
        for i in 0..<6{trackChecks[i].state = (i<2 ? (project.hiddenVideoTracks ?? []).contains(i):(project.mutedAudioTracks ?? []).contains(i-2)) ? .off:.on}
        updateInspector();scrollInspectorTop();changeZoom();updateCache()
    }
    func assetName(_ id:String)->String{project.assets.first(where:{$0.id==id}).map{URL(fileURLWithPath:$0.path).lastPathComponent} ?? id}
    func select(_ selection:ClipSelection?){selected=selection;timeline.selected=selection;timeline.needsDisplay=true;if let selection,let i=selections.firstIndex(of:selection){clipPicker.selectItem(at:i)};updateInspector();scrollInspectorTop()}
    @objc func pickClip(){let i=clipPicker.indexOfSelectedItem;if selections.indices.contains(i){select(selections[i])}}
    func scrollInspectorTop(){inspectorScroll.contentView.scroll(to:.zero);inspectorScroll.reflectScrolledClipView(inspectorScroll.contentView)}
    func updateInspector(){
        // Every field starts empty and disabled; the selected clip fills only the fields it has, so
        // nothing shows the previous clip's numbers (or a cleared selection's) greyed out.
        fields.values.forEach{$0.isEnabled=false;$0.stringValue=""};subtitleText.isEditable=false;subtitleText.string="";trackPicker.removeAllItems();rotationPicker.removeAllItems();rotationPicker.isEnabled=false;selectionLabel.stringValue="选择片段后，修改参数并应用"
        func set(_ key:String,_ value:Double){fields[key]?.stringValue=String(format:"%.3f",value);fields[key]?.isEnabled=true}
        func show(_ tab:Int){inspectorTabs.selectedSegment=tab;switchInspectorTab()}
        guard let selected else{clipPicker.selectItem(at:-1);return}
        switch selected{
        case .video(let id):guard let c=project.videoClips.first(where:{$0.id==id}) else{return};set("start",Double(c.startFrame)/30);set("source",Double(c.sourceStartFrame)/30);set("duration",Double(c.durationFrames)/30);set("x",c.rect.x);set("y",c.rect.y);set("width",c.rect.width);set("height",c.rect.height);set("opacity",c.opacity)
            // Rotation is stored in multiples of 90°; keep any other stored value selectable as-is.
            let angles=Array(Set([0,90,180,270,c.rotationDegrees])).sorted();for a in angles{rotationPicker.addItem(withTitle:"\(a)°");rotationPicker.lastItem?.tag=a};rotationPicker.selectItem(withTag:c.rotationDegrees);rotationPicker.isEnabled=true
            trackPicker.addItems(withTitles:["V1","V2"]);trackPicker.selectItem(at:c.track);selectionLabel.stringValue=c.linkGroupID == nil ? "视频/图片 · 未关联声音":"画面与原声联动 · 时间编辑同步";if inspectorTabs.selectedSegment != 3{show(0)}
        case .audio(let id):guard let c=project.audioClips.first(where:{$0.id==id}) else{return};set("start",Double(c.startFrame)/30);set("source",Double(c.sourceStartFrame)/30);set("duration",Double(c.durationFrames)/30);set("gain",c.gain);set("fadeIn",Double(c.fadeInFrames)/30);set("fadeOut",Double(c.fadeOutFrames)/30);trackPicker.addItems(withTitles:["A1","A2","A3","A4"]);trackPicker.selectItem(at:c.track);selectionLabel.stringValue=c.linkGroupID == nil ? "独立音频":"视频原声 · 时间编辑与画面同步";if inspectorTabs.selectedSegment != 3{show(1)}
        case .subtitle(let id):guard let c=project.subtitles.first(where:{$0.id==id}) else{return};set("start",Double(c.startFrame)/30);set("duration",Double(c.endFrame-c.startFrame)/30);set("font",c.fontSize);fields["position"]?.stringValue=c.positionY.map{String(format:"%.3f",$0)} ?? "默认";fields["position"]?.isEnabled=true;fields["color"]?.stringValue=c.colorHex;fields["color"]?.isEnabled=true;subtitleText.string=c.text;subtitleText.isEditable=true;trackPicker.addItem(withTitle:"字幕");selectionLabel.stringValue="中英最多两行 · 时间吸附到30fps项目帧";if inspectorTabs.selectedSegment != 3{show(2)}
        }
    }
    func number(_ key:String)throws->Double{guard let n=Double(fields[key]?.stringValue ?? ""),n.isFinite,abs(n)<=1_000_000 else{throw ProjectError.invalid("参数不是有效数字：\(key)")};return n}
    func frameField(_ key:String)throws->Int{Int((try number(key)*30).rounded())}
    func contentEnd(_ p:EditorProject)->Int{max(1,(p.videoClips.map{$0.startFrame+$0.durationFrames}+p.audioClips.map{$0.startFrame+$0.durationFrames}+p.subtitles.map(\.endFrame)).max() ?? 1)}
    func ensureEditable()->Bool{if busy{showError(ProjectError.invalid("正在处理上一项操作，请稍后"));return false};return true}
    func apply(_ candidate:EditorProject,label:String,replacementHistory:EditHistory?=nil,after:(()->Void)?=nil){
        guard ensureEditable() else{return}
        // With media offline the preview cannot compile; the edit (and undo/redo) still commits on
        // project validation, the preview waits for relink/removal, and export keeps its strict checks.
        let offline=candidate.offlineAssetIDs(baseURL:baseURL)
        if !offline.isEmpty{do{try candidate.validate()}catch{showError(error);return}
            player.pause();if let replacementHistory{history=replacementHistory}else{history.record(before:project,after:candidate,label:label)}
            project=candidate;dirty=true;buildGeneration+=1;buildTask?.cancel();compiled=nil;player.replaceCurrentItem(with:nil);refreshFields();persistRecovery()
            statusLabel.stringValue="已完成：\(label)。有 \(offline.count) 个素材离线（\(offline.map{assetName($0)}.joined(separator:"、"))），预览暂停；重连或删除相关片段后恢复";after?();return}
        busy=true;let old=project,root=baseURL;player.pause();statusLabel.stringValue="正在验证：\(label)…"
        Task{do{let built=try await TimelineEngine.compile(project:candidate,baseURL:root)
            if let replacementHistory{history=replacementHistory}else{history.record(before:old,after:candidate,label:label)}
            project=candidate;dirty=true;busy=false;refreshFields();install(built,at:scrubber.doubleValue);persistRecovery();statusLabel.stringValue="已完成：\(label)";after?()
        }catch{busy=false;refreshFields();showError(error)}}
    }
    func persistRecovery(){do{try RecoveryStore.write(project,baseURL:baseURL,projectURL:projectURL,to:recoveryURL,unsaved:dirty);saveLabel.stringValue=dirty ? "已自动保存恢复副本":"已保存"}catch{saveLabel.stringValue="未保存：\(error.localizedDescription)";showError(error)}}
    var recoveryHistoryURL:URL{recoveryURL.deletingLastPathComponent().appendingPathComponent("history",isDirectory:true)}
    func preserveRecovery()throws{guard dirty else{return};let folder=recoveryHistoryURL;try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);try RecoveryStore.write(project,baseURL:baseURL,projectURL:projectURL,to:folder.appendingPathComponent(UUID().uuidString+".json"))}
    /// History copies are never deleted automatically; this shows them in Finder.
    @objc func openRecoveryHistory(){do{try FileManager.default.createDirectory(at:recoveryHistoryURL,withIntermediateDirectories:true);NSWorkspace.shared.activateFileViewerSelecting([recoveryHistoryURL])}catch{showError(error)}}
    func mayReplace()->Bool{guard ensureEditable() else{return false};if !dirty{return true};let a=NSAlert();a.messageText="当前工程尚未手动保存";a.informativeText="可以保存后继续，或保留独立恢复副本后继续。";a.addButton(withTitle:"保存工程");a.addButton(withTitle:"保留恢复副本并继续");a.addButton(withTitle:"取消");switch a.runModal(){case .alertFirstButtonReturn:return save(toNew:false);case .alertSecondButtonReturn:do{try preserveRecovery();return true}catch{showError(error);return false};default:return false}}
    func install(_ built:CompiledTimeline,at seconds:Double){compiled=built;buildGeneration+=1;buildTask?.cancel();let item=AVPlayerItem(asset:built.composition);item.videoComposition=built.videoComposition;item.audioMix=built.audioMix;player.replaceCurrentItem(with:item);let target=max(0,min(seconds.isFinite ? seconds:0,Double(project.durationFrames-1)/30));player.seek(to:CMTime(seconds:target,preferredTimescale:30),toleranceBefore:.zero,toleranceAfter:.zero);progress.doubleValue=100}
    func compilePreview(){buildGeneration+=1;let generation=buildGeneration;buildTask?.cancel();let snapshot=project,root=baseURL,position=scrubber.doubleValue;player.pause();player.replaceCurrentItem(with:nil);compiled=nil
        buildTask=Task{do{let built=try await TimelineEngine.compile(project:snapshot,baseURL:root);guard !Task.isCancelled,generation==buildGeneration else{return};install(built,at:position);statusLabel.stringValue="预览就绪"}catch{guard !Task.isCancelled,generation==buildGeneration else{return};showError(error)}}}
    func load(_ url:URL){
        // From the menu while the start window is up: show the main window the project opens in.
        guard mayReplace() else{return};if welcome != nil{enterMain()};busy=true;statusLabel.stringValue="正在读取并核验工程素材…"
        Task{do{let (candidate,changed)=try await Task.detached(priority:.userInitiated){
            // Relative references stay relative (resolved against baseURL on use), so saving
            // an opened package keeps it movable. A changed or missing file does not block opening.
            try AssetStore.verified(ProjectStore.load(url),baseURL:url.deletingLastPathComponent())
        }.value
        project=candidate;changedAssets=Set(changed);baseURL=url.deletingLastPathComponent();projectURL=url;dirty=false;busy=false;history.reset();selected=nil;refreshFields();persistRecovery();compilePreview()
        if !changed.isEmpty{report("有 \(changed.count) 个素材内容已变化",changed.map{assetName($0)+"：文件内容与工程记录的指纹不一致。工程已打开，可重连原文件或删除相关片段；处理前不能导出。"})}
        }catch{busy=false;showError(error)}}
    }
    func newProject(portrait:Bool){guard mayReplace() else{return};if welcome != nil{enterMain()};project=EditorProject(name:portrait ? "未命名竖版":"未命名横版",width:portrait ? 1080:1920,height:portrait ? 1920:1080,durationFrames:1);baseURL=URL(fileURLWithPath:NSHomeDirectory());projectURL=nil;selected=nil;changedAssets=[];dirty=false;history.reset();scrubber.doubleValue=0;refreshFields();persistRecovery();compilePreview()}
    @objc func newLandscape(){newProject(portrait:false)}
    @objc func newPortrait(){newProject(portrait:true)}
    @objc func openProject(){let p=NSOpenPanel();p.allowedContentTypes=[.json];p.canChooseDirectories=false;if p.runModal() == .OK,let u=p.url{load(u)}}
    func sampleURL(_ name:String)->URL?{let roots=[Bundle.main.resourceURL?.appendingPathComponent("Samples"),URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("fixtures")];return roots.compactMap{$0?.appendingPathComponent(name)}.first{FileManager.default.fileExists(atPath:$0.path)}}
    @objc func openF1(){if let u=sampleURL("F1.json"){load(u)}}
    @objc func openF2(){if let u=sampleURL("F2.json"){load(u)}}
    @discardableResult func save(toNew:Bool)->Bool{guard ensureEditable() else{return false};var destination=toNew ? nil:projectURL
        if destination==nil{let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue=project.name+".json";guard panel.runModal() == .OK,let u=panel.url else{return false};destination=u}
        do{let url=destination!;let saved=try ProjectStore.save(project,from:baseURL,to:url);project=saved;baseURL=url.deletingLastPathComponent();projectURL=url;dirty=false;refreshFields();persistRecovery();statusLabel.stringValue="工程已保存：\(url.lastPathComponent)";return true}catch{showError(error);return false}}
    @objc func saveAction(){_ = save(toNew:false)}
    @objc func saveAs(){_ = save(toNew:true)}
    @objc func collectProject(){guard ensureEditable() else{return};let panel=NSSavePanel();panel.nameFieldStringValue=project.name+"-工程包";panel.title="收集到新的文件夹（包含素材）";guard panel.runModal() == .OK,let url=panel.url else{return};let snapshot=project,root=baseURL;busy=true;statusLabel.stringValue="正在复制并核验素材…"
        Task{do{let collected=try await Task.detached{try AssetStore.collect(snapshot,baseURL:root,to:url)}.value;project=collected;changedAssets=[];baseURL=url;projectURL=url.appendingPathComponent("project.json");history.reset();dirty=false;busy=false;refreshFields();persistRecovery();statusLabel.stringValue="已收集可移动工程：\(url.lastPathComponent)"}catch{busy=false;showError(error)}}}
    @objc func recoverProject(){guard mayReplace() else{return};if welcome != nil{enterMain()};do{let recovered=try RecoveryStore.read(recoveryURL);project=recovered.project;changedAssets=[];baseURL=recoveryURL.deletingLastPathComponent();projectURL=recovered.projectURL;dirty=true;history.reset();selected=nil;refreshFields();saveLabel.stringValue="已恢复自动保存，请保存工程";compilePreview()}catch{showError(error)}}
    @objc func undoEdit(){guard ensureEditable() else{return};var next=history;if let p=next.undo(){apply(p,label:"撤销",replacementHistory:next)}}
    @objc func redoEdit(){guard ensureEditable() else{return};var next=history;if let p=next.redo(){apply(p,label:"重做",replacementHistory:next)}}
    @objc func splitClip(){guard let selected else{return};do{apply(try TimelineEdits.split(project,selection:selected,atFrame:Int((scrubber.doubleValue*30).rounded())),label:"分割片段")}catch{showError(error)}}
    @objc func deleteClip(){guard let selected else{return};do{apply(try TimelineEdits.delete(project,selection:selected),label:"删除片段")}catch{showError(error)}}
    func move(_ selection:ClipSelection,frame:Int,track:Int){do{var p=project;let length=timeline.interval(selection)?.1 ?? 1;p.durationFrames=max(p.durationFrames,frame+length);apply(try TimelineEdits.move(p,selection:selection,toFrame:frame,track:track),label:"移动片段")}catch{showError(error);timeline.needsDisplay=true}}
    func trim(_ selection:ClipSelection,start:Int,end:Int){do{apply(try TimelineEdits.trim(project,selection:selection,startFrame:start,endFrame:end),label:"裁剪片段")}catch{showError(error)}}
    @objc func fitDuration(){var p=project;p.durationFrames=contentEnd(p);apply(p,label:"收尾到内容")}
    @objc func toggleTrack(_ button:NSButton){var p=project;if button.tag<2{var hidden=Set(p.hiddenVideoTracks ?? []);if button.state == .off{hidden.insert(button.tag)}else{hidden.remove(button.tag)};p.hiddenVideoTracks=hidden.sorted()}else{var muted=Set(p.mutedAudioTracks ?? []);if button.state == .off{muted.insert(button.tag-2)}else{muted.remove(button.tag-2)};p.mutedAudioTracks=muted.sorted()};apply(p,label:"轨道开关")}
    @objc func applyInspector(){guard let selected else{return};do{let start=try frameField("start"),length=try frameField("duration");guard start>=0,length>0,start<=18000,length<=18000-start else{throw ProjectError.invalid("片段时间须位于10分钟以内")};var p=project;p.durationFrames=max(p.durationFrames,start+length)
        switch selected{
        case .video(let id):guard let old=p.videoClips.first(where:{$0.id==id}) else{return};let source=try frameField("source")
            if p.assets.first(where:{$0.id==old.assetID})?.kind == .image{guard source==0 else{throw ProjectError.invalid("静帧素材入点须为0")};let i=p.videoClips.firstIndex{$0.id==id}!;p.videoClips[i].durationFrames=length;p.durationFrames=max(p.durationFrames,old.startFrame+length)}else{let trimStart=old.startFrame+source-old.sourceStartFrame;p=try TimelineEdits.trim(p,selection:selected,startFrame:trimStart,endFrame:trimStart+length)}
            p=try TimelineEdits.move(p,selection:selected,toFrame:start,track:trackPicker.indexOfSelectedItem);let i=p.videoClips.firstIndex{$0.id==id}!;p.videoClips[i].rect=FrameRect(x:try number("x"),y:try number("y"),width:try number("width"),height:try number("height"));p.videoClips[i].opacity=try number("opacity");p.videoClips[i].rotationDegrees=rotationPicker.selectedTag()
        case .audio(let id):guard let old=p.audioClips.first(where:{$0.id==id}) else{return};let source=try frameField("source"),trimStart=old.startFrame+source-old.sourceStartFrame;p=try TimelineEdits.trim(p,selection:selected,startFrame:trimStart,endFrame:trimStart+length);p=try TimelineEdits.move(p,selection:selected,toFrame:start,track:trackPicker.indexOfSelectedItem);let i=p.audioClips.firstIndex{$0.id==id}!;p.audioClips[i].gain=try number("gain");p.audioClips[i].fadeInFrames=try frameField("fadeIn");p.audioClips[i].fadeOutFrames=try frameField("fadeOut")
        case .subtitle(let id):let i=p.subtitles.firstIndex{$0.id==id}!;guard !subtitleText.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw ProjectError.invalid("字幕文字不能为空；不需要这条字幕时请用“删除片段”")};p.subtitles[i].startFrame=start;p.subtitles[i].endFrame=start+length;p.subtitles[i].text=subtitleText.string;p.subtitles[i].fontSize=try number("font");p.subtitles[i].colorHex=fields["color"]!.stringValue;p.subtitles[i].positionY=fields["position"]?.stringValue == "默认" ? nil:try number("position")
        };try p.validate();apply(p,label:"修改片段参数")
    }catch{showError(error)}}
    @objc func addSubtitle(){let start=Int((scrubber.doubleValue*30).rounded());let cue=SubtitleCue(startFrame:start,endFrame:min(18000,start+90),text:"输入字幕");var p=project;p.durationFrames=max(p.durationFrames,cue.endFrame);p.subtitles.append(cue);apply(p,label:"添加字幕",after:{[weak self] in self?.select(.subtitle(cue.id))})}
    @objc func importSRT(){guard ensureEditable() else{return};let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"srt") ?? .plainText,.plainText];guard panel.runModal() == .OK,let url=panel.url else{return};do{let data=try Data(contentsOf:url);let text=try SRTCodec.text(from:data);var p=project;let cues=try SRTCodec.parse(text);p.durationFrames=max(p.durationFrames,cues.map(\.endFrame).max() ?? 1);let candidate=try SRTCodec.importing(text,into:p,replacing:false);let notes=SRTCodec.compatibilityNotes(text);apply(candidate,label:"导入SRT"+(notes.isEmpty ? "":"（"+notes.joined(separator:"；")+"）"))}catch{showError(error);let parts=error.localizedDescription.components(separatedBy:"：");if parts.count>1{report("SRT 未导入："+parts[0],parts.dropFirst().joined(separator:"：").components(separatedBy:"；"))}}}
    @objc func exportSRT(){let panel=NSSavePanel();panel.allowedContentTypes=[UTType(filenameExtension:"srt") ?? .plainText];panel.nameFieldStringValue=project.name+".srt";guard panel.runModal() == .OK,let url=panel.url else{return};do{let text=try SRTCodec.encode(project.subtitles);try text.write(to:url,atomically:true,encoding:.utf8);statusLabel.stringValue="字幕已导出：\(url.lastPathComponent)"}catch{showError(error)}}
    @objc func relinkAsset(){guard ensureEditable(),let index=selectedAssetIndex else{showError(ProjectError.invalid("先在侧栏选择要重连的素材"));return};let id=project.assets[index].id;let panel=NSOpenPanel();guard panel.runModal() == .OK,let url=panel.url else{return};do{let candidate=try AssetStore.relink(project,baseURL:baseURL,assetID:id,to:url);history.record(before:project,after:candidate,label:"重连素材");project=candidate;changedAssets.remove(id);dirty=true;refreshFields();persistRecovery();compilePreview()}catch{showError(error)}}
    /// Each file is probed first (all format problems at once), fingerprinted only after it
    /// passes, and committed independently: one bad file no longer discards the whole batch.
    @objc func importMedia(){guard ensureEditable() else{return};let panel=NSOpenPanel();panel.allowedContentTypes=[.movie,.audio,.png,.jpeg];panel.allowsMultipleSelection=true;guard panel.runModal() == .OK,!panel.urls.isEmpty else{return};let urls=panel.urls,old=project,root=baseURL,playhead=Int((scrubber.doubleValue*30).rounded());busy=true;statusLabel.stringValue="正在验证导入素材…"
        Task{var candidate=old,imported=0,notes=[String](),failures=[String]()
            for url in urls{let name=url.lastPathComponent,id=UUID().uuidString
                do{
                    // The size/modification stamp taken with the hash lets later opens skip rereading this file.
                    let isImage=["png","jpg","jpeg"].contains(url.pathExtension.lowercased())
                    let info:MediaInspection?=isImage ? nil:try await TimelineEngine.inspect(url)
                    if let rejection=info?.rejection{throw ProjectError.invalid(rejection)}
                    if let info,info.hasVideo,info.videoFrames==nil{throw ProjectError.invalid("无法读取视频长度")}
                    if let info,!info.hasVideo,info.audioFrames==nil{throw ProjectError.invalid("无法读取音频长度")}
                    let identity=try await Task.detached{try AssetStore.hashed(url)}.value
                    if let info{
                        if info.hasVideo{
                            let placed=try ImportPlacement.appendVideo(candidate,assetID:id,path:url.path,fingerprint:identity.fingerprint,video:info.videoFrames!,audio:info.audioOnlyProblem == nil ? info.audioFrames:nil)
                            candidate=placed.project;if let problem=info.audioOnlyProblem{notes.append("\(name)：\(problem)")};if let note=placed.note{notes.append("\(name)：\(note)")}
                        }else{candidate=try ImportPlacement.appendAudio(candidate,assetID:id,path:url.path,fingerprint:identity.fingerprint,audio:info.audioFrames!,at:playhead)}
                    }else{candidate=try ImportPlacement.appendImage(candidate,assetID:id,path:url.path,fingerprint:identity.fingerprint)}
                    if let i=candidate.assets.firstIndex(where:{$0.id==id}){candidate.assets[i]=AssetStore.stamped(candidate.assets[i],identity.stamp)}
                    imported+=1
                }catch{failures.append(error.localizedDescription.contains(name) ? error.localizedDescription:"\(name)：\(error.localizedDescription)")}
            }
            guard imported>0 else{busy=false;report("没有导入任何素材",failures);return}
            do{let built=try await TimelineEngine.compile(project:candidate,baseURL:root);history.record(before:old,after:candidate,label:"导入素材");project=candidate;dirty=true;busy=false;refreshFields();install(built,at:scrubber.doubleValue);persistRecovery()
                statusLabel.stringValue="已导入 \(imported)/\(urls.count) 个素材"+(failures.isEmpty ? "":"；\(failures.count) 个失败")+(notes.isEmpty ? "":"；有提示")
                if !failures.isEmpty || !notes.isEmpty{report("已导入 \(imported)/\(urls.count) 个素材",notes+failures)}
            }catch{busy=false;showError(error)}}
    }
    /// Non-blocking sheet listing per-file import results.
    func report(_ title:String,_ lines:[String]){lines.forEach{NSLog("IndependentEditor: %@",$0)};if title.hasPrefix("没有"){statusLabel.stringValue="未完成：\(title)"};let alert=NSAlert();alert.messageText=title;alert.informativeText=lines.joined(separator:"\n\n");alert.beginSheetModal(for:window){_ in}}
    @objc func exportVideo(){guard !exporting,ensureEditable() else{return};let p=NSSavePanel();p.allowedContentTypes=[.mpeg4Movie];p.nameFieldStringValue=project.name+".mp4";guard p.runModal() == .OK,let url=p.url else{return};guard !FileManager.default.fileExists(atPath:url.path) else{showError(ProjectError.invalid("请用新文件名导出，已有成片不会被覆盖"));return};let snapshot=project,root=baseURL;exporting=true;statusLabel.stringValue="正在导出冻结工程…";progress.doubleValue=0;exportGeneration+=1;let generation=exportGeneration
        // Cancellation now reaches the fingerprint stage; progress updates that arrive after this
        // export finished (or from an older export) are dropped, so 100% never falls back to 99%.
        exportTask=Task{[self] in do{let verified=try await AssetStore.fingerprintedInBackground(snapshot,baseURL:root);let built=try await TimelineEngine.compile(project:verified,baseURL:root);try Task.checkCancellation();let mix=try await TimelineEngine.export(built,to:url){[weak self] p in Task{@MainActor in guard let self,self.exporting,self.exportGeneration==generation else{return};self.progress.doubleValue=p*100}};exporting=false;statusLabel.stringValue="导出完成：\(url.lastPathComponent)"+(mix.clippingWarning == nil ? "":"（混音有削波，见提示）");progress.doubleValue=100;if let warning=mix.clippingWarning{report("导出完成，但混音有削波",[warning])}}catch{exporting=false;if error is CancellationError{statusLabel.stringValue="已取消导出，原工程与已有成片保持不变";progress.doubleValue=0}else{showError(error)}}}
    }
    @objc func cancelExport(){exportTask?.cancel()}
    @objc func togglePlayback(){guard compiled != nil else{return};if player.rate==0{if player.currentTime().seconds>=Double(project.durationFrames-1)/30{seek(0)};player.play()}else{player.pause()}}
    func seek(_ frame:Int){let f=max(0,min(project.durationFrames-1,frame));scrubber.doubleValue=Double(f)/30;player.pause();player.seek(to:CMTime(value:Int64(f),timescale:30),toleranceBefore:.zero,toleranceAfter:.zero);timeline.position=Double(f);timeline.needsDisplay=true}
    @objc func scrub(){seek(Int((scrubber.doubleValue*30).rounded()))}
    @objc func stepBack(){seek(Int((scrubber.doubleValue*30).rounded())-1)}
    @objc func stepForward(){seek(Int((scrubber.doubleValue*30).rounded())+1)}
    @objc func changeZoom(){let width=max(900,timelineScroll.contentSize.width)*zoom.doubleValue;timeline.setFrameSize(NSSize(width:width,height:TimelineView.contentHeight));timeline.needsDisplay=true}
    func updateCache(){let snapshot=project,root=baseURL;cache.refresh(project:snapshot,baseURL:root){[weak self] thumbs,waves in self?.timeline.thumbnails=thumbs;self?.timeline.waveforms=waves;self?.timeline.needsDisplay=true}}
    func windowDidResize(_ notification:Notification){changeZoom()}
    func windowShouldClose(_ sender:NSWindow)->Bool{if sender === welcome{enterMain();return false};guard !exporting else{showError(ProjectError.invalid("请等待导出完成或取消导出后关闭"));return false};NSApp.terminate(nil);return false}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{if exporting{showError(ProjectError.invalid("导出进行中，请先取消或等待完成"));return .terminateCancel};return mayReplace() ? .terminateNow:.terminateCancel}
    func showError(_ error:Error){statusLabel.stringValue="未完成：\(error.localizedDescription)";NSLog("IndependentEditor: %@",error.localizedDescription)}
}
