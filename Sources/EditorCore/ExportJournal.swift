import Foundation
import Darwin

/// Cleanup is limited to a marked, exclusive folder whose recorded directory and volume identities
/// still match. Unverifiable old records are retained; a similar filename alone is never ownership.
public enum ExportJournal {
    public struct Identity: Codable, Sendable, Equatable {
        public let device: UInt64
        public let inode: UInt64
        public let volumeUUID: String?
    }
    public struct Entry: Codable, Sendable, Equatable {
        public let pid: Int32
        public let staging: URL
        public let started: Date
        // Optional fields allow old journals to be decoded without authorizing their deletion.
        public let token: String?
        public let kind: String?
        public let parentIdentity: Identity?
        public let directoryIdentity: Identity?
    }
    public struct Staging: Sendable {
        public let entry: Entry
        public let journalFile: URL?
        public var temporary: URL { entry.staging.appendingPathComponent(entry.token! + ".partial.mp4") }
    }
    public struct SweepReport: Sendable, Equatable {
        public var removed: [URL] = []
        public var bytes: Int64 = 0
        /// Includes active, unavailable, legacy and otherwise unverifiable records.
        public var kept = 0
    }
    private static let marker = ".jianfang-work-owner.json"

    /// Creates the staging folder and journal before AVAssetWriter is allowed to start.
    /// A supplied journal that cannot be saved fails the export rather than losing recovery data.
    public static func prepare(near destination: URL, journal: URL?, pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                               useSystemStaging: Bool = true) throws -> Staging {
        guard let parent = canonicalURL(destination) else { throw posixError() }
        let token = UUID().uuidString
        let area: URL
        if useSystemStaging, let systemArea = AssetStore.stagingDirectory(near: parent) {
            guard let resolved = canonicalURL(systemArea) else { throw posixError() }
            area = resolved
        } else {
            area = parent.appendingPathComponent(".jianfang-export-" + token, isDirectory: true)
            try FileManager.default.createDirectory(at: area, withIntermediateDirectories: false)
        }
        let entry = try mark(area, token: token, kind: "export", pid: pid)
        do {
            var file: URL?
            if let journal {
                try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
                let target = journal.appendingPathComponent(token + ".json")
                try JSONEncoder().encode(entry).write(to: target, options: .withoutOverwriting)
                file = target
            }
            return Staging(entry: entry, journalFile: file)
        } catch {
            var report = SweepReport()
            _ = removeOwned(entry, report: &report)
            throw error
        }
    }

    /// The caller has finished using this specific export. Failed or uncertain cleanup keeps its
    /// journal, including when an external drive disappeared during a handled export failure.
    @discardableResult
    public static func finish(_ staging: Staging) -> SweepReport {
        var report = SweepReport()
        if removeOwned(staging.entry, report: &report) {
            if let file = staging.journalFile { try? FileManager.default.removeItem(at: file) }
        } else { report.kept = 1 }
        return report
    }

    public static func processIsRunning(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    @discardableResult
    public static func sweep(_ folder: URL, isRunning: (Int32) -> Bool = processIsRunning) -> SweepReport {
        var report = SweepReport()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard isRegular(file), let data = try? Data(contentsOf: file),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data), !isRunning(entry.pid) else {
                report.kept += 1; continue
            }
            if removeOwned(entry, report: &report) { try? FileManager.default.removeItem(at: file) }
            else { report.kept += 1 }
        }
        return report
    }

    /// New carrier folders carry the same identity marker. Unmarked folders from older builds are
    /// deliberately left for the OS; process IDs and matching names alone do not authorize deletion.
    public static func createCarrierFolder(in root: URL = FileManager.default.temporaryDirectory,
                                          pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> URL {
        let token = UUID().uuidString
        guard let parent = canonicalURL(root) else { throw posixError() }
        let area = parent.appendingPathComponent("IndependentEditor-\(pid)-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: false)
        _ = try mark(area, token: token, kind: "carrier", pid: pid)
        return area
    }

    public static func sweepCarrierFolders(in root: URL, isRunning: (Int32) -> Bool = processIsRunning) -> Int {
        var count = 0
        guard let canonicalRoot = canonicalURL(root) else { return 0 }
        let folders = (try? FileManager.default.contentsOfDirectory(at: canonicalRoot, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix("IndependentEditor-") {
            let markerURL = folder.appendingPathComponent(marker)
            guard folder.path == canonicalURL(folder)?.path, isRegular(markerURL), let data = try? Data(contentsOf: markerURL),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.kind == "carrier",
                  entry.staging.path == folder.path,
                  !isRunning(entry.pid) else { continue }
            var report = SweepReport()
            if removeOwned(entry, report: &report) { count += 1 }
        }
        return count
    }

    private static func mark(_ area: URL, token: String, kind: String, pid: Int32) throws -> Entry {
        let entry = Entry(pid: pid, staging: area, started: Date(), token: token, kind: kind,
                          parentIdentity: try identity(area.deletingLastPathComponent()), directoryIdentity: try identity(area))
        try JSONEncoder().encode(entry).write(to: area.appendingPathComponent(marker), options: .withoutOverwriting)
        return entry
    }

    /// Foundation may normalize /private/tmp back to its /tmp symlink while directory enumeration
    /// returns /private/tmp. POSIX realpath provides one actual path without reintroducing aliases.
    private static func canonicalURL(_ url: URL) -> URL? {
        guard url.isFileURL, let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private static func identity(_ url: URL) throws -> Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw posixError() }
        return identity(info, at: url)
    }
    private static func identity(_ info: stat, at url: URL) -> Identity {
        Identity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
                 volumeUUID: (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString)
    }
    private static func matches(_ recorded: Identity, _ current: Identity) -> Bool {
        guard recorded.inode == current.inode else { return false }
        if let uuid = recorded.volumeUUID { return current.volumeUUID == uuid }
        return current.volumeUUID == nil && recorded.device == current.device
    }
    private static func isRegular(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    /// Operations are anchored to opened, no-follow directory descriptors. All payloads are direct
    /// regular children; unknown children and symlinks fail closed. No recursive deletion is used.
    private static func removeOwned(_ entry: Entry, report: inout SweepReport) -> Bool {
        guard let token = entry.token, UUID(uuidString: token) != nil,
              let kind = entry.kind, kind == "export" || kind == "carrier",
              let parentIdentity = entry.parentIdentity, let directoryIdentity = entry.directoryIdentity,
              entry.staging.isFileURL else { return false }
        let area = entry.staging, parent = area.deletingLastPathComponent()
        guard parent.path == canonicalURL(parent)?.path else { return false }
        var targetStat = stat()
        if lstat(area.path, &targetStat) == 0 {
            guard area.path == canonicalURL(area)?.path else { return false }
        } else if errno != ENOENT { return false }
        // Only traversal is needed on the parent. macOS may allow access to our replacement
        // directory while denying a read-open of the shared TemporaryItems parent.
        let parentFD = open(parent.path, O_SEARCH | O_NOFOLLOW)
        guard parentFD >= 0 else { return false }
        defer { close(parentFD) }
        var parentStat = stat()
        guard fstat(parentFD, &parentStat) == 0, matches(parentIdentity, identity(parentStat, at: parent)) else { return false }
        let folderFD = openat(parentFD, area.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if folderFD < 0 {
            // Parent is still the recorded volume/directory and this exact staging folder is gone.
            return errno == ENOENT
        }
        defer { close(folderFD) }
        var directoryStat = stat()
        guard fstat(folderFD, &directoryStat) == 0, matches(directoryIdentity, identity(directoryStat, at: area)),
              let markerData = readMarker(folderFD), let recorded = try? JSONDecoder().decode(Entry.self, from: markerData),
              recorded == entry, let names = namesIn(folderFD) else { return false }
        var payloads: [(String, stat)] = []
        for name in names where name != marker {
            var info = stat()
            // FAT volumes store extended attributes in AppleDouble sidecars. Only accept a
            // valid sidecar for our marker or an already allowed task-specific payload.
            let metadata = name.hasPrefix("._") &&
                (name == "._" + marker || allowedPayload(String(name.dropFirst(2)), token: token, kind: kind)) &&
                isAppleDouble(folderFD, name: name)
            guard (allowedPayload(name, token: token, kind: kind) || metadata),
                  fstatat(folderFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG else { return false }
            payloads.append((name, info))
        }
        // Remove sidecars first: deleting their original may cause macOS to remove them too.
        for (name, original) in payloads.sorted(by: { $0.0.hasPrefix("._") && !$1.0.hasPrefix("._") }) {
            var current = stat()
            guard fstatat(folderFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_ino == original.st_ino, current.st_dev == original.st_dev,
                  (current.st_mode & S_IFMT) == S_IFREG, unlinkat(folderFD, name, 0) == 0 else { return false }
            report.removed.append(area.appendingPathComponent(name))
            report.bytes += Int64(current.st_size)
        }
        // Remove the marker last. If the final rmdir fails, restore it so a later retry can verify
        // ownership; any newly added unknown item remains untouched.
        guard unlinkat(folderFD, marker, 0) == 0 else { return false }
        var pathStat = stat()
        if fstatat(parentFD, area.lastPathComponent, &pathStat, AT_SYMLINK_NOFOLLOW) == 0,
           pathStat.st_ino == directoryStat.st_ino, pathStat.st_dev == directoryStat.st_dev,
           unlinkat(parentFD, area.lastPathComponent, AT_REMOVEDIR) == 0 {
            report.removed.append(area)
            return true
        }
        let markerFD = openat(folderFD, marker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if markerFD >= 0 {
            let handle = FileHandle(fileDescriptor: markerFD, closeOnDealloc: true)
            try? handle.write(contentsOf: markerData)
        }
        return false
    }

    private static func readMarker(_ directoryFD: Int32) -> Data? {
        let fd = openat(directoryFD, marker, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0, info.st_size <= 16_384 else { return nil }
        return try? handle.readToEnd()
    }
    private static func isAppleDouble(_ directoryFD: Int32, name: String) -> Bool {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 26, info.st_size <= 65_536 else { return false }
        return (try? handle.read(upToCount: 8)) == Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00])
    }
    private static func namesIn(_ fd: Int32) -> [String]? {
        let copy = dup(fd)
        guard copy >= 0 else { return nil }
        guard let stream = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(stream) }
        var names: [String] = []
        errno = 0
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return errno == 0 ? names : nil
    }
    private static func allowedPayload(_ name: String, token: String, kind: String) -> Bool {
        if kind == "export" {
            let partial = token + ".partial.mp4"
            return name == partial || name.hasPrefix(partial + ".sb-")
        }
        if name.hasPrefix("silence-"), name.hasSuffix(".wav") {
            return UUID(uuidString: String(name.dropFirst(8).dropLast(4))) != nil
        }
        if name.hasPrefix("carrier-"), let suffix = name.range(of: ".mp4") {
            let identifier = String(name[name.index(name.startIndex, offsetBy: 8)..<suffix.lowerBound])
            let ending = String(name[suffix.upperBound...])
            return UUID(uuidString: identifier) != nil && (ending.isEmpty || ending.hasPrefix(".sb-"))
        }
        return false
    }
}
