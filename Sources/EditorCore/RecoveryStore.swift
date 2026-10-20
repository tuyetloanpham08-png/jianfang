import Foundation

public struct RecoverySnapshot: Codable, Sendable {
    public var version:Int=1
    public let project:EditorProject
    public let projectURL:URL?
    public let savedAt:Date
    /// false when the snapshot equals a manually saved project; nil in older snapshots (treated as unsaved).
    public var unsaved:Bool?=nil
}

/// Immediate atomic snapshot writes. Media references are absolute, so recovery is independent
/// of the original project directory. The last readable primary is retained as .backup.
public enum RecoveryStore {
    /// Public release identity; development and test builds keep separate recovery folders.
    public static let coreBundleID="io.github.jianfang.editor"
    /// Autosave and recovery-history folder for one build. Each bundle ID gets
    /// Application Support/<bundle ID>, and an unbundled `swift run` gets
    /// Jianfang-Dev, so a test build never reads, overwrites or saves through the user's
    /// real autosave. JF_SUPPORT_DIR (an absolute path) overrides both, for isolated GUI checks.
    public static func supportFolder(bundleID:String?,environment:[String:String],home:URL)->URL {
        if let override=environment["JF_SUPPORT_DIR"],override.hasPrefix("/") { return URL(fileURLWithPath:override,isDirectory:true) }
        let root=home.appendingPathComponent("Library/Application Support",isDirectory:true)
        guard let id=bundleID,!id.isEmpty,id.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || $0=="." || $0=="-")}) else {
            return root.appendingPathComponent("Jianfang-Dev",isDirectory:true)
        }
        return root.appendingPathComponent(id,isDirectory:true)
    }
    private static func decode(_ data:Data) throws -> RecoverySnapshot {
        let snapshot=try JSONDecoder().decode(RecoverySnapshot.self,from:data)
        guard snapshot.version==1, snapshot.project.assets.allSatisfy({$0.path.hasPrefix("/")}),snapshot.projectURL?.isFileURL != false else { throw ProjectError.invalid("恢复快照版本或素材路径无效") }
        try snapshot.project.validate();var project=snapshot.project;project.schemaVersion=2
        return RecoverySnapshot(project:project,projectURL:snapshot.projectURL,savedAt:snapshot.savedAt,unsaved:snapshot.unsaved)
    }
    public static func write(_ project:EditorProject,baseURL:URL,projectURL:URL?,to url:URL,unsaved:Bool=true) throws {
        try project.validate()
        guard projectURL?.isFileURL != false else { throw ProjectError.invalid("恢复工程路径须为本地文件") }
        var absolute=project;absolute.schemaVersion=2
        absolute.assets=try project.assets.map { asset in var a=asset;a.path=try project.assetURL(asset.id,baseURL:baseURL).standardizedFileURL.path;return a }
        let snapshot=RecoverySnapshot(project:absolute,projectURL:projectURL,savedAt:Date(),unsaved:unsaved)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];let data=try encoder.encode(snapshot)
        _=try decode(data)
        let fm=FileManager.default;try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        if let previous=try? Data(contentsOf:url), (try? decode(previous)) != nil {
            try previous.write(to:url.appendingPathExtension("backup"),options:.atomic)
        }
        try data.write(to:url,options:.atomic)
    }
    public static func read(_ url:URL) throws -> RecoverySnapshot {
        do { return try decode(Data(contentsOf:url)) }
        catch {
            do { return try decode(Data(contentsOf:url.appendingPathExtension("backup"))) }
            catch let error as ProjectError { throw error }
            catch { throw ProjectError.invalid("恢复文件和它的备份都无法读取或已损坏：\(url.lastPathComponent)。可从菜单“打开恢复历史”查看较早的副本") }
        }
    }
    public static func clear(_ url:URL) throws {
        for candidate in [url,url.appendingPathExtension("backup")] where FileManager.default.fileExists(atPath:candidate.path) { try FileManager.default.removeItem(at:candidate) }
    }
    /// Startup prompt only for a readable snapshot that holds unsaved edits.
    public static func needsPrompt(_ url:URL) -> Bool {
        guard let snapshot=try? read(url) else { return FileManager.default.fileExists(atPath:url.path) }
        return snapshot.unsaved != false
    }
    /// "Start blank" keeps the snapshot as a timestamped copy in `folder`, then clears the
    /// primary so the same prompt does not reappear on every launch. Copies are never pruned.
    @discardableResult public static func archive(_ url:URL,into folder:URL) throws -> [URL] {
        let fm=FileManager.default;try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        var copies:[URL]=[]
        for source in [url,url.appendingPathExtension("backup")] where fm.fileExists(atPath:source.path) {
            let copy=folder.appendingPathComponent(UUID().uuidString+"-"+source.lastPathComponent);try fm.copyItem(at:source,to:copy);copies.append(copy)
        }
        try clear(url);return copies
    }
}
