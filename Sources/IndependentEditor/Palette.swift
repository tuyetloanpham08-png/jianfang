import AppKit

/// Colours for the macOS-style layout. Each one resolves against the view's effective
/// appearance, so the window follows the system light/dark setting without extra code.
enum Palette {
    static func dynamic(_ light:NSColor,_ dark:NSColor)->NSColor{NSColor(name:nil){$0.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? dark:light}}
    static func hex(_ v:UInt32)->NSColor{NSColor(srgbRed:CGFloat((v>>16)&0xFF)/255,green:CGFloat((v>>8)&0xFF)/255,blue:CGFloat(v&0xFF)/255,alpha:1)}

    static let viewer=dynamic(hex(0xE9E9EC),hex(0x161618))
    static let panel=dynamic(hex(0xF6F6F6),hex(0x2B2B2D))
    static let card=dynamic(.white,hex(0x2C2C2E))
    static let timeline=dynamic(.white,hex(0x1E1E1E))
    static let lane=dynamic(hex(0xF5F5F7),hex(0x29292B))

    struct ClipStyle {let fill:NSColor,border:NSColor,text:NSColor}
    static let videoClip=ClipStyle(fill:dynamic(hex(0xDCE8FC),hex(0x1F3A5F)),border:dynamic(hex(0xA9C7F5),hex(0x2F5D99)),text:dynamic(hex(0x0B4AA8),hex(0xBFD7FA)))
    static let imageClip=ClipStyle(fill:dynamic(hex(0xE6E2F2),hex(0x3A3350)),border:dynamic(hex(0xC9C1E3),hex(0x5A4F7A)),text:dynamic(hex(0x4B3F78),hex(0xDAD3F2)))
    static let audioClip=ClipStyle(fill:dynamic(hex(0xDCF2E2),hex(0x1E4630)),border:dynamic(hex(0xA6DDB4),hex(0x2F7048)),text:dynamic(hex(0x1B6B34),hex(0xBFE8CC)))
    static let subtitleClip=ClipStyle(fill:dynamic(hex(0xFDEBD3),hex(0x4D3415)),border:dynamic(hex(0xF2C690),hex(0x7A5321)),text:dynamic(hex(0x7A4200),hex(0xF6D9B0)))
}

/// A plain view filled with a (dynamic) colour, optionally rounded with a hairline border.
final class FillView:NSView {
    var color:NSColor{didSet{needsDisplay=true}}
    var cornerRadius:CGFloat=0,bordered=false
    init(_ color:NSColor,cornerRadius:CGFloat=0,bordered:Bool=false){self.color=color;self.cornerRadius=cornerRadius;self.bordered=bordered;super.init(frame:.zero)}
    required init?(coder:NSCoder){fatalError("not used")}
    override func draw(_ dirtyRect:NSRect){
        let path=NSBezierPath(roundedRect:bounds.insetBy(dx:bordered ? 0.5:0,dy:bordered ? 0.5:0),xRadius:cornerRadius,yRadius:cornerRadius)
        color.setFill();path.fill()
        if bordered{NSColor.separatorColor.setStroke();path.lineWidth=1;path.stroke()}
    }
    override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}
}
