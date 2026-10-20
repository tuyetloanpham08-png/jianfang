import Foundation
import CryptoKit

public enum AssetStore {
    /// Streaming SHA-256; the entire media file is never loaded into memory.
    public static func fingerprint(_ url:URL) throws -> String {
        guard url.isFileURL,(try? url.resourceValues(forKeys:[.isRegularFileKey]))?.isRegularFile==true else { throw ProjectError.invalid("素材必须是本地普通文件，且当前可以访问：\(url.lastPathComponent)") }
        do {
            let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
            var hash=SHA256()
            // Checked per 1 MB chunk, so cancelling an export stops a multi-GB hash promptly.
            while let data=try handle.read(upToCount:1_048_576),!data.isEmpty { if Task.isCancelled { throw CancellationError() };hash.update(data:data) }
            return hash.finalize().map{String(format:"%02x",$0)}.joined()
        } catch is CancellationError { throw CancellationError() }
        catch { throw ProjectError.invalid("无法读取素材内容：\(url.lastPathComponent)。请确认文件没有被移走、外接盘已连接且有读取权限") }
    }
    /// Current size and modification time, nil when the file cannot be stat'ed.
    public static func stamp(_ url:URL) -> (size:Int64,modifiedAt:Double)? {
        guard let values=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]),let size=values.fileSize,let date=values.contentModificationDate else { return nil }
        return (Int64(size),date.timeIntervalSinceReferenceDate)
    }
    /// SHA-256 plus the stamp taken *before* reading: if the file is modified while it is being
    /// hashed, the recorded stamp no longer matches and the next open rehashes it.
    public static func hashed(_ url:URL) throws -> (fingerprint:String,stamp:(size:Int64,modifiedAt:Double)?) {
        let before=stamp(url);return (try fingerprint(url),before)
    }
    public static func stamped(_ asset:MediaAsset,_ stamp:(size:Int64,modifiedAt:Double)?) -> MediaAsset {
        var a=asset;a.byteSize=stamp?.size;a.modifiedAt=stamp?.modifiedAt;return a
    }
    static func stampUnchanged(_ asset:MediaAsset,url:URL) -> Bool {
        guard asset.fingerprint != nil,let size=asset.byteSize,let modified=asset.modifiedAt,let now=stamp(url) else { return false }
        return now.size==size && abs(now.modifiedAt-modified)<0.000_5
    }
    /// Strict check used before export and collection: always rereads and hashes every file.
    public static func fingerprinted(_ project:EditorProject,baseURL:URL) throws -> EditorProject {
        try project.validate();var p=project;p.schemaVersion=2
        p.assets=try project.assets.map { asset in
            let url=try project.assetURL(asset.id,baseURL:baseURL)
            var a=asset;let (value,stamp)=try hashed(url)
            if let expected=asset.fingerprint,expected != value { throw ProjectError.invalid("素材内容已变化：\(url.lastPathComponent)。请重连原文件或删除相关片段后再导出") }
            a.fingerprint=value;return stamped(a,stamp)
        }
        return p
    }
    /// `fingerprinted` off the caller's actor. A detached task does not inherit cancellation, so it
    /// is forwarded explicitly: cancelling the caller (e.g. "取消导出") stops hashing within ~1 MB.
    public static func fingerprintedInBackground(_ project:EditorProject,baseURL:URL) async throws -> EditorProject {
        let job=Task.detached(priority:.userInitiated){try fingerprinted(project,baseURL:baseURL)}
        return try await withTaskCancellationHandler{try await job.value} onCancel:{job.cancel()}
    }
    /// Opening never fails because one file changed or is missing: readable files are
    /// fingerprinted, a mismatch is reported in `changed` (the recorded fingerprint is kept
    /// so the original can still be relinked), and unreadable files are left for relinking.
    public static func verified(_ project:EditorProject,baseURL:URL) throws -> (project:EditorProject,changed:[String]) {
        let result=try verify(project,baseURL:baseURL);return (result.project,result.changed)
    }
    /// As `verified`, plus which assets were actually rehashed. A file whose size and modification
    /// time still equal the stamp recorded with its fingerprint is not reread, so opening a project
    /// with gigabytes of media no longer reads every byte; any stamp difference falls back to a full
    /// hash. Export and collection still run the strict full check (`fingerprinted`).
    public static func verify(_ project:EditorProject,baseURL:URL) throws -> (project:EditorProject,changed:[String],hashed:[String]) {
        try project.validate();var p=project;p.schemaVersion=2;var changed:[String]=[],hashed=[String]()
        for index in p.assets.indices {
            let url=try project.assetURL(p.assets[index].id,baseURL:baseURL)
            guard FileManager.default.isReadableFile(atPath:url.path) else { continue }
            if stampUnchanged(p.assets[index],url:url) { continue }
            let (value,stamp)=try self.hashed(url);hashed.append(p.assets[index].id)
            if let expected=p.assets[index].fingerprint {
                if expected != value { changed.append(p.assets[index].id) }   // keep the old stamp: still changed next time
                else { p.assets[index]=stamped(p.assets[index],stamp) }
            } else { p.assets[index].fingerprint=value;p.assets[index]=stamped(p.assets[index],stamp) }
        }
        return (p,changed,hashed)
    }
    /// Exact-byte relink only. A legacy project must fingerprint its original source first;
    /// file names, extensions, size and duration alone are never accepted as proof of identity.
    public static func relink(_ project:EditorProject,baseURL:URL,assetID:String,to source:URL) throws -> EditorProject {
        try project.validate()
        guard let index=project.assets.firstIndex(where:{$0.id==assetID}),let expected=project.assets[index].fingerprint else { throw ProjectError.invalid("缺少原素材指纹，无法安全重连；不能按同名文件猜测") }
        let (value,stamp)=try hashed(source)
        guard value==expected else { throw ProjectError.invalid("新素材SHA-256与原素材不一致，已拒绝重连") }
        var p=project;p.schemaVersion=2;p.assets[index].path=source.standardizedFileURL.path;p.assets[index]=stamped(p.assets[index],stamp);try p.validate();return p
    }
    /// A fresh system-managed temporary directory on the same volume as `folder`, so the final move
    /// stays atomic. After a crash, leftovers sit in the system's TemporaryItems area, which macOS
    /// purges, instead of as hidden partial files in the user's folder. nil when the volume has none.
    public static func stagingDirectory(near folder: URL) -> URL? {
        try? FileManager.default.url(for:.itemReplacementDirectory,in:.userDomainMask,appropriateFor:folder,create:true)
    }
    /// Collect into a new directory with project.json and media/. Nothing is published until
    /// copies and hashes pass. Existing destinations and original source files are never replaced.
    @discardableResult public static func collect(_ project:EditorProject,baseURL:URL,to destination:URL) throws -> EditorProject {
        let fm=FileManager.default
        guard destination.isFileURL,!fm.fileExists(atPath:destination.path) else { throw ProjectError.invalid("收集目标必须是尚不存在的本地目录") }
        let p=try fingerprinted(project,baseURL:baseURL)
        let parent=destination.deletingLastPathComponent()
        guard (try parent.resourceValues(forKeys:[.isDirectoryKey])).isDirectory==true else { throw ProjectError.invalid("收集目标的父目录不存在") }
        let area=stagingDirectory(near:parent)
        let staging=area?.appendingPathComponent("collecting",isDirectory:true) ?? parent.appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString).collecting",isDirectory:true)
        try fm.createDirectory(at:staging.appendingPathComponent("media",isDirectory:true),withIntermediateDirectories:true)
        var published=false
        defer{if !published { try? fm.removeItem(at:staging) };if let area { try? fm.removeItem(at:area) }}
        var result=p
        result.assets=try p.assets.map { asset in
            let source=try p.assetURL(asset.id,baseURL:baseURL)
            let ext=source.pathExtension.lowercased().filter{$0.isASCII && ($0.isLetter || $0.isNumber)}
            let fileName=asset.fingerprint!+(ext.isEmpty ? "" : "."+ext)
            let relative="media/"+fileName,copy=staging.appendingPathComponent(relative)
            if !fm.fileExists(atPath:copy.path) { try fm.copyItem(at:source,to:copy) }
            let (value,stamp)=try hashed(copy)
            guard value==asset.fingerprint else { throw ProjectError.invalid("素材收集后指纹不一致") }
            var a=stamped(asset,stamp);a.path=relative;return a
        }
        try result.validate();try ProjectStore.encoded(result).write(to:staging.appendingPathComponent("project.json"),options:.atomic)
        // moveItem refuses an existing destination, including a destination created during copying.
        try fm.moveItem(at:staging,to:destination);published=true;return result
    }
}
