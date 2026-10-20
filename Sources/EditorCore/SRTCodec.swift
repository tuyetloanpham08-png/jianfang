import Foundation

/// UTF-8 SRT. Both millisecond endpoints quantize independently to the nearest project frame
/// (ties round up). Export uses nearest milliseconds, giving exact frame round trips at 30 fps.
/// Cues are half-open intervals. Zero-length after quantization, overlaps and >2 lines reject.
public enum SRTCodec {
    private static func requireFPS(_ fps:Int) throws { guard fps==30 else { throw ProjectError.invalid("SRT仅支持30fps工程") } }
    /// Common public SRT variants are accepted: "," or "." before milliseconds, 1–3 hour digits.
    private static func milliseconds(_ stamp:String) throws -> Int {
        let pieces=stamp.replacingOccurrences(of:",",with:":").replacingOccurrences(of:".",with:":").split(separator:":",omittingEmptySubsequences:false)
        guard pieces.count==4, pieces[0].count>=1, pieces[0].count<=3, pieces[1].count==2,pieces[2].count==2,pieces[3].count==3,
              pieces.allSatisfy({$0.allSatisfy{$0.isASCII && $0.isNumber}}),
              let h=Int(pieces[0]),let m=Int(pieces[1]),let s=Int(pieces[2]),let ms=Int(pieces[3]),m<60,s<60 else { throw ProjectError.invalid("SRT时间格式无效：\(stamp)") }
        return ((h*60+m)*60+s)*1000+ms
    }
    private static let gb18030=String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    /// UTF-8 only (with or without BOM). UTF-16 and probable GBK/GB18030 files are named so the
    /// user knows what to convert; they are never decoded by guessing.
    public static func text(from data:Data) throws -> String {
        if let text=String(data:data,encoding:.utf8) { return text }
        if data.starts(with:[0xff,0xfe]) || data.starts(with:[0xfe,0xff]) { throw ProjectError.invalid("SRT 是 UTF-16 编码（检测到字节顺序标记），须为 UTF-8：请用文本编辑器“另存为 UTF-8”后再导入") }
        if let guess=String(data:data,encoding:gb18030), guess.unicodeScalars.contains(where:{(0x4E00...0x9FFF).contains($0.value)}) {
            throw ProjectError.invalid("SRT 疑似 GBK/GB18030 编码，须为 UTF-8：请用文本编辑器“另存为 UTF-8”后再导入")
        }
        throw ProjectError.invalid("SRT 不是有效的 UTF-8 文本，须为 UTF-8：请用文本编辑器“另存为 UTF-8”后再导入")
    }
    public static func parse(_ data:Data,fps:Int=30) throws -> [SubtitleCue] { try parse(text(from:data),fps:fps) }
    /// Inline style markup that is removed rather than burned in literally: <i> <b> <u> <font …> and {\…} overrides.
    private static let styleTag=try! NSRegularExpression(pattern:#"</?(?:i|b|u|font)(?:\s[^>]*)?>|\{\\[^}]*\}"#,options:[.caseInsensitive])
    private static func stripStyle(_ line:String)->(String,Int) {
        let range=NSRange(line.startIndex...,in:line),count=styleTag.numberOfMatches(in:line,range:range)
        return (count==0 ? line : styleTag.stringByReplacingMatches(in:line,range:range,withTemplate:""),count)
    }
    /// What import silently tolerated, for the UI to state: ignored position coordinates and removed style tags.
    public static func compatibilityNotes(_ input:String) -> [String] {
        let lines=input.replacingOccurrences(of:"\r\n",with:"\n").components(separatedBy:"\n")
        let coordinates=lines.filter{$0.contains("-->") && $0.components(separatedBy:"-->").last!.trimmingCharacters(in:.whitespaces).contains(" ")}.count
        let tags=lines.filter{!$0.contains("-->")}.map{stripStyle($0).1}.reduce(0,+)
        return (coordinates>0 ? ["已忽略 \(coordinates) 处时间行后的位置坐标（位置以工程样式为准）"]:[])+(tags>0 ? ["已去除 \(tags) 个样式标签（如 <i>、{\\an8}），只保留文字"]:[])
    }
    public static func parse(_ input:String,fps:Int=30) throws -> [SubtitleCue] { try entries(input,fps:fps).map(\.cue) }

    /// A parsed cue with its SRT sequence number and first line, for error locations.
    struct Entry { let index:Int; let line:Int; let cue:SubtitleCue }
    private static func stamp(_ frame:Int,fps:Int=30)->String {
        let ms=(frame*1000+fps/2)/fps
        return String(format:"%02d:%02d:%02d,%03d",ms/3_600_000,(ms/60_000)%60,(ms/1000)%60,ms%1000)
    }
    private static func listed(_ title:String,_ problems:[String])->ProjectError {
        .invalid(title+problems.prefix(8).joined(separator:"；")+(problems.count>8 ? "；另有 \(problems.count-8) 处未列出":""))
    }
    /// Every malformed block and every overlap is collected with its block number and line
    /// number, then reported together; nothing is imported while any problem remains.
    static func entries(_ input:String,fps:Int) throws -> [Entry] {
        try requireFPS(fps)
        let text=input.replacingOccurrences(of:"\u{feff}",with:"").replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        var blocks:[(line:Int,lines:[String])]=[],current:[String]=[],firstLine=0
        for (number,line) in text.components(separatedBy:"\n").enumerated() {
            if line.trimmingCharacters(in:.whitespaces).isEmpty { if !current.isEmpty { blocks.append((firstLine,current));current=[] } }
            else { if current.isEmpty { firstLine=number+1 };current.append(line) }
        }
        if !current.isEmpty { blocks.append((firstLine,current)) }
        guard !blocks.isEmpty else { throw ProjectError.invalid("未找到有效字幕；空SRT不会清空现有字幕") }
        var found:[Entry]=[],problems:[String]=[],indices=Set<Int>()
        for (number,block) in blocks.enumerated() {
            do {
                guard let index=Int(block.lines[0].trimmingCharacters(in:.whitespaces)),index>0 else { throw ProjectError.invalid("第一行须为正整数序号") }
                guard indices.insert(index).inserted else { throw ProjectError.invalid("序号 \(index) 重复") }
                guard block.lines.count>=2 else { throw ProjectError.invalid("缺少时间行") }
                let timing=block.lines[1].components(separatedBy:"-->").map{$0.trimmingCharacters(in:.whitespaces)}
                guard timing.count==2 else { throw ProjectError.invalid("时间行须使用 -->") }
                // Position coordinates after the end time ("X1:… Y1:…") are ignored.
                let endStamp=timing[1].split(separator:" ",maxSplits:1).first.map(String.init) ?? ""
                let startMS=try milliseconds(timing[0]),endMS=try milliseconds(endStamp)
                guard endMS>startMS else { throw ProjectError.invalid("结束时间须晚于开始时间") }
                let start=(startMS*fps+500)/1000,end=(endMS*fps+500)/1000
                guard end>start else { throw ProjectError.invalid("量化到30fps后不足一帧") }
                guard end<=18000 else { throw ProjectError.invalid("超出10分钟") }
                // Style tags are removed; a line holding only tags (e.g. "{\an8}") disappears.
                let textLines=block.lines.dropFirst(2).map{stripStyle($0)}.filter{$0.1==0 || !$0.0.trimmingCharacters(in:.whitespaces).isEmpty}.map(\.0)
                guard !textLines.isEmpty, !textLines.allSatisfy({$0.trimmingCharacters(in:.whitespaces).isEmpty}) else { throw ProjectError.invalid("没有字幕文字") }
                guard textLines.count<=2 else { throw ProjectError.invalid("文字超过两行") }
                found.append(Entry(index:index,line:block.line,cue:SubtitleCue(startFrame:start,endFrame:end,text:textLines.joined(separator:"\n"))))
            } catch { problems.append("第\(number+1)条（第\(block.line)行）：\(error.localizedDescription)") }
        }
        let sorted=found.sorted{$0.cue.startFrame<$1.cue.startFrame}
        for (a,b) in zip(sorted,sorted.dropFirst()) where a.cue.endFrame>b.cue.startFrame {
            problems.append("序号 \(a.index)（第\(a.line)行，\(stamp(a.cue.startFrame))–\(stamp(a.cue.endFrame))）与序号 \(b.index)（第\(b.line)行，\(stamp(b.cue.startFrame))–\(stamp(b.cue.endFrame))）时间重叠")
        }
        guard problems.isEmpty else { throw listed("SRT 有 \(problems.count) 处问题，未导入任何字幕：",problems) }
        try validate(sorted.map(\.cue));return sorted
    }
    private static func validate(_ cues:[SubtitleCue]) throws {
        guard !cues.isEmpty else { throw ProjectError.invalid("未找到有效字幕；空SRT不会清空现有字幕") }
        let p=EditorProject(durationFrames:18000,subtitles:cues)
        try p.validate()
        let sorted=cues.sorted{$0.startFrame<$1.startFrame}
        if let index=sorted.firstIndex(where:{$0.isBlank || $0.text.contains("\r")}) {
            let cue=sorted[index]
            throw ProjectError.invalid("第\(index+1)条字幕（\(stamp(cue.startFrame,fps:30)) 开始）\(cue.isBlank ? "文字为空" : "含有回车符")。请在属性里填写文字或删除这条字幕后再导出 SRT")
        }
    }
    public static func encode(_ cues:[SubtitleCue],fps:Int=30) throws -> String {
        try requireFPS(fps);try validate(cues)
        return cues.sorted{$0.startFrame<$1.startFrame}.enumerated().map { index,cue in
            "\(index+1)\n\(stamp(cue.startFrame,fps:fps)) --> \(stamp(cue.endFrame,fps:fps))\n\(cue.text)\n"
        }.joined(separator:"\n")
    }
    /// Appending lists every new cue that overlaps an existing subtitle and imports nothing.
    public static func importing(_ text:String, into project:EditorProject, replacing:Bool=true) throws -> EditorProject {
        try project.validate();let found=try entries(text,fps:project.fps);var result=project;result.schemaVersion=2
        if !replacing {
            var conflicts:[String]=[]
            for e in found { for old in project.subtitles where old.startFrame<e.cue.endFrame && e.cue.startFrame<old.endFrame {
                conflicts.append("序号 \(e.index)（第\(e.line)行，\(stamp(e.cue.startFrame))–\(stamp(e.cue.endFrame))）与已有字幕「\(old.text.replacingOccurrences(of:"\n",with:" ").prefix(12))」（\(stamp(old.startFrame))–\(stamp(old.endFrame))）重叠")
            } }
            guard conflicts.isEmpty else { throw listed("SRT 与已有字幕有 \(conflicts.count) 处时间冲突，未导入任何字幕，请先调整：",conflicts) }
        }
        let cues=found.map(\.cue)
        result.subtitles=replacing ? cues : project.subtitles+cues
        try result.validate();return result
    }
}
